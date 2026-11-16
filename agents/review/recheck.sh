#!/usr/bin/env bash
# Reviewer gate for a failed check run (KOE-27). Decides whether the failure should start another review
# of an agent PR, cancels auto-merge first, and writes pr_number and fix_round to $GITHUB_OUTPUT
# (pr_number stays empty when no review should start).
# Inputs: CHECK_NAME, HEAD_SHA, PR_NUMBER (from the event, may be empty), GH_TOKEN, GITHUB_REPOSITORY.
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/../lib/checks.sh"
out=${GITHUB_OUTPUT:-/dev/null}
skip() { echo "Not re-reviewing: $1"; echo "pr_number=" >> "$out"; exit 0; }

# The factory's own build and review checks never retrigger a review.
if jq -en --arg n "$CHECK_NAME" '{name: $n} | '"$CHECKS_OWN_FILTER" >/dev/null; then skip "'$CHECK_NAME' is a factory check"; fi

pr=$PR_NUMBER
if [ -z "$pr" ]; then
  # Some apps' check runs come without pull request info; find it through the commit.
  pr=$(gh api "repos/$GITHUB_REPOSITORY/commits/$HEAD_SHA/pulls" --jq '[.[] | select(.state == "open")][0].number // empty' 2>/dev/null || true)
fi
[[ "$pr" =~ ^[0-9]+$ ]] || skip "no open pull request for this check"

info=$(gh pr view "$pr" --json state,isDraft,labels,comments,autoMergeRequest,headRefOid) || skip "could not read PR #$pr"
labels=$(jq -c '[.labels[].name]' <<<"$info")
[ "$(jq -r .state <<<"$info")" = "OPEN" ] || skip "PR #$pr is not open"
jq -e 'index("agent-built")' <<<"$labels" >/dev/null || skip "PR #$pr is not an agent PR"
# The failing check must belong to the PR's current head, not to an older push.
[ "$(jq -r .headRefOid <<<"$info")" = "$HEAD_SHA" ] || skip "the check ran on an older commit"

# Nothing may merge with a red check: cancel auto-merge before anything else.
if [ "$(jq -r '.autoMergeRequest != null' <<<"$info")" = "true" ]; then
  gh pr merge "$pr" --disable-auto || echo "::warning::Could not cancel auto-merge on PR #$pr."
  gh pr comment "$pr" --body "⚠️ Check \`$CHECK_NAME\` failed after approval, so auto-merge was cancelled. The reviewer is checking the PR again." || true
fi

jq -e 'index("agent-fixing")' <<<"$labels" >/dev/null && skip "a fix round is already running on PR #$pr"
[ "$(jq -r .isDraft <<<"$info")" = "false" ] || skip "PR #$pr is a draft"

# Fix rounds so far, from the builder's comments, so the reviewer's round cap still applies.
round=$(jq -r '[.comments[].body | capture("^### 🔧 Builder applied review fixes \\(round (?<n>[0-9]+)\\)").n | tonumber] | max // 0' <<<"$info")
echo "Re-reviewing PR #$pr after failed check '$CHECK_NAME' (fix rounds so far: $round)."
{ echo "pr_number=$pr"; echo "fix_round=$round"; } >> "$out"
