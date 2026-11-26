#!/usr/bin/env bash
# Reviewer: collect PR, diff, ticket and follow-up context into .factory-review/. Writes step outputs.
set -eo pipefail
source "$FACTORY_DIR/agents/lib/linear.sh"
source "$FACTORY_DIR/agents/lib/checks.sh"
mkdir -p .factory-review
gh pr view "$PR_NUMBER" --json title,body,author,headRefName,baseRefName,additions,deletions,changedFiles,files,labels \
  > .factory-review/pr.json
base=$(jq -r .baseRefName .factory-review/pr.json)
git diff "origin/$base...HEAD" > .factory-review/diff.patch
echo "base=$base" >> "$GITHUB_OUTPUT"
# Opened by the builder: labelled agent-built and authored by the factory app or the workflow's bot.
# A revert PR from the deploy watch (label deploy-revert) is never one: it is never auto-merged or fixed by the builder.
agent_pr=$(jq -r --arg app "${APP_SLUG:-}" '([.labels[].name] | index("agent-built") != null) and ([.labels[].name] | index("deploy-revert") == null)
  and (.author.login as $a | ($a | test("github-actions")) or ($app != "" and ($a == "app/" + $app or $a == $app + "[bot]")))' .factory-review/pr.json)
echo "agent_pr=$agent_pr" >> "$GITHUB_OUTPUT"

# The previous factory review on this PR, so a fix round can be checked against it.
gh pr view "$PR_NUMBER" --json comments \
  | jq -r '[.comments[] | select(.body | startswith("### ") and contains("Factory review"))] | last | .body // empty' \
  > .factory-review/previous-review.md
[ -s .factory-review/previous-review.md ] || rm .factory-review/previous-review.md

# Linear identifier from the branch name (e.g. koe-6-edit-trip -> KOE-6).
identifier=$(jq -r .headRefName .factory-review/pr.json | grep -oiE '^([a-z]+/)?[a-z0-9]+-[0-9]+' | sed -E 's#^.*/##' | tr '[:lower:]' '[:upper:]' || true)
is_follow_up=false
if [ -n "$identifier" ] && issue=$(linear_issue "$identifier") && [ "$(jq -r '.data.issue.id // empty' <<<"$issue")" != "" ]; then
  jq -r '.data.issue | "# \(.identifier): \(.title)\n\n\(.description // "")"' <<<"$issue" > .factory-review/ticket.md
  is_follow_up=$(jq -r --arg l "$FOLLOW_UP_LABEL" '[.data.issue.labels.nodes[].name] | index($l) != null' <<<"$issue")
  team_id=$(jq -r '.data.issue.team.id' <<<"$issue")
  linear_open_follow_ups "$team_id" > .factory-review/open-follow-ups.md || true
else
  identifier=""
  echo "No linked Linear ticket was found for this PR." > .factory-review/ticket.md
fi
[ "$is_follow_up" = "true" ] && touch .factory-review/no-follow-ups
echo "identifier=$identifier" >> "$GITHUB_OUTPUT"
echo "is_follow_up=$is_follow_up" >> "$GITHUB_OUTPUT"

# Other CI checks (not the factory's own jobs): wait for them, then save what failed.
checks_wait || true
checks_collect_failed .factory-review/checks || echo "::warning::Couldn't collect check details."

# GitHub's own merge status (KV-80): a conflicting PR is never approved. GitHub needs a moment after a push to work it out.
for _ in $(seq 1 "${MERGEABLE_TRIES:-6}"); do
  gh pr view "$PR_NUMBER" --json mergeable,mergeStateStatus > .factory-review/merge.json 2>/dev/null || echo '{}' > .factory-review/merge.json
  [ "$(jq -r '.mergeable // "UNKNOWN"' .factory-review/merge.json)" != "UNKNOWN" ] && break
  sleep "${MERGEABLE_WAIT:-5}"
done
if [ "$(jq -r '.mergeable // "UNKNOWN"' .factory-review/merge.json)" = "CONFLICTING" ]; then
  # Which files conflict, from a trial merge that is undone straight away.
  git -c user.name=factory-bot -c user.email=factory-bot@users.noreply.github.com merge --no-commit --no-ff "origin/$base" </dev/null >/dev/null 2>&1 || true
  git diff --name-only --diff-filter=U > .factory-review/conflicting-files.txt 2>/dev/null || true
  git merge --abort 2>/dev/null || git reset -q --hard
fi

# Did a builder conflict round just finish (its comment is the latest on the PR)? And was the PR escalated before it?
# Then the review only checks the resolution: it never lifts the escalation (publish.sh).
gh pr view "$PR_NUMBER" --json comments,labels > "$RUNNER_TEMP/pr-comments.json" 2>/dev/null || echo '{}' > "$RUNNER_TEMP/pr-comments.json"
if [ "$(jq -r '.comments[-1].body // "" | startswith("### 🔧 Builder resolved merge conflicts")' "$RUNNER_TEMP/pr-comments.json")" = "true" ]; then
  touch .factory-review/conflict-round
  # Files the builder resolved: those that differ from both parents of the merge commit.
  if [ "$(git rev-list --parents -n1 HEAD | wc -w)" = "3" ]; then git show --cc --name-only --format= HEAD > .factory-review/conflict-files.txt || true; fi
  if jq -e '[.labels[]?.name] | index("needs-human") != null' "$RUNNER_TEMP/pr-comments.json" >/dev/null; then
    touch .factory-review/was-escalated
    # What Koen was asked, and why, from the last escalation, so the verdict can keep it.
    jq -r '[.comments[] | select(.body | test("<!-- factory-escalation: "))] | last | .body // empty' "$RUNNER_TEMP/pr-comments.json" > "$RUNNER_TEMP/last-escalation.md"
    sed -nE 's/^\*\*What you need to decide:\*\* //p' "$RUNNER_TEMP/last-escalation.md" | head -n1 > .factory-review/previous-decision.txt
    sed -nE 's/.*<!-- factory-escalation: ([^ ]*) -->.*/\1/p' "$RUNNER_TEMP/last-escalation.md" | head -n1 > .factory-review/previous-categories.txt
  fi
fi
