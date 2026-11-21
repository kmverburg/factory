# shellcheck shell=bash
# Turns health check results into Linear tickets, sourced by health.sh (needs agents/lib/linear.sh).
# One ticket per failed check ("Factory health: <title>") in the Factory project, in Todo, labelled source:health and
# Origin › Agent. The check's key is in the ticket as `Signature: \`healthsig-<key>\``: a failing check with an open ticket
# updates that ticket (no new one), and a ticket whose check passes again gets one comment.

# $1 = results file (JSON lines). Prints what it did. Returns 1 when Linear can't be used.
health_sync_tickets() {
  local ctx team project todo labels label_id origin open today line status key title detail fix sig issue uuid desc body input created
  ctx=$(linear_project_context "${HEALTH_PROJECT:-Factory}" 2>/dev/null) || ctx=""
  team=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null) || team=""
  project=$(jq -r '.id // empty' <<<"$ctx" 2>/dev/null) || project=""
  if [ -z "$team" ] || [ -z "$project" ]; then
    echo "::error::Linear project '${HEALTH_PROJECT:-Factory}' not found or Linear unreachable; no tickets were created or updated"
    return 1
  fi
  todo=$(jq -r '[.team.states.nodes[] | select((.name | ascii_downcase) == "todo")][0].id // empty' <<<"$ctx")
  labels=$(jq -c '.team.labels.nodes // []' <<<"$ctx")
  label_id=$(linear_ensure_label "$team" source:health "$labels")
  origin=$(linear_group_label_id "$labels" Origin Agent)
  [ -n "$origin" ] || echo "::warning::Label 'Origin › Agent' not found"
  open=$(linear_open_issues_with_label "$team" "$project" source:health 2>/dev/null) || open=""
  if [ -z "$open" ]; then echo "::error::Could not list the open health tickets; not creating tickets (they might be duplicates)"; return 1; fi
  today=$(date -u +%F)

  while IFS= read -r line; do
    status=$(jq -r '.status' <<<"$line")
    [ "$status" = "skip" ] && continue
    key=$(jq -r '.key' <<<"$line"); title=$(jq -r '.title' <<<"$line")
    detail=$(jq -r '.detail' <<<"$line"); fix=$(jq -r '.fix' <<<"$line")
    sig="healthsig-$key"
    issue=$(jq -c --arg s "Signature: \`$sig\`" '[.[] | select((.description // "") | contains($s))][0] // empty' <<<"$open")
    uuid=$(jq -r '.id // empty' <<<"${issue:-{\}}")
    desc=$(jq -r '.description // ""' <<<"${issue:-{\}}")
    if [ "$status" = "fail" ]; then
      body="$detail

**How to fix:** $fix

---
Found by the daily factory health check (\`agents/health/\`, see docs/health-check.md). Last seen failing: $today.
Health status: failing
Signature: \`$sig\`"
      if [ -z "$uuid" ]; then
        input=$(jq -n --arg t "$team" --arg ti "Factory health: $title" --arg d "$body" --arg s "$todo" --arg l "$label_id" --arg o "$origin" --arg p "$project" \
          '{teamId: $t, title: $ti, description: $d, projectId: $p}
           + (if $s != "" then {stateId: $s} else {} end)
           + {labelIds: ([$l, $o] | map(select(. != "")))}')
        created=$(linear_create_issue "$input" 2>/dev/null) || created=""
        if [ -n "$created" ]; then echo "created ${created%% *}: Factory health: $title"; else echo "::warning::Could not create a ticket for: $title"; fi
      else
        if [[ "$desc" == *"Health status: recovered"* ]]; then
          linear_comment_on_id "$uuid" "🏭 The health check fails again: $detail"
        fi
        linear_update_description "$uuid" "$body"
        echo "updated $(jq -r '.identifier' <<<"$issue"): Factory health: $title"
      fi
    elif [ -n "$uuid" ] && [[ "$desc" == *"Health status: failing"* ]]; then
      linear_comment_on_id "$uuid" "✅ The health check passes again ($today): $detail You can close this ticket."
      linear_update_description "$uuid" "${desc/Health status: failing/Health status: recovered ($today)}"
      echo "recovered $(jq -r '.identifier' <<<"$issue"): Factory health: $title"
    fi
  done <"$1"
}
