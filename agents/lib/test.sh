#!/usr/bin/env bash
# Tests for linear_set_group_label: linear_gql is faked, so no network is used.
# Usage: bash agents/lib/test.sh
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/linear.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }

TEAM='[{"id":"d-auto","name":"Autonomous","parent":{"name":"Delivery"}},{"id":"d-human","name":"Human involved","parent":{"name":"Delivery"}},{"id":"o-agent","name":"Agent","parent":{"name":"Origin"}},{"id":"bug","name":"Bug","parent":null}]'
CALLS=$(mktemp)
# $ISSUE_LABELS = labels on the issue. Records mutations in $CALLS.
linear_gql() {
  case "$1" in
    *"issue(id"*) jq -nc --argjson t "$TEAM" --argjson l "$ISSUE_LABELS" '{data: {issue: {id: "uuid", labels: {nodes: $l}, team: {labels: {nodes: $t}}}}}' ;;
    *issueAddLabel*) echo "add $(jq -r .l <<<"$2")" >> "$CALLS"; echo '{}' ;;
    *issueRemoveLabel*) echo "remove $(jq -r .l <<<"$2")" >> "$CALLS"; echo '{}' ;;
  esac
}
run() { # $1 = labels on issue, $2 = label to set. Prints the mutations on one line.
  ISSUE_LABELS="$1"; : > "$CALLS"
  linear_set_group_label KOE-1 Delivery "$2" >/dev/null
  tr '\n' ',' < "$CALLS"
}
AUTO='{"id":"d-auto","name":"Autonomous","parent":{"name":"Delivery"}}'
HUMAN='{"id":"d-human","name":"Human involved","parent":{"name":"Delivery"}}'
BUG='{"id":"bug","name":"Bug","parent":null}'

check "adds Human involved to an issue without a Delivery label" "add d-human," "$(run "[$BUG]" "Human involved")"
check "adds Autonomous to an issue without a Delivery label" "add d-auto," "$(run "[]" "Autonomous")"
check "replaces Autonomous with Human involved" "remove d-auto,add d-human," "$(run "[$AUTO,$BUG]" "Human involved")"
check "never replaces Human involved with Autonomous" "" "$(run "[$HUMAN]" "Autonomous")"
check "same label already set changes nothing" "" "$(run "[$HUMAN]" "Human involved")"
check "other labels are never removed" 0 "$(run "[$AUTO,$BUG]" "Human involved" | grep -c 'remove bug')"
check "unknown label changes nothing" "" "$(run "[]" "Nope")"
check "group label id lookup" "o-agent" "$(linear_group_label_id "$TEAM" Origin Agent)"
check "group label id lookup needs the right group" "" "$(linear_group_label_id "$TEAM" Delivery Agent)"
rm -f "$CALLS"
exit $fail
