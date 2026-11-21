#!/usr/bin/env bash
# Approve: merge an agent PR because Koen commented "approve" or "merge" on its Linear ticket (factory-approve event).
# Waits for the required checks, squash-merges and deletes the branch with the factory app's token, and tells the
# ticket the outcome. Refusals are reported in Linear and don't fail the run.
set -eo pipefail
source "$FACTORY_DIR/agents/lib/linear.sh"
if [[ ! "$PR_NUMBER" =~ ^[0-9]+$ ]] || [[ ! "$IDENTIFIER" =~ ^[A-Z0-9]+-[0-9]+$ ]]; then
  echo "::error::factory-approve needs a numeric pr_number and a valid identifier"; exit 1
fi
wait_seconds=${CHECK_WAIT_SECONDS:-1800}
poll_seconds=${CHECK_POLL_SECONDS:-30}
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
say() { linear_comment "$IDENTIFIER" "$1"; echo "$1"; }

if ! pr=$(gh pr view "$PR_NUMBER" --json state,url,labels,headRefName 2>/dev/null); then
  say "🏭 Couldn't approve: pull request #$PR_NUMBER could not be read. Run: $run_url"; exit 0
fi
url=$(jq -r .url <<<"$pr")
case "$(jq -r .state <<<"$pr")" in
  MERGED) say "🏭 $url is already merged."; exit 0 ;;
  OPEN) ;;
  *) say "🏭 Not merging $url: it is closed."; exit 0 ;;
esac
if ! jq -e '.labels | any(.name == "agent-built")' <<<"$pr" >/dev/null; then
  say "🏭 Not merging $url: it isn't a factory PR (no \`agent-built\` label)."; exit 0
fi
if ! jq -e --arg p "$(printf '%s' "$IDENTIFIER" | tr '[:upper:]' '[:lower:]')-" '.headRefName | ascii_downcase | startswith($p)' <<<"$pr" >/dev/null; then
  say "🏭 Not merging $url: its branch doesn't belong to $IDENTIFIER."; exit 0
fi

# Wait for the required checks (a repo without required checks merges right away).
waited=0
while :; do
  # gh exits non-zero while checks fail or are pending, but still prints the JSON.
  out=$(gh pr checks "$PR_NUMBER" --required --json name,bucket 2>/dev/null) || true
  jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || out='[]'
  failed=$(jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(", ")' <<<"$out")
  pending=$(jq '[.[] | select(.bucket == "pending")] | length' <<<"$out")
  if [ -n "$failed" ]; then
    say "🏭 Not merging $url: required check failed: $failed. Fix it (comment \`change: …\`) and approve again."; exit 0
  fi
  [ "$pending" = "0" ] && break
  if [ "$waited" -ge "$wait_seconds" ]; then
    say "🏭 Not merging $url: required checks were still running after $((wait_seconds / 60)) minutes. Approve again when they finish."; exit 0
  fi
  sleep "$poll_seconds"; waited=$((waited + poll_seconds))
done

if err=$(gh pr merge "$PR_NUMBER" --squash --delete-branch 2>&1); then
  say "✅ Merged $url (squash, branch deleted) on your approval."
elif gh pr merge "$PR_NUMBER" --auto --squash --delete-branch >/dev/null 2>&1; then
  say "🏭 $url couldn't merge yet ($(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)), so auto-merge is on: it merges when GitHub's requirements are met."
else
  say "🏭 Couldn't merge $url: $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-300). Run: $run_url"
fi
exit 0
