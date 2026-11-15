# shellcheck shell=bash
# CI check helpers, sourced by the agent scripts.
# Every function warns instead of failing, so a check problem never breaks a run.

# True for the factory's own jobs (the caller's "build"/"review" jobs and the Factory workflows),
# which must never be waited for or investigated.
CHECKS_OWN_FILTER='(.workflow // "") as $w | (.name // "") as $n
  | ($w | test("^Factory( build| review)?$")) or ($n | test("^(build|review)( / |$)"))'

# Prints the PR's checks as a JSON array, without the factory's own jobs. Prints [] when unavailable.
checks_list() {
  local out
  out=$(gh pr checks "$PR_NUMBER" --json name,state,bucket,link,workflow,description 2>/dev/null) || true
  jq -c "[.[]? | select(($CHECKS_OWN_FILTER) | not)]" <<<"$out" 2>/dev/null || echo '[]'
}

# Waits until no other check is pending, at most ${CHECKS_WAIT_SECONDS:-900} seconds.
checks_wait() {
  local deadline=$((SECONDS + ${CHECKS_WAIT_SECONDS:-900})) pending
  while :; do
    pending=$(checks_list | jq '[.[] | select(.bucket == "pending")] | length')
    [ "${pending:-0}" = "0" ] && return 0
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "::warning::$pending check(s) still pending after waiting; reviewing anyway."
      return 0
    fi
    echo "Waiting for $pending check(s) to finish..."
    sleep 30
  done
}

# $1 = text. Prints the Cloudflare build UUID found in it, if any.
checks_build_id() {
  grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$1" | head -n1 || true
}

# $1 = build id. Prints the build log, or fails when the token/account isn't set or the API call fails.
# The token only goes to curl through stdin, so it is never printed or visible in a process list.
checks_cloudflare_log() {
  [ -n "$CLOUDFLARE_BUILDS_TOKEN" ] && [ -n "$CLOUDFLARE_ACCOUNT_ID" ] || return 1
  [[ "$CLOUDFLARE_ACCOUNT_ID" =~ ^[0-9a-fA-F]+$ ]] || return 1
  local resp
  resp=$(printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_BUILDS_TOKEN" \
    | curl -sS --fail-with-body --max-time 60 -K - \
      "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/builds/builds/$1/logs" 2>/dev/null) || return 1
  jq -r '.result.lines // [] | .[] | if type == "array" then (.[1] // .[0] | tostring) else tostring end' <<<"$resp" 2>/dev/null \
    | tail -n 400 | cut -c1-1000
}

# $1 = output directory. Writes one markdown file per failed check: name, link, check run output and,
# for Cloudflare Workers Builds, the build log. Check text is data from outside the repo.
checks_collect_failed() {
  local dir=$1 sha runs failed n=0 name link slug file body build_id log
  mkdir -p "$dir"
  failed=$(checks_list | jq -c '[.[] | select(.bucket == "fail")]')
  [ "$(jq length <<<"$failed")" != "0" ] || return 0
  sha=$(gh pr view "$PR_NUMBER" --json headRefOid -q .headRefOid 2>/dev/null) || sha=""
  runs='[]'
  if [ -n "$sha" ]; then
    runs=$(gh api --paginate "repos/$GITHUB_REPOSITORY/commits/$sha/check-runs" --jq '.check_runs[]' 2>/dev/null | jq -s -c . 2>/dev/null) \
      || runs='[]'
    [ -n "$runs" ] || runs='[]'
  else
    echo "::warning::Couldn't read the PR head commit, so check outputs are limited."
  fi
  while IFS= read -r check; do
    n=$((n + 1))
    name=$(jq -r .name <<<"$check")
    link=$(jq -r '.link // ""' <<<"$check")
    slug=$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '-' | cut -c1-50)
    file="$dir/$n-$slug.md"
    body=$(jq -r --arg name "$name" '([.[] | select(.name == $name)] | first) // {}
      | "Conclusion: \(.conclusion // "unknown")\nTitle: \(.output.title // "(none)")\n\n### Summary\n\(.output.summary // "(none)")\n\n### Details\n\(.output.text // "(none)")"' <<<"$runs" | cut -c1-4000 | head -c 20000)
    {
      echo "# Failed check: $name"
      echo "Link: $link"
      echo "Description: $(jq -r '.description // ""' <<<"$check")"
      echo
      echo "$body"
    } > "$file"
    if [[ "$name" == *"Workers Builds"* ]] || [[ "$link" == *"dash.cloudflare.com"* ]]; then
      build_id=$(checks_build_id "$body $link")
      {
        echo
        echo "### Cloudflare build log"
        if [ -z "$build_id" ]; then
          echo "Not available: no build ID found in the check output."
        elif log=$(checks_cloudflare_log "$build_id") && [ -n "$log" ]; then
          echo "Build $build_id, last lines:"
          echo '```'
          printf '%s\n' "$log"
          echo '```'
        else
          echo "Not available: no read-only Cloudflare token (CLOUDFLARE_BUILDS_TOKEN, CLOUDFLARE_ACCOUNT_ID) or the Cloudflare API call failed."
        fi
      } >> "$file"
    fi
  done < <(jq -c '.[]' <<<"$failed")
  echo "Saved details of $n failed check(s) to $dir"
}
