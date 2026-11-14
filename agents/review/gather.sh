#!/usr/bin/env bash
# Reviewer: collect PR, diff, ticket and follow-up context into .factory-review/. Writes step outputs.
set -eo pipefail
source "$FACTORY_DIR/agents/lib/linear.sh"
mkdir -p .factory-review
gh pr view "$PR_NUMBER" --json title,body,author,headRefName,baseRefName,additions,deletions,changedFiles,files,labels \
  > .factory-review/pr.json
base=$(jq -r .baseRefName .factory-review/pr.json)
git diff "origin/$base...HEAD" > .factory-review/diff.patch
echo "base=$base" >> "$GITHUB_OUTPUT"
# Opened by the builder: labelled agent-built and authored by the workflow's bot.
agent_pr=$(jq -r '([.labels[].name] | index("agent-built") != null) and (.author.login | test("github-actions"))' .factory-review/pr.json)
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
