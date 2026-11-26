#!/usr/bin/env bash
# Tests for the escalation learning (agents/review/learn.jq and learn.sh): fake PR history, fake gh, no network.
# Usage: bash agents/review/test-learn.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# $1 = number, $2 = categories, $3 = day of the escalation, $4 = state, $5 = merged by (human | bot), $6 = "late" for a commit after the escalation
pr() {
  jq -n --argjson n "$1" --arg c "$2" --arg d "$3" --arg st "$4" --arg by "$5" --arg late "$6" '
    {number: $n, url: ("https://github.com/o/r/pull/" + ($n | tostring)), title: ("PR " + ($n | tostring)), state: $st,
     mergedBy: {login: "x", is_bot: ($by == "bot")},
     comments: [{body: ("### 🙋\n<!-- factory-escalation: " + $c + " -->"), createdAt: ("2026-01-" + $d + "T10:00:00Z")}],
     commits: ([{committedDate: ("2026-01-" + $d + "T09:00:00Z"), messageHeadline: "work"}]
       + (if $late == "late" then [{committedDate: ("2026-01-" + $d + "T11:00:00Z"), messageHeadline: "fix"}]
          elif $late == "merge" then [{committedDate: ("2026-01-" + $d + "T11:00:00Z"), messageHeadline: "Merge branch main"}] else [] end))}'
}
# $@ = PR JSON objects. Prints the ids of the proposed categories.
ids() {
  jq -n --argjson prs "$(printf '%s\n' "$@" | jq -s .)" --slurpfile c "$here/categories.json" '{prs: $prs, cats: $c[0], streak: 3}' \
    | jq -r -f "$here/learn.jq" | jq -r .id | paste -sd, -
}
dev=dependency-dev
check "3 in a row -> proposal" "$dev" "$(ids "$(pr 1 $dev 01 MERGED human)" "$(pr 2 $dev 02 MERGED human)" "$(pr 3 $dev 03 MERGED human)")"
check "only 2 -> nothing" "" "$(ids "$(pr 1 $dev 01 MERGED human)" "$(pr 2 $dev 02 MERGED human)")"
check "a commit after the escalation breaks it" "" "$(ids "$(pr 1 $dev 01 MERGED human late)" "$(pr 2 $dev 02 MERGED human)" "$(pr 3 $dev 03 MERGED human)")"
check "merge of the base branch doesn't count as a change" "$dev" "$(ids "$(pr 1 $dev 01 MERGED human merge)" "$(pr 2 $dev 02 MERGED human)" "$(pr 3 $dev 03 MERGED human)")"
check "closed without merging breaks it" "" "$(ids "$(pr 1 $dev 01 MERGED human)" "$(pr 2 $dev 02 MERGED human)" "$(pr 3 $dev 03 CLOSED human)")"
check "an older change doesn't matter" "$dev" "$(ids "$(pr 1 $dev 01 MERGED human late)" "$(pr 2 $dev 02 MERGED human)" "$(pr 3 $dev 03 MERGED human)" "$(pr 4 $dev 04 MERGED human)")"
check "merged by a bot doesn't count" "" "$(ids "$(pr 1 $dev 01 MERGED bot)" "$(pr 2 $dev 02 MERGED human)" "$(pr 3 $dev 03 MERGED human)")"
check "other categories don't mix" "" "$(ids "$(pr 1 $dev 01 MERGED human)" "$(pr 2 schema 02 MERGED human)" "$(pr 3 $dev 03 MERGED human)")"
check "a PR with two categories counts for both" "dependency-dev,schema" "$(ids "$(pr 1 $dev,schema 01 MERGED human)" "$(pr 2 $dev,schema 02 MERGED human)" "$(pr 3 $dev,schema 03 MERGED human)")"
check "never for workflow changes" "" "$(ids "$(pr 1 workflow-change 01 MERGED human)" "$(pr 2 workflow-change 02 MERGED human)" "$(pr 3 workflow-change 03 MERGED human)")"
check "never for security" "" "$(ids "$(pr 1 security 01 MERGED human)" "$(pr 2 security 02 MERGED human)" "$(pr 3 security 03 MERGED human)")"
check "open PRs are ignored" "$dev" "$(ids "$(pr 1 $dev 01 MERGED human)" "$(pr 2 $dev 02 MERGED human)" "$(pr 3 $dev 03 MERGED human)" "$(pr 4 $dev 04 OPEN human)")"
check "workflow-change, security and factory-rule are never proposed" "false false false" "$(jq -r '[.[] | select(.id == "workflow-change" or .id == "security" or .id == "factory-rule") | .propose] | join(" ")' "$here/categories.json")"

# Every category in the reviewer prompt is in categories.json, and the other way round.
for id in $(jq -r '.[].id' "$here/categories.json"); do
  [ "$id" != fix-cap ] || continue   # set by publish.sh, not by the reviewer
  check "prompt names $id" yes "$(grep -q -- "$id" "$here/prompt.md" && echo yes || echo no)"
done

# learn.sh: fake gh and issue writer; files one ticket for the category.
mkdir -p "$tmp/bin" "$tmp/fd/agents/lib" "$tmp/fd/agents/review"
cp "$here"/{learn.sh,learn.jq,categories.json} "$tmp/fd/agents/review/"
echo 'linear_issue() { echo "{\"data\":{\"issue\":{\"project\":{\"id\":\"p\"},\"team\":{\"id\":\"t\"}}}}"; }' > "$tmp/fd/agents/lib/linear.sh"
echo 'issue_write() { echo "$1" >> "$SPEC_LOG"; echo "created KV-9 u"; }' > "$tmp/fd/agents/lib/issue-writer.sh"
printf '#!/usr/bin/env bash\ncat "$PRS_FILE"\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
printf '%s\n' "$(pr 1 $dev 01 MERGED human)" "$(pr 2 $dev 02 MERGED human)" "$(pr 3 $dev 03 MERGED human)" | jq -s . > "$tmp/prs.json"
: > "$tmp/specs"
(PATH="$tmp/bin:$PATH" PRS_FILE="$tmp/prs.json" SPEC_LOG="$tmp/specs" FACTORY_DIR="$tmp/fd" GITHUB_REPOSITORY=o/r IDENTIFIER=KV-1 bash "$tmp/fd/agents/review/learn.sh")
check "learn.sh files one ticket" 1 "$(wc -l < "$tmp/specs" | tr -d ' ')"
check "ticket: Todo, Origin Agent, lists the PRs" "todo Agent 3" "$(jq -r '"\(.state) \(.origin) \(.agent_notes | [scan("pull/")] | length)"' "$tmp/specs")"
check "ticket: dedup marker names the category" 1 "$(jq -r '.dedup_marker | contains("`dependency-dev`")' "$tmp/specs" | grep -c true || true)"
: > "$tmp/specs"
(PATH="$tmp/bin:$PATH" PRS_FILE="$tmp/prs.json" SPEC_LOG="$tmp/specs" FACTORY_DIR="$tmp/fd" GITHUB_REPOSITORY=o/r IDENTIFIER="" bash "$tmp/fd/agents/review/learn.sh")
check "learn.sh without a ticket does nothing" 0 "$(wc -l < "$tmp/specs" | tr -d ' ')"
exit $fail
