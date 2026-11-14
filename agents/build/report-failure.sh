#!/usr/bin/env bash
# Builder: tell Linear (and the PR, for fix rounds) that the run failed.
set -eo pipefail
source "$FACTORY_DIR/agents/lib/linear.sh"
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
if [ "$EVENT_TYPE" = "factory-fix" ] && [ -n "$PR_NUMBER" ]; then
  gh pr comment "$PR_NUMBER" --body "💥 The factory fix run failed. Logs: $run_url" || true
  gh pr edit "$PR_NUMBER" --add-label needs-human || true
fi
linear_comment "$ISSUE_IDENTIFIER" "💥 The factory build failed. Logs: $run_url"
linear_set_state "$ISSUE_IDENTIFIER" "Needs Human"
