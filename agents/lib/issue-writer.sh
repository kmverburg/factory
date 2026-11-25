# shellcheck shell=bash
# The issue writer: the one way the factory creates Linear tickets. Sourced after lib/linear.sh.
# Every part of the factory that files a ticket (reviewer follow-ups, log scout, caller sync, health check, manual
# tickets from the builder and reviewer, rough notes from Koen) calls issue_write, so tickets look and behave the same.
# New parts that create tickets must use it too (README, "Issue writer").
#
# issue_write SPEC [CTX]
#   SPEC = JSON: {
#     "project": "Backpack",            project name (not needed when CTX is given)
#     "title": "…", "goal": "what was found and why",
#     "steps": ["exact step", …],       optional; a numbered "Steps" section (manual tickets)
#     "acceptance": ["…"], "out_of_scope": ["…"], "agent_notes": "…", "related": ["KV-1"],
#     "footer": "text kept at the bottom (for example Koen's original words)",
#     "origin": "Agent" (default) | "Human",
#     "priority": 2,                    optional Linear priority (1 urgent, 2 high, 3 medium, 4 low)
#     "manual": true,                   label factory:manual, assigned to Koen (FACTORY_OWNER_EMAIL)
#     "delivery": "Human involved" | "Autonomous",   only when known
#     "state": "triage" (Todo if the team has no triage) | "todo" | "blocked" | "needs human",
#     "blocked_by": ["KV-1"],           those tickets block the new one (state blocked needs at least one)
#     "blocks": ["KV-2"],               the new ticket blocks those, which move to Blocked unless "block_state": false
#     "labels": ["source:logs"],        extra labels, created when missing
#     "update": "KV-7",                 rewrite this existing ticket (title, description, project, labels, assignee) instead of creating one;
#                                       its state only changes when "state" is given, its other labels are kept, no deduplication
#     "dedup": true, "dedup_marker": "text that is in the description of a ticket about the same thing",
#     "dedup_comment": "comment for an existing ticket (default: the goal)"
#   }
#   CTX = {id, team: {id, states: {nodes}, labels: {nodes}}} (what linear_project_context prints); looked up from "project" when absent.
# Never moves a ticket to Agent Ready. Prints "created IDENT url" or "duplicate IDENT url", or nothing (with a warning on stderr).
FACTORY_OWNER_EMAIL=${FACTORY_OWNER_EMAIL:-linear@kmverburg.nl}
MANUAL_LABEL=${MANUAL_LABEL:-factory:manual}

# $1 = spec. Prints the ticket description.
issue_format() {
  jq -r '
    def list($a; f): ($a // []) | map(select(. != "")) | to_entries | map(f) | join("\n");
    "## Goal\n" + (.goal // "")
    + (if ((.steps // []) | length) > 0 then "\n\n## Steps\n" + list(.steps; "\(.key + 1). \(.value)") else "" end)
    + "\n\n## Acceptance criteria\n"
    + (if ((.acceptance // []) | length) > 0 then list(.acceptance; "- [ ] \(.value)") else "- [ ] The goal above is met." end)
    + "\n\n## Out of scope\n"
    + (if ((.out_of_scope // []) | length) > 0 then list(.out_of_scope; "- \(.value)") else "- Nothing beyond the goal above." end)
    + "\n\n+++ Agent notes\n\n"
    + (if (.agent_notes // "") != "" then .agent_notes else "None." end)
    + (if ((.related // []) | length) > 0 then "\n\nRelated tickets: " + (.related | join(", ")) else "" end)
    + "\n\n+++"
    + (if (.footer // "") != "" then "\n\n---\n" + .footer else "" end)' <<<"$1"
}

# $1 = identifier. Prints the issue uuid, or nothing.
issue_uuid() { linear_issue "$1" 2>/dev/null | jq -r '.data.issue.id // empty'; }

# $1 = blocker identifier or uuid, $2 = blocked one, $3 = type (blocks | related). Warns instead of failing.
issue_relate() {
  local a b
  a=$(issue_uuid "$1"); b=$(issue_uuid "$2")
  if [ -z "$a" ] || [ -z "$b" ]; then echo "::warning::Could not relate $1 and $2: ticket not found" >&2; return 0; fi
  linear_gql 'mutation($a: String!, $b: String!, $t: IssueRelationType!) { issueRelationCreate(input: { issueId: $a, relatedIssueId: $b, type: $t }) { success } }' \
    "$(jq -n --arg a "$a" --arg b "$b" --arg t "$3" '{a: $a, b: $b, t: $t}')" >/dev/null \
    || echo "::warning::Could not relate $1 and $2" >&2
}

# $1 = spec, $2 = ctx (optional)
issue_write() {
  local spec=$1 ctx=$2 project team_id project_id labels states state_want state_id title desc
  local label_ids=() lid name origin delivery assignee open dup dup_id dup_ident dup_url comment input created ident url other update uuid existing
  if [ -z "$ctx" ]; then
    project=$(jq -r '.project // empty' <<<"$spec")
    ctx=$(linear_project_context "$project" 2>/dev/null) || ctx=""
  fi
  team_id=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null) || team_id=""
  if [ -z "$team_id" ]; then echo "::warning::Linear project '${project:-?}' not found or Linear unreachable; no ticket '$(jq -r .title <<<"$spec")'" >&2; return 0; fi
  project_id=$(jq -r '.id // empty' <<<"$ctx")
  labels=$(jq -c '.team.labels.nodes // []' <<<"$ctx")
  states=$(jq -c '.team.states.nodes // []' <<<"$ctx")
  title=$(jq -r '.title' <<<"$spec")

  update=$(jq -r '.update // empty' <<<"$spec")

  # Deduplication: an open ticket in the same project with the same title or marker gets a comment instead.
  if [ -z "$update" ] && [ "$(jq -r '(.dedup // false) or ((.dedup_marker // "") != "")' <<<"$spec")" = true ]; then
    open=$(linear_gql 'query($t: ID!, $p: ID) { issues(first: 250, filter: { team: { id: { eq: $t } }, project: { id: { eq: $p } }, state: { type: { nin: ["completed", "canceled"] } } }) { nodes { id identifier url title description } } }' \
      "$(jq -n --arg t "$team_id" --arg p "$project_id" '{t: $t, p: (if $p == "" then null else $p end)}')" | jq -c '.data.issues.nodes // empty') || open=""
    if [ -z "$open" ]; then echo "::warning::Could not list the open tickets; not creating '$title' to avoid a duplicate" >&2; return 0; fi
    dup=$(jq -c --argjson s "$spec" '
      [.[] | select((($s.dedup // false) and ((.title | ascii_downcase) == ($s.title | ascii_downcase)))
                    or ((($s.dedup_marker // "") != "") and ((.description // "") | contains($s.dedup_marker))))][0] // empty' <<<"$open")
    if [ -n "$dup" ]; then
      dup_id=$(jq -r .id <<<"$dup"); dup_ident=$(jq -r .identifier <<<"$dup"); dup_url=$(jq -r .url <<<"$dup")
      comment=$(jq -r '.dedup_comment // ("Found again: " + (.goal // .title))' <<<"$spec")
      linear_comment_on_id "$dup_id" "$comment"
      echo "duplicate $dup_ident $dup_url"
      return 0
    fi
  fi

  # State. Triage falls back to Todo; blocked needs a blocker; Agent Ready is never used.
  state_want=$(jq -r '(.state // "todo") | ascii_downcase' <<<"$spec")
  if [ "$state_want" = blocked ] && [ "$(jq '(.blocked_by // []) | length' <<<"$spec")" = 0 ]; then
    echo "::warning::'$title' should be Blocked but has no blocker; using Todo" >&2; state_want=todo
  fi
  case "$state_want" in
    triage) state_id=$(jq -r '[.[] | select(.type == "triage")][0].id // ([.[] | select((.name | ascii_downcase) == "todo")][0].id) // empty' <<<"$states") ;;
    "agent ready") echo "::warning::The issue writer never uses Agent Ready; using Todo" >&2; state_id=$(jq -r '[.[] | select((.name | ascii_downcase) == "todo")][0].id // empty' <<<"$states") ;;
    *) state_id=$(jq -r --arg n "$state_want" '[.[] | select((.name | ascii_downcase) == $n)][0].id // empty' <<<"$states") ;;
  esac
  [ -n "$state_id" ] || echo "::warning::Linear state '$state_want' not found; the ticket gets the team's default state" >&2

  # Labels: Origin always, Delivery when known, factory:manual for manual work, plus the extras.
  origin=$(jq -r '.origin // "Agent"' <<<"$spec"); delivery=$(jq -r '.delivery // empty' <<<"$spec")
  lid=$(linear_group_label_id "$labels" Origin "$origin")
  if [ -n "$lid" ]; then label_ids+=("$lid"); else echo "::warning::Label 'Origin › $origin' not found" >&2; fi
  if [ -n "$delivery" ]; then
    lid=$(linear_group_label_id "$labels" Delivery "$delivery")
    if [ -n "$lid" ]; then label_ids+=("$lid"); else echo "::warning::Label 'Delivery › $delivery' not found" >&2; fi
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    lid=$(linear_ensure_label "$team_id" "$name" "$labels")
    if [ -n "$lid" ]; then label_ids+=("$lid"); else echo "::warning::Could not find or create label '$name'" >&2; fi
  done < <(jq -r --arg m "$MANUAL_LABEL" '((.labels // []) + (if .manual then [$m] else [] end)) | unique | .[]' <<<"$spec")

  # Assignee: Koen for manual work, nobody for agent work.
  assignee=""
  if [ "$(jq -r '.manual // false' <<<"$spec")" = true ]; then
    assignee=$(linear_gql 'query($e: String!) { users(first: 1, filter: { email: { eq: $e } }) { nodes { id } } }' \
      "$(jq -n --arg e "$FACTORY_OWNER_EMAIL" '{e: $e}')" | jq -r '.data.users.nodes[0].id // empty') || assignee=""
    [ -n "$assignee" ] || echo "::warning::Linear user '$FACTORY_OWNER_EMAIL' not found; the manual ticket is unassigned" >&2
  fi

  desc=$(issue_format "$spec")
  input=$(jq -n --arg t "$team_id" --arg ti "$title" --arg d "$desc" --arg s "$state_id" --arg p "$project_id" --arg a "$assignee" \
    --argjson pr "$(jq -c '.priority // null' <<<"$spec")" \
    --argjson l "$(printf '%s\n' "${label_ids[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
    '{teamId: $t, title: $ti, description: $d, labelIds: $l}
     + (if $s != "" then {stateId: $s} else {} end)
     + (if $p != "" then {projectId: $p} else {} end)
     + (if $a != "" then {assigneeId: $a} else {} end)
     + (if ($pr | type) == "number" then {priority: $pr} else {} end)')
  if [ -n "$update" ]; then
    # Rewrite in place: keep the labels the ticket already has, and its state unless one was asked for.
    existing=$(linear_issue "$update" 2>/dev/null) || existing=""
    uuid=$(jq -r '.data.issue.id // empty' <<<"$existing")
    if [ -z "$uuid" ]; then echo "::warning::Ticket $update not found; nothing rewritten" >&2; return 0; fi
    input=$(jq -c --argjson e "$(jq -c '[.data.issue.labels.nodes[]?.id]' <<<"$existing")" '.labelIds = (($e + .labelIds) | unique)' <<<"$input")
    [ -n "$(jq -r '.state // empty' <<<"$spec")" ] || input=$(jq -c 'del(.stateId)' <<<"$input")
    if linear_gql 'mutation($id: String!, $i: IssueUpdateInput!) { issueUpdate(id: $id, input: $i) { success } }' \
      "$(jq -n --arg id "$uuid" --argjson i "$input" '{id: $id, i: $i}')" >/dev/null; then
      echo "updated $update $(jq -r '.data.issue.url // empty' <<<"$existing")"
    else echo "::warning::Could not rewrite ticket $update" >&2; fi
    return 0
  fi
  created=$(linear_create_issue "$input" 2>/dev/null) || created=""
  if [ -z "$created" ]; then echo "::warning::Could not create ticket: $title" >&2; return 0; fi
  ident=${created%% *}; url=${created#* }

  # Relations. Tickets that block the new one, tickets the new one blocks (they wait in Blocked), related tickets.
  for other in $(jq -r '(.blocked_by // [])[]' <<<"$spec"); do issue_relate "$other" "$ident" blocks; done
  for other in $(jq -r '(.blocks // [])[]' <<<"$spec"); do
    issue_relate "$ident" "$other" blocks
    if [ "$(jq -r '.block_state != false' <<<"$spec")" = true ]; then linear_set_state "$other" Blocked; fi
  done
  for other in $(jq -r '(.related // [])[]' <<<"$spec"); do issue_relate "$ident" "$other" related; done
  echo "created $ident $url"
}

# $1 = source issue, $2 = JSON file with [{title, goal, acceptance, out_of_scope, agent_notes}] (a plain "description" is used as the goal),
# $3 = footer, $4 = optional "blocking": the new tickets are manual work that blocks the source issue.
# Creates the tickets through issue_write (same team and project as the source, Todo, Origin › Agent, no duplicates of open follow-ups)
# and prints a markdown line per ticket.
linear_create_follow_ups() {
  local data ctx item spec out ident url
  data=$(linear_issue "$1") || { echo "::warning::Linear lookup failed" >&2; return 0; }
  ctx=$(jq -c '.data.issue | {id: (.project.id // null), team: .team}' <<<"$data")
  [ "$(jq -r '.team.id // empty' <<<"$ctx")" != "" ] || return 0
  while IFS= read -r item; do
    spec=$(jq -c --arg f "$3" --arg src "$(jq -r '.data.issue.identifier' <<<"$data")" '
      {title, goal: (.goal // .description // ""), acceptance, out_of_scope, agent_notes, footer: $f,
       origin: "Agent", state: "todo", labels: ["factory:follow-up"], dedup: true,
       dedup_comment: ("The reviewer proposed this again (follow-up to " + $src + ").")}' <<<"$item")
    out=$(issue_write "$spec" "$ctx") || true
    case "$out" in
      "created "*) read -r _ ident url <<<"$out"; echo "- [$ident]($url): $(jq -r .title <<<"$item")" ;;
      "duplicate "*) echo "::notice::Skipped duplicate follow-up: $(jq -r .title <<<"$item")" >&2 ;;
      *) echo "::warning::Could not create follow-up: $(jq -r .title <<<"$item")" >&2 ;;
    esac
  done < <(jq -c '.[]' "$2")
}

# $1 = source issue identifier, $2 = JSON file with [{title, why, steps}], $3 = "blocking" (the source issue waits in Blocked)
# or "related", $4 = footer. Creates one manual ticket per task: factory:manual, assigned to Koen, exact steps, Todo.
# Prints a markdown line per ticket.
linear_create_manual_tickets() {
  local data ctx item spec out ident url blocks=false
  data=$(linear_issue "$1") || { echo "::warning::Linear lookup failed" >&2; return 0; }
  ctx=$(jq -c '.data.issue | {id: (.project.id // null), team: .team}' <<<"$data")
  [ "$(jq -r '.team.id // empty' <<<"$ctx")" != "" ] || return 0
  [ "$3" = blocking ] && blocks=true
  while IFS= read -r item; do
    spec=$(jq -c --arg f "$4" --arg src "$1" --argjson b "$blocks" '
      {title, goal: ((.why // "") + "\n\nThis is manual work the factory could not do or confirm itself. It is needed for " + $src + "."),
       steps, acceptance: (.acceptance // ["The steps above are done."]),
       agent_notes: ("The factory checked that it cannot do this itself. When this ticket is Done" + (if $b then ", " + $src + " is released by the relay." else "." end)),
       footer: $f, origin: "Agent", manual: true, delivery: "Human involved", state: "todo", dedup: true,
       related: (if $b then [] else [$src] end), blocks: (if $b then [$src] else [] end)}' <<<"$item")
    out=$(issue_write "$spec" "$ctx") || true
    case "$out" in
      "created "*) read -r _ ident url <<<"$out"; echo "- [$ident]($url): $(jq -r .title <<<"$item")" ;;
      "duplicate "*) echo "::notice::Skipped duplicate manual ticket: $(jq -r .title <<<"$item")" >&2 ;;
      *) echo "::warning::Could not create manual ticket: $(jq -r .title <<<"$item")" >&2 ;;
    esac
  done < <(jq -c '.[]' "$2")
}
