#!/usr/bin/env bash
# Daily secret scan (docs/secret-scan.md): looks for leaked secrets in the last day's GitHub Actions logs of every repo,
# Cloudflare Workers Builds logs and new commits on every branch, and files one high-priority ticket per leak.
# Usage: scan.sh [--dry-run]   (or DRY_RUN=1): prints what it found (never the secret) and touches nothing in Linear or GitHub.
# Env: GH_TOKEN (factory app token), FACTORY_REPO ("owner/repo"), LINEAR_API_KEY, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_BUILDS_TOKEN,
#      and the current secrets (names in match.py), which are only compared as hashes.
# Optional: SCAN_PROJECT (default "Factory"), SCAN_SINCE (ISO time, default 24 hours ago), SCAN_MAX_TICKETS (default 10),
#      WRANGLER_CONFIG, APPS_FILE, for tests.
# Never prints a secret: only where it was found, which type, and a fingerprint of the place.
# Exits 1 only when a leak was found but could not be reported.
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$here/../.." && pwd)
# shellcheck source=../lib/linear.sh
source "$here/../lib/linear.sh"
# shellcheck source=../lib/issue-writer.sh
source "$here/../lib/issue-writer.sh"
# shellcheck source=../health/checks.sh
source "$here/../health/checks.sh"   # list_repos, bearer_get
[ "$1" = "--dry-run" ] && DRY_RUN=1
: "${FACTORY_REPO:?FACTORY_REPO is required}"
SCAN_PROJECT=${SCAN_PROJECT:-Factory}
SCAN_SINCE=${SCAN_SINCE:-$(date -u -d '24 hours ago' +%FT%TZ)}
SCAN_MAX_TICKETS=${SCAN_MAX_TICKETS:-10}
WRANGLER_CONFIG=${WRANGLER_CONFIG:-$ROOT/relay/wrangler.jsonc}
APPS_FILE=${APPS_FILE:-$ROOT/agents/scout/apps.json}
MATCH=${SCAN_MATCH:-$here/match.py}
MAX_RUNS=100; MAX_COMMITS=200; MAX_BYTES=30000000
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FINDINGS="$TMP/findings.jsonl"; : > "$FINDINGS"

# $1 = key (stable id of the place), $2 = place as text for the ticket. Reads text on stdin and records one finding per secret type.
scan_text() {
  local key=$1 where=$2 hit
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    jq -nc --arg k "$key" --arg w "$where" --argjson h "$hit" \
      '{key: $k, where: $w, type: $h.type, how: $h.how} | .fp = ""' >> "$FINDINGS"
  done < <(head -c "$MAX_BYTES" | python3 -I "$MATCH" 2>/dev/null || true)
}

# ---------- Sources ----------

scan_actions_logs() { # $1 = repo
  local repo=$1 id n=0 zip="$TMP/log.zip"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    if gh api "repos/$repo/actions/runs/$id/logs" > "$zip" 2>/dev/null && [ -s "$zip" ]; then
      unzip -p "$zip" 2>/dev/null | scan_text "actions:$repo:$id" "the GitHub Actions log of run https://github.com/$repo/actions/runs/$id" || true
    fi
  done < <(gh api "repos/$repo/actions/runs?created=%3E%3D$SCAN_SINCE&per_page=$MAX_RUNS" --jq '.workflow_runs[].id' 2>/dev/null | head -n "$MAX_RUNS" || true)
  echo "scanned the logs of $n Actions run(s) in $repo" >&2
}

scan_commits() { # $1 = repo
  local repo=$1 branch sha branches seen="$TMP/seen" n=0
  : > "$seen"
  branches=$(gh api --paginate "repos/$repo/branches" --jq '.[].name' 2>/dev/null) || { echo "::warning::Could not list the branches of $repo" >&2; return 0; }
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      grep -qx "$sha" "$seen" && continue
      echo "$sha" >> "$seen"
      n=$((n + 1)); [ "$n" -le "$MAX_COMMITS" ] || break 2
      # The diff has the message in the commit's own patch header only for patches; take the message separately.
      {
        gh api "repos/$repo/commits/$sha" -H 'Accept: application/vnd.github.diff' 2>/dev/null | grep -E '^\+' || true
        gh api "repos/$repo/commits/$sha" --jq '.commit.message' 2>/dev/null || true
      } | scan_text "commit:$repo:$sha" "the commit https://github.com/$repo/commit/$sha (found on branch \`$branch\`)"
    done < <(gh api --paginate "repos/$repo/commits?sha=$(jq -rn --arg b "$branch" '$b|@uri')&since=$SCAN_SINCE&per_page=100" --jq '.[].sha' 2>/dev/null || true)
  done <<<"$branches"
  echo "scanned $n new commit(s) in $repo" >&2
}

scan_builds() { # $1 = repo, $2 = worker
  local repo=$1 worker=$2 base res code file tag id n=0
  [ -n "$worker" ] || return 0
  if [ -z "$CLOUDFLARE_BUILDS_TOKEN" ] || [ -z "$CLOUDFLARE_ACCOUNT_ID" ]; then echo "skipped the Workers Builds logs of $repo: no Cloudflare builds token" >&2; return 0; fi
  [[ "$CLOUDFLARE_ACCOUNT_ID" =~ ^[0-9a-fA-F]+$ ]] || return 0
  base="https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID"
  res=$(bearer_get "$CLOUDFLARE_BUILDS_TOKEN" "$base/workers/scripts?per_page=100"); code=${res%%$'\t'*}; file=${res#*$'\t'}
  tag=$(jq -r --arg w "$worker" '[.result[]? | select(.id == $w) | .tag][0] // empty' "$file" 2>/dev/null)
  if [ "$code" != 200 ] || [ -z "$tag" ]; then echo "skipped the Workers Builds logs of $repo: the Worker $worker could not be looked up (HTTP $code)" >&2; return 0; fi
  res=$(bearer_get "$CLOUDFLARE_BUILDS_TOKEN" "$base/builds/workers/$tag/builds?per_page=50"); code=${res%%$'\t'*}; file=${res#*$'\t'}
  if [ "$code" != 200 ]; then echo "skipped the Workers Builds logs of $repo: Cloudflare did not list the builds (HTTP $code)" >&2; return 0; fi
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9a-fA-F-]{8,}$ ]] || continue
    n=$((n + 1))
    res=$(bearer_get "$CLOUDFLARE_BUILDS_TOKEN" "$base/builds/builds/$id/logs"); code=${res%%$'\t'*}; file=${res#*$'\t'}
    [ "$code" = 200 ] || continue
    jq -r '.result.lines // [] | .[] | if type == "array" then (.[1] // .[0] | tostring) else tostring end' "$file" 2>/dev/null \
      | scan_text "build:$worker:$id" "the Cloudflare Workers Builds log of build \`$id\` of the Worker \`$worker\` (dashboard: Workers & Pages → $worker → Builds)"
  done < <(jq -r --arg s "$SCAN_SINCE" '(.result.builds? // .result // [])[]? | select((.created_on // "") >= $s) | .build_uuid // .id // empty' "$file" 2>/dev/null)
  echo "scanned the logs of $n Workers Build(s) of $worker" >&2
}

# GitHub's own secret scanning and push protection: turn them on for public repos where the app may; list what Koen has to do.
ensure_github_scanning() { # $1 = repo. Prints the repo when it could not be switched on.
  local repo=$1 info state
  info=$(gh api "repos/$repo" 2>/dev/null) || { echo "$repo (could not read the settings)"; return 0; }
  if [ "$(jq -r '.private' <<<"$info")" != false ]; then
    echo "$repo is private: GitHub secret scanning there needs GitHub Advanced Security" >&2; return 0
  fi
  state=$(jq -r '[.security_and_analysis.secret_scanning.status, .security_and_analysis.secret_scanning_push_protection.status] | join(" ")' <<<"$info")
  [ "$state" = "enabled enabled" ] && return 0
  [ -n "$DRY_RUN" ] && { echo "would turn on GitHub secret scanning and push protection in $repo (now: $state)" >&2; return 0; }
  if gh api -X PATCH "repos/$repo" --input - >/dev/null 2>&1 <<<'{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'; then
    echo "turned on GitHub secret scanning and push protection in $repo" >&2
  else
    echo "$repo"
  fi
}

# ---------- Report ----------

# $1 = secret type, $2 = how ("format" or "value:NAME"). Prints the rotation steps as a JSON array.
rotation_steps() {
  jq -nc --arg t "$1" --arg h "$2" '
    ($h | sub("^value:"; "")) as $name
    | (if $h | startswith("value:") then ["The leaked value is the current `\($name)`."] else ["The text looks like a \($t) (it may be one the factory does not use; check before rotating)."] end) as $intro
    | ({"GitHub token": ["Revoke it: for a personal token GitHub → Settings → Developer settings → Tokens → Delete; an app installation token expires by itself within an hour, so check that it has.",
         "If it was the app key, GitHub → Settings → Developer settings → GitHub Apps → the factory app → Private keys → generate a new key and delete the old one."],
       "Linear API key": ["Linear → Settings → Account → Security & access → revoke the leaked key and create a new one."],
       "Claude token": ["Run `claude setup-token` for a new token; the old one stops working when you sign it out of the account (claude.ai → Settings → Claude Code, revoke the session)."],
       "Cloudflare token": ["Cloudflare dashboard → My Profile → API Tokens → the token → Roll (or delete it and create a new one with the same permissions)."],
       "Private key": ["Generate a new key pair (for the factory GitHub App: its settings → Private keys → Generate, then delete the old key), and revoke the leaked key everywhere it was trusted."],
       "Linear webhook secret": ["Linear → Settings → API → Webhooks → the factory webhook → regenerate the signing secret."],
       "Health check secret": ["Make a new random string (16+ characters)."]}[$t] // ["Revoke the secret at the service that issued it and create a new one."]) as $svc
    | $intro + $svc + [
        (if ($name | length) > 0 and $h != "format" then "In Infisical (project `factory`, environment `prod`) replace `\($name)` with the new value in the folder named in the README'"'"'s *Secrets* table (`/shared` for most); the sync updates GitHub and Cloudflare." else "In Infisical (project `factory`, environment `prod`) replace the matching secret from the README'"'"'s *Secrets* table with the new value; the sync updates GitHub and Cloudflare." end),
        "Delete the leak where you can: delete the Actions run logs (Actions → the run → ⋯ → Delete all logs) or remove the commit from the branch (and tell GitHub support to purge it if it was ever on a public branch). Deleting does not make the old secret safe again: rotating does.",
        "Check the service'"'"'s audit log for use of the old secret since it leaked."]'
}

report() {
  local ctx project_id team_id n=0 f spec steps skipped=0 created
  ctx=$(linear_project_context "$SCAN_PROJECT" 2>/dev/null) || ctx=""
  project_id=$(jq -r '.id // empty' <<<"$ctx" 2>/dev/null); team_id=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null)
  if [ -z "$project_id" ] || [ -z "$team_id" ]; then
    echo "::error::Linear project '$SCAN_PROJECT' not found or Linear unreachable; the leaks above could not be reported."; return 1
  fi
  local label_id
  label_id=$(linear_ensure_label "$team_id" "factory:secret-leak" "$(jq -c '.team.labels.nodes // []' <<<"$ctx")")
  if [ -n "$label_id" ] && [ -z "$(jq -r '[.team.labels.nodes[] | select(.name == "factory:secret-leak")][0].id // empty' <<<"$ctx")" ]; then
    ctx=$(jq -c --arg id "$label_id" '.team.labels.nodes += [{id: $id, name: "factory:secret-leak", parent: null}]' <<<"$ctx")
  fi
  while IFS= read -r f; do
    n=$((n + 1))
    if [ "$n" -gt "$SCAN_MAX_TICKETS" ]; then skipped=$((skipped + 1)); continue; fi
    steps=$(rotation_steps "$(jq -r .type <<<"$f")" "$(jq -r .how <<<"$f")")
    spec=$(jq -c --argjson s "$steps" '
      {title: "Secret leak: \(.type) in \(.key | split(":") | .[0:2] | join(" "))",
       origin: "Agent", state: "todo", priority: 2, labels: ["factory:secret-leak"],
       dedup_marker: "Leak: `secretleak-\(.fp)`",
       dedup_comment: "The daily secret scan found this leak again (\(.where)). Not reported twice; rotate it.",
       goal: "The daily secret scan (`agents/secrets/`, see `docs/secret-scan.md`) found a **\(.type)** in \(.where). \(if .how == "format" then "It matches the format of that kind of secret." else "It equals the current value of `\(.how | sub("^value:"; ""))` (compared as hashes only)." end) **The secret is deliberately not repeated here**; do not paste it into this ticket or a comment.",
       acceptance: $s,
       out_of_scope: ["Rotating secrets automatically."],
       footer: "Leak: `secretleak-\(.fp)`\nFound by the secret scan on \(now | strftime("%Y-%m-%d")) (window starts \($since))."}' --arg since "$SCAN_SINCE" <<<"$f")
    created=$(issue_write "$spec" "$ctx" 2>/dev/null | sed -n 's/^\(created\|duplicate\) //p') || created=""
    if [ -n "$created" ]; then echo "ticket for $(jq -r .type <<<"$f") ($(jq -r .key <<<"$f" | cut -d: -f1)): ${created%% *}"; else echo "::error::Could not create the ticket for a leak in $(jq -r .key <<<"$f" | cut -d: -f1)"; FAILED=1; fi
  done < <(jq -c . "$FINDINGS")
  [ "$skipped" -eq 0 ] || echo "::warning::$skipped more leak(s) not ticketed (limit $SCAN_MAX_TICKETS per run); they are in the run log (places only)."
  return "${FAILED:-0}"
}

# ---------- Main ----------

if [ -z "$GH_TOKEN" ]; then echo "::error::No GitHub token: nothing could be scanned."; exit 1; fi
need_koen=()
while IFS=$'\t' read -r repo _project worker; do
  scan_actions_logs "$repo"
  scan_commits "$repo"
  scan_builds "$repo" "$worker"
  while IFS= read -r line; do [ -n "$line" ] && need_koen+=("$line"); done < <(ensure_github_scanning "$repo")
done < <(list_repos)

# The same leak in the same place with the same type is one finding; its fingerprint does not contain the secret.
jq -s -c '[.[]] | unique_by([.key, .type]) | .[]' "$FINDINGS" > "$TMP/unique.jsonl"
while IFS= read -r line; do
  fp=$(jq -r '"\(.key)|\(.type)"' <<<"$line" | sha256sum | cut -c1-16)
  jq -c --arg fp "$fp" '.fp = $fp' <<<"$line"
done < "$TMP/unique.jsonl" > "$FINDINGS"

count=$(jq -s length "$FINDINGS")
echo "$count leak(s) found."
jq -r '"LEAK  \(.type) (\(.how | split(":")[0])) in \(.where)  [secretleak-\(.fp)]"' "$FINDINGS"
status=0
if [ -n "$DRY_RUN" ]; then echo "Dry run: no tickets created."
elif [ "$count" -gt 0 ]; then report || status=1; fi

if [ "${#need_koen[@]}" -gt 0 ]; then
  echo "GitHub secret scanning could not be switched on by the app for: ${need_koen[*]}"
  echo "Koen: Settings → Code security → turn on Secret protection (secret scanning) and Push protection in each repo, or grant the app Administration: Read and write."
  if [ -z "$DRY_RUN" ] && [ -n "$LINEAR_API_KEY" ]; then
    ctx=$(linear_project_context "$SCAN_PROJECT" 2>/dev/null) || ctx=""
    spec=$(jq -nc --arg r "${need_koen[*]}" '{title: "Turn on GitHub secret scanning and push protection", origin: "Agent", state: "todo", manual: true, dedup: true,
      goal: "The daily secret scan could not turn on GitHub secret scanning and push protection itself for: \($r). They are free for public repos.",
      steps: ["Open each repo on GitHub → Settings → Advanced Security (Code security).", "Turn on Secret protection (secret scanning) and Push protection.", "Or give the factory GitHub App *Administration: Read and write* so the daily scan can do it."],
      acceptance: ["Secret scanning and push protection are on in every repo listed."], out_of_scope: ["Private repos that would need GitHub Advanced Security."],
      footer: "Created by the secret scan (`agents/secrets/scan.sh`)."}')
    [ -z "$ctx" ] || issue_write "$spec" "$ctx" >/dev/null 2>&1 || true
  fi
fi
exit $status
