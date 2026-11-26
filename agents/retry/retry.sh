#!/usr/bin/env bash
# Usage limit retries (docs/usage-limits.md): finds retry requests that the builder and reviewer left on tickets when
# Claude's usage limit stopped them, and sends the original event again once its time has come.
# For every repo in the relay's PROJECT_REPOS, looks at the tickets in Agent Working and In Review. A request (a comment
# with a hidden marker holding the original payload) that is due and not started yet is sent as a repository_dispatch with
# the same event type and payload; a comment marks it as started. Requests more than 3 hours past due are left to the
# stuck check.
# Usage: retry.sh [--dry-run]   (or DRY_RUN=1): only prints what it would send.
# Env: GH_TOKEN (factory app token), FACTORY_REPO ("owner/repo"), LINEAR_API_KEY.
# Optional: WRANGLER_CONFIG, APPS_FILE, RETRY_NOW (epoch seconds), for tests.
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$here/../.." && pwd)
# shellcheck source=../lib/linear.sh
source "$here/../lib/linear.sh"
# shellcheck source=../health/checks.sh
source "$here/../health/checks.sh"
# shellcheck source=../lib/usage-limit.sh
source "$here/../lib/usage-limit.sh"
[ "$1" = "--dry-run" ] && DRY_RUN=1
: "${FACTORY_REPO:?FACTORY_REPO is required}"
WRANGLER_CONFIG=${WRANGLER_CONFIG:-$ROOT/relay/wrangler.jsonc}
APPS_FILE=${APPS_FILE:-$ROOT/agents/scout/apps.json}
NOW=${RETRY_NOW:-$(date +%s)}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# $1 = repo, $2 = identifier. Sends the pending retry of the ticket, if it is due.
retry_ticket() {
  local repo=$1 id=$2 comments req at event n key payload
  comments=$(linear_issue_comments "$id" 2>/dev/null) || comments="[]"
  [ -n "$comments" ] || comments="[]"
  req=$(retry_pending "$comments" "$NOW")
  [ -n "$req" ] || return 0
  at=$(jq -r .at <<<"$req"); event=$(jq -r .event <<<"$req"); n=$(jq -r .n <<<"$req"); key=$(jq -r .key <<<"$req")
  if [ "$at" -gt "$NOW" ]; then echo "$id: retry $n of $key is due in $(( (at - NOW) / 60 )) minute(s), waiting."; return 0; fi
  payload=$(jq -r .payload <<<"$req" | base64 -d 2>/dev/null) || payload=""
  if ! jq -e 'type == "object"' <<<"$payload" >/dev/null 2>&1; then echo "::warning::$id: the retry request has no readable payload"; return 0; fi
  echo "$id: sending $event again (retry $n)."
  [ -z "$DRY_RUN" ] || return 0
  jq -c --arg e "$event" '{event_type: $e, client_payload: .}' <<<"$payload" > "$TMP/dispatch.json"
  if gh api "repos/$repo/dispatches" --input "$TMP/dispatch.json" >/dev/null; then
    [ "$event" != factory-fix ] || gh pr edit "$(jq -r '.pr_number // empty' <<<"$payload")" -R "$repo" --add-label agent-fixing >/dev/null 2>&1 || true
    linear_comment "$id" "🔁 Trying again after the usage limit (retry $n of $RETRY_MAX).
<!-- factory-retry-started key=$key n=$n -->"
  else
    echo "::warning::$id: the GitHub dispatch for the retry was refused"
  fi
}

while IFS=$'\t' read -r repo project _; do
  ctx=$(linear_project_context "$project" 2>/dev/null) || ctx=""
  project_id=$(jq -r '.id // empty' <<<"$ctx" 2>/dev/null); team_id=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null)
  if [ -z "$project_id" ] || [ -z "$team_id" ]; then echo "::warning::Linear project '$project' not found; skipped $repo."; continue; fi
  for state in "Agent Working" "In Review"; do
    tickets=$(linear_issues_in_state "$team_id" "$project_id" "$state" 2>/dev/null) || tickets="[]"
    [ -n "$tickets" ] || tickets="[]"
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      retry_ticket "$repo" "$id"
    done < <(jq -r '.[].identifier' <<<"$tickets")
  done
done < <(list_repos)
exit 0
