#!/usr/bin/env bash
# Deploy watch: an hour after an app's merge to main is deployed, compare production for that hour with the 24 hours
# before it (the scout's Workers Logs data: error rate, 5xx rate, request time p95). Normal -> a short comment on the
# ticket. Clearly worse -> a revert PR (never merged automatically) with a Needs Human ticket, and a comment on the
# original ticket. Too little traffic -> "not enough traffic to judge". See docs/deploy-watch.md.
# Usage: watch.sh [--dry-run]   (or DRY_RUN=1). A dry run prints the comparison for the deploys of the last 24 hours
# (the window so far when the hour isn't over) and opens nothing; it needs no Linear key.
# Env: GH_TOKEN (the factory app's token, covering all app repos), GITHUB_OWNER, CLOUDFLARE_ACCOUNT_ID,
#      CLOUDFLARE_OBSERVABILITY_TOKEN, LINEAR_API_KEY.
# Optional (tests): WATCH_APPS (apps file, default agents/scout/apps.json), WATCH_NOW (epoch seconds), WATCH_FETCH
#      (script replacing scout/fetch.sh), WATCH_GIT_BASE (clone URL base instead of GitHub).
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
# shellcheck source=../lib/linear.sh
source "$root/agents/lib/linear.sh"
# shellcheck source=../lib/issue-writer.sh
source "$root/agents/lib/issue-writer.sh"
[ "$1" = "--dry-run" ] && DRY_RUN=1
apps_file=${WATCH_APPS:-$root/agents/scout/apps.json}
fetch=${WATCH_FETCH:-$root/agents/scout/fetch.sh}
now=${WATCH_NOW:-$(date +%s)}
GRACE_HOURS=8      # a deploy is still judged this long after its hour ended (missed runs), never later
MIN_WINDOW_MIN=20  # a newer deploy cuts the hour short; less than this is not judged
FAILED=0
: "${GITHUB_OWNER:?GITHUB_OWNER is required}"

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# $1 = app JSON. Prints the app's settings: defaults plus its "watch" object.
settings_for() { jq -c --slurpfile d "$here/defaults.json" '$d[0] + (.watch // {} | if type == "object" then . else {} end)' <<<"$1"; }

# $1 = repo ("owner/name"), $2 = branch, $3 = settings, $4 = lookback hours. Prints one JSON line per deployed commit on the
# branch: {sha, subject, deployed_ms}. A commit counts as deployed when its Workers Builds check run succeeded.
deploys_of() {
  local repo=$1 branch=$2 s=$3 hours=$4 commits sha subject runs done_at
  commits=$(gh api "repos/$repo/commits?sha=$branch&since=$(iso $((now - hours * 3600)))&per_page=50" \
    --jq '.[] | [.sha, (.commit.message | split("\n")[0])] | @tsv') || return 1
  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] || continue
    runs=$(gh api "repos/$repo/commits/$sha/check-runs?per_page=100") || { echo "::warning::Could not read the check runs of $repo@${sha:0:7}" >&2; continue; }
    done_at=$(jq -r --arg re "$(jq -r .deploy_check <<<"$s")" '[.check_runs[]? | select((.name | test($re; "i")) and .conclusion == "success") | .completed_at] | sort | last // empty' <<<"$runs")
    [ -n "$done_at" ] || continue
    jq -nc --arg sha "$sha" --arg subj "$subject" --argjson ms "$(( $(date -u -d "$done_at" +%s) * 1000 ))" '{sha: $sha, subject: $subj, deployed_ms: $ms}'
  done <<<"$commits"
}

# $1 = worker, $2 = filters JSON, $3 = hours. Prints the raw response (and warns when it hit the 2000 event limit).
events_for() {
  local raw
  raw=$(SCOUT_WINDOW_HOURS=$3 bash "$fetch" "$1" "$2") || return 1
  jq -e '(.result.events.events // .events.events // .events // []) | type == "array"' <<<"$raw" >/dev/null 2>&1 || return 1
  echo "$raw"
}
# $1 = raw response. Prints its events as an array, and the oldest timestamp when it hit the limit (else 0) as a second line.
oldest_if_full() {
  jq -r '(.result.events.events // .events.events // .events // []) as $e | if ($e | length) >= 2000 then ([$e[].timestamp] | min) else 0 end' <<<"$1"
}

# $1 = result JSON from compare.jq, $2 = minutes watched. Prints a markdown table.
numbers_table() {
  jq -r '"| | 24 h before | after |\n|---|---|---|\n| Requests | \(.before.requests) | \(.after.requests) |\n"
    + ([.rows[] | "| \(.name) | \(.before_display) | \(.after_display) |"] | join("\n"))' <<<"$1"
}

# $1 = repo, $2 = sha, $3 = new ticket identifier, $4 = original ticket identifier, $5 = PR title, $6 = PR body file, $7 = base branch.
# Opens the revert PR (branch <new ticket>-revert-<ticket>, labels agent-built + deploy-revert). Prints its URL, or nothing and the reason on stderr.
open_revert_pr() {
  local repo=$1 sha=$2 new=$3 orig=$4 title=$5 body_file=$6 base=$7 dir branch parents base_url
  dir=$(mktemp -d)
  branch="$(tr '[:upper:]' '[:lower:]' <<<"$new")-revert-$(tr '[:upper:]' '[:lower:]' <<<"$orig")"
  base_url=${WATCH_GIT_BASE:-https://x-access-token:${GH_TOKEN}@github.com}
  (
    cd "$dir"
    git clone -q --filter=blob:none --no-checkout "$base_url/$repo.git" repo >/dev/null 2>&1 || { echo "could not clone $repo" >&2; exit 1; }
    cd repo
    git config user.name "factory"; git config user.email "factory@users.noreply.github.com"
    git checkout -q -b "$branch" "origin/$base" || { echo "could not check out $base" >&2; exit 1; }
    parents=$(git rev-list --parents -n 1 "$sha" | wc -w)
    if [ "$parents" -gt 2 ]; then git revert --no-edit -m 1 "$sha" >/dev/null 2>&1; else git revert --no-edit "$sha" >/dev/null 2>&1; fi \
      || { echo "git revert has conflicts (later commits touch the same lines)" >&2; exit 1; }
    git push -q origin "$branch" >/dev/null 2>&1 || { echo "could not push the branch" >&2; exit 1; }
  ) || { rm -rf "$dir"; return 1; }
  rm -rf "$dir"
  gh label create agent-built --repo "$repo" --color 5319E7 --description "Opened by the factory builder agent" --force >/dev/null 2>&1 || true
  gh label create deploy-revert --repo "$repo" --color B60205 --description "Revert opened by the deploy watch; never auto-merged" --force >/dev/null 2>&1 || true
  gh pr create --repo "$repo" --base "$base" --head "$branch" --title "$title" --body-file "$body_file" \
    --label agent-built --label deploy-revert 2>/dev/null | tail -n1
}

# $1 = app JSON, $2 = repo ("owner/name"), $3 = settings, $4 = deploy JSON, $5 = window end (ms), $6 = base branch.
judge_deploy() {
  local app_json=$1 repo=$2 s=$3 d=$4 end_ms=$5 base=$6 worker project sha subject deploy_ms ticket short
  local hours from_ms cover_from=0 oldest reqs errs result status minutes ctx comments orig title body table pr_body res new new_url pr why
  worker=$(jq -r .worker <<<"$app_json"); project=$(jq -r .project <<<"$app_json")
  sha=$(jq -r .sha <<<"$d"); subject=$(jq -r .subject <<<"$d"); deploy_ms=$(jq -r .deployed_ms <<<"$d"); short=${sha:0:7}
  ticket=$(grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' <<<"$subject" | tr '[:lower:]' '[:upper:]' || true)
  minutes=$(( (end_ms - deploy_ms) / 60000 ))
  echo "-- $project $short \"$subject\" deployed $(iso $((deploy_ms / 1000))), watched $minutes min"
  if [ -z "$ticket" ] && [ -z "$DRY_RUN" ]; then echo "No ticket id in the commit title: not watched (nowhere to report)."; return 0; fi

  # Already judged? (A comment on the ticket carries the marker.) Linear unreachable: skip, so nothing is reported twice.
  if [ -z "$DRY_RUN" ]; then
    comments=$(linear_issue_comment_bodies "$ticket" 2>/dev/null) || comments=""
    if [ -z "$comments" ] || [ "$comments" = null ]; then echo "::warning::Could not read $ticket in Linear (not found or unreachable); skipping $short"; FAILED=1; return 0; fi
    if jq -e --arg m "Deploy watch (\`$short\`)" 'any(.[]; contains($m))' <<<"$comments" >/dev/null; then echo "Already judged."; return 0; fi
  fi
  if [ "$minutes" -lt "$MIN_WINDOW_MIN" ]; then
    echo "A newer deploy followed after $minutes min: not judged."
    [ -z "$DRY_RUN" ] && linear_comment "$ticket" "ℹ️ Deploy watch (\`$short\`): another deploy followed after $minutes minutes, so this one wasn't judged on its own. The newer deploy is watched against the 24 hours before it."
    return 0
  fi

  hours=$(( (now * 1000 - (deploy_ms - $(jq -r .baseline_hours <<<"$s") * 3600000)) / 3600000 + 2 ))
  if ! reqs=$(events_for "$worker" '[{"key":"event","operation":"eq","value":"request"}]' "$hours") \
     || ! errs=$(events_for "$worker" '[{"key":"$metadata.level","operation":"eq","type":"string","value":"error"}]' "$hours"); then
    echo "::warning::Could not read the logs of $worker; $short will be tried again"; FAILED=1; return 0
  fi
  # A query that hit the 2000 event limit only covers the newest events: the comparison starts where both queries have data.
  for oldest in "$(oldest_if_full "$reqs")" "$(oldest_if_full "$errs")"; do
    [ "$oldest" -gt "$cover_from" ] && cover_from=$oldest
    [ "$oldest" != 0 ] && echo "::warning::A query for $worker hit the 2000-event limit; the comparison covers only part of the 24 hours before the deploy" >&2
  done
  from_ms=$(( deploy_ms - $(jq -r .baseline_hours <<<"$s") * 3600000 ))
  [ "$cover_from" -gt "$from_ms" ] && from_ms=$cover_from
  if [ "$cover_from" -gt "$deploy_ms" ]; then
    result='{"status":"unreadable","reasons":[],"rows":[],"before":{"requests":0},"after":{"requests":0}}'
  else
    result=$(jq -n -L "$root/agents/scout" --argjson requests "$reqs" --argjson errors "$errs" --argjson deploy_ms "$deploy_ms" \
      --argjson end_ms "$end_ms" --argjson from_ms "$from_ms" --argjson s "$s" -f "$here/compare.jq")
  fi
  status=$(jq -r .status <<<"$result"); table=$(numbers_table "$result" "$minutes")
  echo "Result: $status"; echo "$table"
  jq -r '.reasons[] | "- " + .' <<<"$result"
  [ -z "$DRY_RUN" ] || return 0

  orig=$(linear_issue "$ticket" | jq -r '.data.issue.title // empty') || orig=""
  case "$status" in
    ok)
      linear_comment "$ticket" "✅ Deploy watch (\`$short\`): watched for $minutes minutes after the deploy, all normal.

$table" ;;
    low_traffic)
      linear_comment "$ticket" "ℹ️ Deploy watch (\`$short\`): not enough traffic to judge ($(jq -r .after.requests <<<"$result") requests in the $minutes minutes after the deploy, $(jq -r .before.requests <<<"$result") in the 24 hours before; at least $(jq -r .min_requests <<<"$s") each are needed)." ;;
    unreadable)
      linear_comment "$ticket" "ℹ️ Deploy watch (\`$short\`): too many log lines to compare this deploy with the time before it (Workers Logs returns at most 2000 events per query)." ;;
    bad)
      title="Revert: ${orig:-$subject}"
      body="Deploy watch found production clearly worse in the $minutes minutes after \`$short\` ($subject) was deployed, compared with the 24 hours before:

$table

$(jq -r '.reasons[] | "- " + .' <<<"$result")

A revert PR is opened below; it is never merged automatically. Comment \`approve\` on this ticket to merge it, or close the PR if the numbers are fine."
      ctx=$(linear_project_context "$project" 2>/dev/null) || ctx=""
      res=$(issue_write "$(jq -n --arg t "$title" --arg g "$body" --arg o "$ticket" --arg sha "$sha" '{
          title: $t, goal: $g, origin: "Agent", delivery: "Human involved", state: "needs human", related: [$o],
          acceptance: ["Koen decided: merge the revert PR (comment `approve` here) or close it when the numbers turn out fine."],
          out_of_scope: ["Merging the revert automatically."],
          agent_notes: "Opened by the deploy watch (docs/deploy-watch.md). The numbers come from Workers Logs.",
          dedup_marker: ("Deploy watch commit: " + $sha), footer: ("Deploy watch commit: " + $sha)}')" "$ctx") || res=""
      new=$(sed -n 's/^created \([^ ]*\) .*/\1/p' <<<"$res"); new_url=$(sed -n 's/^created [^ ]* //p' <<<"$res")
      if [ -z "$new" ]; then
        echo "::warning::No revert ticket was created for $short ($(head -n1 <<<"$res")); will retry"; FAILED=1; return 0
      fi
      echo "Created $new"
      pr_body=$(mktemp)
      printf 'Reverts `%s` (%s). Opened by the deploy watch because production got worse after the deploy; %s.\n\n%s\n\nTicket: %s\n\nNever merged automatically: comment `approve` on %s or merge it yourself.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' \
        "$short" "$subject" "$(jq -r '.reasons | join("; ")' <<<"$result")" "$table" "$new_url" "$new" > "$pr_body"
      if pr=$(open_revert_pr "$repo" "$sha" "$new" "$ticket" "$new: Revert \"$subject\"" "$pr_body" "$base" 2>"$pr_body.err") && [ -n "$pr" ]; then
        linear_comment "$new" "Revert PR: $pr (never merged automatically; comment \`approve\` to merge it)."
        linear_comment "$ticket" "⚠️ Deploy watch (\`$short\`): production got worse after the deploy ($(jq -r '.reasons | join("; ")' <<<"$result")). Revert PR: $pr, ticket: $new_url."
      else
        why=$(tail -n1 "$pr_body.err" 2>/dev/null || true)
        linear_comment "$new" "Couldn't open the revert PR (${why:-unknown reason}). Revert by hand: \`git revert $sha\`."
        linear_comment "$ticket" "⚠️ Deploy watch (\`$short\`): production got worse after the deploy ($(jq -r '.reasons | join("; ")' <<<"$result")). The revert PR couldn't be opened (${why:-unknown reason}); see $new_url."
      fi
      rm -f "$pr_body" "$pr_body.err" ;;
  esac
}

scan_app() {
  local app_json=$1 project repo s branch lookback deploys d deploy_ms next end_ms window_ms
  project=$(jq -r .project <<<"$app_json"); repo=$(jq -r .repo <<<"$app_json")
  [ "$(jq -r '.watch == false' <<<"$app_json")" = true ] && { echo "== $project: watching is off"; return 0; }
  case "$repo" in */*) ;; *) repo="$GITHUB_OWNER/$repo" ;; esac
  s=$(settings_for "$app_json"); window_ms=$(( $(jq -r .window_minutes <<<"$s") * 60000 ))
  echo "== $project ($repo)"
  branch=$(gh api "repos/$repo" --jq .default_branch) || { echo "::warning::Could not read $repo"; FAILED=1; return 0; }
  if [ -n "$DRY_RUN" ]; then lookback=24; else lookback=$(( GRACE_HOURS + $(jq -r .window_minutes <<<"$s") / 60 + 1 )); fi
  deploys=$(deploys_of "$repo" "$branch" "$s" "$lookback") || { echo "::warning::Could not list the commits of $repo"; FAILED=1; return 0; }
  deploys=$(jq -cs 'sort_by(.deployed_ms)' <<<"$deploys")
  [ "$(jq length <<<"$deploys")" -gt 0 ] || { echo "No deploys in the last $lookback hours."; return 0; }
  while IFS= read -r d; do
    deploy_ms=$(jq -r .deployed_ms <<<"$d")
    end_ms=$(( deploy_ms + window_ms ))
    next=$(jq -r --argjson t "$deploy_ms" '[.[] | select(.deployed_ms > $t) | .deployed_ms] | min // empty' <<<"$deploys")
    [ -n "$next" ] && [ "$next" -lt "$end_ms" ] && end_ms=$next
    if [ -n "$DRY_RUN" ]; then
      [ "$end_ms" -gt $((now * 1000)) ] && end_ms=$((now * 1000))
    else
      if [ $((now * 1000)) -lt $((deploy_ms + window_ms)) ]; then echo "-- $(jq -r '.sha[0:7]' <<<"$d"): the hour isn't over yet"; continue; fi
      if [ $((now * 1000)) -gt $((deploy_ms + window_ms + GRACE_HOURS * 3600000)) ]; then continue; fi
    fi
    judge_deploy "$app_json" "$repo" "$s" "$d" "$end_ms" "$branch" || { echo "::warning::Judging $(jq -r '.sha[0:7]' <<<"$d") failed"; FAILED=1; }
  done < <(jq -c '.[]' <<<"$deploys")
}

while IFS= read -r app; do
  scan_app "$app" || { echo "::warning::Watching $(jq -r .project <<<"$app") failed"; FAILED=1; }
done < <(jq -c '.[]' "$apps_file")
[ "$FAILED" = 0 ] || { echo "::error::The deploy watch could not finish for every app (see warnings above)"; exit 1; }
