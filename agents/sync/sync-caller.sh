#!/usr/bin/env bash
# Keeps every app repo's .github/workflows/factory.yml equal to templates/app-repo/.github/workflows/factory.yml.
# For each app repo in the relay's PROJECT_REPOS (minus this repo) whose copy differs, it opens or updates one PR
# titled "Update factory caller workflow". The leading comment lines are repo-specific and are left alone.
# A failure for one repo is reported at the end and doesn't stop the others.
# Env: GH_TOKEN (the factory app's token, covering all app repos), FACTORY_REPO (this repo, "owner/repo").
# Optional: TEMPLATE, WRANGLER_CONFIG (paths, for tests).
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
template=${TEMPLATE:-$root/templates/app-repo/.github/workflows/factory.yml}
config=${WRANGLER_CONFIG:-$root/relay/wrangler.jsonc}
path=.github/workflows/factory.yml
branch=factory/sync-caller-workflow
title="Update factory caller workflow"
label=factory-sync
: "${FACTORY_REPO:?FACTORY_REPO is required}"

# The leading comment lines only.
header() { awk '/^#/ { print; next } { exit }' "$1"; }
# Everything after the leading comment lines.
body() { awk 'f || !/^#/ { f = 1; print }' "$1"; }

# Repos from the first PROJECT_REPOS block of the relay config (JSONC, so no jq), minus the factory itself.
# Values may be "repo" (the factory's owner is assumed) or "owner/repo".
repos() {
  awk '/"PROJECT_REPOS"/ { on = 1 } on { print } on && /}/ { exit }' "$config" \
    | grep -oE '"[^"]+"[[:space:]]*:[[:space:]]*"[^"/]+(/[^"/]+)?"' \
    | sed -E 's/.*:[[:space:]]*"([^"]+)"$/\1/' \
    | awk -v owner="${FACTORY_REPO%%/*}" '{ print (index($0, "/") ? $0 : owner "/" $0) }' \
    | grep -vxF "$FACTORY_REPO" | sort -u || true
}

sync_repo() {
  local repo=$1 tmp=$2 default sha head new
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

  # The branch always starts from the current default branch, so an old sync PR is brought up to date.
  head=$(gh api "repos/$repo/git/ref/heads/$default" --jq .object.sha) || return 1
  if ! gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$head" >/dev/null 2>&1; then
    gh api -X PATCH "repos/$repo/git/refs/heads/$branch" -f sha="$head" -F force=true >/dev/null || return 1
  fi
  jq -n --arg m "$title" --arg b "$branch" --arg s "$sha" --rawfile c "$tmp/new.yml" \
    '{message: $m, branch: $b, content: ($c | @base64)} + (if $s != "" then {sha: $s} else {} end)' > "$tmp/put.json"
  gh api -X PUT "repos/$repo/contents/$path" --input "$tmp/put.json" >/dev/null || return 1

  new=$(gh pr list -R "$repo" --head "$branch" --state open --json number --jq '.[0].number // empty') || return 1
  if [ -n "$new" ]; then
    echo "$repo: updated PR #$new"; return 0
  fi
  gh label create "$label" -R "$repo" --color 5319E7 --description "Synced from the factory's caller template" --force >/dev/null || return 1
  gh pr create -R "$repo" --head "$branch" --base "$default" --title "$title" --label "$label" --body \
"Syncs \`$path\` with the template in $FACTORY_REPO (\`templates/app-repo/$path\`). The leading comment lines are kept.

This PR changes \`.github/\`, so the factory reviewer always escalates it for a human to approve. It is opened automatically by the factory's *Sync caller workflow* run." || return 1
  echo "$repo: opened PR"
}

list=$(repos)
if [ -z "$list" ]; then echo "::error::No app repos found in $config"; exit 1; fi
failed=""
while IFS= read -r repo; do
  tmp=$(mktemp -d)
  if ! sync_repo "$repo" "$tmp"; then
    echo "::error::Syncing $repo failed"; failed="$failed $repo"
  fi
  rm -rf "$tmp"
done <<< "$list"
if [ -n "$failed" ]; then echo "Failed:$failed"; exit 1; fi
