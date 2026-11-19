#!/usr/bin/env bash
# Keeps every app repo's .github/workflows/factory.yml equal to templates/app-repo/.github/workflows/factory.yml.
# For each app repo in the relay's PROJECT_REPOS (minus this repo) whose copy differs, it opens or updates one PR
# titled "Update factory caller workflow". The leading comment lines are repo-specific and are left alone.
# A failure for one repo is reported at the end and doesn't stop the others.
# Every PR gets a Linear ticket ("Merge the factory caller update", Needs Human) in the app's project (the PROJECT_REPOS key).
# The PR's branch and title start with the ticket's identifier so Linear links the PR. An open sync PR keeps its ticket.
# The ticket that caused the change (from the merge commit title) gets a comment linking the new tickets and PRs.
# Linear problems only log warnings; the PRs are opened anyway.
# Env: GH_TOKEN (the factory app's token, covering all app repos), FACTORY_REPO (this repo, "owner/repo"), LINEAR_API_KEY.
# Optional: TRIGGER_TITLE (the merge commit message), TEMPLATE, WRANGLER_CONFIG (paths, for tests).
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
# shellcheck source=../lib/linear.sh
source "$root/agents/lib/linear.sh"
template=${TEMPLATE:-$root/templates/app-repo/.github/workflows/factory.yml}
config=${WRANGLER_CONFIG:-$root/relay/wrangler.jsonc}
path=.github/workflows/factory.yml
fallback_branch=factory/sync-caller-workflow
title="Update factory caller workflow"
ticket_title="Merge the factory caller update"
label=factory-sync
: "${FACTORY_REPO:?FACTORY_REPO is required}"

# The leading comment lines only.
header() { awk '/^#/ { print; next } { exit }' "$1"; }
# Everything after the leading comment lines.
body() { awk 'f || !/^#/ { f = 1; print }' "$1"; }

# "repo<TAB>project" lines from the first PROJECT_REPOS block of the relay config (JSONC, so no jq), minus the factory itself.
# Values may be "repo" (the factory's owner is assumed) or "owner/repo".
repos() {
  awk '/"PROJECT_REPOS"/ { on = 1 } on { print } on && /}/ { exit }' "$config" \
    | grep -oE '"[^"]+"[[:space:]]*:[[:space:]]*"[^"/]+(/[^"/]+)?"' \
    | sed -E 's/^"([^"]+)"[[:space:]]*:[[:space:]]*"([^"]+)"$/\2\t\1/' \
    | awk -F'\t' -v owner="${FACTORY_REPO%%/*}" '{ print (index($1, "/") ? $1 : owner "/" $1) "\t" $2 }' \
    | grep -v "^$FACTORY_REPO	" | sort -u || true
}

# $1 = project name. Creates the Linear ticket for a sync PR and prints "IDENTIFIER url", or nothing (with a warning).
create_ticket() {
  local ctx team_id project_id state_id labels origin human desc input created
  ctx=$(linear_project_context "$1" 2>/dev/null) || ctx=""
  team_id=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null) || team_id=""
  project_id=$(jq -r '.id // empty' <<<"$ctx" 2>/dev/null) || project_id=""
  if [ -z "$team_id" ]; then echo "::warning::Linear project '$1' not found or Linear unreachable; no ticket for $repo" >&2; return 0; fi
  state_id=$(jq -r '[.team.states.nodes[] | select((.name | ascii_downcase) == "needs human")][0].id // empty' <<<"$ctx")
  labels=$(jq -c '.team.labels.nodes // []' <<<"$ctx")
  origin=$(linear_group_label_id "$labels" Origin Agent)
  human=$(linear_group_label_id "$labels" Delivery "Human involved")
  [ -n "$state_id" ] || echo "::warning::Linear state 'Needs Human' not found for project '$1'" >&2
  [ -n "$origin" ] && [ -n "$human" ] || echo "::warning::Linear labels 'Origin › Agent' or 'Delivery › Human involved' not found for project '$1'" >&2
  desc="The factory's caller workflow template changed in $FACTORY_REPO${trigger_id:+ ($trigger_id)}, so \`$path\` in \`$repo\` has to change too. The factory opened a pull request that syncs it; the leading comment lines of the file are kept.

The PR touches \`.github/\`, so the factory reviewer always escalates it and it needs a human to approve and merge it. Merging the PR moves this ticket to Done."
  input=$(jq -n --arg t "$team_id" --arg ti "$ticket_title" --arg d "$desc" --arg s "$state_id" --arg o "$origin" --arg h "$human" --arg p "$project_id" \
    '{teamId: $t, title: $ti, description: $d}
     + (if $s != "" then {stateId: $s} else {} end)
     + {labelIds: ([$o, $h] | map(select(. != "")))}
     + (if $p != "" then {projectId: $p} else {} end)')
  created=$(linear_create_issue "$input" 2>/dev/null) || created=""
  if [ -z "$created" ]; then echo "::warning::Could not create the Linear ticket for $repo" >&2; fi
  echo "$created"
}

sync_repo() {
  local repo=$1 project=$2 tmp=$3 default sha head new existing branch pr_title ticket ticket_id ticket_url pr_url
  default=$(gh api "repos/$repo" --jq .default_branch) || return 1

  # The repo's current copy (it may be missing).
  if gh api "repos/$repo/contents/$path?ref=$default" > "$tmp/file.json" 2> "$tmp/err"; then
    jq -r .content "$tmp/file.json" | base64 -d > "$tmp/current.yml" || return 1
    sha=$(jq -r .sha "$tmp/file.json")
  elif grep -qi "not found\|404" "$tmp/err"; then
    : > "$tmp/current.yml"; sha=""
  else
    cat "$tmp/err" >&2; return 1
  fi

  if [ -n "$sha" ] && [ "$(body "$tmp/current.yml")" = "$(body "$template")" ]; then
    echo "$repo: up to date"; return 0
  fi

  # New file = the repo's own header comments (or the template's if it has no copy) + the template's body.
  { if [ -n "$sha" ]; then header "$tmp/current.yml"; else header "$template"; fi; body "$template"; } > "$tmp/new.yml"

  # An open sync PR is updated and keeps its ticket (the identifier in its branch name); otherwise a new ticket and branch.
  existing=$(gh pr list -R "$repo" --label "$label" --state open --json number,headRefName --jq '.[0] // empty | "\(.number) \(.headRefName)"') || return 1
  ticket_id=""; ticket_url=""
  if [ -n "$existing" ]; then
    new=${existing%% *}; branch=${existing#* }
    ticket_id=$(grep -oiE '^[a-z][a-z0-9]*-[0-9]+' <<<"$branch" | tr '[:lower:]' '[:upper:]' | head -n1 || true)
  else
    new=""
    ticket=$(create_ticket "$project")
    ticket_id=${ticket%% *}; ticket_url=${ticket#* }
    if [ -n "$ticket_id" ]; then branch="$(tr '[:upper:]' '[:lower:]' <<<"$ticket_id")-factory-caller-update"; else branch=$fallback_branch; fi
  fi
  pr_title=${ticket_id:+$ticket_id: }$title

  # The branch always starts from the current default branch, so an old sync PR is brought up to date.
  head=$(gh api "repos/$repo/git/ref/heads/$default" --jq .object.sha) || return 1
  if ! gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$head" >/dev/null 2>&1; then
    gh api -X PATCH "repos/$repo/git/refs/heads/$branch" -f sha="$head" -F force=true >/dev/null || return 1
  fi
  jq -n --arg m "$pr_title" --arg b "$branch" --arg s "$sha" --rawfile c "$tmp/new.yml" \
    '{message: $m, branch: $b, content: ($c | @base64)} + (if $s != "" then {sha: $s} else {} end)' > "$tmp/put.json"
  gh api -X PUT "repos/$repo/contents/$path" --input "$tmp/put.json" >/dev/null || return 1

  if [ -n "$new" ]; then
    echo "$repo: updated PR #$new"
    echo "- $repo: updated PR #$new${ticket_id:+ (ticket $ticket_id)}" >> "$summary"
    return 0
  fi
  gh label create "$label" -R "$repo" --color 5319E7 --description "Synced from the factory's caller template" --force >/dev/null || return 1
  pr_url=$(gh pr create -R "$repo" --head "$branch" --base "$default" --title "$pr_title" --label "$label" --body \
"Syncs \`$path\` with the template in $FACTORY_REPO (\`templates/app-repo/$path\`). The leading comment lines are kept.

This PR changes \`.github/\`, so the factory reviewer always escalates it for a human to approve. It is opened automatically by the factory's *Sync caller workflow* run.${ticket_id:+

Linear: $ticket_id}") || return 1
  echo "$repo: opened PR"
  echo "- $repo: ${pr_url:-opened PR}${ticket_id:+, ticket ${ticket_url:+[$ticket_id]($ticket_url)}}" >> "$summary"
}

list=$(repos)
if [ -z "$list" ]; then echo "::error::No app repos found in $config"; exit 1; fi
# The ticket that caused the change, from the merge commit title ("KV-35: ...").
trigger_id=$(head -n1 <<<"${TRIGGER_TITLE:-}" | grep -oE '^[A-Z][A-Z0-9]*-[0-9]+' || true)
summary=$(mktemp)
failed=""
while IFS=$'\t' read -r repo project; do
  tmp=$(mktemp -d)
  if ! sync_repo "$repo" "$project" "$tmp"; then
    echo "::error::Syncing $repo failed"; failed="$failed $repo"
  fi
  rm -rf "$tmp"
done <<< "$list"
if [ -n "$trigger_id" ] && [ -s "$summary" ]; then
  linear_comment "$trigger_id" "The factory caller template change needs a sync in the app repos. Tickets and PRs for a human to merge:

$(cat "$summary")" || echo "::warning::Could not comment on $trigger_id"
fi
rm -f "$summary"
if [ -n "$failed" ]; then echo "Failed:$failed"; exit 1; fi
