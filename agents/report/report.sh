#!/usr/bin/env bash
# Weekly factory report: counts last week's tickets (autonomy, origin, lead time, fix rounds, escalations, failed runs)
# from Linear and posts it as a project update on the Factory project, with a health. Claude only words the suggestions.
# Usage: report.sh [--dry-run]   (or DRY_RUN=1: prints the update, posts nothing)
# Env: LINEAR_API_KEY. Optional: REPORT_PROJECT (default "Factory"), REPORT_NOW (epoch seconds), REPORT_NO_LLM=1,
#      REPORT_ISSUES_FILE (recorded issues JSON instead of Linear, for tests; no key needed).
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/linear.sh
source "$here/../lib/linear.sh"
[ "$1" = "--dry-run" ] && DRY_RUN=1
PROJECT=${REPORT_PROJECT:-Factory}
now=${REPORT_NOW:-$(date -u +%s)}
today=$(date -u -d "@$now" +%F)
since=$(date -u -d "@$((now - 14 * 86400))" +%Y-%m-%dT%H:%M:%SZ)

# $1 = team id, $2 = start (ISO). Prints every issue of the team updated since then, in the shape compute.jq reads.
fetch_issues() {
  local after="null" page all="[]" i=0
  while [ "$i" -lt 40 ]; do
    page=$(linear_gql 'query($t: ID!, $s: DateTimeOrDuration!, $a: String) { issues(first: 25, after: $a, filter: { team: { id: { eq: $t } }, updatedAt: { gte: $s } }) { pageInfo { hasNextPage endCursor } nodes { identifier createdAt completedAt labels(first: 50) { nodes { name parent { name } } } history(first: 100) { nodes { createdAt toState { name } } } comments(first: 100) { nodes { createdAt body } } } } }' \
      "$(jq -n --arg t "$1" --arg s "$2" --argjson a "$after" '{t: $t, s: $s, a: $a}')") || return 1
    jq -e '.data.issues.nodes' >/dev/null 2>&1 <<<"$page" || return 1
    all=$(jq -c --argjson p "$page" '. + [$p.data.issues.nodes[] | {identifier, createdAt, completedAt,
      labels: [.labels.nodes[] | {name, group: .parent.name}], history: [.history.nodes[] | {createdAt, to: .toState.name}], comments: .comments.nodes}]' <<<"$all")
    [ "$(jq -r '.data.issues.pageInfo.hasNextPage' <<<"$page")" = true ] || { echo "$all"; return 0; }
    after=$(jq -c '.data.issues.pageInfo.endCursor' <<<"$page"); i=$((i + 1))
  done
  echo "::warning::More than 1000 tickets in two weeks; the report covers only the first 1000" >&2
  echo "$all"
}

if [ -n "$REPORT_ISSUES_FILE" ]; then issues=$(<"$REPORT_ISSUES_FILE"); ctx=""
else
  : "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"
  ctx=$(linear_project_context "$PROJECT") || ctx=""
  team_id=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null) || team_id=""
  [ -n "$team_id" ] || { echo "::error::Linear project '$PROJECT' not found" >&2; exit 1; }
  issues=$(fetch_issues "$team_id" "$since") || { echo "::error::Could not read the tickets from Linear" >&2; exit 1; }
fi
echo "$(jq length <<<"$issues") ticket(s) updated in the last 14 days" >&2

report=$(jq -nc --argjson n "$now" --argjson i "$issues" '{now: $n, issues: $i}' | jq -c -f "$here/compute.jq")

suggestions=""
if [ -z "$REPORT_NO_LLM" ] && command -v claude >/dev/null; then
  p=$(<"$here/prompt.md"); numbers=$(jq -c '{autonomous_pct: .this.autonomous_pct, previous_autonomous_pct: .prev.autonomous_pct, finished: .this.finished,
    escalations: .this.escalations, escalation_reasons: .this.escalation_reasons, round_limit_hit: .this.round_limit_hit,
    failed_runs: .this.failed_runs, failure_causes: .this.failure_causes}' <<<"$report")
  p=${p//\{\{NUMBERS\}\}/$numbers}
  out=$(env -u LINEAR_API_KEY claude -p --max-turns 3 --allowedTools "" <<<"$p" 2>/dev/null) || out=""
  grep -q '^### Suggestions' <<<"$out" && suggestions=$out
  [ -n "$suggestions" ] || echo "::warning::Claude gave no usable suggestions; using the plain ones" >&2
fi
if [ -z "$suggestions" ]; then
  suggestions=$(jq -r '.this as $t | "### Suggestions\n" + (if $t.escalations == 0 then "- No escalations this week, so there is nothing to base a suggestion on."
    else ($t.escalation_reasons[0:3] | map("- \(.count) of \($t.escalations) escalations: \(.reason). Check whether this can be handled without a human.") | join("\n")) end)' <<<"$report")
fi

body=$(jq -nr --argjson r "$report" --arg s "$suggestions" --arg d "$today" '{report: $r, suggestions: $s, date: $d}' | jq -r -f "$here/render.jq")
health=$(jq -r .health <<<"$report")
if [ -n "$DRY_RUN" ]; then
  echo "--- would post as a project update on $PROJECT (health: $health)"; echo "$body"; exit 0
fi
project_id=$(jq -r .id <<<"$ctx")
url=$(linear_project_update_create "$project_id" "$body" "$health") || url=""
if [ -n "$url" ]; then echo "Posted the weekly factory report: $url"
else echo "::error::Could not post the weekly factory report" >&2; exit 1; fi
