# shellcheck shell=bash
# The checks of the daily factory health check, sourced by health.sh. Every check calls `record` and never
# prints a secret value: secrets only go to curl through stdin and only statuses end up in the results.
# Env: RESULTS (file), FACTORY_REPO, GH_TOKEN (factory app token, for gh), RELAY_URL, HEALTH_CHECK_SECRET,
# LINEAR_API_KEY, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN, CLOUDFLARE_BUILDS_TOKEN, CLOUDFLARE_OBSERVABILITY_TOKEN,
# CLAUDE_CODE_OAUTH_TOKEN, FACTORY_APP_ID, FACTORY_APP_PRIVATE_KEY, APP_TOKEN_OK, HEALTH_ORG_TOKEN (optional).

# $1 = ok|fail|skip, $2 = key (stable, lowercase), $3 = title, $4 = what happened, $5 = how to fix (failures only)
record() {
  jq -cn --arg s "$1" --arg k "$2" --arg t "$3" --arg d "$4" --arg f "${5:-}" '{status: $s, key: $k, title: $t, detail: $d, fix: $f}' >>"$RESULTS"
}

# $1 = token, then curl arguments. Sends the token as a bearer header without it showing up in a process list.
curl_bearer() {
  local token=$1
  shift
  printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS --max-time 30 -K - "$@"
}

# $1 = file with the app's PROJECT_REPOS etc. Prints "owner/repo" lines from the relay config (JSONC: own-line comments only).
health_repos() {
  grep -v '^[[:space:]]*//' "${WRANGLER_CONFIG:-relay/wrangler.jsonc}" \
    | jq -r --arg owner "${FACTORY_REPO%%/*}" '.vars.PROJECT_REPOS | to_entries[] | .value | if contains("/") then . else $owner + "/" + . end' | sort -u
}
# $1 = repo "owner/repo". Prints the repo's Worker name, or nothing.
health_worker() {
  if [ "$1" = "$FACTORY_REPO" ]; then
    grep -v '^[[:space:]]*//' "${WRANGLER_CONFIG:-relay/wrangler.jsonc}" | jq -r '.name // empty'
  else
    jq -r --arg r "${1#*/}" '[.[] | select(.repo == $r)][0].worker // empty' "${APPS_FILE:-agents/scout/apps.json}"
  fi
}

# ---------- Relay ----------
check_relay() {
  if [ -z "$RELAY_URL" ]; then
    record fail relay-url "Relay URL is not set" "The health check doesn't know where the relay runs, so it can't test it." "Set the repo variable or secret RELAY_URL (the Worker's URL, no trailing slash) in this repo."
    return
  fi
  local url=${RELAY_URL%/} body status
  body=$(curl -sS --max-time 30 "$url/" 2>/dev/null) || body=""
  if [ "$body" != "factory-relay is running" ]; then
    record fail relay-reachable "Relay is not reachable" "GET $url/ did not answer 'factory-relay is running'." "Check the Worker 'factory' in Cloudflare (Workers & Pages → factory → Deployments and Observability) and the latest deploy of main."
    return
  fi
  record ok relay-reachable "Relay is reachable" "GET / answers."
  if [ -z "$HEALTH_CHECK_SECRET" ]; then
    record fail relay-deep "Relay deep check is not set up" "Repo secret HEALTH_CHECK_SECRET is missing, so the relay's GitHub token can't be tested." "Add HEALTH_CHECK_SECRET (any long random string) in Infisical: /shared (this repo) and /cloudflare/factory-relay (the Worker)."
    return
  fi
  body=$(curl_bearer "$HEALTH_CHECK_SECRET" -w '\n%{http_code}' "$url/health?deep=1" 2>/dev/null) || body=$'\n000'
  status=${body##*$'\n'}
  body=${body%$'\n'*}
  case "$status" in
    200) ;;
    404) record fail relay-deep "Relay deep check is off" "GET /health?deep=1 answered 404: the Worker has no HEALTH_CHECK_SECRET." "Add HEALTH_CHECK_SECRET to /cloudflare/factory-relay in Infisical (same value as the repo secret) and wait for the sync." ; return ;;
    401) record fail relay-deep "Relay rejects the health check secret" "GET /health?deep=1 answered 401: the repo secret and the Worker's HEALTH_CHECK_SECRET differ." "Make HEALTH_CHECK_SECRET the same in /shared and /cloudflare/factory-relay in Infisical." ; return ;;
    *) record fail relay-deep "Relay deep check failed" "GET /health?deep=1 answered HTTP $status." "Look at the Worker's logs in Cloudflare (Observability tab)." ; return ;;
  esac
  if [ "$(jq -r '.github.ok' <<<"$body" 2>/dev/null)" = "true" ]; then
    record ok relay-github-token "Relay's GitHub token is valid" "GitHub accepted the relay's token."
  else
    record fail relay-github-token "Relay's GitHub token is invalid" "GitHub answered $(jq -r '.github.status // "no response"' <<<"$body" 2>/dev/null) to the relay's token. Builds can't start." "Create a new token with Contents: Read and write on every app repo and the factory repo, and replace GITHUB_TOKEN in Infisical (/cloudflare/factory-relay)."
  fi
  if [ "$(jq -r '.linear.ok' <<<"$body" 2>/dev/null)" = "true" ]; then
    record ok relay-linear-key "Relay's Linear key is valid" "Linear accepted the relay's key."
  else
    record fail relay-linear-key "Relay's Linear key is invalid" "Linear rejected the LINEAR_API_KEY the relay uses." "Replace LINEAR_API_KEY in Infisical (/shared and /cloudflare/factory-relay)."
  fi
  local missing
  missing=$(jq -r '[.secrets // {} | to_entries[] | select(.value != true) | .key] | join(", ")' <<<"$body" 2>/dev/null) || missing="unknown"
  if [ -z "$missing" ]; then
    record ok relay-secrets "Relay has all its secrets" "LINEAR_API_KEY, LINEAR_WEBHOOK_SECRET and GITHUB_TOKEN are set on the Worker."
  else
    record fail relay-secrets "Relay is missing secrets" "Not set on the Worker: $missing." "Add them in Infisical under /cloudflare/factory-relay and wait for the sync to the Worker."
  fi
}

# ---------- GitHub ----------
# The leading comment lines are repo-specific; compare everything after them.
caller_body() { awk 'f || !/^#/ { f = 1; print }'; }

# $1 = org installations JSON (optional). Whether the Claude GitHub app covers every repo can only be read with an org admin token.
check_claude_app() {
  local owner=${FACTORY_REPO%%/*} inst sel
  if [ -z "$HEALTH_ORG_TOKEN" ]; then
    record skip claude-app "Claude GitHub app on the app repos" "Not checked: GitHub only shows an org's app installations to an org admin. Set HEALTH_ORG_TOKEN (read-only, 'Administration: read' on the org) to enable this."
    return
  fi
  inst=$(GH_TOKEN=$HEALTH_ORG_TOKEN gh api "orgs/$owner/installations" --jq '[.installations[] | select(.app_slug == "claude")][0]' 2>/dev/null) || inst=""
  sel=$(jq -r '.repository_selection // empty' <<<"$inst" 2>/dev/null) || sel=""
  case "$sel" in
    all) record ok claude-app "Claude GitHub app is installed" "Installed on all repositories of $owner." ;;
    selected) record skip claude-app "Claude GitHub app on the app repos" "Installed on selected repositories only; GitHub doesn't list them for an org token. Check Settings → GitHub Apps → Claude by hand." ;;
    *) record fail claude-app "Claude GitHub app is not installed" "No 'claude' app installation found for $owner (or HEALTH_ORG_TOKEN can't read it)." "Install the Claude GitHub app (github.com/apps/claude) on the app repos, or fix HEALTH_ORG_TOKEN." ;;
  esac
}

check_github() {
  local installed repos r name branch got want req cf_req runs
  if ! installed=$(gh api --paginate installation/repositories --jq '.repositories[].full_name' 2>/dev/null); then
    record fail github-app-token "Factory GitHub app token doesn't work" "The factory app's token could not list the repos it is installed on." "Check FACTORY_APP_ID and FACTORY_APP_PRIVATE_KEY (Infisical /shared) and that the app still exists and is installed on the account."
    return
  fi
  check_claude_app
  repos=$(health_repos)
  for r in $repos; do
    name=${r#*/}
    if grep -qxF "$r" <<<"$installed"; then
      record ok "github-$name-app" "Factory app is installed on $name" "The app can see $r."
    else
      record fail "github-$name-app" "Factory app is not installed on $name" "$r is in PROJECT_REPOS but the factory app's installation doesn't include it." "Settings → GitHub Apps → the factory app → Configure → add $r."
      continue
    fi
    if ! branch=$(gh api "repos/$r" --jq '.default_branch' 2>/dev/null); then continue; fi
    # Caller workflow
    got=$(gh api "repos/$r/contents/.github/workflows/factory.yml" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null) || got=""
    if [ -z "$got" ]; then
      record fail "github-$name-caller" "$name has no factory caller workflow" ".github/workflows/factory.yml is missing in $r." "Copy templates/app-repo/.github/workflows/factory.yml into $r (or run the 'Sync caller workflow' workflow here)."
    elif [ "$r" != "$FACTORY_REPO" ] && [ "$(caller_body <<<"$got")" != "$(caller_body <"${TEMPLATE:-templates/app-repo/.github/workflows/factory.yml}")" ]; then
      record fail "github-$name-caller" "$name's factory caller workflow is out of date" ".github/workflows/factory.yml in $r differs from the template." "Run the 'Sync caller workflow' workflow in the factory repo and merge the PR it opens in $r."
    else
      record ok "github-$name-caller" "$name has the factory caller workflow" "Present and up to date."
    fi
    # Required checks on the default branch (rulesets and classic branch protection)
    req=$({ gh api "repos/$r/rules/branches/$branch" --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null || true
            gh api "repos/$r/branches/$branch/protection/required_status_checks" --jq '(.contexts[]?), (.checks[]?.context)' 2>/dev/null || true; } | sort -u)
    if [ -z "$req" ]; then
      record fail "github-$name-required-checks" "$name has no required checks on $branch" "Neither a ruleset nor branch protection requires status checks on $branch of $r, so auto-merge would merge without waiting for CI." "Settings → Rules → add a ruleset for $branch that requires the repo's checks (and the Cloudflare Workers Builds check)."
    else
      record ok "github-$name-required-checks" "$name has required checks on $branch" "Required: $(tr '\n' ',' <<<"$req" | sed 's/,$//; s/,/, /g')."
    fi
    # Auto-merge
    want=$(gh api "repos/$r" --jq '.allow_auto_merge' 2>/dev/null) || want=""
    if [ "$want" = "true" ]; then
      record ok "github-$name-auto-merge" "Auto-merge is allowed on $name" "allow_auto_merge is on."
    else
      record fail "github-$name-auto-merge" "Auto-merge is not allowed on $name" "allow_auto_merge is '${want:-unknown}' for $r, so approved PRs can't merge themselves." "Settings → General → Pull Requests → Allow auto-merge in $r."
    fi
    # Cloudflare check on the latest commit of the default branch
    cf_req=$(grep -iE 'workers builds|cloudflare' <<<"$req" | head -n1 || true)
    runs=$(gh api --paginate "repos/$r/commits/$branch/check-runs" --jq '.check_runs[].name' 2>/dev/null) || runs=""
    if [ -z "$cf_req" ]; then
      record fail "cloudflare-$name-check" "$name has no required Cloudflare check" "No required check on $branch of $r mentions Cloudflare Workers Builds." "Add the 'Workers Builds: …' check to the required checks of $branch in $r."
    elif grep -qxF "$cf_req" <<<"$runs"; then
      record ok "cloudflare-$name-check" "Cloudflare check reported on $name" "'$cf_req' ran on the latest commit of $branch."
    else
      record fail "cloudflare-$name-check" "Cloudflare check did not report on $name" "The latest commit of $branch in $r has no '$cf_req' check run. Auto-merge would wait forever." "Check that the Worker is still connected to $r in Cloudflare (Workers & Pages → the Worker → Settings → Builds) and that the Cloudflare GitHub app is installed on $r."
    fi
  done
}

# ---------- Cloudflare ----------
# $1 = path below /accounts/$CLOUDFLARE_ACCOUNT_ID/. Prints the response; fails on an HTTP error.
cf_get() {
  curl_bearer "$CLOUDFLARE_BUILDS_TOKEN" --fail-with-body "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/$1" 2>/dev/null
}
check_cloudflare_builds() {
  local r name worker scripts tag triggers
  if [ -z "$CLOUDFLARE_BUILDS_TOKEN" ] || ! [[ "$CLOUDFLARE_ACCOUNT_ID" =~ ^[0-9a-fA-F]{32}$ ]]; then
    record skip cloudflare-builds "Workers Builds connections" "Not checked: CLOUDFLARE_BUILDS_TOKEN or CLOUDFLARE_ACCOUNT_ID is missing or malformed (see the secrets checks)."
    return
  fi
  scripts=$(cf_get "workers/scripts") || scripts=""
  for r in $(health_repos); do
    name=${r#*/}
    worker=$(health_worker "$r")
    [ -n "$worker" ] || continue
    tag=$(jq -r --arg w "$worker" '[.result[]? | select(.id == $w)][0].tag // empty' <<<"$scripts" 2>/dev/null) || tag=""
    if [ -z "$tag" ]; then
      record fail "cloudflare-$name-connection" "Workers Builds connection of $name can't be checked" "Worker '$worker' was not found with CLOUDFLARE_BUILDS_TOKEN (or the token can't read Workers Scripts)." "Check the Worker's name, and that the token has Workers Scripts: Read and Workers Builds Configuration: Read on the account."
      continue
    fi
    triggers=$(cf_get "builds/workers/$tag/triggers") || triggers=""
    if [ "$(jq -r '[.result[]? | select(.repo_connection != null)] | length' <<<"$triggers" 2>/dev/null || echo 0)" -gt 0 ]; then
      record ok "cloudflare-$name-connection" "Workers Builds is connected for $name" "Worker '$worker' has a build trigger with a repository connection."
    else
      record fail "cloudflare-$name-connection" "Workers Builds is no longer connected for $name" "Worker '$worker' has no build trigger connected to a repository, so merges to main don't deploy." "Cloudflare → Workers & Pages → $worker → Settings → Builds → Connect, and pick $r."
    fi
  done
}

# ---------- Linear: the GitHub integration ----------
check_linear_integration() {
  local r name pr id num merged age issue state linked
  for r in $(health_repos); do
    name=${r#*/}
    pr=$(gh pr list -R "$r" --state merged --label agent-built --limit 1 --json number,title,headRefName,mergedAt --jq '.[0] // empty' 2>/dev/null) || pr=""
    if [ -z "$pr" ]; then record skip "linear-$name-integration" "Linear links $name's PRs" "No merged agent PR yet."; continue; fi
    num=$(jq -r '.number' <<<"$pr")
    id=$(jq -r '.headRefName + " " + .title' <<<"$pr" | grep -oiE '[a-z]+-[0-9]+' | head -n1 | tr '[:lower:]' '[:upper:]') || id=""
    merged=$(jq -r '.mergedAt' <<<"$pr")
    age=$(( $(date +%s) - $(date -d "$merged" +%s 2>/dev/null || echo 0) ))
    if [ "$age" -lt 3600 ]; then record skip "linear-$name-integration" "Linear links $name's PRs" "The last agent PR (#$num) was merged less than an hour ago; Linear may not have caught up."; continue; fi
    if [ -z "$id" ]; then
      record fail "linear-$name-integration" "Last agent PR of $name has no ticket id" "PR #$num in $r has no Linear identifier in its branch or title, so Linear can't link it." "Check agents/build/publish.sh names branches and titles with the ticket id."
      continue
    fi
    issue=$(linear_gql 'query($id: String!) { issue(id: $id) { identifier state { name type } attachments(first: 50) { nodes { url } } } }' "$(jq -n --arg id "$id" '{id: $id}')" 2>/dev/null) || issue=""
    state=$(jq -r '.data.issue.state.type // empty' <<<"$issue" 2>/dev/null) || state=""
    linked=$(jq -r --arg u "/$r/pull/$num" '[.data.issue.attachments.nodes[]? | select(.url | endswith($u))] | length' <<<"$issue" 2>/dev/null) || linked=0
    if [ -z "$state" ]; then
      record fail "linear-$name-integration" "Ticket of $name's last agent PR not found" "PR #$num in $r names $id but Linear has no such issue (or rejected the lookup)." "Check the PR's title/branch and the LINEAR_API_KEY."
    elif [ "${linked:-0}" = "0" ]; then
      record fail "linear-$name-integration" "Linear doesn't link $name's PRs" "$id has no attachment for PR #$num of $r: the GitHub integration doesn't link this repo's PRs." "Linear → Settings → Integrations → GitHub: check that $r is connected to the team, and re-authorize the integration if needed."
    elif [ "$state" != "completed" ]; then
      record fail "linear-$name-integration" "Linear didn't close the ticket of $name's last agent PR" "$id is linked to PR #$num (merged) but its state is not Done." "Linear → Settings → Integrations → GitHub → workflow automation: 'on PR merge' should move tickets to Done."
    else
      record ok "linear-$name-integration" "Linear links $name's PRs" "$id is linked to PR #$num and Done."
    fi
  done
}

# ---------- Secrets ----------
# $1 = secret name, $2 = format regex or "", $3 = what a failing value means. Records a failure when unset or malformed.
secret_present() {
  local value=${!1}
  if [ -z "$value" ]; then
    record fail "secret-${1,,}" "Secret $1 is missing" "The repo secret $1 is not set in this repo." "Set $1 in Infisical (folder /shared or /github/factory) and let the sync write it to GitHub."
    return 1
  fi
  if [ -n "$2" ] && ! [[ "$value" =~ $2 ]]; then
    record fail "secret-${1,,}" "Secret $1 has the wrong format" "$1 is set (${#value} characters) but doesn't look like $3." "Replace $1 in Infisical with a fresh $3."
    return 1
  fi
}
# $1 = secret name. Verifies a Cloudflare API token: account-owned first, then user-owned.
secret_cloudflare_token() {
  local name=$1 resp
  secret_present "$name" '^[A-Za-z0-9_-]{30,}$' "a Cloudflare API token" || return 0
  resp=$(curl_bearer "${!name}" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/tokens/verify" 2>/dev/null) || resp=""
  [ "$(jq -r '.result.status // empty' <<<"$resp" 2>/dev/null)" = "active" ] \
    || resp=$(curl_bearer "${!name}" "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null) || resp=""
  if [ "$(jq -r '.result.status // empty' <<<"$resp" 2>/dev/null)" = "active" ]; then
    record ok "secret-${name,,}" "Secret $name is valid" "Cloudflare reports the token as active."
  else
    record fail "secret-${name,,}" "Secret $name is rejected by Cloudflare" "Cloudflare's token verify did not report $name as active (expired, revoked or wrong account)." "Create a new token with the same permissions and replace $name in Infisical."
  fi
}
check_secrets() {
  local code
  if secret_present LINEAR_API_KEY '^lin_api_[A-Za-z0-9]{20,}$' "a Linear personal API key (lin_api_…)"; then
    if [ "$(linear_gql 'query { viewer { id } }' '{}' 2>/dev/null | jq -r '.data.viewer.id // empty' 2>/dev/null)" != "" ]; then
      record ok secret-linear_api_key "Secret LINEAR_API_KEY is valid" "Linear's viewer query succeeded."
    else
      record fail secret-linear_api_key "Secret LINEAR_API_KEY is rejected by Linear" "Linear's viewer query failed with this key." "Create a new personal API key in Linear (Settings → Security) and replace LINEAR_API_KEY in Infisical."
    fi
  fi
  if secret_present CLOUDFLARE_ACCOUNT_ID '^[0-9a-fA-F]{32}$' "a 32-character hex Cloudflare account id"; then
    record ok secret-cloudflare_account_id "Secret CLOUDFLARE_ACCOUNT_ID looks right" "32 hex characters."
  fi
  for code in CLOUDFLARE_API_TOKEN CLOUDFLARE_BUILDS_TOKEN CLOUDFLARE_OBSERVABILITY_TOKEN; do secret_cloudflare_token "$code"; done
  if secret_present FACTORY_APP_ID '^[0-9]+$' "a numeric GitHub App id" && secret_present FACTORY_APP_PRIVATE_KEY '^-----BEGIN [A-Z ]*PRIVATE KEY-----' "a PEM private key"; then
    if [ "$APP_TOKEN_OK" = "true" ]; then
      record ok secret-factory_app "Factory app secrets are valid" "A token was created for the factory app."
    else
      record fail secret-factory_app "Factory app token can't be created" "FACTORY_APP_ID and FACTORY_APP_PRIVATE_KEY are set but creating an installation token failed." "Generate a new private key for the GitHub App and replace FACTORY_APP_PRIVATE_KEY in Infisical; check FACTORY_APP_ID."
    fi
  fi
  if secret_present CLAUDE_CODE_OAUTH_TOKEN '^sk-ant-oat[0-9]*-[A-Za-z0-9_-]{20,}$' "a Claude OAuth token (from 'claude setup-token')"; then
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$CLAUDE_CODE_OAUTH_TOKEN" | curl -sS --max-time 30 -K - -o /dev/null -w '%{http_code}' \
      -H "anthropic-version: 2023-06-01" -H "anthropic-beta: oauth-2025-04-20" "https://api.anthropic.com/v1/models?limit=1" 2>/dev/null) || code=000
    if [ "$code" = "200" ]; then
      record ok secret-claude_code_oauth_token "Secret CLAUDE_CODE_OAUTH_TOKEN is valid" "Anthropic accepted the token."
    else
      record fail secret-claude_code_oauth_token "Secret CLAUDE_CODE_OAUTH_TOKEN is rejected" "Anthropic answered HTTP $code to a models request with this token (expired or revoked)." "Run 'claude setup-token' and replace CLAUDE_CODE_OAUTH_TOKEN in Infisical (/shared)."
    fi
  fi
}

# ---------- Real Linear queries ----------
# Runs every read-only query the relay and the agents send, against the real Linear API, with sample values.
check_linear_queries() {
  local ctx team project issue_id queries n i q file vars values resp key base total=0 bad=0
  ctx=$(linear_project_context "${HEALTH_PROJECT:-Factory}" 2>/dev/null) || ctx=""
  team=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null) || team=""
  project=$(jq -r '.id // empty' <<<"$ctx" 2>/dev/null) || project=""
  if [ -z "$team" ] || [ -z "$project" ]; then
    record fail linear-project "Linear project '${HEALTH_PROJECT:-Factory}' not found" "The project lookup returned nothing, so queries can't be tried with real ids." "Check LINEAR_API_KEY and that the Linear project exists with that exact name."
    return
  fi
  issue_id=$(linear_gql 'query($t: ID!) { team(id: $t) { issues(first: 1) { nodes { identifier } } } }' "$(jq -n --arg t "$team" '{t: $t}')" 2>/dev/null | jq -r '.data.team.issues.nodes[0].identifier // empty' 2>/dev/null) || issue_id=""
  queries=$(node "${QUERIES_SCRIPT:-agents/health/queries.mjs}" .) || { record fail linear-queries "Linear queries can't be listed" "agents/health/queries.mjs failed." "Run it by hand: node agents/health/queries.mjs"; return; }
  n=$(jq length <<<"$queries")
  declare -A seen=()
  for ((i = 0; i < n; i++)); do
    q=$(jq -r ".[$i].query" <<<"$queries")
    file=$(jq -r ".[$i].file" <<<"$queries")
    vars=$(jq -c ".[$i].variables" <<<"$queries")
    base=$(sed -E 's/^query *[A-Za-z0-9_]* *(\([^)]*\))? *\{ *([A-Za-z0-9_]+).*/\2/' <<<"$q")
    key="linear-query-$(tr -c 'a-z0-9\n' '-' <<<"${file,,}")-$base"
    seen[$key]=$(( ${seen[$key]:-0} + 1 ))
    [ "${seen[$key]}" = "1" ] || key="$key-${seen[$key]}"
    total=$((total + 1))
    # Sample values by variable name: $id an issue, $t the team, $p the project, $n its name, $l a label name.
    values=$(jq -c --arg id "$issue_id" --arg t "$team" --arg p "$project" --arg n "${HEALTH_PROJECT:-Factory}" '
      map({(.name): (if .name == "id" then $id elif .name == "t" then $t elif .name == "p" then $p elif .name == "n" then $n elif .name == "l" then "source:health" else null end)}) | add // {}' <<<"$vars")
    if [ "$(jq '[.[] | select(. == null)] | length' <<<"$values")" != "0" ] || { [ -z "$issue_id" ] && jq -e 'has("id")' <<<"$values" >/dev/null; }; then
      record fail "$key" "Linear query in $file has no sample values" "The health check has no sample value for a variable of the query starting '${q:0:80}…' (or the Factory team has no issue to use)." "Add the variable to the sample values in check_linear_queries (agents/health/checks.sh)."
      bad=$((bad + 1)); continue
    fi
    resp=$(linear_gql "$q" "$values" 2>/dev/null) || true
    if [ -n "$resp" ] && [ "$(jq -r 'if (.errors // null) == null and (.data // null) != null then "ok" else "bad" end' <<<"$resp" 2>/dev/null)" = "ok" ]; then
      continue
    fi
    bad=$((bad + 1))
    record fail "$key" "Linear rejects a query in $file" "Linear answered with an error to the read-only query starting '${q:0:80}…': $(jq -r '[.errors[]?.message] | join("; ") | .[0:300]' <<<"$resp" 2>/dev/null || echo 'no readable answer')" "Fix the query in $file (a typical cause is a query that is too complex: ask for fewer nested nodes or lower first: values), and run the health check again."
  done
  [ "$bad" != "0" ] || record ok linear-queries "All Linear queries run" "$total read-only queries ran against the real Linear API without errors."
}
