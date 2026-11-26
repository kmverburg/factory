#!/usr/bin/env bash
# Hourly stuck check (docs/health-check.md, "Stuck tickets and PRs"): finds work the factory dropped without a word
# and retries it once, or hands it to Koen.
#   1. Tickets in Agent Working with no factory run in progress that haven't changed for an hour: back to Agent Ready
#      (a fresh build), or, when the ticket has an open agent PR, a fix round on that PR. Found stuck again within
#      24 hours: Needs Human.
#   2. Open agent PRs (label agent-built) with no verdict label (agent-approved, needs-human, agent-fixing) for an hour
#      and no review running: the review is started again once (factory-review event). Still no verdict an hour
#      later: the ticket goes to Needs Human.
# Runs that are queued or in progress never count as stuck. Retries are remembered by a hidden marker in the comment
# the check leaves on the ticket. If the runs of a repo can't be read, nothing in that repo is touched.
# Usage: stuck.sh [--dry-run]   (or DRY_RUN=1): only prints what it found.
# Env: GH_TOKEN (factory app token), FACTORY_REPO ("owner/repo"), LINEAR_API_KEY.
# Optional: WRANGLER_CONFIG, APPS_FILE, STUCK_NOW (epoch seconds), STUCK_AFTER (seconds, default 3600),
#           STUCK_WINDOW (seconds, default 86400), for tests.
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$here/../.." && pwd)
# shellcheck source=../lib/linear.sh
source "$here/../lib/linear.sh"
# shellcheck source=checks.sh
source "$here/checks.sh"
# shellcheck source=../lib/usage-limit.sh
source "$here/../lib/usage-limit.sh"
[ "$1" = "--dry-run" ] && DRY_RUN=1
: "${FACTORY_REPO:?FACTORY_REPO is required}"
WRANGLER_CONFIG=${WRANGLER_CONFIG:-$ROOT/relay/wrangler.jsonc}
APPS_FILE=${APPS_FILE:-$ROOT/agents/scout/apps.json}
NOW=${STUCK_NOW:-$(date +%s)}
AFTER=${STUCK_AFTER:-3600}
WINDOW=${STUCK_WINDOW:-86400}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
VERDICTS='["agent-approved","needs-human","agent-fixing"]'

epoch() { date -u -d "$1" +%s 2>/dev/null || echo 0; }
say() { echo "$*"; }
act() { [ -z "$DRY_RUN" ]; }

# $1 = run JSON ({id, url, conclusion, status}) or empty. Prints a markdown link with the conclusion.
run_link() {
  if [ -z "$1" ]; then echo "no run found"; return; fi
  jq -r '"[run \(.id), \(.conclusion // .status)](\(.url))"' <<<"$1"
}

# $1 = repo, $2 = run JSON or empty. Prints what is known about why the run stopped, one line (best effort).
run_why() {
  local jobs failed id notes=""
  [ -n "$2" ] || { echo "no run to look at"; return; }
  id=$(jq -r .id <<<"$2")
  jobs=$(gh api "repos/$1/actions/runs/$id/jobs" --jq '[.jobs[] | {id, name, conclusion, step: ([.steps[]? | select(.conclusion == "failure" or .conclusion == "cancelled")][0].name)}]' 2>/dev/null) || jobs="[]"
  failed=$(jq -r '[.[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped")][0] // empty' <<<"$jobs")
  if [ -n "$failed" ]; then
    notes="job \`$(jq -r .name <<<"$failed")\` ended as $(jq -r .conclusion <<<"$failed")"
    [ "$(jq -r '.step // ""' <<<"$failed")" = "" ] || notes="$notes at step \`$(jq -r .step <<<"$failed")\`"
    local msg
    msg=$(gh api "repos/$1/check-runs/$(jq -r .id <<<"$failed")/annotations" --jq '[.[] | select(.annotation_level == "failure") | .message][0] // empty' 2>/dev/null | head -c 300) || msg=""
    [ -z "$msg" ] || notes="$notes; GitHub says: \"${msg//$'\n'/ }\""
  else
    notes="the run ended as $(jq -r '.conclusion // .status' <<<"$2")"
  fi
  echo "$notes"
}

# $1 = runs JSON, $2 = identifier (KV-1). Prints the runs that belong to the ticket: its identifier is in the run's
# title (the caller names dispatch runs "Factory KV-1") or its branch starts with it (pull request and check runs).
runs_of() {
  jq -c --arg id "$2" '[.[] | select(
      ((.title // "") | ascii_upcase | test("(^|[^A-Z0-9])" + $id + "([^0-9]|$)"))
      or ((.branch // "") | ascii_downcase | startswith(($id | ascii_downcase) + "-")))]' <<<"$1"
}

# $1 = repo, $2 = identifier. Prints the open agent PR of the ticket as JSON, or nothing.
pr_of() {
  jq -c --arg id "$2" '[.[] | select((.headRefName | ascii_downcase | startswith(($id | ascii_downcase) + "-")) and (.isDraft | not))][0] // empty' <<<"$PRS"
}

# $1 = repo, $2 = event type, $3 = client_payload JSON. Returns the success of the dispatch.
dispatch() {
  jq -n --arg e "$2" --argjson p "$3" '{event_type: $e, client_payload: $p}' > "$TMP/dispatch.json"
  gh api "repos/$1/dispatches" --input "$TMP/dispatch.json" >/dev/null
}

# $1 = comments JSON [{body, createdAt}], $2 = marker kind. Prints the latest comment with that marker as {createdAt, prev}, or nothing.
last_marker() {
  jq -c --arg k "<!-- stuck-check:$2" '[.[]? | select(.body | contains($k)) | {createdAt, prev: ((.body | capture("prev=(?<u>[^ ]*) -->").u) // "")}] | sort_by(.createdAt) | last // empty' <<<"$1"
}

# $1 = identifier, $2 = comment. Moves the ticket to Needs Human with the comment.
hand_to_koen() {
  linear_comment "$1" "$2"
  linear_set_state "$1" "Needs Human"
  linear_set_group_label "$1" Delivery "Human involved"
}

# $1 = repo, $2 = identifier, $3 = ticket JSON {updatedAt}, $4 = runs JSON. Handles one ticket in Agent Working.
check_ticket() {
  local repo=$1 id=$2 updated=$3 runs=$4 mine active last comments marker pr round link why prev first_link n
  mine=$(runs_of "$runs" "$id")
  active=$(jq -r '[.[] | select(.status != "completed")] | length' <<<"$mine")
  if [ "$active" -gt 0 ]; then say "$id: a run is in progress, left alone."; return; fi
  if [ "$UNATTRIBUTED" -gt 0 ]; then say "$id: a run without a ticket name is in progress in $repo, left alone."; return; fi
  if [ $((NOW - $(epoch "$updated"))) -le "$AFTER" ]; then say "$id: changed less than an hour ago, left alone."; return; fi
  HANDLED+=("$id")
  last=$(jq -c '[.[] | select(.status == "completed")] | sort_by(.created) | last // empty' <<<"$mine")
  link=$(run_link "$last")
  comments=$(linear_issue_comments "$id" 2>/dev/null) || comments="[]"
  if [ -n "$(retry_pending "$comments" "$NOW")" ]; then say "$id: waiting for a retry after Claude's usage limit, left alone."; return; fi
  marker=$(last_marker "$comments" ticket)
  pr=$(pr_of "$repo" "$id")
  if [ -n "$marker" ] && [ $((NOW - $(epoch "$(jq -r .createdAt <<<"$marker")"))) -le "$WINDOW" ]; then
    prev=$(jq -r .prev <<<"$marker")
    why=$(run_why "$repo" "$last")
    say "$id: stuck again ($link); was started again before (${prev:-unknown run}). $(act || echo '[dry run] ')Needs Human."
    act || return 0
    first_link=${prev:+"[first run]($prev)"}
    hand_to_koen "$id" "🏭 Stuck again: the last run stopped without reporting back ($link). It was already started again once in the last 24 hours after an earlier run stopped (${first_link:-run unknown}), so the factory won't retry a second time. Why the runs stopped, as far as known: $why. A human needs to look."
    [ -z "$pr" ] || gh pr edit "$(jq -r .number <<<"$pr")" -R "$repo" --add-label needs-human --remove-label agent-fixing >/dev/null 2>&1 || true
    return
  fi
  if [ -n "$pr" ]; then
    n=$(jq -r .number <<<"$pr")
    round=$(jq -r '[.comments[]?.body | capture("^### 🔧 Builder applied review fixes \\(round (?<n>[0-9]+)\\)").n | tonumber] | max // 0' <<<"$pr")
    say "$id: stuck ($link), PR #$n is open: $(act || echo '[dry run] ')fix round."
    act || return 0
    if dispatch "$repo" factory-fix "$(jq -n --arg pr "$n" --arg r "$round" --arg id "$id" \
      '{pr_number: $pr, round: $r, identifier: $id, feedback: "The previous run for this ticket stopped without reporting back. Continue on this branch: check the pull request, its review comments and failing checks, and finish what the ticket asks for."}')"; then
      gh pr edit "$n" -R "$repo" --add-label agent-fixing >/dev/null 2>&1 || true
      linear_comment "$id" "🏭 The last run stopped without reporting back ($link); starting it again as a fix round on PR #$n.
<!-- stuck-check:ticket prev=$(jq -r '.url // ""' <<<"${last:-null}") -->"
    else
      hand_to_koen "$id" "🏭 The last run stopped without reporting back ($link), and starting a fix round on PR #$n failed (the GitHub dispatch was refused). A human needs to look."
    fi
    return
  fi
  say "$id: stuck ($link), no open PR: $(act || echo '[dry run] ')back to Agent Ready."
  act || return 0
  linear_comment "$id" "🏭 The last run stopped without reporting back ($link); starting it again.
<!-- stuck-check:ticket prev=$(jq -r '.url // ""' <<<"${last:-null}") -->"
  linear_set_state "$id" "Agent Ready"
}

# $1 = repo, $2 = runs JSON. Handles the open agent PRs without a verdict.
check_prs() {
  local repo=$1 runs=$2 round pr n branch id mine active last link comments marker issue state_type state_name prev why
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    n=$(jq -r .number <<<"$pr"); branch=$(jq -r .headRefName <<<"$pr")
    id=$(grep -oiE '^([a-z]+/)?[a-z0-9]+-[0-9]+' <<<"$branch" | sed -E 's#^.*/##' | tr '[:lower:]' '[:upper:]' || true)
    [ -n "$id" ] || continue
    [[ " ${HANDLED[*]} " == *" $id "* ]] && continue
    mine=$(runs_of "$runs" "$id")
    active=$(jq -r '[.[] | select(.status != "completed")] | length' <<<"$mine")
    if [ "$active" -gt 0 ] || [ "$UNATTRIBUTED" -gt 0 ]; then say "PR #$n ($id): a run is in progress, left alone."; continue; fi
    issue=$(linear_issue "$id" 2>/dev/null) || issue=""
    state_type=$(jq -r '.data.issue.state.type // empty' <<<"$issue" 2>/dev/null); state_name=$(jq -r '.data.issue.state.name // empty' <<<"$issue" 2>/dev/null)
    case "$state_type" in completed|canceled|"") continue ;; esac
    if [ "$(tr '[:upper:]' '[:lower:]' <<<"$state_name")" = "needs human" ]; then continue; fi
    # In Conflicts (KV-80): a conflict round is running (the PR is agent-fixing, which has a verdict label anyway) or the
    # conflict is left to Koen on purpose. Never a missing verdict.
    if [ "$(tr '[:upper:]' '[:lower:]' <<<"$state_name")" = "conflicts" ]; then continue; fi
    last=$(jq -c '[.[] | select(.status == "completed")] | sort_by(.created) | last // empty' <<<"$mine")
    link=$(run_link "$last")
    comments=$(linear_issue_comments "$id" 2>/dev/null) || comments="[]"
    if [ -n "$(retry_pending "$comments" "$NOW")" ]; then say "PR #$n ($id): waiting for a retry after Claude's usage limit, left alone."; continue; fi
    marker=$(last_marker "$comments" review)
    if [ -n "$marker" ] && [ $((NOW - $(epoch "$(jq -r .createdAt <<<"$marker")"))) -le "$WINDOW" ]; then
      if [ $((NOW - $(epoch "$(jq -r .createdAt <<<"$marker")"))) -le "$AFTER" ]; then say "PR #$n ($id): the review was started again less than an hour ago, left alone."; continue; fi
      prev=$(jq -r .prev <<<"$marker"); why=$(run_why "$repo" "$last")
      say "PR #$n ($id): still no verdict after the second review. $(act || echo '[dry run] ')Needs Human."
      act || continue
      hand_to_koen "$id" "🏭 PR #$n still has no review verdict an hour after the review was started again. Review runs: ${prev:+[first]($prev), }$link. Why they stopped, as far as known: $why. The factory won't start a third review; a human needs to look at the PR."
      gh pr edit "$n" -R "$repo" --add-label needs-human >/dev/null 2>&1 || true
      continue
    fi
    if [ $((NOW - $(epoch "$(jq -r .updatedAt <<<"$pr")"))) -le "$AFTER" ]; then continue; fi
    say "PR #$n ($id): no verdict for over an hour and no review running. $(act || echo '[dry run] ')Starting the review again."
    act || continue
    round=$(jq -r '[.comments[]?.body | capture("^### 🔧 Builder applied review fixes \\(round (?<n>[0-9]+)\\)").n | tonumber] | max // 0' <<<"$pr")
    if dispatch "$repo" factory-review "$(jq -n --arg pr "$n" --arg r "$round" --arg id "$id" '{pr_number: $pr, round: $r, identifier: $id}')"; then
      linear_comment "$id" "🏭 PR #$n has had no review verdict for over an hour and no review is running (last run: $link); starting the review again.
<!-- stuck-check:review prev=$(jq -r '.url // ""' <<<"${last:-null}") -->"
    else
      echo "::warning::Could not start the review of PR #$n in $repo"
    fi
  done < <(jq -c --argjson v "$VERDICTS" \
    '.[] | select((.isDraft | not) and ((.labels | map(.name)) as $l | ($v | map(. as $x | $l | index($x)) | any | not)))' <<<"$PRS")
}

# Tickets waiting for a retry after Claude's usage limit (agents/retry/retry.sh) are left alone.
# Runs only matter if they are readable: a repo whose runs can't be listed is skipped, never judged.
while IFS=$'\t' read -r repo project _; do
  runs=$(gh api "repos/$repo/actions/workflows/factory.yml/runs?per_page=100" \
    --jq '[.workflow_runs[] | {id, status, conclusion, event, branch: .head_branch, title: .display_title, url: .html_url, created: .created_at}]' 2>/dev/null) \
    || { echo "::warning::$repo: couldn't read the factory runs; skipped."; continue; }
  PRS=$(gh pr list -R "$repo" --state open --label agent-built --limit 100 --json number,headRefName,isDraft,labels,updatedAt,comments 2>/dev/null) \
    || { echo "::warning::$repo: couldn't list the agent PRs; skipped."; continue; }
  # A run started by a dispatch that carries no ticket name (the caller doesn't name its runs yet) could belong to
  # any ticket of the repo, so while one is in progress nothing in the repo counts as stuck.
  UNATTRIBUTED=$(jq -r '[.[] | select(.status != "completed" and .event == "repository_dispatch" and ((.title // "") | test("[A-Za-z0-9]+-[0-9]+") | not))] | length' <<<"$runs")
  HANDLED=()
  ctx=$(linear_project_context "$project" 2>/dev/null) || ctx=""
  project_id=$(jq -r '.id // empty' <<<"$ctx" 2>/dev/null); team_id=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null)
  if [ -z "$project_id" ] || [ -z "$team_id" ]; then echo "::warning::Linear project '$project' not found; skipped $repo."; continue; fi
  tickets=$(linear_issues_in_state "$team_id" "$project_id" "Agent Working" 2>/dev/null) || tickets="[]"
  [ -n "$tickets" ] || tickets="[]"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    check_ticket "$repo" "$(jq -r .identifier <<<"$t")" "$(jq -r .updatedAt <<<"$t")" "$runs"
  done < <(jq -c '.[]' <<<"$tickets")
  # Tickets in Conflicts count as busy while a conflict round is running (the PR has agent-fixing). If that round died
  # before it moved the ticket on, it is handled like a stuck Agent Working ticket; conflicts left to Koen are not touched.
  ctickets=$(linear_issues_in_state "$team_id" "$project_id" "Conflicts" 2>/dev/null) || ctickets="[]"
  [ -n "$ctickets" ] || ctickets="[]"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    cid=$(jq -r .identifier <<<"$t")
    jq -e --arg id "$cid" '.[] | select((.headRefName | ascii_downcase | startswith(($id | ascii_downcase) + "-")) and (.labels | map(.name) | index("agent-fixing")))' <<<"$PRS" >/dev/null || continue
    check_ticket "$repo" "$cid" "$(jq -r .updatedAt <<<"$t")" "$runs"
  done < <(jq -c '.[]' <<<"$ctickets")
  check_prs "$repo" "$runs"
done < <(list_repos)
exit 0
