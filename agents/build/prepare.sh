#!/usr/bin/env bash
# Builder: validate the event and prepare the branch and .factory/ files. Writes step outputs.
set -eo pipefail
case "$EVENT_TYPE" in factory-build|factory-fix) ;; *) echo "::error::Unknown event '$EVENT_TYPE'"; exit 1 ;; esac
if [[ ! "$ISSUE_IDENTIFIER" =~ ^[A-Z0-9]+-[0-9]+$ ]]; then
  echo "::error::Missing or invalid Linear identifier: '$ISSUE_IDENTIFIER'"; exit 1
fi
if [ "$EVENT_TYPE" = "factory-fix" ] && { [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]] || [[ ! "$FIX_ROUND" =~ ^[0-9]+$ ]]; }; then
  echo "::error::factory-fix needs a numeric pr_number and round"; exit 1
fi

source "$FACTORY_DIR/agents/lib/linear.sh"
source "$FACTORY_DIR/agents/lib/checks.sh"
mkdir -p .factory
if [ "$EVENT_TYPE" = "factory-build" ]; then
  slug=$(printf '%s' "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-40 | sed -E 's/-+$//')
  branch="$(printf '%s' "$ISSUE_IDENTIFIER" | tr '[:upper:]' '[:lower:]')-${slug:-task}"
  git checkout -b "$branch"
  printf '# %s: %s\n\n%s\n' "$ISSUE_IDENTIFIER" "$ISSUE_TITLE" "$ISSUE_DESCRIPTION" > .factory/ticket.md
else
  pr=$(gh pr view "$PR_NUMBER" --json headRefName,state,body)
  if [ "$(jq -r .state <<<"$pr")" != "OPEN" ]; then echo "::error::PR #$PR_NUMBER is not open"; exit 1; fi
  branch=$(jq -r .headRefName <<<"$pr")
  git checkout -B "$branch" "origin/$branch"
  if issue=$(linear_issue "$ISSUE_IDENTIFIER") && [ "$(jq -r '.data.issue.id // empty' <<<"$issue")" != "" ]; then
    jq -r '.data.issue | "# \(.identifier): \(.title)\n\n\(.description // "")"' <<<"$issue" > .factory/ticket.md
  else
    jq -r .body <<<"$pr" > .factory/ticket.md
  fi
  printf '%s\n' "$FIX_FEEDBACK" > .factory/review-feedback.md
  checks_collect_failed .factory/checks || echo "::warning::Couldn't collect check details."
  linear_set_state "$ISSUE_IDENTIFIER" "Agent Working"
fi
echo "name=$branch" >> "$GITHUB_OUTPUT"
echo "base_sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
