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
  pr=$(gh pr view "$PR_NUMBER" --json headRefName,baseRefName,state,body)
  if [ "$(jq -r .state <<<"$pr")" != "OPEN" ]; then echo "::error::PR #$PR_NUMBER is not open"; exit 1; fi
  branch=$(jq -r .headRefName <<<"$pr")
  git checkout -B "$branch" "origin/$branch"
  if issue=$(linear_issue "$ISSUE_IDENTIFIER") && [ "$(jq -r '.data.issue.id // empty' <<<"$issue")" != "" ]; then
    jq -r '.data.issue | "# \(.identifier): \(.title)\n\n\(.description // "")"' <<<"$issue" > .factory/ticket.md
  else
    jq -r .body <<<"$pr" > .factory/ticket.md
  fi
  if [ "$FIX_CONFLICT" = "true" ]; then
    # Start the merge of the base branch and leave the conflicts in the working tree for the builder (KV-49).
    base=$(jq -r .baseRefName <<<"$pr")
    git fetch -q origin "$base"
    git -c user.name="factory-bot" -c user.email="factory-bot@users.noreply.github.com" merge --no-commit --no-ff "origin/$base" </dev/null >/dev/null 2>&1 || true
    files=$(git diff --name-only --diff-filter=U || true)
    {
      printf 'This PR conflicts with `%s`, and the merge of `origin/%s` is started in the working tree (not committed).\n' "$base" "$base"
      printf 'Resolve the conflicts so that both sides keep their intent: this PR'"'"'s ticket (.factory/ticket.md) and the\n'
      printf 'commits that landed on `%s` (listed below). Do not run `git commit`; the workflow commits the merge.\n\n' "$base"
      printf 'Conflicting files:\n%s\n\n' "${files:-(none: the merge was clean or already done)}"
      printf 'Commits on `%s` since this branch was cut:\n%s\n' "$base" "$(git log --format='- %h %s%n%b' "$(git merge-base HEAD "origin/$base")..origin/$base" | head -80)"
    } > .factory/review-feedback.md
  elif [ "$FIX_REQUESTED" = "true" ]; then
    printf 'Koen asked for these changes in a Linear comment. Do what he says.\n\n%s\n' "$FIX_FEEDBACK" > .factory/review-feedback.md
  else
    printf '%s\n' "$FIX_FEEDBACK" > .factory/review-feedback.md
  fi
  checks_collect_failed .factory/checks || echo "::warning::Couldn't collect check details."
  linear_set_state "$ISSUE_IDENTIFIER" "Agent Working"
fi
echo "name=$branch" >> "$GITHUB_OUTPUT"
echo "base_sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
