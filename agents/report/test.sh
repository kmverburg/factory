#!/usr/bin/env bash
# Tests for the weekly factory report with recorded tickets (no network, no Claude). Usage: bash agents/report/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
now=$(date -u -d 2026-11-23T08:00:00Z +%s)   # a Monday; this week = 16 to 23 Nov, the week before = 9 to 16 Nov

L() { jq -nc --arg g "$1" --arg n "$2" '{group: $g, name: $n}'; }
cat > "$tmp/issues.json" <<J
[
 {"identifier":"KV-1","createdAt":"2026-11-17T08:00:00.000Z","completedAt":"2026-11-18T08:00:00.000Z",
  "labels":[$(L Delivery Autonomous),$(L Origin Agent)],"history":[{"createdAt":"2026-11-18T02:00:00.000Z","to":"Agent Ready"}],
  "comments":[{"createdAt":"2026-11-18T03:00:00.000Z","body":"🔧 Reviewer asked for fixes on https://x/pull/1 (round 1 of 2). The builder is on it:\n\n- a"}]},
 {"identifier":"KV-2","createdAt":"2026-11-10T08:00:00.000Z","completedAt":"2026-11-20T08:00:00.000Z",
  "labels":[$(L Delivery "Human involved"),$(L Origin Human)],"history":[{"createdAt":"2026-11-19T08:00:00.000Z","to":"Agent Ready"},{"createdAt":"2026-11-10T08:00:00.000Z","to":"Agent Ready"}],
  "comments":[
   {"createdAt":"2026-11-18T09:00:00.000Z","body":"🙋 Reviewer agent wants you to look at https://x/pull/2\n\n- Dev-only dependency update, 3 files\n- Still needs fixes after 2 automatic rounds.\n"},
   {"createdAt":"2026-11-18T10:00:00.000Z","body":"💥 The factory build failed. Logs: https://x/runs/9\n\nClaude reported:\n\`\`\`\nRate limit hit at 12:00\n\`\`\`"}]},
 {"identifier":"KV-3","createdAt":"2026-11-11T08:00:00.000Z","completedAt":"2026-11-12T08:00:00.000Z",
  "labels":[$(L Delivery Autonomous),$(L Origin Agent)],"history":[{"createdAt":"2026-11-11T20:00:00.000Z","to":"Agent Ready"}],"comments":[]},
 {"identifier":"KV-4","createdAt":"2026-11-01T08:00:00.000Z","completedAt":null,"labels":[],"history":[],"comments":[]}
]
J
out=$(REPORT_ISSUES_FILE="$tmp/issues.json" REPORT_NOW=$now REPORT_NO_LLM=1 bash "$here/report.sh" --dry-run 2>/dev/null)
rep=$(jq -nc --argjson n "$now" --slurpfile i "$tmp/issues.json" '{now: $n, issues: $i[0]}' | jq -c -f "$here/compute.jq")
q() { jq -r "$1" <<<"$rep"; }
check "finished this week" 2 "$(q .this.finished)"
check "autonomous share" 50 "$(q .this.autonomous_pct)"
check "autonomous share last week" 100 "$(q .prev.autonomous_pct)"
check "ideas from Agent (created this week)" 1 "$(q .this.ideas_agent)"
check "lead time median, hours" 15 "$(q .this.lead_time_median_hours)"
check "slowest lead time, hours" 24 "$(q .this.lead_time_slowest_hours)"
check "slowest ticket" KV-2 "$(q .this.slowest_ticket)"
check "fix rounds per ticket" 0.5 "$(q .this.fix_rounds_per_ticket)"
check "round limit hit" 1 "$(q .this.round_limit_hit)"
check "escalation reason, numbers normalised" "Dev-only dependency update, N files" "$(q '.this.escalation_reasons[0].reason')"
check "failure cause" "Rate limit hit at N:N" "$(q '.this.failure_causes[0].reason')"
check "health: failed runs up and autonomous down" atRisk "$(q .health)"
check "previous week has no failures" 0 "$(q .prev.failed_runs)"
grep -q '^\*\*Health: at risk\|^\*\*Health: off track' <<<"$out" && ok=1 || ok=0
check "dry run prints the update" 1 "$ok"
grep -q '^### Suggestions' <<<"$out" && ok=1 || ok=0
check "dry run has suggestions" 1 "$ok"
check "dry run posts nothing" 0 "$(grep -c 'Posted' <<<"$out" || true)"

empty=$(jq -nc --argjson n "$now" '{now: $n, issues: []}' | jq -c -f "$here/compute.jq")
check "empty: on track" onTrack "$(jq -r .health <<<"$empty")"
check "empty: no division by zero" null "$(jq -c .this.autonomous_pct <<<"$empty")"
exit $fail
