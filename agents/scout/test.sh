#!/usr/bin/env bash
# Tests for the log scout: grouping, masking, deduplication and dry run, using recorded fixture data.
# Usage: bash agents/scout/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0
check() { # $1 = name, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi
}
groups=$(bash "$here/group.sh" < "$here/fixtures/response.json")

check "groups: events with only line numbers/emails/ids differing are merged" 4 "$(jq length <<<"$groups")"
check "groups: biggest group first with its count" 3 "$(jq '.[0].count' <<<"$groups")"
check "groups: first seen" "2025-10-09T08:53:20Z" "$(jq -r '.[0].first_seen' <<<"$groups")"
check "groups: last seen" "2025-10-09T08:56:40Z" "$(jq -r '.[0].last_seen' <<<"$groups")"
check "groups: top frame without line numbers" "at getTrip (file:///worker/src/trips.ts)" "$(jq -r '.[0].frame' <<<"$groups")"
check "groups: signatures are unique" 4 "$(jq '[.[].signature] | unique | length' <<<"$groups")"
check "groups: signature is stable across runs" "$(jq -r '.[0].signature' <<<"$groups")" "$(bash "$here/group.sh" < "$here/fixtures/response.json" | jq -r '.[0].signature')"
check "groups: empty response gives no groups" "[]" "$(echo '{"result":{"events":{"events":[]}}}' | bash "$here/group.sh" | jq -c .)"

# Masking
all=$(jq -c . <<<"$groups")
for secret in jane@example.com bob@example.com abcDEF1234567890xyz sk_live_ABCDEFGHIJKLMNOP; do
  check "masking: '$secret' is gone" 0 "$(grep -cF "$secret" <<<"$all" || true)"
done
check "masking: email replaced" 1 "$(jq '[.[] | select(.sample.message | contains("[email]"))] | length > 0 | if . then 1 else 0 end' <<<"$groups")"
check "masking: bearer token replaced" 1 "$(jq '[.[] | select(.sample.message | contains("[token]"))] | length | if . > 0 then 1 else 0 end' <<<"$groups")"

# Deduplication: an open ticket holding a signature absorbs that group.
sig=$(jq -r '.[0].signature' <<<"$groups")
open=$(jq -nc --arg s "$sig" '[{id: "u1", identifier: "KOE-1", description: ("text\n\nSignature: `" + $s + "`")}, {id: "u2", identifier: "KOE-2", description: "other"}]')
plan=$(jq -nc --argjson groups "$groups" --argjson open "$open" -f "$here/dedup.jq")
check "dedup: matched group becomes a comment" "KOE-1" "$(jq -r '.existing[0].issue.identifier' <<<"$plan")"
check "dedup: one existing" 1 "$(jq '.existing | length' <<<"$plan")"
check "dedup: others are new" 3 "$(jq '.new | length' <<<"$plan")"

# Dry run: prints tickets (at most 3), never calls Linear (no key set, curl would fail).
out=$(env -u LINEAR_API_KEY SCOUT_APPS="$here/fixtures/apps.json" SCOUT_NO_LLM=1 SAMPLE_FILE="$here/fixtures/response.json" bash "$here/scout.sh" --dry-run)
check "dry run: at most 3 tickets" 3 "$(grep -c '^--- would create' <<<"$out")"
check "dry run: signature in ticket" 1 "$(grep -c "Signature: \`$sig\`" <<<"$out")"
check "dry run: sample is in a code block" 1 "$(grep -c '^### Sample' <<<"$out" | awk '{print ($1 > 0)}')"
check "dry run: no raw email" 0 "$(grep -c 'example.com' <<<"$out" || true)"
inj=$(jq -c '{result: {events: {events: [.result.events.events[5]]}}}' "$here/fixtures/response.json")
inj_file=$(mktemp); echo "$inj" > "$inj_file"
out=$(env -u LINEAR_API_KEY SCOUT_APPS="$here/fixtures/apps.json" SCOUT_NO_LLM=1 SAMPLE_FILE="$inj_file" bash "$here/scout.sh" --dry-run); rm -f "$inj_file"
check "dry run: injected text stays inside a code block" 1 "$(awk '/^```/{b=!b} /ignore previous/ && !/^--- would/{print b}' <<<"$out" | head -n1)"
check "dry run: backticks in logs cannot close the code block" 0 "$(grep -v "^--- would" <<<"$out" | grep -c "Agent Ready \`\`\`" || true)"

# Signals: counting, thresholds, week-over-week, report. Fixture events: 30 slow trip requests (p95 3.2 s, 3 of them 404),
# 25 fast pings, 3 imports from one host (1 failed), 25 warnings, 3 no-change AI requests (2 about a shopping list).
ev="$here/fixtures/events.json"
metric() { jq -n -L "$here" --argjson signal "$1" --argjson events "$(cat "$ev")" -f "$here/metrics.jq" -c; }
sigs=$(jq -c '.[]' "$here/signals.json")
slow=$(metric "$(sed -n 1p <<<"$sigs")")
check "metrics: p95 per route, ids normalised" 3230 "$(jq -s '.[] | select(.group == "/api/trips/N") | .value' <<<"$slow")"
check "metrics: a second route is its own row" 2 "$(jq -s length <<<"$slow")"
rate=$(metric "$(sed -n 2p <<<"$sigs")")
check "metrics: 4xx rate is a share of the route's requests" 0.1 "$(jq -s '.[] | select(.group == "/api/trips/N") | .value' <<<"$rate")"
imp='{"name":"imp","filters":[{"key":"event","operation":"eq","value":"job_import"}],"where":[{"key":"ok","operation":"eq","value":false}],"by":"host","measure":"count","expect":["never.example"]}'
check "metrics: boolean where, by host" 1 "$(metric "$imp" | jq -s '.[] | select(.group == "example.org") | .value')"
check "metrics: expected group with no events reports zero" 0 "$(metric "$imp" | jq -s '.[] | select(.group == "never.example") | .value')"
check "metrics: events that do not exist report zero" "0 0" "$(metric '{"name":"x","filters":[{"key":"event","operation":"eq","value":"nope"}],"measure":"p95","field":"ms"}' | jq -rs '"\(.[0].value) \(.[0].n)"')"
M=$(while IFS= read -r s; do metric "$s"; done <<<"$sigs" | jq -s .)
F=$(jq -n -L "$here" --argjson metrics "$M" --argjson prev null -f "$here/evaluate.jq")
check "evaluate: thresholds only without last week" "Slow requests (p95 ms) › /api/trips/N|Warnings › Slow upstream took N ms" "$(jq -r 'map(.id) | join("|")' <<<"$F")"
F2=$(jq -n -L "$here" --argjson metrics "$M" --argjson prev "$(cat "$here/fixtures/prev.json")" -f "$here/evaluate.jq")
check "evaluate: worse than last week is flagged with the old value" "1000 ms" "$(jq -r '.[] | select(.group == "/api/trips/N") | .previous_display' <<<"$F2")"
check "evaluate: unchanged signals are not flagged" 0 "$(jq '[.[] | select(.group == "/api/ping")] | length' <<<"$F2")"
check "evaluate: ticket:false signals are never flagged" 0 "$(jq -n -L "$here" --argjson metrics '[{"id":"u","signal":"u","group":"","ticket":false,"direction":"above","threshold":1,"n":9,"min_count":1,"value":9,"unit":"","floor":1,"worse_pct":50}]' --argjson prev null -f "$here/evaluate.jq" | jq length)"
report=$(jq -n -L "$here" --argjson metrics "$M" --argjson prev "$(cat "$here/fixtures/prev.json")" --argjson findings "$F2" --arg date 2025-10-13 -f "$here/report.jq")
check "report: change vs last week in the table" 1 "$(jq -r '.table' <<<"$report" | grep -c '/api/trips/N | 3230 ms | 30 | 1000 ms | +223%' || true)"
check "report: used last week, not this week" "used last week, not this week" "$(jq -r '.summary.quiet[0].why' <<<"$report")"
check "report: health follows the number of findings" atRisk "$(jq -r .health <<<"$report")"

# Dry run with signals: numbers, tickets (max 3 in total, errors first), report, no Linear, no raw email.
run() { env -u LINEAR_API_KEY SCOUT_APPS="$here/fixtures/apps-signals.json" SCOUT_NO_LLM=1 SAMPLE_SHIPPED_FILE="$here/fixtures/shipped.json" SAMPLE_FILE="$here/fixtures/response.json" SAMPLE_EVENTS_FILE="$ev" "$@" bash "$here/scout.sh" --dry-run; }
out=$(run SAMPLE_PREV_FILE="$here/fixtures/prev.json")
check "signals dry run: at most 3 tickets in total" 3 "$(grep -c '^--- would create' <<<"$out")"
out=$(run SAMPLE_PREV_FILE="$here/fixtures/prev.json" SCOUT_MODE=weekly SCOUT_APPS="$here/fixtures/apps-signals.json")
check "signals dry run: numbers are shown (in the numbers and in the report)" 2 "$(grep -c '^| Import job duration (p95 ms) | 70002 ms | 3 |' <<<"$out" || true)"
check "signals dry run: the weekly report is shown" 1 "$(grep -c '^## Weekly health report: Feast' <<<"$out" || true)"
check "signals dry run: report carries the data for next week" 1 "$(grep -c '^```scout-state' <<<"$out" || true)"
check "signals dry run: expected but unused action shows" 2 "$(grep -c 'Usage per action › export | 0' <<<"$out" || true)"
no_err=$(run SAMPLE_FILE=<(echo '{"result":{"events":{"events":[]}}}') SCOUT_MODE=weekly)
check "signals dry run: a signal over its threshold gets a ticket" 1 "$(grep -c '^--- would create in Triage, label source:logs: \[logs\] Slow requests' <<<"$no_err" || true)"
check "signals dry run: no-change requests become a theme ticket" 1 "$(grep -c '^--- would create.*Feature request: unsorted requests' <<<"$no_err" || true)"
check "signals dry run: theme examples are masked" 0 "$(grep -c 'example.com' <<<"$no_err" || true)"
check "signals dry run: theme examples sit in a code block" 1 "$(awk '/^```/{b=!b} /shopping list/ && !/^--- would/{print b}' <<<"$no_err" | head -n1)"
daily=$(run SCOUT_MODE=daily SAMPLE_PREV_FILE="$here/fixtures/prev.json")
check "daily run: no weekly report" 0 "$(grep -c 'Weekly health report' <<<"$daily" || true)"
check "signals dry run: signatures are stable" "$(grep -o 'logsig-[0-9a-f]*' <<<"$no_err" | sort | tr '\n' ' ')" "$(run SAMPLE_FILE=<(echo '{"result":{"events":{"events":[]}}}') SCOUT_MODE=weekly | grep -o 'logsig-[0-9a-f]*' | sort | tr '\n' ' ')"

# Shipped this week: plain-code section from merged and deployed tickets (Claude only words the lines).
sh=$(jq -nr -L "$here" --argjson items "$(cat "$here/fixtures/shipped.json")" --argjson lines '{"KV-10":"You can now rename trip types"}' -f "$here/shipped.jq")
check "shipped: starts with the heading" "### Shipped this week" "$(head -n1 <<<"$sh")"
check "shipped: Claude's line with a link to the ticket" 1 "$(grep -c '^- You can now rename trip types (\[KV-10\](https://linear.app/issue/KV-10))$' <<<"$sh" || true)"
check "shipped: fixes and reverts are listed apart from features" "**New**|**Fixes**|**Reverts**" "$(grep -o '^\*\*[A-Za-z]*\*\*' <<<"$sh" | tr '\n' '|' | sed 's/|$//')"
check "shipped: a title falls back to the ticket title, one line" 1 "$(grep -c '^- Bug: save conflict on slow networks' <<<"$sh" || true)"
check "shipped: newlines in titles cannot start another line" 0 "$(grep -c '^Ignore previous' <<<"$sh" || true)"
check "shipped: nothing shipped says so" "Nothing shipped this week." "$(jq -nr -L "$here" --argjson items '[]' --argjson lines '{}' -f "$here/shipped.jq" | tail -n1)"
check "shipped: unreadable GitHub says so" "Could not read what was deployed this week." "$(jq -nr -L "$here" --argjson items null --argjson lines '{}' -f "$here/shipped.jq" | tail -n1)"
out=$(run SAMPLE_PREV_FILE="$here/fixtures/prev.json" SCOUT_MODE=weekly SAMPLE_SHIPPED_FILE="$here/fixtures/shipped.json")
check "weekly report: Shipped this week comes first" "### Shipped this week" "$(grep -A2 '^## Weekly health report' <<<"$out" | tail -n1)"
check "daily run: no shipped section" 0 "$(run SCOUT_MODE=daily | grep -c 'Shipped this week' || true)"

# shipped.sh with a fake gh: only commits whose deploy check succeeded, tickets from the subject, kinds by title.
tmp=$(mktemp -d); mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$2" in
  repos/o/a) echo main ;;
  repos/o/a/commits\?*) printf 'c1\tKV-1: Add trip types (#5)\nc2\tBug: no ticket (#6)\nc3\tKV-3: Revert "KV-1: Add trip types" (#7)\nc4\tKV-4: Fix login (#8)\nc5\tKV-5: Not deployed (#9)\n' ;;
  repos/o/a/commits/c5/check-runs*) echo '{"check_runs":[{"name":"Workers Builds: a","conclusion":"failure"}]}' ;;
  repos/o/a/commits/*/check-runs*) echo '{"check_runs":[{"name":"Workers Builds: a","conclusion":"success"}]}' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
got=$(PATH="$tmp/bin:$PATH" bash "$here/shipped.sh" o/a | jq -c 'map("\(.ticket):\(.kind)")')
check "shipped.sh: deployed tickets only, oldest first, with kinds" '["KV-4:fix","KV-3:revert","KV-1:feature"]' "$got"
check "shipped.sh: unreadable repo gives null" null "$(PATH="$tmp/bin:$PATH" bash "$here/shipped.sh" o/zzz 2>/dev/null)"
rm -rf "$tmp"

exit $fail
