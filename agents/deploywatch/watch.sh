#!/usr/bin/env bash
# Deploy watch: after an app repo's deploy workflow finishes on main, compares the hour after the deploy with the 24 hours
# before it (same Workers Logs data as the log scout: error rate, 5xx rate, request time p95). When it got clearly worse it
# opens a revert PR (never merged automatically) linked to a new Linear ticket in Needs Human and comments on the original ticket.
# When the hour passes without problems, the original ticket gets a short "all normal" comment.
# Usage: watch.sh [--dry-run]   (or DRY_RUN=1): prints the comparison and opens/comments nothing.
# Env: GH_TOKEN (the factory app's token, covering all app repos), CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_OBSERVABILITY_TOKEN,
#      LINEAR_API_KEY, GITHUB_OWNER (owner of the repos in apps.json).
# Optional: WATCH_APPS (apps file, default agents/scout/apps.json), WATCH_LOOKBACK_HOURS (default 4: deploys older than
#      that are not judged any more), WATCH_NOW_MS (epoch ms, for tests), WATCH_FETCH (script replacing scout/fetch.sh),
#      WATCH_GIT_BASE (where repos are cloned from, default https://github.com; for tests).
# An app's thresholds are the optional "watch" object in its apps.json entry, on top of defaults.json; "watch": {"enabled": false} skips it.
# Everything is judged once: the original ticket gets a comment holding a marker (<!-- deploy-watch:SHA -->) and later runs skip it.
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
# shellcheck source=../lib/linear.sh
source "$root/agents/lib/linear.sh"
[ "$1" = "--dry-run" ] && DRY_RUN=1
apps_file=${WATCH_APPS:-$root/agents/scout/apps.json}
fetch=${WATCH_FETCH:-$root/agents/scout/fetch.sh}
lookback_h=${WATCH_LOOKBACK_HOURS:-4}
now_ms=${WATCH_NOW_MS:-$(( $(date +%s) * 1000 ))}
WATCH_MS=3600000
BEFORE_MS=86400000
FAILED=0
LABEL=factory-revert
git_base=${WATCH_GIT_BASE:-https://github.com}

# $1 = worker, $2 = from ms, $3 = to ms, $4 = filters JSON. Prints the events, or fails.
events() {
  local raw n
  raw=$(SCOUT_FROM_MS=$2 SCOUT_TO_MS=$3 bash "$fetch" "$1" "$4") || return 1
  n=$(jq '(.result.events.events // .events.events // .events // []) | length' <<<"$raw" 2>/dev/null || echo 0)
  [ "$n" -lt 2000 ] || echo "::warning::A query for $1 hit the 2000-event limit, so its numbers cover only part of the window" >&2
  echo "$raw"
}
REQ='[{"key":"event","operation":"eq","type":"string","value":"request"}]'
ERR='[{"key":"$metadata.level","operation":"eq","type":"string","value":"error"}]'

# $1 = repo (owner/name), $2 = project, $3 = sha, $4 = original ticket id (may be empty), $5 = commit title,
# $6 = result JSON, $7 = deploy url. Opens the Linear ticket and the revert PR. Prints "TICKET_URL PR_URL" (either may be empty).
open_revert() {
  local repo=$1 project=$2 sha=$3 orig=$4 ctitle=$5 result=$6 durl=$7
  local ctx team_id project_id state_id labels origin human orig_title title desc input created tid turl branch dir rtitle pr_url="" parents mflag="" b="${3:0:7}" note=""
  ctx=$(linear_project_context "$project" 2>/dev/null) || ctx=""
  team_id=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null) || team_id=""
  project_id=$(jq -r '.id // empty' <<<"$ctx" 2>/dev/null) || project_id=""
  orig_title=""
  [ -z "$orig" ] || orig_title=$(linear_issue "$orig" 2>/dev/null | jq -r '.data.issue.title // empty' 2>/dev/null) || orig_title=""
  if [ -n "$orig" ] && [ -n "$orig_title" ]; then title="Revert: $orig: $orig_title"; else title="Revert: $(head -c 120 <<<"$ctitle")"; fi
  tid=""; turl=""
  if [ -n "$team_id" ]; then
    state_id=$(jq -r '[.team.states.nodes[] | select((.name | ascii_downcase) == "needs human")][0].id // empty' <<<"$ctx")
    labels=$(jq -c '.team.labels.nodes // []' <<<"$ctx")
    origin=$(linear_group_label_id "$labels" Origin Agent)
    human=$(linear_group_label_id "$labels" Delivery "Human involved")
    [ -n "$state_id" ] || echo "::warning::Linear state 'Needs Human' not found for project '$project'" >&2
    [ -n "$origin" ] || echo "::warning::Linear label 'Origin › Agent' not found for project '$project'" >&2
    desc="Production got worse after the deploy of \`$b\` in \`$repo\`${orig:+ ($orig)}: $ctitle

$(jq -r '.reasons[] | "- \(.)"' <<<"$result")

$(table "$result")

Deploy run: $durl

The factory opened a revert PR for the merge. It is never merged automatically: review it and merge it, or close it if the change isn't the cause."
    input=$(jq -n --arg t "$team_id" --arg ti "$title" --arg d "$desc" --arg s "$state_id" --arg o "$origin" --arg h "$human" --arg p "$project_id" \
      '{teamId: $t, title: $ti, description: $d}
       + (if $s != "" then {stateId: $s} else {} end)
       + {labelIds: ([$o, $h] | map(select(. != "")))}
       + (if $p != "" then {projectId: $p} else {} end)')
    created=$(linear_create_issue "$input" 2>/dev/null) || created=""
    tid=${created%% *}; turl=${created#* }
    [ -n "$tid" ] || echo "::warning::Could not create the Linear ticket for the revert of $b" >&2
  else
    echo "::warning::Linear project '$project' not found or Linear unreachable; no ticket for the revert of $b" >&2
  fi
  if [ -n "$tid" ]; then branch="$(tr '[:upper:]' '[:lower:]' <<<"$tid")-revert-$b"; else branch="factory/revert-$b"; fi
  rtitle="${tid:+$tid: }Revert: $ctitle"

  dir=$(mktemp -d)
  # The token goes in a header, not in the URL, and is masked in the log.
  auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
  echo "::add-mask::${auth#AUTHORIZATION: basic }"
  git_t() { git -C "$dir" -c "http.https://github.com/.extraheader=$auth" -c user.name="factory-agent" -c user.email="factory-agent@users.noreply.github.com" "$@"; }
  if git -c "http.https://github.com/.extraheader=$auth" clone -q --depth 100 --branch main "$git_base/$repo.git" "$dir"; then
    parents=$(git -C "$dir" rev-list --parents -n 1 "$sha" | wc -w)
    [ "$parents" -le 2 ] || mflag="-m 1"
    git_t checkout -q -b "$branch"
    # shellcheck disable=SC2086
    if git_t revert --no-edit $mflag "$sha" >/dev/null 2>&1; then
      if git_t push -q origin "$branch" 2>/dev/null; then
        gh label create "$LABEL" -R "$repo" --color B60205 --description "Revert PR opened by the deploy watch" --force >/dev/null || true
        pr_url=$(gh pr create -R "$repo" --head "$branch" --base main --title "$rtitle" --label "$LABEL" --label needs-human --body \
"Reverts $sha${orig:+ ($orig)}: $ctitle

Production got worse after this change was deployed ($durl):

$(jq -r '.reasons[] | "- \(.)"' <<<"$result")

$(table "$result")

**This PR is never merged automatically.** Merge it to roll the change back, or close it if the change isn't the cause.

Deploy-watch: revert of $sha${tid:+

Linear: $tid}" 2>/dev/null) || pr_url=""
      else note="pushing the revert branch failed"; fi
    else
      git_t revert --abort >/dev/null 2>&1 || true
      note="the revert does not apply cleanly (later changes touch the same code)"
    fi
  else note="cloning $repo failed"; fi
  rm -rf "$dir"
  if [ -z "$pr_url" ]; then
    echo "::warning::No revert PR for $b: $note" >&2
    [ -z "$tid" ] || linear_comment "$tid" "⚠️ The factory could not open a revert PR automatically: $note. Revert \`$sha\` by hand if needed."
  elif [ -n "$tid" ]; then
    linear_comment "$tid" "Revert PR: $pr_url (never merged automatically)"
  fi
  echo "$turl $pr_url"
}

# $1 = result JSON. Prints a markdown table of the numbers.
table() {
  jq -r '"| | 24 h before | watched hour |\n|---|---|---|\n"
    + "| Requests | \(.before.requests) | \(.after.requests) |\n"
    + "| Errors | \(.before.errors) | \(.after.errors) |\n"
    + "| Error rate | \(.before.error_rate * 100 | . * 1000 | round / 1000)% | \(.after.error_rate * 100 | . * 1000 | round / 1000)% |\n"
    + "| 5xx rate | \(.before.rate_5xx * 100 | . * 1000 | round / 1000)% | \(.after.rate_5xx * 100 | . * 1000 | round / 1000)% |\n"
    + "| p95 request time | \(.before.p95_ms) ms | \(.after.p95_ms) ms |"' <<<"$1"
}

# $1 = app JSON, $2 = repo (owner/name), $3 = run JSON {headSha, updatedAt, url}, $4 = end of the watched time (ms), $5 = complete (true/false).
judge() {
  local app_json=$1 repo=$2 run=$3 end_ms=$4 complete=$5
  local project worker cfg sha short t_ms url b_req b_err a_req a_err result status orig msg ctitle marker out
  project=$(jq -r .project <<<"$app_json"); worker=$(jq -r .worker <<<"$app_json")
  cfg=$(jq -c --argjson app "$app_json" '. + ($app.watch // {})' "$here/defaults.json")
  sha=$(jq -r .headSha <<<"$run"); short=${sha:0:7}; url=$(jq -r .url <<<"$run")
  t_ms=$(( $(date -d "$(jq -r .updatedAt <<<"$run")" +%s) * 1000 ))

  b_req=$(events "$worker" $((t_ms - BEFORE_MS)) "$t_ms" "$REQ") || return 1
  b_err=$(events "$worker" $((t_ms - BEFORE_MS)) "$t_ms" "$ERR") || return 1
  a_req=$(events "$worker" "$t_ms" "$end_ms" "$REQ") || return 1
  a_err=$(events "$worker" "$t_ms" "$end_ms" "$ERR") || return 1
  result=$(jq -n -L "$root/agents/scout" -L "$here" --argjson cfg "$cfg" --argjson before_requests "$b_req" --argjson before_errors "$b_err" \
    --argjson after_requests "$a_req" --argjson after_errors "$a_err" -f "$here/compare.jq") || return 1
  status=$(jq -r .status <<<"$result")

  msg=$(gh api "repos/$repo/commits/$sha" --jq .commit.message 2>/dev/null) || msg=""
  ctitle=$(head -n1 <<<"$msg"); [ -n "$ctitle" ] || ctitle="commit $short"
  orig=$(grep -oE '^[A-Z][A-Z0-9]*-[0-9]+' <<<"$ctitle" | head -n1 || true)
  marker="<!-- deploy-watch:$sha -->"

  echo "-- $project: $short \"$ctitle\" deployed $(jq -r .updatedAt <<<"$run")${orig:+ ($orig)}: $status$([ "$complete" = true ] || echo ' (so far: the hour is not over yet)')"
  jq -r '.reasons[]? | "   - \(.)"' <<<"$result"
  table "$result" | sed 's/^/   /'
  if [ -n "$DRY_RUN" ]; then
    case "$status" in
      alert) echo "   Dry run: would open a revert PR for $short, a Needs Human ticket, and comment on ${orig:-(no original ticket)}" ;;
      ok) echo "   Dry run: would comment \"all normal\" on ${orig:-(no original ticket)}" ;;
      *) echo "   Dry run: would comment \"not enough traffic to judge\" on ${orig:-(no original ticket)}" ;;
    esac
    return 0
  fi

  # Judged once: skip when the marker comment is on the original ticket, or a revert PR for this commit exists.
  if [ -n "$orig" ] && linear_has_comment "$orig" "$marker"; then echo "   Already judged"; return 0; fi
  if [ "$status" = alert ] && gh pr list -R "$repo" --label "$LABEL" --state all --limit 100 --json body --jq '.[].body' 2>/dev/null | grep -qF "Deploy-watch: revert of $sha"; then
    echo "   A revert PR for $short exists already"; return 0
  fi

  case "$status" in
    alert)
      out=$(open_revert "$repo" "$project" "$sha" "$orig" "$ctitle" "$result" "$url") || out=""
      echo "   Revert: ${out:-failed}"
      if [ -n "$orig" ]; then
        linear_comment "$orig" "🚨 Production got worse after this deploy ($short). $(jq -r '.reasons | join("; ")' <<<"$result").

Revert ticket: ${out%% *}
Revert PR: ${out#* }

$(table "$result")
$marker"
      fi ;;
    ok)
      [ -z "$orig" ] || linear_comment "$orig" "✅ Watched for an hour after deploy, all normal ($(jq -r '"\(.after.requests) requests, \(.after.errors) errors, p95 \(.after.p95_ms) ms"' <<<"$result")).
$marker" ;;
    *)
      [ -z "$orig" ] || linear_comment "$orig" "ℹ️ Watched for an hour after deploy: $(jq -r '.reasons[0]' <<<"$result").
$marker" ;;
  esac
}

# $1 = app JSON
watch_app() {
  local app_json=$1 project repo workflow runs run t_ms next end_ms complete
  project=$(jq -r .project <<<"$app_json"); repo=$(jq -r .repo <<<"$app_json")
  case "$repo" in */*) ;; *) [ -n "$GITHUB_OWNER" ] && repo="$GITHUB_OWNER/$repo" ;; esac
  if [ "$(jq -r '.watch.enabled | if . == null then true else . end' <<<"$app_json")" = false ]; then echo "== $project: deploy watch is off"; return 0; fi
  workflow=$(jq -r --argjson app "$app_json" '($app.watch.workflow // .workflow)' "$here/defaults.json")
  echo "== $project ($repo, workflow $workflow)"
  if ! runs=$(gh run list -R "$repo" --workflow "$workflow" --branch main --event push --status success --limit 20 --json headSha,updatedAt,url 2>&1); then
    echo "::warning::Could not list the deploy runs of $repo: $(head -c 200 <<<"$runs")"; FAILED=1; return 0
  fi
  # Oldest first; a run counts as a deploy when it finished within the lookback time.
  runs=$(jq -c 'sort_by(.updatedAt)' <<<"$runs")
  while IFS= read -r run; do
    t_ms=$(( $(date -d "$(jq -r .updatedAt <<<"$run")" +%s) * 1000 ))
    [ $(( now_ms - t_ms )) -le $(( lookback_h * 3600000 )) ] || continue
    next=$(jq -r --arg t "$(jq -r .updatedAt <<<"$run")" '[.[] | select(.updatedAt > $t) | .updatedAt][0] // empty' <<<"$runs")
    end_ms=$(( t_ms + WATCH_MS )); complete=true
    if [ -n "$next" ]; then
      next=$(( $(date -d "$next" +%s) * 1000 ))
      if [ "$next" -lt "$end_ms" ]; then echo "-- $(jq -r '.headSha[0:7]' <<<"$run"): a newer deploy came within the hour, so it is judged with that one"; continue; fi
    fi
    if [ "$now_ms" -lt "$end_ms" ]; then
      complete=false; end_ms=$now_ms
      # Real runs wait for the full hour; dry runs show the numbers so far.
      [ -n "$DRY_RUN" ] || { echo "-- $(jq -r '.headSha[0:7]' <<<"$run"): still watching"; continue; }
    fi
    judge "$app_json" "$repo" "$run" "$end_ms" "$complete" || { echo "::warning::Could not judge the deploy in $repo"; FAILED=1; }
  done < <(jq -c '.[]' <<<"$runs")
}

while IFS= read -r app; do
  watch_app "$app" || { echo "::warning::Watching $(jq -r .project <<<"$app") failed"; FAILED=1; }
done < <(jq -c '.[]' "$apps_file")
[ "$FAILED" = 0 ] || { echo "::error::The deploy watch could not check every app (see warnings above)"; exit 1; }
