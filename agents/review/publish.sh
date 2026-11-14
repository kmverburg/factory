#!/usr/bin/env bash
# Reviewer: post the verdict, label the PR, update Linear, send fix rounds and create follow-ups.
set -eo pipefail
source "$FACTORY_DIR/agents/lib/linear.sh"
v=.factory-review/verdict.json
pr_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/pull/$PR_NUMBER"
round=${FIX_ROUND:-0}

if ! jq -e '.decision == "approve" or .decision == "fix" or .decision == "escalate"' "$v" >/dev/null 2>&1; then
  echo '{"decision":"escalate","risk":"high","summary":"The reviewer agent did not produce a valid verdict.","reasons":["No valid verdict.json"],"fix_requests":[],"follow_ups":[],"checks":"unknown"}' > "$v"
fi
decision=$(jq -r .decision "$v")

# Automatic fixes only for agent PRs with a ticket, and only a limited number of rounds.
if [ "$decision" = "fix" ]; then
  why=""
  if [ "$(jq '.fix_requests // [] | length' "$v")" = "0" ]; then why="The reviewer asked for fixes but didn't list any."
  elif [ "$AGENT_PR" != "true" ] || [ -z "$IDENTIFIER" ]; then why="Fixes are needed, but this PR wasn't opened by the factory, so it isn't changed automatically."
  elif [ "$round" -ge "$MAX_FIX_ROUNDS" ]; then why="Still needs fixes after $MAX_FIX_ROUNDS automatic rounds."
  fi
  if [ -n "$why" ]; then
    jq --arg w "$why" '.decision = "escalate" | .reasons = ((.reasons // []) + [$w])' "$v" > "$v.tmp" && mv "$v.tmp" "$v"
    decision=escalate
  fi
fi
risk=$(jq -r '.risk // "unknown"' "$v")

# Follow-up tickets (Todo), never from a PR that is itself a follow-up.
created=""
if [ -n "$IDENTIFIER" ] && [ "$IS_FOLLOW_UP" != "true" ]; then
  jq --argjson n "$MAX_FOLLOW_UPS" '[.follow_ups // [] | .[] | select((.title // "") != "" and (.description // "") != "")] | .[:$n]' "$v" > "$RUNNER_TEMP/follow_ups.json"
  if [ "$(jq length "$RUNNER_TEMP/follow_ups.json")" != "0" ]; then
    created=$(linear_create_follow_ups "$IDENTIFIER" "$RUNNER_TEMP/follow_ups.json" "Found by the factory reviewer on $pr_url (follow-up to $IDENTIFIER).") || true
  fi
fi

{
  case "$decision" in
    approve) echo "### ✅ Factory review: approved (risk: $risk)" ;;
    fix) echo "### 🔧 Factory review: sending fixes to the builder (round $((round + 1)) of $MAX_FIX_ROUNDS, risk: $risk)" ;;
    *) echo "### 🙋 Factory review: needs a human (risk: $risk)" ;;
  esac
  echo
  jq -r '.summary // ""' "$v"
  if [ "$(jq '.reasons // [] | length' "$v")" != "0" ]; then
    echo; echo "**Why:**"; jq -r '.reasons[] | "- \(.)"' "$v"
  fi
  if [ "$(jq '.fix_requests // [] | length' "$v")" != "0" ]; then
    echo; echo "**Fixes requested:**"; jq -r '.fix_requests[] | "- \(.)"' "$v"
  fi
  if [ -n "$created" ]; then
    echo; echo "**Follow-up tickets created (Todo):**"; echo "$created"
  fi
  echo; echo "**Checks:** $(jq -r '.checks // "not reported"' "$v")"
} > "$RUNNER_TEMP/comment.md"
gh pr comment "$PR_NUMBER" --body-file "$RUNNER_TEMP/comment.md"

gh label create agent-approved --color 0E8A16 --description "Factory reviewer found nothing risky" --force >/dev/null
gh label create agent-fixing --color FBCA04 --description "Builder agent is applying review fixes" --force >/dev/null
gh label create needs-human --color D93F0B --description "Factory wants a human to look" --force >/dev/null
follow_note=""
[ -n "$created" ] && follow_note=$(printf '\n\nFollow-up tickets created:\n%s' "$created")

case "$decision" in
  approve)
    gh pr edit "$PR_NUMBER" --add-label agent-approved --remove-label needs-human --remove-label agent-fixing
    if [ -n "$IDENTIFIER" ]; then
      linear_comment "$IDENTIFIER" "✅ Reviewer agent approved $pr_url (risk: $risk). Ready to merge.$follow_note"
      linear_set_state "$IDENTIFIER" "In Review"
    fi
    ;;
  fix)
    gh pr edit "$PR_NUMBER" --add-label agent-fixing --remove-label needs-human --remove-label agent-approved
    feedback=$(jq -r '.fix_requests[] | "- \(.)"' "$v")
    jq -n --arg pr "$PR_NUMBER" --arg round "$((round + 1))" --arg id "$IDENTIFIER" --arg fb "$feedback" \
      '{event_type: "factory-fix", client_payload: {pr_number: $pr, round: $round, identifier: $id, feedback: $fb}}' \
      > "$RUNNER_TEMP/dispatch.json"
    gh api "repos/$GITHUB_REPOSITORY/dispatches" --input "$RUNNER_TEMP/dispatch.json"
    linear_comment "$IDENTIFIER" "$(printf '🔧 Reviewer asked for fixes on %s (round %s of %s). The builder is on it:\n\n%s%s' "$pr_url" "$((round + 1))" "$MAX_FIX_ROUNDS" "$feedback" "$follow_note")"
    ;;
  *)
    gh pr edit "$PR_NUMBER" --add-label needs-human --remove-label agent-approved --remove-label agent-fixing
    if [ -n "$IDENTIFIER" ]; then
      linear_comment "$IDENTIFIER" "$(printf '🙋 Reviewer agent wants you to look at %s\n\n' "$pr_url"; jq -r '.reasons[]? | "- \(.)"' "$v"; printf '%s' "$follow_note")"
      linear_set_state "$IDENTIFIER" "Needs Human"
    fi
    ;;
esac
exit 0
