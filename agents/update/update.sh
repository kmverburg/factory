#!/usr/bin/env bash
# Keeps open agent PRs up to date with their base branch (KV-49, KV-80).
# For every open, non-draft PR with the label `agent-built` (all of them targeting BASE_BRANCH, or only PR_NUMBER):
#   - not behind the base: nothing to do (a ticket still in the Linear status Conflicts goes back to where it was).
#   - behind, merges cleanly: merges the base into the branch and pushes (which re-runs the checks); same for Linear.
#   - behind, conflicts: the ticket moves to Conflicts with a comment listing the files, auto-merge is cancelled, the PR
#     gets `agent-fixing` and a `factory-fix` event with conflict=true goes to the builder. The builder resolves the
#     conflicts as a fix round that doesn't count towards the round cap. This includes escalated PRs (`needs-human`):
#     they keep that label throughout, and the reviewer never lifts their escalation after a conflict round.
# Left alone: PRs that are already being fixed (`agent-fixing`, so a round is never sent twice), deploy-watch reverts
# (`deploy-revert`) and PRs without a ticket identifier in the branch name. Those with conflicts are left to Koen: the
# ticket (if any) stays in Conflicts with a comment saying the factory won't resolve it itself.
# Needs a full checkout of the repo. Env: GH_TOKEN (the factory app's token, so pushes start CI), GITHUB_REPOSITORY, BASE_BRANCH
# (ignored when PR_NUMBER is set). Optional: PR_NUMBER, LINEAR_API_KEY (without it Linear isn't touched).
# Problems with one PR only log warnings.
set -eo pipefail
: "${GITHUB_REPOSITORY:?}"
pr_filter=${PR_NUMBER:-}
base_filter=${BASE_BRANCH:-}
[ -n "$pr_filter" ] || [ -n "$base_filter" ] || { echo "::error::BASE_BRANCH or PR_NUMBER is required"; exit 1; }
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/linear.sh
source "$here/../lib/linear.sh"
# shellcheck source=../lib/conflicts.sh
source "$here/../lib/conflicts.sh"
git_id=(-c user.name="factory-bot" -c user.email="factory-bot@users.noreply.github.com")

# The factory app's token only reaches git through this helper; a failure here surfaces at the first push.
gh auth setup-git || true
gh label create agent-fixing --color FBCA04 --description "Builder agent is applying review fixes" --force >/dev/null || true
gh label create needs-human --color D93F0B --description "Factory wants a human to look" --force >/dev/null || true

prs=$(gh pr list --state open --label agent-built --limit 100 \
  --json number,headRefName,baseRefName,isDraft,labels,autoMergeRequest,comments)
while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  n=$(jq -r .number <<<"$pr"); head=$(jq -r .headRefName <<<"$pr"); base=$(jq -r .baseRefName <<<"$pr")
  has_label() { jq -e --arg l "$1" '.labels | map(.name) | index($l)' <<<"$pr" >/dev/null; }
  if [ "$(jq -r .isDraft <<<"$pr")" = "true" ]; then echo "PR #$n: draft, skipped."; continue; fi
  if has_label agent-fixing; then echo "PR #$n: a fix round is running, skipped."; continue; fi
  identifier=$(grep -oiE '^([a-z]+/)?[a-z0-9]+-[0-9]+' <<<"$head" | sed -E 's#^.*/##' | tr '[:lower:]' '[:upper:]' || true)
  escalated=false; if has_label needs-human; then escalated=true; fi

  git fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" "+refs/heads/$head:refs/remotes/origin/$head" \
    || { echo "::warning::PR #$n: couldn't fetch $head or $base."; continue; }
  if git merge-base --is-ancestor "origin/$base" "origin/$head"; then echo "PR #$n: up to date."; [ -z "$identifier" ] || conflict_clear "$identifier" "$escalated"; continue; fi

  git reset -q --hard; git clean -fdq
  git checkout -q --detach "origin/$head"
  if git "${git_id[@]}" merge --no-edit -m "Merge $base into $head" "origin/$base" </dev/null >/dev/null 2>&1; then
    if git push -q origin "HEAD:refs/heads/$head"; then
      echo "PR #$n: merged $base into $head."
      [ -z "$identifier" ] || conflict_clear "$identifier" "$escalated"
      gh pr comment "$n" --body "🔄 \`$base\` moved on, so the factory merged it into this branch (no conflicts). The checks run again." || true
    else
      echo "::warning::PR #$n: merged $base locally but the push failed (a base change under .github/ needs the app's workflow permission?)."
    fi
    continue
  fi

  files=$(git diff --name-only --diff-filter=U </dev/null)
  git merge --abort 2>/dev/null || git reset -q --hard
  if [ -z "$files" ]; then echo "::warning::PR #$n: merging $base failed without conflicting files."; continue; fi

  # A deploy-watch revert that no longer applies cleanly is Koen's call, not the builder's.
  if has_label deploy-revert; then
    echo "PR #$n: a deploy-watch revert with conflicts; left to Koen."
    [ -z "$identifier" ] || conflict_found "$identifier" "$files" "This is a deploy-watch revert, so the factory won't resolve the conflicts itself. Koen decides: resolve it, merge it, or close the PR."
    continue
  fi
  if [ -z "$identifier" ]; then
    # Said once: a PR that already waits for a human isn't commented on again.
    if [ "$escalated" != "true" ]; then
      gh pr edit "$n" --add-label needs-human || true
      gh pr comment "$n" --body "⚠️ This PR conflicts with \`$base\`, but its branch name has no ticket identifier, so the factory can't send it to the builder. Conflicting files:
$(sed 's/^/- /' <<<"$files")" || true
    else
      echo "PR #$n: conflicts, no ticket identifier; already waiting for a human."
    fi
    continue
  fi
  if [ "$(jq -r '.autoMergeRequest != null' <<<"$pr")" = "true" ]; then
    gh pr merge "$n" --disable-auto || echo "::warning::Could not cancel auto-merge on PR #$n."
  fi
  conflict_found "$identifier" "$files" "The builder is resolving them; the ticket moves back when it is done."
  # Fix rounds so far, so the reviewer's cap carries on from where it was: conflict rounds don't count.
  round=$(jq -r '[.comments[].body | capture("^### 🔧 Builder applied review fixes \\(round (?<n>[0-9]+)\\)").n | tonumber] | max // 0' <<<"$pr")
  commits=$(git log --format='- %h %s' "$(git merge-base "origin/$base" "origin/$head")..origin/$base" | head -30)
  feedback=$(printf '%s moved on and this branch conflicts with it. Conflicting files:\n%s\n\nCommits that landed on %s since this branch was cut:\n%s' \
    "$base" "$(sed 's/^/- /' <<<"$files")" "$base" "$commits")
  # needs-human stays on an escalated PR: only agent-fixing is added.
  gh pr edit "$n" --add-label agent-fixing || true
  jq -n --arg pr "$n" --arg round "$round" --arg id "$identifier" --arg fb "$feedback" \
    '{event_type: "factory-fix", client_payload: {pr_number: $pr, round: $round, identifier: $id, conflict: "true", feedback: $fb}}' \
    > "${RUNNER_TEMP:-/tmp}/update-dispatch.json"
  if gh api "repos/$GITHUB_REPOSITORY/dispatches" --input "${RUNNER_TEMP:-/tmp}/update-dispatch.json"; then
    echo "PR #$n: conflicts with $base; sent to the builder."
    gh pr comment "$n" --body "⚔️ \`$base\` moved on and this PR conflicts with it. The builder is resolving the conflicts (this doesn't count as a review fix round)." || true
  else
    echo "::warning::PR #$n: couldn't start the conflict fix."
    gh pr edit "$n" --remove-label agent-fixing --add-label needs-human || true
    linear_comment "$identifier" "🏭 The factory couldn't start the builder to resolve the merge conflicts on PR #$n (the GitHub dispatch was refused). A human needs to look." || true
  fi
done < <(jq -c --arg p "$pr_filter" --arg b "$base_filter" \
  '.[] | select(if $p != "" then (.number | tostring) == $p else .baseRefName == $b end)' <<<"$prs")
exit 0
