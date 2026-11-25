#!/usr/bin/env bash
# Tests for the issue writer: formatting, labels, assignee, state, deduplication and the blocking setup of manual tickets.
# linear_gql is faked, so no network is used. Usage: bash agents/lib/test-issue-writer.sh
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/linear.sh"
source "$here/issue-writer.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
has() { if grep -qF -- "$2" <<<"$3"; then echo "ok   $1"; else echo "FAIL $1: '$2' not found"; fail=1; fi; }

CALLS=$(mktemp); trap 'rm -f "$CALLS"' EXIT
CTX='{"id":"p1","team":{"id":"t1","states":{"nodes":[{"id":"s-triage","name":"Triage","type":"triage"},{"id":"s-todo","name":"Todo","type":"unstarted"},{"id":"s-blocked","name":"Blocked","type":"unstarted"},{"id":"s-nh","name":"Needs Human","type":"started"},{"id":"s-ar","name":"Agent Ready","type":"unstarted"}]},"labels":{"nodes":[{"id":"o-agent","name":"Agent","parent":{"name":"Origin"}},{"id":"o-human","name":"Human","parent":{"name":"Origin"}},{"id":"d-human","name":"Human involved","parent":{"name":"Delivery"}},{"id":"l-manual","name":"factory:manual","parent":null}]}}}'
CTX_NO_TRIAGE=$(jq -c '.team.states.nodes |= map(select(.type != "triage"))' <<<"$CTX")
# Records every mutation as "name<TAB>variables" in $CALLS. OPEN = open issues the dedup query returns.
linear_gql() {
  case "$1" in
    *"users(first"*) echo '{"data":{"users":{"nodes":[{"id":"u-koen"}]}}}' ;;
    *"issues(first: 250"*) if [ "$OPEN" = NONE ]; then echo '{"data":{}}'; else echo "{\"data\":{\"issues\":{\"nodes\":${OPEN:-[]}}}}"; fi ;;
    *"issue(id"*) jq -nc --arg id "$(jq -r .id <<<"$2")" '{data: {issue: {id: ("uuid-" + $id), identifier: $id, team: {states: {nodes: [{id: "s-blocked", name: "Blocked", type: "unstarted"}]}}}}}' ;;
    *issueCreate*) echo "issueCreate	$(jq -c . <<<"$2")" >> "$CALLS"; echo '{"data":{"issueCreate":{"issue":{"identifier":"KV-90","url":"https://linear.app/KV-90"}}}}' ;;
    *issueRelationCreate*) echo "relation	$(jq -c . <<<"$2")" >> "$CALLS"; echo '{"data":{}}' ;;
    *issueUpdate*) echo "update	$(jq -c . <<<"$2")" >> "$CALLS"; echo '{"data":{}}' ;;
    *commentCreate*) echo "comment	$(jq -c . <<<"$2")" >> "$CALLS"; echo '{"data":{}}' ;;
    *issueLabelCreate*) echo "labelCreate	$(jq -c . <<<"$2")" >> "$CALLS"; echo '{"data":{"issueLabelCreate":{"issueLabel":{"id":"l-new"}}}}' ;;
  esac
}
run() { : > "$CALLS"; OUT=$(issue_write "$1" "${2:-$CTX}" 2>/dev/null); }
created_input() { grep '^issueCreate' "$CALLS" | cut -f2- | jq -c .input; }
BASE='{"title":"Fix the thing","goal":"It is broken.","acceptance":["It works"],"out_of_scope":["Redesign"],"agent_notes":"Look at x.ts","footer":"Found by a test."}'

# Formatting
desc=$(issue_format "$BASE")
has "format: Goal" "## Goal
It is broken." "$desc"
has "format: Acceptance criteria are a checklist" "## Acceptance criteria
- [ ] It works" "$desc"
has "format: Out of scope" "## Out of scope
- Redesign" "$desc"
has "format: Agent notes are collapsible" "+++ Agent notes

Look at x.ts

+++" "$desc"
has "format: footer at the bottom" "---
Found by a test." "$desc"
check "format: sections in order" "## Goal,## Acceptance criteria,## Out of scope,+++ Agent notes" "$(grep -E '^(## |\+\+\+ )' <<<"$desc" | paste -sd, -)"
empty=$(issue_format '{"title":"t","goal":"g"}')
has "format: default acceptance criterion" "- [ ] The goal above is met." "$empty"
has "format: default out of scope" "- Nothing beyond the goal above." "$empty"
has "format: manual steps are numbered" "1. Open the dashboard
2. Add the secret" "$(issue_format '{"goal":"g","steps":["Open the dashboard","Add the secret"]}')"
has "format: related tickets" "Related tickets: KV-1, KV-2" "$(issue_format '{"goal":"g","related":["KV-1","KV-2"]}')"

# Agent ticket: Origin Agent, no assignee, Todo
run "$BASE"
check "output names the ticket" "created KV-90 https://linear.app/KV-90" "$OUT"
check "agent ticket: Origin › Agent" '["o-agent"]' "$(created_input | jq -c .labelIds)"
check "agent ticket: no assignee" null "$(created_input | jq -c '.assigneeId // null')"
check "agent ticket: Todo by default" s-todo "$(created_input | jq -r .stateId)"
check "agent ticket: project and team" "p1 t1" "$(created_input | jq -r '"\(.projectId) \(.teamId)"')"
check "description is the formatted text" "$desc" "$(created_input | jq -r .description)"

check "no priority unless asked" null "$(created_input | jq -c '.priority // null')"
run "$(jq -c '. + {priority: 2}' <<<"$BASE")"
check "priority is passed on" 2 "$(created_input | jq -r .priority)"

# Labels and assignee
run "$(jq -c '. + {origin: "Human", delivery: "Human involved", manual: true}' <<<"$BASE")"
check "manual ticket: Origin, Delivery and factory:manual" '["o-human","d-human","l-manual"]' "$(created_input | jq -c .labelIds)"
check "manual ticket: assigned to Koen" u-koen "$(created_input | jq -r .assigneeId)"
run "$(jq -c '. + {labels: ["source:logs"]}' <<<"$BASE")"
check "extra label that doesn't exist is created" 1 "$(grep -c '^labelCreate' "$CALLS")"
check "extra label is on the ticket" '["o-agent","l-new"]' "$(created_input | jq -c .labelIds)"

# State
run "$(jq -c '. + {state: "triage"}' <<<"$BASE")"; check "triage: Triage state" s-triage "$(created_input | jq -r .stateId)"
run "$(jq -c '. + {state: "triage"}' <<<"$BASE")" "$CTX_NO_TRIAGE"; check "triage: Todo when the team has no triage" s-todo "$(created_input | jq -r .stateId)"
run "$(jq -c '. + {state: "needs human"}' <<<"$BASE")"; check "needs human state" s-nh "$(created_input | jq -r .stateId)"
run "$(jq -c '. + {state: "agent ready"}' <<<"$BASE")"; check "never Agent Ready" s-todo "$(created_input | jq -r .stateId)"
run "$(jq -c '. + {state: "blocked"}' <<<"$BASE")"; check "blocked without a blocker becomes Todo" s-todo "$(created_input | jq -r .stateId)"
run "$(jq -c '. + {state: "blocked", blocked_by: ["KV-5"]}' <<<"$BASE")"
check "blocked with a blocker: Blocked state" s-blocked "$(created_input | jq -r .stateId)"
check "blocked by: KV-5 blocks the new ticket" '{"a":"uuid-KV-5","b":"uuid-KV-90","t":"blocks"}' "$(grep '^relation' "$CALLS" | cut -f2-)"

# Deduplication
OPEN='[{"id":"u1","identifier":"KV-3","url":"https://linear.app/KV-3","title":"FIX THE THING","description":"x"}]'
run "$(jq -c '. + {dedup: true}' <<<"$BASE")"
check "dedup by title: no new ticket" 0 "$(grep -c '^issueCreate' "$CALLS")"
check "dedup by title: comment on the existing one" 1 "$(grep -c '^comment' "$CALLS")"
check "dedup output" "duplicate KV-3 https://linear.app/KV-3" "$OUT"
OPEN='[{"id":"u1","identifier":"KV-3","url":"u","title":"Other","description":"Signature: `logsig-1`"}]'
run "$(jq -c '. + {dedup_marker: "Signature: `logsig-1`", dedup_comment: "Again"}' <<<"$BASE")"
check "dedup by marker: comment text" Again "$(grep '^comment' "$CALLS" | cut -f2- | jq -r .b)"
run "$(jq -c '. + {dedup_marker: "Signature: `logsig-2`"}' <<<"$BASE")"
check "dedup: another marker creates the ticket" 1 "$(grep -c '^issueCreate' "$CALLS")"
OPEN=NONE; run "$(jq -c '. + {dedup: true}' <<<"$BASE")"
check "dedup: no list of open tickets means no ticket" 0 "$(grep -c '^issueCreate' "$CALLS")"
OPEN='[]'

# Manual tickets block the original, which moves to Blocked
printf '%s' '[{"title":"Add the secret","why":"The app needs it.","steps":["Open Infisical","Add KEY"]}]' > "$CALLS.tasks"
data_issue='{"data":{"issue":{"id":"uuid-KV-8","identifier":"KV-8","project":{"id":"p1"},"team":'"$(jq -c .team <<<"$CTX")"'}}}'
linear_issue() { if [ "$1" = KV-8 ]; then echo "$data_issue"; else linear_gql "issue(id" "$(jq -n --arg id "$1" '{id: $id}')"; fi; }
: > "$CALLS"; OUT=$(linear_create_manual_tickets KV-8 "$CALLS.tasks" blocking "Footer text" 2>/dev/null)
check "manual: markdown line for the ticket" "- [KV-90](https://linear.app/KV-90): Add the secret" "$OUT"
check "manual: assigned to Koen" u-koen "$(created_input | jq -r .assigneeId)"
check "manual: label factory:manual" 1 "$(created_input | jq '.labelIds | index("l-manual") != null' | grep -c true)"
has "manual: exact steps in the description" "1. Open Infisical" "$(created_input | jq -r .description)"
check "manual: KV-90 blocks KV-8" '{"a":"uuid-KV-90","b":"uuid-KV-8","t":"blocks"}' "$(grep '^relation' "$CALLS" | cut -f2-)"
check "manual: the original moves to Blocked" 1 "$(grep -c '^update.*s-blocked' "$CALLS")"
: > "$CALLS"; OUT=$(linear_create_manual_tickets KV-8 "$CALLS.tasks" related "F" 2>/dev/null)
check "related manual ticket: original not blocked" 0 "$(grep -c '^update' "$CALLS")"
check "related manual ticket: related relation" related "$(grep '^relation' "$CALLS" | cut -f2- | jq -r .t)"
OPEN='[{"id":"u1","identifier":"KV-3","url":"u","title":"Add the secret","description":"x"}]'
: > "$CALLS"; OUT=$(linear_create_manual_tickets KV-8 "$CALLS.tasks" blocking "F" 2>/dev/null)
check "manual: no duplicate ticket for the same task" 0 "$(grep -c '^issueCreate' "$CALLS")"
rm -f "$CALLS.tasks"

# Follow-ups use the writer too
printf '%s' '[{"title":"Add tests","goal":"There are none.","acceptance":["A test runs"]}]' > "$CALLS.fu"
OPEN='[]'; : > "$CALLS"; OUT=$(linear_create_follow_ups KV-8 "$CALLS.fu" "Found by the reviewer." 2>/dev/null)
check "follow-up: markdown line" "- [KV-90](https://linear.app/KV-90): Add tests" "$OUT"
check "follow-up: Todo, Origin Agent, nobody assigned" 's-todo ["o-agent","l-new"] null' "$(created_input | jq -r '"\(.stateId) \(.labelIds | tojson) \(.assigneeId // null)"')"
has "follow-up: footer" "Found by the reviewer." "$(created_input | jq -r .description)"
rm -f "$CALLS.fu"
exit $fail
