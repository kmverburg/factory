# shellcheck shell=bash
# Linear helpers, sourced by the agent scripts.
# Every function warns instead of failing, so Linear problems never break a build.
linear_gql() {
  [ -n "$LINEAR_API_KEY" ] || return 1
  curl -sS --fail-with-body https://api.linear.app/graphql \
    -H "Content-Type: application/json" -H "Authorization: $LINEAR_API_KEY" \
    -d "$(jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')"
}
# $1 = issue identifier (KOE-6) or id. Prints the issue as JSON.
linear_issue() {
  linear_gql 'query($id: String!) { issue(id: $id) { id identifier title description url state { name type } project { id } labels(first: 250) { nodes { id name parent { name } } } team { id states { nodes { id name type } } labels(first: 250) { nodes { id name parent { name } } } } } }' \
    "$(jq -n --arg id "$1" '{id: $id}')"
}
# $1 = issue, $2 = state name (case-insensitive)
linear_set_state() {
  local data uuid state_id
  data=$(linear_issue "$1") || { echo "::warning::Linear lookup failed"; return 0; }
  uuid=$(jq -r '.data.issue.id // empty' <<<"$data")
  # Never reopen a finished issue: a run that ends after the PR was merged must not undo "Done".
  case "$(jq -r '.data.issue.state.type // empty' <<<"$data")" in
    completed|canceled) echo "::notice::Linear issue $1 is already $(jq -r '.data.issue.state.name' <<<"$data"); not moving it to '$2'"; return 0 ;;
  esac
  state_id=$(jq -r --arg n "$2" '.data.issue.team.states.nodes[] | select((.name | ascii_downcase) == ($n | ascii_downcase)) | .id' <<<"$data" | head -n1)
  if [ -z "$uuid" ] || [ -z "$state_id" ]; then echo "::warning::Linear issue $1 or state '$2' not found"; return 0; fi
  linear_gql 'mutation($id: String!, $s: String!) { issueUpdate(id: $id, input: { stateId: $s }) { success } }' \
    "$(jq -n --arg id "$uuid" --arg s "$state_id" '{id: $id, s: $s}')" >/dev/null \
    || echo "::warning::Linear state update failed"
}
# $1 = issue, $2 = markdown body
linear_comment() {
  local uuid
  uuid=$(linear_issue "$1" | jq -r '.data.issue.id // empty') || true
  [ -n "$uuid" ] || { echo "::warning::Linear issue $1 not found"; return 0; }
  linear_gql 'mutation($i: String!, $b: String!) { commentCreate(input: { issueId: $i, body: $b }) { success } }' \
    "$(jq -n --arg i "$uuid" --arg b "$2" '{i: $i, b: $b}')" >/dev/null \
    || echo "::warning::Linear comment failed"
}
# $1 = labels JSON [{id, name, parent: {name}}], $2 = group, $3 = label. Prints the id of that label inside that group, or nothing.
linear_group_label_id() {
  jq -r --arg g "$2" --arg l "$3" '[.[] | select(((.parent.name // "") | ascii_downcase) == ($g | ascii_downcase) and (.name | ascii_downcase) == ($l | ascii_downcase))][0].id // empty' <<<"$1"
}
# $1 = issue, $2 = label group (Delivery), $3 = label (Autonomous). Makes it the only label of that group on the issue and keeps all other labels.
# "Human involved" in group Delivery is never replaced by "Autonomous". Warns instead of failing.
linear_set_group_label() {
  local data uuid target others other
  data=$(linear_issue "$1") || { echo "::warning::Linear lookup failed"; return 0; }
  uuid=$(jq -r '.data.issue.id // empty' <<<"$data")
  target=$(linear_group_label_id "$(jq -c '.data.issue.team.labels.nodes // []' <<<"$data")" "$2" "$3")
  if [ -z "$uuid" ] || [ -z "$target" ]; then echo "::warning::Linear issue $1 or label '$2 › $3' not found"; return 0; fi
  # Labels of the same group already on the issue (other than the target).
  others=$(jq -r --arg g "$2" --arg t "$target" '.data.issue.labels.nodes[] | select(((.parent.name // "") | ascii_downcase) == ($g | ascii_downcase) and .id != $t) | "\(.id)\t\(.name)"' <<<"$data")
  if [ "$(tr '[:upper:]' '[:lower:]' <<<"$3")" = "autonomous" ] && grep -qiP '\tHuman involved$' <<<"$others"; then
    echo "::notice::Linear issue $1 already has Human involved; not setting Autonomous"; return 0
  fi
  while IFS=$'\t' read -r other _; do
    [ -n "$other" ] || continue
    linear_gql 'mutation($id: String!, $l: String!) { issueRemoveLabel(id: $id, labelId: $l) { success } }' \
      "$(jq -n --arg id "$uuid" --arg l "$other" '{id: $id, l: $l}')" >/dev/null \
      || echo "::warning::Linear label removal failed"
  done <<<"$others"
  if jq -e --arg t "$target" '.data.issue.labels.nodes | any(.id == $t)' <<<"$data" >/dev/null; then return 0; fi
  linear_gql 'mutation($id: String!, $l: String!) { issueAddLabel(id: $id, labelId: $l) { success } }' \
    "$(jq -n --arg id "$uuid" --arg l "$target" '{id: $id, l: $l}')" >/dev/null \
    || echo "::warning::Linear label update failed"
}
FOLLOW_UP_LABEL="factory:follow-up"
# $1 = team id. Prints titles of open follow-up issues, one per line.
linear_open_follow_ups() {
  linear_gql 'query($t: ID!, $l: String!) { issues(first: 100, filter: { team: { id: { eq: $t } }, labels: { some: { name: { eq: $l } } }, state: { type: { nin: ["completed", "canceled"] } } }) { nodes { identifier title } } }' \
    "$(jq -n --arg t "$1" --arg l "$FOLLOW_UP_LABEL" '{t: $t, l: $l}')" \
    | jq -r '.data.issues.nodes[] | "\(.identifier): \(.title)"'
}
# $1 = source issue, $2 = JSON file with [{title, description}], $3 = footer.
# Creates the issues in Todo (same team and project) and prints a markdown line per issue.
linear_create_follow_ups() {
  local data team_id project_id state_id label_id origin_id existing item title desc input created
  data=$(linear_issue "$1") || { echo "::warning::Linear lookup failed" >&2; return 0; }
  team_id=$(jq -r '.data.issue.team.id // empty' <<<"$data")
  [ -n "$team_id" ] || return 0
  project_id=$(jq -r '.data.issue.project.id // empty' <<<"$data")
  state_id=$(jq -r '[.data.issue.team.states.nodes[] | select((.name | ascii_downcase) == "todo")][0].id // empty' <<<"$data")
  [ -n "$state_id" ] || state_id=$(jq -r '[.data.issue.team.states.nodes[] | select(.type == "backlog")][0].id // empty' <<<"$data")
  label_id=$(jq -r --arg l "$FOLLOW_UP_LABEL" '[.data.issue.team.labels.nodes[] | select(.name == $l)][0].id // empty' <<<"$data")
  if [ -z "$label_id" ]; then
    label_id=$(linear_gql 'mutation($n: String!, $t: String!) { issueLabelCreate(input: { name: $n, teamId: $t, color: "#5E6AD2" }) { issueLabel { id } } }' \
      "$(jq -n --arg n "$FOLLOW_UP_LABEL" --arg t "$team_id" '{n: $n, t: $t}')" | jq -r '.data.issueLabelCreate.issueLabel.id // empty') || true
  fi
  origin_id=$(linear_group_label_id "$(jq -c '.data.issue.team.labels.nodes // []' <<<"$data")" Origin Agent)
  [ -n "$origin_id" ] || echo "::warning::Label 'Origin › Agent' not found" >&2
  existing=$(linear_open_follow_ups "$team_id" | sed -E 's/^[^:]+: //' | tr '[:upper:]' '[:lower:]') || true
  while IFS= read -r item; do
    title=$(jq -r '.title' <<<"$item")
    desc=$(jq -r '.description' <<<"$item")
    if grep -qxF "$(tr '[:upper:]' '[:lower:]' <<<"$title")" <<<"$existing"; then
      echo "::notice::Skipped duplicate follow-up: $title" >&2
      continue
    fi
    input=$(jq -n --arg t "$team_id" --arg ti "$title" --arg d "$desc"$'\n\n---\n'"$3" --arg s "$state_id" --arg l "$label_id" --arg o "$origin_id" --arg p "$project_id" \
      '{teamId: $t, title: $ti, description: $d}
       + (if $s != "" then {stateId: $s} else {} end)
       + {labelIds: ([$l, $o] | map(select(. != "")))}
       + (if $p != "" then {projectId: $p} else {} end)')
    created=$(linear_gql 'mutation($input: IssueCreateInput!) { issueCreate(input: $input) { issue { identifier url } } }' \
      "$(jq -n --argjson i "$input" '{input: $i}')" | jq -r '.data.issueCreate.issue // empty | "- [\(.identifier)](\(.url)): "' 2>/dev/null) || true
    if [ -z "$created" ]; then echo "::warning::Could not create follow-up: $title" >&2; continue; fi
    echo "$created$title"
  done < <(jq -c '.[]' "$2")
}
# $1 = project name (case-insensitive). Prints {id, name, team: {id, states, labels}} for its first team, or nothing.
linear_project_context() {
  linear_gql 'query($n: String!) { projects(first: 1, filter: { name: { eqIgnoreCase: $n } }) { nodes { id name teams(first: 1) { nodes { id states { nodes { id name type } } labels(first: 250) { nodes { id name parent { name } } } } } } } }' \
    "$(jq -n --arg n "$1" '{n: $n}')" \
    | jq -c '.data.projects.nodes[0] // empty | {id, name, team: .teams.nodes[0]}'
}
# $1 = team id, $2 = project id, $3 = label name. Prints open issues with that label as a JSON array [{id, identifier, description}].
linear_open_issues_with_label() {
  linear_gql 'query($t: ID!, $p: ID!, $l: String!) { issues(first: 250, filter: { team: { id: { eq: $t } }, project: { id: { eq: $p } }, labels: { some: { name: { eq: $l } } }, state: { type: { nin: ["completed", "canceled"] } } }) { nodes { id identifier description } } }' \
    "$(jq -n --arg t "$1" --arg p "$2" --arg l "$3" '{t: $t, p: $p, l: $l}')" \
    | jq -c '.data.issues.nodes'
}
# $1 = team id, $2 = label name, $3 = the team's labels as JSON [{id, name}]. Prints the label id, creating the label if needed.
linear_ensure_label() {
  local id
  id=$(jq -r --arg l "$2" '[.[] | select(.name == $l)][0].id // empty' <<<"$3")
  if [ -z "$id" ]; then
    id=$(linear_gql 'mutation($n: String!, $t: String!) { issueLabelCreate(input: { name: $n, teamId: $t, color: "#F2994A" }) { issueLabel { id } } }' \
      "$(jq -n --arg n "$2" --arg t "$1" '{n: $n, t: $t}')" | jq -r '.data.issueLabelCreate.issueLabel.id // empty') || true
  fi
  echo "$id"
}
# $1 = issue input JSON (IssueCreateInput). Prints "IDENTIFIER url" or nothing. Never moves an issue to Agent Ready: callers choose the state.
linear_create_issue() {
  linear_gql 'mutation($input: IssueCreateInput!) { issueCreate(input: $input) { issue { identifier url } } }' \
    "$(jq -n --argjson i "$1" '{input: $i}')" | jq -r '.data.issueCreate.issue // empty | "\(.identifier) \(.url)"'
}
# $1 = issue uuid, $2 = markdown body
linear_comment_on_id() {
  linear_gql 'mutation($i: String!, $b: String!) { commentCreate(input: { issueId: $i, body: $b }) { success } }' \
    "$(jq -n --arg i "$1" --arg b "$2" '{i: $i, b: $b}')" >/dev/null \
    || echo "::warning::Linear comment failed"
}
# $1 = project id. Prints the project's latest updates as a JSON array [{createdAt, body}] (newest first).
linear_project_updates() {
  linear_gql 'query($p: String!) { project(id: $p) { projectUpdates(first: 10) { nodes { createdAt body } } } }' \
    "$(jq -n --arg p "$1" '{p: $p}')" | jq -c '.data.project.projectUpdates.nodes // empty'
}
# $1 = project id, $2 = markdown body, $3 = health (onTrack, atRisk or offTrack). Prints the update url, or nothing.
linear_project_update_create() {
  linear_gql 'mutation($p: String!, $b: String!, $h: ProjectUpdateHealthType) { projectUpdateCreate(input: { projectId: $p, body: $b, health: $h }) { projectUpdate { url } } }' \
    "$(jq -n --arg p "$1" --arg b "$2" --arg h "$3" '{p: $p, b: $b, h: $h}')" \
    | jq -r '.data.projectUpdateCreate.projectUpdate.url // empty'
}
