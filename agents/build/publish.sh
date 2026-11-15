#!/usr/bin/env bash
# Builder: commit the agent's work and open or update the pull request. Writes step outputs.
set -eo pipefail
source "$FACTORY_DIR/agents/lib/linear.sh"
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
gh label create needs-human --color D93F0B --description "Factory wants a human to look" --force >/dev/null

if [ -s .factory/QUESTIONS.md ]; then
  questions=$(cat .factory/QUESTIONS.md)
  if [ "$EVENT_TYPE" = "factory-fix" ]; then
    gh pr comment "$PR_NUMBER" --body "$(printf '🤔 The builder agent needs input before it can apply the review fixes:\n\n%s' "$questions")"
    gh pr edit "$PR_NUMBER" --add-label needs-human
  fi
  linear_comment "$ISSUE_IDENTIFIER" "$(printf '🤔 The builder agent needs input:\n\n%s\n\nUpdate the ticket, then move it back to **Agent Ready**.' "$questions")"
  linear_set_state "$ISSUE_IDENTIFIER" "Needs Human"
  linear_set_group_label "$ISSUE_IDENTIFIER" Delivery "Human involved"
  exit 0
fi

body_file="$RUNNER_TEMP/pr_body.md"
if [ -s .factory/PR_BODY.md ]; then cp .factory/PR_BODY.md "$body_file"; else echo "_The agent didn't write a summary._" > "$body_file"; fi
rm -rf .factory

if [ "$EVENT_TYPE" = "factory-build" ]; then
  message="$ISSUE_IDENTIFIER: $ISSUE_TITLE"
else
  message="$ISSUE_IDENTIFIER: address review feedback (round $FIX_ROUND)"
fi
git add -A
if ! git diff --cached --quiet; then
  git -c user.name="factory-bot" -c user.email="factory-bot@users.noreply.github.com" commit -q -m "$message"
fi
if [ "$(git rev-list --count "$BASE_SHA"..HEAD)" = "0" ]; then
  if [ "$EVENT_TYPE" = "factory-fix" ]; then
    gh pr comment "$PR_NUMBER" --body "🏭 The builder agent couldn't apply the review fixes (no changes). Run: $run_url"
    gh pr edit "$PR_NUMBER" --add-label needs-human
  fi
  linear_comment "$ISSUE_IDENTIFIER" "🏭 The builder agent finished without changing any code. Run: $run_url"
  linear_set_state "$ISSUE_IDENTIFIER" "Needs Human"
  linear_set_group_label "$ISSUE_IDENTIFIER" Delivery "Human involved"
  exit 0
fi

# The Claude action leaves its (now revoked) token in the remote URL; use the workflow's token instead.
git remote set-url origin "https://github.com/$GITHUB_REPOSITORY.git"
gh auth setup-git

if [ "$EVENT_TYPE" = "factory-build" ]; then
  git push --force -u origin "$BRANCH"
  gh label create agent-built --color 5319E7 --description "Opened by the factory builder agent" --force >/dev/null
  pr_number=$(gh pr list --head "$BRANCH" --state open --json number -q '.[0].number')
  {
    echo "Linear: [$ISSUE_IDENTIFIER]($ISSUE_URL)"
    echo
    cat "$body_file"
  } > "$RUNNER_TEMP/pr_full.md"
  if [ -n "$pr_number" ]; then
    gh pr edit "$pr_number" --body-file "$RUNNER_TEMP/pr_full.md"
  else
    gh pr create --base "$GITHUB_REF_NAME" --head "$BRANCH" \
      --title "$ISSUE_IDENTIFIER: $ISSUE_TITLE" --body-file "$RUNNER_TEMP/pr_full.md" --label agent-built
    pr_number=$(gh pr view "$BRANCH" --json number -q .number)
  fi
  linear_comment "$ISSUE_IDENTIFIER" "🏭 Pull request ready: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/pull/$pr_number. The reviewer agent is checking it now."
else
  git push origin "$BRANCH"
  pr_number="$PR_NUMBER"
  { echo "### 🔧 Builder applied review fixes (round $FIX_ROUND)"; echo; cat "$body_file"; } > "$RUNNER_TEMP/fix_comment.md"
  gh pr comment "$pr_number" --body-file "$RUNNER_TEMP/fix_comment.md"
  linear_comment "$ISSUE_IDENTIFIER" "🔧 Builder pushed fixes for round $FIX_ROUND. The reviewer agent is checking again."
fi
echo "pr_number=$pr_number" >> "$GITHUB_OUTPUT"
