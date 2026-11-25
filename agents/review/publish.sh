#!/usr/bin/env bash
# Reviewer: post the verdict, label the PR, update Linear, send fix rounds and create follow-ups.
set -eo pipefail
source "$FACTORY_DIR/agents/lib/linear.sh"
source "$FACTORY_DIR/agents/lib/issue-writer.sh"
source "$FACTORY_DIR/agents/review/workflows.sh"
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
    jq '.categories = ((.categories // []) + ["fix-cap"])' "$v" > "$v.tmp" && mv "$v.tmp" "$v"
    decision=escalate
  fi
fi

# Any change under .github/ always needs a human, whatever the verdict or risk. Done here in code so the
# reviewer prompt can't be talked out of it.
wf_files=$(workflows_changed .factory-review/pr.json .factory-review/diff.patch)
if [ -n "$wf_files" ] && [ "$decision" != "escalate" ]; then
  wf_list=$(printf '%s' "$wf_files" | tr '\n' ' ')
  jq --arg w "This PR changes files under .github/ ($wf_list), which always needs a human to approve." \
    '.decision = "escalate" | .reasons = ((.reasons // []) + [$w]) | .fix_requests = [] | .categories = ((.categories // []) + ["workflow-change"])' "$v" > "$v.tmp" && mv "$v.tmp" "$v"
  decision=escalate
fi
# Escalation categories: only known ids (categories.json), at least one, so they can be counted (docs/escalation-learning.md).
# "What you need to decide" is the first thing Koen reads; without one from the reviewer it falls back to the first reason.
jq --slurpfile c "$FACTORY_DIR/agents/review/categories.json" '
  .categories = ([(.categories // [])[] | select(. as $x | $c[0] | map(.id) | index($x))] | unique | if length == 0 then ["other"] else . end)
  | .decision_needed = (if ((.decision_needed // "") | gsub("\\s"; "")) != "" then .decision_needed
      else "Approve this PR anyway? " + ((.reasons // [])[0] // .summary // "The reviewer needs a human to look.") end)
  | .decision_needed = (.decision_needed | gsub("\n"; " ") | .[:300])' "$v" > "$v.tmp" && mv "$v.tmp" "$v"
categories=$(jq -r '.categories | join(",")' "$v")
decide=$(jq -r .decision_needed "$v")
risk=$(jq -r '.risk // "unknown"' "$v")

# Auto-merge only for an approved, low-risk PR opened by the factory, unless the repo opted out.
# merge_note is empty when auto-merge is on, otherwise the reason it isn't.
auto_merge=false
merge_note=""
if [ "$decision" = "approve" ]; then
  if [ -n "$wf_files" ]; then merge_note="the PR changes .github/"
  elif [ "$risk" != "low" ]; then merge_note="risk is $risk, not low"
  elif [ "$AGENT_PR" != "true" ]; then merge_note="this PR wasn't opened by the factory"
  elif grep -qiE '^[[:space:]]*Factory auto-merge:[[:space:]]*off[[:space:]]*$' CLAUDE.md 2>/dev/null; then merge_note="this repo has \`Factory auto-merge: off\` in CLAUDE.md"
  elif [ -z "$FACTORY_APP_TOKEN" ]; then
    merge_note="the factory app token isn't available to the reviewer"
    echo "::warning::FACTORY_APP_TOKEN is not set, so auto-merge was not enabled."
  elif merge_err=$(GH_TOKEN="$FACTORY_APP_TOKEN" gh pr merge "$PR_NUMBER" --auto --squash --delete-branch 2>&1); then
    auto_merge=true
  else
    merge_note="enabling auto-merge failed: $(printf '%s' "$merge_err" | tr '\n' ' ' | cut -c1-300)"
    echo "::warning::Enabling auto-merge failed."
  fi
fi

# Follow-up tickets (Todo), never from a PR that is itself a follow-up.
created=""
if [ -n "$IDENTIFIER" ] && [ "$IS_FOLLOW_UP" != "true" ]; then
  jq --argjson n "$MAX_FOLLOW_UPS" '[.follow_ups // [] | .[] | select((.title // "") != "" and ((.goal // .description // "") != ""))] | .[:$n]' "$v" > "$RUNNER_TEMP/follow_ups.json"
  if [ "$(jq length "$RUNNER_TEMP/follow_ups.json")" != "0" ]; then
    created=$(linear_create_follow_ups "$IDENTIFIER" "$RUNNER_TEMP/follow_ups.json" "Found by the factory reviewer on $pr_url (follow-up to $IDENTIFIER).") || true
  fi
fi

# Manual work the reviewer can't do or confirm itself becomes its own ticket (factory:manual, assigned to Koen).
# When the PR is escalated the ticket blocks the original, which waits in Blocked; otherwise it is only related.
manual_created=""
if [ -n "$IDENTIFIER" ] && [ "$(jq '[.manual_tasks // [] | .[] | select((.title // "") != "" and ((.steps // []) | length) > 0)] | length' "$v")" != "0" ]; then
  jq '[.manual_tasks // [] | .[] | select((.title // "") != "" and ((.steps // []) | length) > 0)] | .[:3]' "$v" > "$RUNNER_TEMP/manual_tasks.json"
  manual_mode=related; [ "$decision" = escalate ] && manual_mode=blocking
  manual_created=$(linear_create_manual_tickets "$IDENTIFIER" "$RUNNER_TEMP/manual_tasks.json" "$manual_mode" "Found by the factory reviewer on $pr_url.") || true
  [ -z "$manual_created" ] || created=$(printf '%s\n%s' "$created" "$manual_created" | sed '/^$/d')
fi

# Preview link and screenshots. The reviewer names the preview URL and up to 3 PNGs under .factory-review/;
# only those are uploaded to Linear, and the markdown goes in both the PR and the Linear comment.
preview_md=""
preview_url=$(jq -r '.preview_url // ""' "$v")
[[ "$preview_url" =~ ^https://[^[:space:]\<\>\(\)]+$ ]] || preview_url=""
if [ -n "$preview_url" ]; then preview_md="**Preview:** $preview_url"
else preview_md="**Preview:** not available (none for this app, or it failed). Any screenshots are from a local run."; fi
shots=""
while IFS=$'\t' read -r shot caption; do
  [ -n "$shot" ] || continue
  case "$shot" in .factory-review/*.png) ;; *) continue ;; esac
  case "$shot" in *..*) continue ;; esac
  [ -f "$shot" ] && [ ! -L "$shot" ] && [ "$(wc -c < "$shot")" -le 5000000 ] || continue
  [ -n "$IDENTIFIER" ] || continue
  asset=$(linear_upload_image "$shot") || true
  [ -n "$asset" ] || continue
  caption=$(printf '%s' "$caption" | tr -d '[]\n' | cut -c1-100)
  shots="$shots$(printf '\n![%s](%s)' "${caption:-screenshot}" "$asset")"
done < <(jq -r '[.screenshots // [] | .[] | select(type == "object") | select((.path // "") != "")] | .[:3][] | "\(.path)\t\(.caption // "")"' "$v")
[ -z "$shots" ] || preview_md="$preview_md"$'\n'"$shots"

{
  [ "$decision" != escalate ] || { echo "**What you need to decide:** $decide"; echo; }
  case "$decision" in
    approve)
      echo "### ✅ Factory review: approved (risk: $risk)"
      if [ "$auto_merge" = "true" ]; then echo; echo "Approved, will merge automatically when checks pass."
      else echo; echo "Approved, but not merging automatically: $merge_note."; fi ;;
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
  echo; printf '%s\n' "$preview_md"
  # Hidden marker: lets learn.sh count what Koen approves unchanged, by reason.
  [ "$decision" != escalate ] || printf '\n<!-- factory-escalation: %s -->\n' "$categories"
} > "$RUNNER_TEMP/comment.md"
gh pr comment "$PR_NUMBER" --body-file "$RUNNER_TEMP/comment.md"

gh label create agent-approved --color 0E8A16 --description "Factory reviewer found nothing risky" --force >/dev/null
gh label create agent-fixing --color FBCA04 --description "Builder agent is applying review fixes" --force >/dev/null
gh label create needs-human --color D93F0B --description "Factory wants a human to look" --force >/dev/null
follow_note=""
[ -n "$created" ] && follow_note=$(printf '\n\nFollow-up and manual tickets created:\n%s' "$created")

case "$decision" in
  approve)
    gh pr edit "$PR_NUMBER" --add-label agent-approved --remove-label needs-human --remove-label agent-fixing
    if [ -n "$IDENTIFIER" ]; then
      if [ "$auto_merge" = "true" ]; then
        linear_comment "$IDENTIFIER" "✅ Reviewer agent approved $pr_url (risk: $risk). Approved, will merge automatically when checks pass.$follow_note

$preview_md"
      else
        linear_comment "$IDENTIFIER" "✅ Reviewer agent approved $pr_url (risk: $risk). Not merging automatically: $merge_note. Merge it yourself.$follow_note

$preview_md"
      fi
      linear_set_state "$IDENTIFIER" "In Review"
      if [ "$auto_merge" = "true" ]; then linear_set_group_label "$IDENTIFIER" Delivery Autonomous
      else linear_set_group_label "$IDENTIFIER" Delivery "Human involved"; fi
    fi
    ;;
  fix)
    gh pr edit "$PR_NUMBER" --add-label agent-fixing --remove-label needs-human --remove-label agent-approved
    feedback=$(jq -r '.fix_requests[] | "- \(.)"' "$v")
    jq -n --arg pr "$PR_NUMBER" --arg round "$((round + 1))" --arg id "$IDENTIFIER" --arg fb "$feedback" \
      '{event_type: "factory-fix", client_payload: {pr_number: $pr, round: $round, identifier: $id, feedback: $fb}}' \
      > "$RUNNER_TEMP/dispatch.json"
    gh api "repos/$GITHUB_REPOSITORY/dispatches" --input "$RUNNER_TEMP/dispatch.json"
    linear_comment "$IDENTIFIER" "$(printf '🔧 Reviewer asked for fixes on %s (round %s of %s). The builder is on it:\n\n%s%s' "$pr_url" "$((round + 1))" "$MAX_FIX_ROUNDS" "$feedback" "$follow_note")

$preview_md"
    ;;
  *)
    gh pr edit "$PR_NUMBER" --add-label needs-human --remove-label agent-approved --remove-label agent-fixing
    if [ -n "$IDENTIFIER" ]; then
      linear_comment "$IDENTIFIER" "$(printf '**What you need to decide:** %s\n\n🙋 Reviewer agent wants you to look at %s\n\n' "$decide" "$pr_url"; jq -r '.reasons[]? | "- \(.)"' "$v"; printf '%s\n\n%s' "$follow_note" "$preview_md")"
      if [ -n "$manual_created" ]; then linear_set_state "$IDENTIFIER" "Blocked"; else linear_set_state "$IDENTIFIER" "Needs Human"; fi
      linear_set_group_label "$IDENTIFIER" Delivery "Human involved"
    fi
    ;;
esac

# Learn from past escalations (best effort, never fails the review): propose a rule for a kind Koen always approves.
bash "$FACTORY_DIR/agents/review/learn.sh" || echo "::warning::Escalation learning failed" >&2
exit 0
