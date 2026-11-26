#!/usr/bin/env bash
# Builder: commit the agent's work and open or update the pull request. Writes step outputs.
set -eo pipefail
source "$FACTORY_DIR/agents/lib/linear.sh"
source "$FACTORY_DIR/agents/lib/issue-writer.sh"
source "$FACTORY_DIR/agents/lib/conflicts.sh"
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
gh label create needs-human --color D93F0B --description "Factory wants a human to look" --force >/dev/null

# Real manual work: separate tickets for Koen that block this one, which waits in Blocked until they are Done.
if [ -s .factory/MANUAL_TASKS.json ] && [ ! -s .factory/QUESTIONS.md ] \
  && jq -e 'type == "array" and any(.[]; (.title // "") != "" and ((.steps // []) | length) > 0)' .factory/MANUAL_TASKS.json >/dev/null 2>&1; then
  jq '[.[] | select((.title // "") != "" and ((.steps // []) | length) > 0)] | .[:3]' .factory/MANUAL_TASKS.json > "$RUNNER_TEMP/manual_tasks.json"
  created=$(linear_create_manual_tickets "$ISSUE_IDENTIFIER" "$RUNNER_TEMP/manual_tasks.json" blocking "Created by the builder agent for $ISSUE_IDENTIFIER. Run: $run_url") || true
  if [ -n "$created" ]; then
    if [ "$EVENT_TYPE" = "factory-fix" ]; then gh pr edit "$PR_NUMBER" --add-label needs-human; fi
    linear_comment "$ISSUE_IDENTIFIER" "$(printf '🤔 The builder agent can'"'"'t continue without manual work. Tickets for Koen (they block this one, which moves on when they are Done):\n\n%s' "$created")"
    linear_set_group_label "$ISSUE_IDENTIFIER" Delivery "Human involved"
    exit 0
  fi
  echo "::warning::Could not create the manual tickets; falling back to Needs Human"
  echo "The builder needs manual work but the tickets could not be created: $(jq -c . .factory/MANUAL_TASKS.json)" > .factory/QUESTIONS.md
fi

if [ -s .factory/QUESTIONS.md ]; then
  questions=$(cat .factory/QUESTIONS.md)
  if [ "$EVENT_TYPE" = "factory-fix" ]; then
    gh pr comment "$PR_NUMBER" --body "$(printf '🤔 The builder agent needs input before it can apply the fixes:\n\n%s' "$questions")"
    gh pr edit "$PR_NUMBER" --add-label needs-human --remove-label agent-fixing
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
elif [ "$FIX_CONFLICT" = "true" ]; then
  message="$ISSUE_IDENTIFIER: merge the base branch and resolve conflicts"
elif [ "$FIX_REQUESTED" = "true" ]; then
  message="$ISSUE_IDENTIFIER: apply the changes Koen asked for"
else
  message="$ISSUE_IDENTIFIER: address review feedback (round $FIX_ROUND)"
fi
# Every fix round starts with a merge of the base branch (prepare.sh), which can leave conflict markers: never push them.
marker_files=""
if [ "$EVENT_TYPE" = "factory-fix" ]; then marker_files=$({ { git diff --name-only --diff-filter=U; git diff HEAD --name-only; } | sort -u | xargs -r grep -lE '^<<<<<<< ' | xargs -r grep -lE '^>>>>>>> '; } 2>/dev/null || true); fi
if [ -n "$marker_files" ]; then
  gh pr comment "$PR_NUMBER" --body "🏭 The builder agent left merge conflict markers in place, so nothing was pushed. Run: $run_url"
  gh pr edit "$PR_NUMBER" --add-label needs-human --remove-label agent-fixing
  linear_comment "$ISSUE_IDENTIFIER" "🏭 The builder agent couldn't resolve the merge conflicts on the pull request. Run: $run_url"
  linear_set_state "$ISSUE_IDENTIFIER" "Needs Human"
  linear_set_group_label "$ISSUE_IDENTIFIER" Delivery "Human involved"
  exit 0
fi
git add -A
if ! git diff --cached --quiet; then
  git -c user.name="factory-bot" -c user.email="factory-bot@users.noreply.github.com" commit -q -m "$message"
fi
if [ "$(git rev-list --count "$BASE_SHA"..HEAD)" = "0" ]; then
  if [ "$EVENT_TYPE" = "factory-fix" ]; then
    gh pr comment "$PR_NUMBER" --body "🏭 The builder agent couldn't apply the review fixes (no changes). Run: $run_url"
    gh pr edit "$PR_NUMBER" --add-label needs-human --remove-label agent-fixing
  fi
  linear_comment "$ISSUE_IDENTIFIER" "🏭 The builder agent finished without changing any code. Run: $run_url"
  linear_set_state "$ISSUE_IDENTIFIER" "Needs Human"
  linear_set_group_label "$ISSUE_IDENTIFIER" Delivery "Human involved"
  exit 0
fi

# $1 = what went wrong. A conflict round that didn't really merge counts as failed: says so instead of reporting success.
conflict_round_failed() {
  gh pr comment "$PR_NUMBER" --body "🏭 The conflict round failed: $1 The PR needs a human. Run: $run_url"
  gh pr edit "$PR_NUMBER" --add-label needs-human --remove-label agent-fixing
  linear_comment "$ISSUE_IDENTIFIER" "🏭 The builder's merge conflict round failed: $1 A human needs to look at the pull request. Run: $run_url"
  linear_set_state "$ISSUE_IDENTIFIER" "Needs Human"
  linear_set_group_label "$ISSUE_IDENTIFIER" Delivery "Human involved"
}
# The base branch must be part of the branch's history (a real merge), not just an edit that looks like its result.
# origin/<base> is the ref prepare.sh merged, so a base that moved on in the meantime doesn't fail the round.
if [ "$FIX_CONFLICT" = "true" ] && [ -n "$BASE_BRANCH" ] && ! git merge-base --is-ancestor "origin/$BASE_BRANCH" HEAD; then
  conflict_round_failed "the branch doesn't contain \`$BASE_BRANCH\` after the round (the builder changed files without merging it), so nothing was pushed."
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
  # GitHub must agree that the conflict is gone (it needs a moment to work it out after a push).
  if [ "$FIX_CONFLICT" = "true" ]; then
    mergeable=UNKNOWN
    for _ in $(seq 1 "${MERGEABLE_TRIES:-12}"); do
      mergeable=$(gh pr view "$PR_NUMBER" --json mergeable -q .mergeable 2>/dev/null || echo UNKNOWN)
      [ "$mergeable" != "UNKNOWN" ] && break
      sleep "${MERGEABLE_WAIT:-5}"
    done
    if [ "$mergeable" = "CONFLICTING" ]; then
      conflict_round_failed "the merge was pushed, but GitHub still reports a conflict with \`$BASE_BRANCH\`."
      exit 0
    fi
  fi
  if [ "$FIX_CONFLICT" = "true" ]; then fix_title="Builder resolved merge conflicts with the base branch"
  elif [ "$FIX_REQUESTED" = "true" ]; then fix_title="Builder applied the changes Koen asked for"; else fix_title="Builder applied review fixes (round $FIX_ROUND)"; fi
  { echo "### 🔧 $fix_title"; echo; cat "$body_file"; } > "$RUNNER_TEMP/fix_comment.md"
  gh pr comment "$pr_number" --body-file "$RUNNER_TEMP/fix_comment.md"
  if [ "$FIX_CONFLICT" = "true" ]; then
    linear_comment "$ISSUE_IDENTIFIER" "🔧 Builder resolved the merge conflicts with the base branch and pushed. The reviewer agent is checking again."
    # Back to the status the ticket had before the conflict; the reviewer's verdict then decides as usual.
    if gh pr view "$PR_NUMBER" --json labels -q '[.labels[].name] | index("needs-human") != null' 2>/dev/null | grep -qx true; then escalated=true; else escalated=false; fi
    linear_set_state "$ISSUE_IDENTIFIER" "$(conflict_home_state "$escalated")"
  elif [ "$FIX_REQUESTED" = "true" ]; then
    linear_comment "$ISSUE_IDENTIFIER" "🔧 Builder pushed the changes you asked for. The reviewer agent is checking again."
  else
    linear_comment "$ISSUE_IDENTIFIER" "🔧 Builder pushed fixes for round $FIX_ROUND. The reviewer agent is checking again."
  fi
fi
echo "pr_number=$pr_number" >> "$GITHUB_OUTPUT"
