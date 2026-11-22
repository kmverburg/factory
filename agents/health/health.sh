#!/usr/bin/env bash
# Daily factory health check (docs/health-check.md): runs the checks in checks.sh, then makes one Linear ticket
# per failed check in the Factory project ("Factory health: …", Todo, Origin › Agent, label factory:health).
# A failure that already has an open ticket updates that ticket; a ticket whose problem is gone gets a comment once.
# Usage: health.sh [--dry-run]   (or DRY_RUN=1): prints the results and touches nothing in Linear.
# Env: GH_TOKEN (factory app token), FACTORY_REPO ("owner/repo"), LINEAR_API_KEY, RELAY_URL, HEALTH_CHECK_SECRET,
#      the secrets listed in checks.sh (CLAUDE_CODE_OAUTH_TOKEN, CLOUDFLARE_*, FACTORY_APP_*), APP_TOKEN_OUTCOME.
# Optional: HEALTH_PROJECT (default "Factory"), WRANGLER_CONFIG, APPS_FILE, HEALTH_TODAY (YYYY-MM-DD), for tests.
# Exits 1 only when the results could not be reported (Linear unreachable); failed checks themselves become tickets.
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$here/../.." && pwd)
# shellcheck source=../lib/linear.sh
source "$here/../lib/linear.sh"
# shellcheck source=checks.sh
source "$here/checks.sh"
[ "$1" = "--dry-run" ] && DRY_RUN=1
: "${FACTORY_REPO:?FACTORY_REPO is required}"
RELAY_URL=${RELAY_URL:-https://relay.kmverburg.nl}
HEALTH_PROJECT=${HEALTH_PROJECT:-Factory}
WRANGLER_CONFIG=${WRANGLER_CONFIG:-$ROOT/relay/wrangler.jsonc}
APPS_FILE=${APPS_FILE:-$ROOT/agents/scout/apps.json}
TODAY=${HEALTH_TODAY:-$(date -u +%F)}
LABEL="factory:health"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results.jsonl"; : > "$RESULTS"

# ---------- Run the checks ----------
run_checks() {
  check_secrets
  check_relay
  if [ -n "$GH_TOKEN" ]; then
    export INSTALLED_REPOS; INSTALLED_REPOS=$(gh api --paginate installation/repositories --jq '.repositories[].full_name' 2>/dev/null) || INSTALLED_REPOS=""
    local repo project worker
    while IFS=$'\t' read -r repo project worker; do
      check_github "$repo"
      check_cloudflare "$repo" "$worker"
      check_linear_links "$repo" "$project"
    done < <(list_repos)
  else
    echo "No GitHub token: skipped the GitHub, Cloudflare and Linear link checks (the FACTORY_APP secrets check reports why)." >&2
  fi
  if [ -n "$LINEAR_API_KEY" ]; then check_linear_queries; else echo "No LINEAR_API_KEY: skipped the Linear query checks." >&2; fi
}

# ---------- Report ----------
print_results() {
  jq -r 'if .ok then "ok    \(.id)" else "FAIL  \(.id): \(.title)\n\(.message)" end' "$RESULTS"
}

# $1 = result JSON. Prints the ticket description.
ticket_body() {
  jq -r --arg d "$TODAY" '
    "Found by the daily factory health check (`agents/health/`, see `docs/health-check.md`). Fixing it is up to this ticket; the check only reports.\n\n"
    + "### What is wrong\n\(.message)\n### How to fix\n\(.fix)\n\n"
    + "Health check: `\(.id)`\nHealth status: failing (checked \($d))"' <<<"$1"
}

report() {
  local ctx project_id team_id labels state_id origin label_id open res id existing uuid ident body count=0
  ctx=$(linear_project_context "$HEALTH_PROJECT" 2>/dev/null) || ctx=""
  project_id=$(jq -r '.id // empty' <<<"$ctx" 2>/dev/null); team_id=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null)
  if [ -z "$project_id" ] || [ -z "$team_id" ]; then
    echo "::error::Linear project '$HEALTH_PROJECT' not found or Linear unreachable; the results could not be reported."
    print_results; return 1
  fi
  labels=$(jq -c '.team.labels.nodes // []' <<<"$ctx")
  state_id=$(jq -r '[.team.states.nodes[] | select((.name | ascii_downcase) == "todo")][0].id // empty' <<<"$ctx")
  origin=$(linear_group_label_id "$labels" Origin Agent)
  label_id=$(linear_ensure_label "$team_id" "$LABEL" "$labels")
  [ -n "$state_id" ] || echo "::warning::Linear state 'Todo' not found; new tickets get the team's default state" >&2
  [ -n "$origin" ] || echo "::warning::Label 'Origin › Agent' not found" >&2
  open=$(linear_open_issues_with_label "$team_id" "$project_id" "$LABEL") || { echo "::error::Could not read the open health tickets"; return 1; }

  while IFS= read -r res; do
    id=$(jq -r .id <<<"$res")
    existing=$(jq -c --arg m "Health check: \`$id\`" '[.[] | select(.description | contains($m))][0] // empty' <<<"$open")
    uuid=$(jq -r '.id // empty' <<<"$existing"); ident=$(jq -r '.identifier // empty' <<<"$existing")
    if [ "$(jq -r .ok <<<"$res")" = true ]; then
      # Gone: comment once, then leave the ticket for a human to close.
      [ -n "$uuid" ] || continue
      if jq -e '.description | contains("Health status: failing")' <<<"$existing" >/dev/null; then
        linear_comment_on_id "$uuid" "✅ The daily health check passed on $TODAY: this problem is gone. Close the ticket if you agree; it is not reopened unless the check fails again."
        linear_set_description "$uuid" "$(jq -r '.description | sub("Health status: failing[^\n]*"; "Health status: resolved (checked '"$TODAY"')")' <<<"$existing")"
        echo "$ident: problem '$id' is gone, commented"
      fi
      continue
    fi
    body=$(ticket_body "$res")
    if [ -n "$uuid" ]; then
      linear_set_description "$uuid" "$body"
      echo "$ident: still failing '$id', updated"
      continue
    fi
    local input created
    input=$(jq -n --arg t "$team_id" --arg ti "Factory health: $(jq -r .title <<<"$res")" --arg d "$body" --arg s "$state_id" --arg o "$origin" --arg l "$label_id" --arg p "$project_id" \
      '{teamId: $t, title: $ti, description: $d, projectId: $p, labelIds: ([$o, $l] | map(select(. != "")))}
       + (if $s != "" then {stateId: $s} else {} end)')
    created=$(linear_create_issue "$input" 2>/dev/null) || created=""
    if [ -n "$created" ]; then echo "created $created for '$id'"; count=$((count + 1)); else echo "::error::Could not create the ticket for '$id'"; FAILED=1; fi
  done < <(jq -c . "$RESULTS")
  return "${FAILED:-0}"
}

run_checks
print_results
failures=$(jq -s '[.[] | select(.ok | not)] | length' "$RESULTS")
echo "$failures of $(jq -s length "$RESULTS") checks failed."
if [ -n "$DRY_RUN" ]; then echo "Dry run: no tickets created or updated."; exit 0; fi
report
