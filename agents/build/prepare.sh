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
  # Every fix round starts with the base branch merged into the branch, whatever started the round (KV-80). The merge is
  # started but not committed: conflicts are left as markers for the builder, a clean merge is what it works on, and the
  # publish step commits it. Nothing is guessed: "is there a conflict" is answered by git here, not by the builder.
  base=$(jq -r .baseRefName <<<"$pr")
  git fetch -q origin "$base"
  merge_state=clean
  if git merge-base --is-ancestor "origin/$base" HEAD; then
    merge_state=uptodate
  elif ! git -c user.name="factory-bot" -c user.email="factory-bot@users.noreply.github.com" merge --no-commit --no-ff "origin/$base" </dev/null >/dev/null 2>&1; then
    merge_state=conflict
  fi
  files=$(git diff --name-only --diff-filter=U || true)
  [ "$merge_state" != conflict ] || [ -n "$files" ] || merge_state=clean
  {
    case "$merge_state" in
      conflict)
        printf 'The merge of `origin/%s` into this branch is started in the working tree (not committed) and it CONFLICTS.\n' "$base"
        printf 'Resolve the conflicts so that both sides keep their intent: this PR'"'"'s ticket (.factory/ticket.md) and the\n'
        printf 'commits that landed on `%s` (listed below). Remove every conflict marker. Do not run `git commit` or `git merge --abort`;\n' "$base"
        printf 'the workflow commits the merge, and it must stay a merge of `%s`.\n\nConflicting files:\n%s\n\n' "$base" "$(sed 's/^/- /' <<<"$files")" ;;
      clean)
        printf 'The merge of `origin/%s` into this branch is started in the working tree (not committed) and it is CLEAN: no conflicts.\n' "$base"
        printf 'Work on the merged result. Do not run `git commit` or `git merge --abort`; the workflow commits the merge and pushes it.\n\n' ;;
      *)
        printf 'This branch already contains `origin/%s`: nothing to merge.\n\n' "$base" ;;
    esac
    if [ "$FIX_CONFLICT" = "true" ]; then
      printf 'This round was started because the PR conflicts with `%s`; the instructions below come from the update job.\n\n' "$base"
      printf '%s\n\n' "$FIX_FEEDBACK"
    elif [ "$FIX_REQUESTED" = "true" ]; then
      printf 'Koen asked for these changes in a Linear comment. Do what he says.\n\n%s\n\n' "$FIX_FEEDBACK"
    else
      printf '%s\n\n' "$FIX_FEEDBACK"
    fi
    if [ "$merge_state" != uptodate ]; then
      printf 'Commits on `%s` since this branch was cut:\n%s\n' "$base" "$(git log --format='- %h %s' "$(git merge-base HEAD "origin/$base")..origin/$base" | head -80)"
    fi
  } > .factory/review-feedback.md
  echo "base=$base" >> "$GITHUB_OUTPUT"
  echo "merge_state=$merge_state" >> "$GITHUB_OUTPUT"
  checks_collect_failed .factory/checks || echo "::warning::Couldn't collect check details."
  linear_set_state "$ISSUE_IDENTIFIER" "Agent Working"
fi
echo "name=$branch" >> "$GITHUB_OUTPUT"
echo "base_sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
