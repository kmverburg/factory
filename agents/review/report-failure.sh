#!/usr/bin/env bash
# Reviewer: when the run failed because of Claude's usage limit, ask for the same review again later
# (docs/usage-limits.md). Any other failure is left as it is (the stuck check starts a review again once).
# Env: FACTORY_DIR, PR_NUMBER, FIX_ROUND, IDENTIFIER (ticket of the PR, may be empty), GH_TOKEN, LINEAR_API_KEY.
set -eo pipefail
source "$FACTORY_DIR/agents/lib/linear.sh"
source "$FACTORY_DIR/agents/lib/usage-limit.sh"
reason=$(bash "$FACTORY_DIR/agents/lib/claude-error.sh" || true)
[ -n "$reason" ] && usage_limit_hit "$reason" || exit 0
[ -n "$IDENTIFIER" ] || exit 0
payload=$(jq -nc --arg pr "$PR_NUMBER" --arg r "${FIX_ROUND:-0}" --arg id "$IDENTIFIER" '{pr_number: $pr, round: $r, identifier: $id}')
rc=0; usage_limit_schedule "$IDENTIFIER" factory-review "factory-review-$PR_NUMBER-${FIX_ROUND:-0}" "$payload" "$reason" || rc=$?
case "$rc" in
  0) echo "::notice::Claude's usage limit was reached; the review will be retried" ;;
  2) linear_comment "$IDENTIFIER" "💥 The review of PR #$PR_NUMBER could not run: Claude's usage limit was still reached after $RETRY_MAX retries, so the factory stops trying. A human needs to look at the PR."
     linear_set_state "$IDENTIFIER" "Needs Human"
     linear_set_group_label "$IDENTIFIER" Delivery "Human involved"
     gh pr edit "$PR_NUMBER" --add-label needs-human >/dev/null 2>&1 || true ;;
esac
exit 0
