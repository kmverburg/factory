#!/usr/bin/env bash
# Weekly dependency check. For every app repo in agents/scout/apps.json (plus this repo) it makes a shallow clone, runs
# `npm outdated` and `npm audit` for every package.json that has a package-lock.json, and files tickets through the issue
# writer in the repo's Linear project: security fixes (high priority, Agent Ready, Todo when a fix needs a new major),
# routine minor and patch updates (Agent Ready) and major updates (Todo). Only versions at least 2 weeks old are proposed,
# except for security fixes. An open ticket from an earlier week is updated, not duplicated. Nothing to do = no ticket.
# Usage: deps.sh [--dry-run]   (or DRY_RUN=1: prints the tickets, touches nothing in Linear)
# Env: GH_TOKEN (read access to the repos), LINEAR_API_KEY, GITHUB_OWNER (owner of the repos in apps.json), FACTORY_REPO
# ("owner/repo", checked too, in the Linear project FACTORY_PROJECT, default "Factory").
# Optional: DEPS_APPS (apps file), MIN_AGE_DAYS (default 14), DEPS_NOW (epoch seconds, for tests), DEPS_ONLY (one repo name).
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
# shellcheck source=../lib/linear.sh
source "$root/agents/lib/linear.sh"
# shellcheck source=../lib/issue-writer.sh
source "$root/agents/lib/issue-writer.sh"
[ "$1" = "--dry-run" ] && DRY_RUN=1
apps_file=${DEPS_APPS:-$root/agents/scout/apps.json}
min_age=${MIN_AGE_DAYS:-14}
now=${DEPS_NOW:-$(date -u +%s)}
week=$(date -u -d "@$now" +%G-W%V)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
FAILED=0

# "project<TAB>owner/repo" per line.
repo_list() {
  local owner=$GITHUB_OWNER
  [ -z "$owner" ] && [ -n "$FACTORY_REPO" ] && owner=${FACTORY_REPO%%/*}
  jq -r --arg o "$owner" '.[] | [.project, (if (.repo | contains("/")) then .repo else $o + "/" + .repo end)] | @tsv' "$apps_file"
  if [ -n "$FACTORY_REPO" ]; then printf '%s\t%s\n' "${FACTORY_PROJECT:-Factory}" "$FACTORY_REPO"; fi
}

# $1 = directory with package.json and package-lock.json, $2 = relative name. Appends to $tmp/updates.jsonl, $tmp/security.jsonl.
scan_dir() {
  local dir=$1 rel=$2 outdated audit name current times t
  # --ignore-scripts: nothing from the packages runs.
  (cd "$dir" && npm ci --ignore-scripts --no-audit --no-fund >/dev/null 2>"$tmp/npm.err") || { echo "::warning::npm ci failed in $rel" >&2; echo "$rel" >> "$tmp/failed.txt"; return 0; }
  outdated=$(cd "$dir" && npm outdated --json 2>/dev/null || true)
  [ -n "$outdated" ] || outdated='{}'
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$outdated" || outdated='{}'
  while IFS=$'\t' read -r name current; do
    [ -n "$name" ] || continue
    times=$(cd "$dir" && npm view "$name" time --json 2>/dev/null || true)
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$times" || { echo "::warning::No publish times for $name" >&2; continue; }
    t=$(jq -c --arg c "$current" --argjson now "$now" --argjson d "$min_age" '{current: $c, times: ., now: $now, min_age_days: $d}' <<<"$times" | jq -c -f "$here/target.jq")
    jq -nc --arg dir "$rel" --arg name "$name" --arg cur "$current" --argjson t "$t" '
      def kind($a; $b): ($a | split(".") | map(tonumber)) as $x | ($b | split(".") | map(tonumber)) as $y
        | if $x[0] != $y[0] then "major" elif $x[1] != $y[1] then "minor" else "patch" end;
      [ ($t.same_major | select(. != null)), ($t.major | select(. != null)) ][]
      | . as $v | kind($cur; $v) as $k
      | {dir: $dir, name: $name, current: $cur, target: $v, kind: $k,
         reason: (if $k == "major" then "major version" elif $k == "patch" then "bug fix release" else "routine update" end)}' >> "$tmp/updates.jsonl"
  done < <(jq -r 'to_entries[] | select(.value.current != null) | [.key, .value.current] | @tsv' <<<"$outdated")
  audit=$(cd "$dir" && npm audit --json 2>/dev/null || true)
  jq -e '.vulnerabilities | type == "object"' >/dev/null 2>&1 <<<"$audit" || return 0
  jq -c --arg dir "$rel" '.vulnerabilities | to_entries[] | .value as $v
    | {dir: $dir, name: .key, severity: $v.severity, direct: ($v.isDirect // false),
       advisories: [$v.via[]? | select(type == "object") | {title: (.title // "advisory"), url: (.url // "")}] | unique,
       fix: (if ($v.fixAvailable | type) == "object" then {version: $v.fixAvailable.version, major: ($v.fixAvailable.isSemVerMajor // false), via: $v.fixAvailable.name}
             elif $v.fixAvailable == true then {version: null, major: false} else null end)}
    | .fix_text = (if .fix == null then "no fix available yet"
                   elif .fix.version != null then "update \(.fix.via) to \(.fix.version)\(if .fix.major then " (new major version)" else "" end)"
                   else "fixed by `npm audit fix`" end)' <<<"$audit" >> "$tmp/security.jsonl"
}

# $1 = project, $2 = owner/repo. Files or updates the tickets. Sets FAILED=1 on problems.
check_repo() {
  local project=$1 repo=$2 work="$tmp/${2//\//_}" dirs d rel spec ctx team_id project_id open out ident desc existing_id existing_desc kind specs
  mkdir -p "$work"; : > "$tmp/updates.jsonl"; : > "$tmp/security.jsonl"; : > "$tmp/failed.txt"
  if ! gh repo clone "$repo" "$work/src" -- --depth 1 --quiet >/dev/null 2>"$tmp/clone.err"; then
    echo "::error::Could not clone $repo" >&2; FAILED=1; return 0
  fi
  dirs=$(cd "$work/src" && git ls-files '*package.json' 'package.json' | grep -v node_modules | xargs -r -n1 dirname | sort -u)
  for rel in $dirs; do
    d="$work/src/$rel"
    [ -f "$d/package-lock.json" ] || { echo "::warning::$repo/$rel has no package-lock.json; skipped" >&2; echo "$rel" >> "$tmp/failed.txt"; continue; }
    scan_dir "$d" "$rel"
  done
  specs=$(jq -n --arg p "$project" --arg r "${repo#*/}" --arg w "$week" \
    --slurpfile u "$tmp/updates.jsonl" --slurpfile s "$tmp/security.jsonl" --rawfile f "$tmp/failed.txt" '
    {project: $p, repo: $r, week: $w, updates: ($u | unique), security: ($s | unique), failed: ($f | split("\n") | map(select(. != "")))}' \
    | jq -c -f "$here/ticket.jq") || { echo "::error::Could not build the tickets for $repo" >&2; FAILED=1; return 0; }
  echo "$repo: $(jq length <<<"$specs") ticket(s) to file"
  [ "$(jq length <<<"$specs")" -gt 0 ] || return 0
  if [ -n "$DRY_RUN" ]; then jq -r '.[] | "--- \(.title) [\(.state), priority \(.priority // "none")]\n" + .goal' <<<"$specs"; return 0; fi

  ctx=$(linear_project_context "$project" 2>/dev/null) || ctx=""
  team_id=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null) || team_id=""
  if [ -z "$team_id" ]; then echo "::error::Linear project '$project' not found" >&2; FAILED=1; return 0; fi
  project_id=$(jq -r .id <<<"$ctx")
  open=$(linear_open_issues_in_project "$team_id" "$project_id") || open=""
  if [ -z "$open" ]; then echo "::error::Could not list the open tickets of $project; no tickets filed" >&2; FAILED=1; return 0; fi

  while IFS= read -r spec; do
    kind=$(jq -r '.dedup_marker | sub("^depsig-.*-(?<k>[a-z]+)$"; .k)' <<<"$spec")
    existing_id=$(jq -r --arg m "$(jq -r .dedup_marker <<<"$spec")" '[.[] | select((.description // "") | contains($m))][0].identifier // empty' <<<"$open")
    if [ -n "$existing_id" ]; then
      # Last week's ticket is still open: bring it up to date (title, list, and a comment when the list changed).
      desc=$(issue_format "$spec")
      existing_desc=$(jq -r --arg i "$existing_id" '[.[] | select(.identifier == $i)][0].description // ""' <<<"$open")
      if [ "$desc" = "$existing_desc" ]; then echo "$repo: $existing_id ($kind) is up to date"; continue; fi
      out=$(issue_write "$(jq -c --arg u "$existing_id" '. + {update: $u}' <<<"$spec")" "$ctx") || out=""
      case "$out" in
        "updated "*) echo "$repo: updated $existing_id ($kind)"
          linear_comment_on_id "$(issue_uuid "$existing_id")" "The weekly dependency check ($week) updated this ticket: the list above is the current one." ;;
        *) echo "::error::Could not update $existing_id" >&2; FAILED=1 ;;
      esac
      continue
    fi
    # New ticket. The writer never uses Agent Ready itself; the ticket is created in Todo and moved afterwards.
    out=$(issue_write "$(jq -c '.state = "todo"' <<<"$spec")" "$ctx") || out=""
    case "$out" in
      "created "*) read -r _ ident _ <<<"$out"; echo "$repo: created $ident ($kind)"
        if [ "$(jq -r .state <<<"$spec")" = "agent ready" ]; then linear_set_state "$ident" "Agent Ready"; fi ;;
      *) echo "::error::Could not create the $kind ticket for $repo" >&2; FAILED=1 ;;
    esac
  done < <(jq -c '.[]' <<<"$specs")
}

[ -n "$DRY_RUN" ] || : "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"
while IFS=$'\t' read -r project repo; do
  [ -n "$project" ] || continue
  [ -z "$DEPS_ONLY" ] || [ "${repo#*/}" = "$DEPS_ONLY" ] || continue
  check_repo "$project" "$repo" || FAILED=1
done < <(repo_list)
exit "$FAILED"
