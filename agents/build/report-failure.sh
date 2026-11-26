#!/usr/bin/env bash
# Builder: tell Linear (and the PR, for fix rounds) that the run failed.
set -eo pipefail
source "$FACTORY_DIR/agents/lib/linear.sh"
source "$FACTORY_DIR/agents/lib/usage-limit.sh"
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
reason=$(bash "$FACTORY_DIR/agents/lib/claude-error.sh" || true)
detail=""
if [ -n "$reason" ]; then
  echo "::error::Claude reported: ${reason//$'\n'/ }"
  detail=$(printf '\n\nClaude reported:\n```\n%s\n```' "$reason")
fi
# Claude's usage limit: wait and run the same step again (docs/usage-limits.md) instead of failing.
if [ -n "$reason" ] && usage_limit_hit "$reason"; then
  key=$EVENT_TYPE; [ "$EVENT_TYPE" != "factory-fix" ] || key="factory-fix-$PR_NUMBER-$FIX_ROUND"
  rc=0; usage_limit_schedule "$ISSUE_IDENTIFIER" "$EVENT_TYPE" "$key" "$FACTORY_PAYLOAD" "$reason" || rc=$?
  if [ "$rc" = 0 ]; then echo "::notice::Claude's usage limit was reached; the run will be retried"; exit 0; fi
  [ "$rc" != 2 ] || detail=$(printf '\n\nClaude'"'"'s usage limit was still reached after %s retries, so the factory stops trying.%s' "$RETRY_MAX" "$detail")
fi
if [ "$EVENT_TYPE" = "factory-fix" ] && [ -n "$PR_NUMBER" ]; then
  gh pr comment "$PR_NUMBER" --body "💥 The factory fix run failed. Logs: $run_url$detail" || true
  gh pr edit "$PR_NUMBER" --add-label needs-human --remove-label agent-fixing || true
fi
linear_comment "$ISSUE_IDENTIFIER" "💥 The factory build failed. Logs: $run_url$detail"
linear_set_state "$ISSUE_IDENTIFIER" "Needs Human"
linear_set_group_label "$ISSUE_IDENTIFIER" Delivery "Human involved"
