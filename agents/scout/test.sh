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
out=$(env -u LINEAR_API_KEY SCOUT_NO_LLM=1 SAMPLE_FILE="$here/fixtures/response.json" bash "$here/scout.sh" --dry-run)
check "dry run: at most 3 tickets" 3 "$(grep -c '^--- would create' <<<"$out")"
check "dry run: signature in ticket" 1 "$(grep -c "Signature: \`$sig\`" <<<"$out")"
check "dry run: sample is in a code block" 1 "$(grep -c '^### Sample' <<<"$out" | awk '{print ($1 > 0)}')"
check "dry run: no raw email" 0 "$(grep -c 'example.com' <<<"$out" || true)"
inj=$(jq -c '{result: {events: {events: [.result.events.events[5]]}}}' "$here/fixtures/response.json")
inj_file=$(mktemp); echo "$inj" > "$inj_file"
out=$(env -u LINEAR_API_KEY SCOUT_NO_LLM=1 SAMPLE_FILE="$inj_file" bash "$here/scout.sh" --dry-run); rm -f "$inj_file"
check "dry run: injected text stays inside a code block" 1 "$(awk '/^```/{b=!b} /ignore previous/ && !/^--- would/{print b}' <<<"$out" | head -n1)"
check "dry run: backticks in logs cannot close the code block" 0 "$(grep -v "^--- would" <<<"$out" | grep -c "Agent Ready \`\`\`" || true)"

exit $fail
