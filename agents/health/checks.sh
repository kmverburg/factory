# shellcheck shell=bash disable=SC2016,SC2034
# The checks of the daily factory health check, sourced by health.sh (docs/health-check.md).
# Each check collects problems with `problem` and ends with `finish ID TITLE FIX`, which records one result line
# in $RESULTS: {id, title, ok, message, fix}. A check that can't run because something it depends on is already
# reported (a missing token) calls `skip`, so one root cause makes one ticket, not ten.
# No check ever prints or logs a secret: tokens only reach curl through stdin, and messages hold status codes only.

PROBLEMS=()
problem() { PROBLEMS+=("$1"); }
finish() { # $1 = id, $2 = title, $3 = how to fix
  if [ "${#PROBLEMS[@]}" -eq 0 ]; then
    jq -nc --arg id "$1" --arg t "$2" '{id: $id, title: $t, ok: true}' >> "$RESULTS"
  else
    jq -nc --arg id "$1" --arg t "$2" --arg f "$3" --arg m "$(printf -- '- %s\n' "${PROBLEMS[@]}")" '{id: $id, title: $t, ok: false, message: $m, fix: $f}' >> "$RESULTS"
  fi
  PROBLEMS=()
}
skip() { echo "skipped $1: $2" >&2; PROBLEMS=(); }

# $1 = token, $2 = URL. Prints "HTTP-status<TAB>body-file"; the token goes to curl through stdin only.
bearer_get() {
  local out; out=$(mktemp -p "$TMP")
  local code
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$1" | curl -sS --max-time 30 -K - -o "$out" -w '%{http_code}' "$2" 2>/dev/null) || code=0
  printf '%s\t%s' "$code" "$out"
}

# ---------- Repos ----------

# "owner/repo<TAB>project<TAB>worker" per repo in the relay's PROJECT_REPOS (JSONC, so no jq). The worker comes from
# the scout's apps.json, or the relay's own name for the factory repo; it may be empty.
list_repos() {
  local repo project worker
  awk '/"PROJECT_REPOS"/ { on = 1 } on { print } on && /}/ { exit }' "$WRANGLER_CONFIG" \
    | grep -oE '"[^"]+"[[:space:]]*:[[:space:]]*"[^"/]+(/[^"/]+)?"' \
    | sed -E 's/^"([^"]+)"[[:space:]]*:[[:space:]]*"([^"]+)"$/\2\t\1/' | sort -u \
    | while IFS=$'\t' read -r repo project; do
        case "$repo" in */*) ;; *) repo="${FACTORY_REPO%%/*}/$repo" ;; esac
        worker=$(jq -r --arg r "${repo##*/}" '[.[] | select(.repo == $r) | .worker][0] // empty' "$APPS_FILE")
        [ "${repo##*/}" = "${FACTORY_REPO##*/}" ] && worker=$(sed -nE 's/^[[:space:]]*"name":[[:space:]]*"([^"]+)".*/\1/p' "$WRANGLER_CONFIG" | head -n1)
        printf '%s\t%s\t%s\n' "$repo" "$project" "$worker"
      done
}

# ---------- Secrets ----------

# $1 = name, $2 = value, $3 = extended regex it must match (or "-" for just "long enough, no whitespace").
secret_format() {
  local name=$1 value=$2 pattern=$3
  if [ -z "$value" ]; then problem "\`$name\` is not set in this repository's secrets."; return 1; fi
  if [ "$pattern" = "-" ]; then
    if [ "${#value}" -lt 20 ] || [[ "$value" =~ [[:space:]] ]]; then problem "\`$name\` has an unexpected format (length ${#value}, expected 20+ characters without whitespace)."; return 1; fi
  elif ! [[ "$value" =~ $pattern ]]; then
    problem "\`$name\` has an unexpected format (length ${#value})."; return 1
  fi
}

# $1 = secret name, $2 = value. Verifies a Cloudflare API token (account-owned or user-owned) is active.
cloudflare_token_active() {
  local res code file account=${CLOUDFLARE_ACCOUNT_ID:-}
  for url in "https://api.cloudflare.com/client/v4/accounts/$account/tokens/verify" "https://api.cloudflare.com/client/v4/user/tokens/verify"; do
    [ -n "$account" ] || [[ "$url" == */user/* ]] || continue
    res=$(bearer_get "$2" "$url"); code=${res%%$'\t'*}; file=${res#*$'\t'}
    if [ "$code" = 200 ] && [ "$(jq -r '.result.status // empty' "$file" 2>/dev/null)" = active ]; then return 0; fi
  done
  problem "\`$1\` is rejected by Cloudflare's token verify (HTTP $code). Create a new token and update it in Infisical."
  return 1
}

check_secret() { # $1 = name, $2 = value, $3 = pattern, $4 = kind (linear|cloudflare|none)
  local name=$1 value=$2 res code
  if secret_format "$name" "$value" "$3"; then
    case "$4" in
      linear)
        res=$(linear_gql 'query { viewer { id } }' '{}' 2>/dev/null) || res=""
        [ -n "$(jq -r '.data.viewer.id // empty' <<<"$res" 2>/dev/null)" ] || problem "Linear rejected \`$name\` (the \`viewer\` query failed)." ;;
      cloudflare) cloudflare_token_active "$name" "$value" || true ;;
    esac
  fi
  finish "secret-$name" "secret $name is missing or invalid" \
    "Fix it in Infisical (project \`factory\`, environment \`prod\`; the README's *Secrets* table says which folder), and let the sync copy it to GitHub. Never edit it in GitHub directly."
}

check_secrets() {
  check_secret CLAUDE_CODE_OAUTH_TOKEN "$CLAUDE_CODE_OAUTH_TOKEN" '^sk-ant-[A-Za-z0-9_-]{30,}$' none
  check_secret LINEAR_API_KEY "$LINEAR_API_KEY" '^lin_api_[A-Za-z0-9]{20,}$' linear
  check_secret CLOUDFLARE_ACCOUNT_ID "$CLOUDFLARE_ACCOUNT_ID" '^[0-9a-f]{32}$' none
  check_secret CLOUDFLARE_API_TOKEN "$CLOUDFLARE_API_TOKEN" - cloudflare
  check_secret CLOUDFLARE_BUILDS_TOKEN "$CLOUDFLARE_BUILDS_TOKEN" - cloudflare
  check_secret CLOUDFLARE_OBSERVABILITY_TOKEN "$CLOUDFLARE_OBSERVABILITY_TOKEN" - cloudflare
  check_secret HEALTH_CHECK_SECRET "$HEALTH_CHECK_SECRET" '^.{16,}$' none
  # The GitHub App: the workflow tries to create a token with the id and key (create-github-app-token) and passes the outcome.
  secret_format FACTORY_APP_ID "$FACTORY_APP_ID" '^[0-9]+$' || true
  secret_format FACTORY_APP_PRIVATE_KEY "$FACTORY_APP_PRIVATE_KEY" 'BEGIN [A-Z ]*PRIVATE KEY' || true
  [ "${APP_TOKEN_OUTCOME:-}" = success ] || problem "The workflow could not create a GitHub App token from \`FACTORY_APP_ID\` and \`FACTORY_APP_PRIVATE_KEY\` (step outcome: ${APP_TOKEN_OUTCOME:-unknown}); see the \`Factory app token\` step of the run."
  finish secret-factory-app "secret FACTORY_APP_ID / FACTORY_APP_PRIVATE_KEY is missing or invalid" \
    "Check the GitHub App's id and private key in Infisical (\`/shared\`); generate a new private key in the app's settings if needed."
}

# ---------- Relay ----------

check_relay() {
  local res code file
  res=$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' "$RELAY_URL/health" 2>/dev/null) || res=0
  if [ "$res" != 200 ]; then
    problem "\`$RELAY_URL/health\` answered HTTP $res; the relay is not reachable (or not deployed with the health route)."
  elif [ -z "$HEALTH_CHECK_SECRET" ]; then
    skip relay "no HEALTH_CHECK_SECRET"; return 0
  else
    res=$(bearer_get "$HEALTH_CHECK_SECRET" "$RELAY_URL/health?deep=1"); code=${res%%$'\t'*}; file=${res#*$'\t'}
    case "$code" in
      200) ;;
      401) problem "The relay refused \`HEALTH_CHECK_SECRET\` (HTTP 401): the relay's copy differs or is missing." ;;
      503)
        [ "$(jq -r '.github // 0' "$file" 2>/dev/null)" = 200 ] || problem "The relay's GitHub token is invalid or expired (GitHub answered HTTP $(jq -r '.github // 0' "$file" 2>/dev/null))."
        [ "$(jq -r '.linear // 0' "$file" 2>/dev/null)" = 200 ] || problem "The relay's Linear key was rejected (Linear answered HTTP $(jq -r '.linear // 0' "$file" 2>/dev/null))."
        while IFS= read -r m; do problem "$m"; done < <(jq -r '(.repos // {}) | to_entries[] | select(.value != 200) | "The relay'"'"'s GitHub token cannot read \(.key) (HTTP \(.value))."' "$file" 2>/dev/null)
        [ "${#PROBLEMS[@]}" -gt 0 ] || problem "The relay's deep health check answered HTTP 503." ;;
      *) problem "The relay's deep health check answered HTTP $code." ;;
    esac
  fi
  finish relay "the relay is not healthy" \
    "Look at the relay's logs in Cloudflare. For an invalid GitHub token, replace \`GITHUB_TOKEN\` in Infisical (\`/cloudflare/factory-relay\`); \`HEALTH_CHECK_SECRET\` must be the same value in \`/cloudflare/factory-relay\` and in this repo's secrets."
}

# ---------- GitHub ----------

# $1 = repo. Prints the names of its required status checks on main (rulesets first, then classic branch protection).
required_checks() {
  {
    gh api "repos/$1/rules/branches/main" --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' 2>/dev/null
    gh api "repos/$1/branches/main/protection/required_status_checks" --jq '.contexts[]?, .checks[]?.context' 2>/dev/null
  } | sort -u || true
}

check_github() { # $1 = repo
  local repo=$1 required last file template existing auto
  if ! printf '%s\n' "$INSTALLED_REPOS" | grep -qixF "$repo"; then
    problem "The factory GitHub App is not installed on \`$repo\` (or its token can't see it)."
    finish "github-${repo##*/}" "GitHub setup of ${repo##*/} is incomplete" "Install the factory app on the repo (GitHub → Settings → Applications), then fix the other points."
    return 0
  fi
  # The caller workflow.
  file=$(gh api "repos/$repo/contents/.github/workflows/factory.yml" --jq .content 2>/dev/null | base64 -d 2>/dev/null) || file=""
  if [ -z "$file" ]; then
    problem "\`.github/workflows/factory.yml\` (the factory caller) is missing on the default branch."
  elif [ "$repo" != "$FACTORY_REPO" ]; then
    template="$ROOT/templates/app-repo/.github/workflows/factory.yml"
    existing=$(awk 'f || !/^#/ { f = 1; print }' <<<"$file")
    [ "$existing" = "$(awk 'f || !/^#/ { f = 1; print }' "$template")" ] || problem "The factory caller workflow differs from \`templates/app-repo/.github/workflows/factory.yml\` (run *Sync caller workflow*)."
  fi
  # Required checks and auto-merge.
  required=$(required_checks "$repo")
  [ -n "$required" ] || problem "\`main\` has no required status checks (rulesets or branch protection), so auto-merge would merge without waiting."
  auto=$(gh api "repos/$repo" --jq .allow_auto_merge 2>/dev/null) || auto=""
  [ "$auto" = true ] || problem "Auto-merge is not allowed on the repo (Settings → General → Allow auto-merge)."
  # The factory ran lately without failing at the start (a missing Claude app or token fails every run).
  last=$(gh api "repos/$repo/actions/workflows/factory.yml/runs?status=completed&per_page=1" --jq '.workflow_runs[0] | select(.event == "repository_dispatch") | .conclusion' 2>/dev/null) || last=""
  [ "$last" != failure ] || problem "The latest completed *Factory* run started by a ticket failed. That also happens when the Claude GitHub App is not installed on the repo (the factory app can't see that itself): check the run's logs."
  finish "github-${repo##*/}" "GitHub setup of ${repo##*/} is incomplete" \
    "Fix the points above: install the factory app and the Claude GitHub App on the repo, add the caller workflow (README step 5), set required checks on \`main\` and allow auto-merge."
}

# ---------- Cloudflare ----------

# The Cloudflare setup depends on how the app deploys, set per app in the scout's apps.json (next to "worker"):
#   "cloudflare": {"required_check": "check"}   deploys through GitHub Actions; that job must be required on main and report
#   no "cloudflare" key (the factory's relay)    deploys through Workers Builds: the *Workers Builds* check and the Git connection
# $1 = repo. Prints the app's required deploy check name, or nothing for Workers Builds.
app_required_check() { jq -r --arg r "${1##*/}" '[.[] | select(.repo == $r) | .cloudflare.required_check // empty][0] // empty' "$APPS_FILE" 2>/dev/null; }

# $1 = repo, $2 = worker
check_cloudflare() {
  local repo=$1 worker=$2 want required cf names res code file tag
  want=$(app_required_check "$repo")
  required=$(required_checks "$repo")
  names=$({ gh api "repos/$repo/commits/main/check-runs?per_page=100" --jq '.check_runs[].name' 2>/dev/null
            gh api "repos/$repo/commits/main/status" --jq '.statuses[].context' 2>/dev/null; } || true)
  if [ -n "$want" ]; then
    # Deploys through GitHub Actions: the deploy workflow's job (e.g. "check", or "Deploy / check") must be required and report.
    cf=$(grep -ixE "(.* / )?$(sed 's/[][\\.^$*+?(){}|]/\\&/g' <<<"$want")" <<<"$required" || true)
    if [ -z "$cf" ]; then
      problem "The deploy workflow's \`$want\` check is not a required check on \`main\`, so a broken change could merge without it."
    else
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        grep -qxF "$c" <<<"$names" || problem "The required check \`$c\` did not report on the latest commit of \`main\`."
      done <<<"$cf"
    fi
    finish "cloudflare-${repo##*/}" "Deploy check of ${repo##*/} is incomplete" \
      "Make the \`$want\` job of the deploy workflow (\`.github/workflows/deploy.yml\`) a required check on \`main\` and check that it runs on every push."
    return 0
  fi
  cf=$(grep -iE 'workers builds|cloudflare' <<<"$required" || true)
  if [ -z "$cf" ]; then
    problem "No required Cloudflare check (*Workers Builds: …*) on \`main\`, so a broken deploy would not block a merge."
  else
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      grep -qxF "$c" <<<"$names" || problem "The required check \`$c\` did not report on the latest commit of \`main\` (the Workers Builds connection may be gone)."
    done <<<"$cf"
  fi
  if [ -z "$worker" ]; then
    echo "no worker known for $repo; skipping the Workers Builds connection check" >&2
  elif [ -z "$CLOUDFLARE_BUILDS_TOKEN" ] || [ -z "$CLOUDFLARE_ACCOUNT_ID" ]; then
    echo "skipped the Workers Builds connection of $repo: no Cloudflare token" >&2
  else
    # The build triggers are listed by the Worker's tag. If the token can't look the Worker up, or doesn't see it, the
    # connection can't be judged: say so on stderr instead of filing a ticket for something that may be fine.
    res=$(bearer_get "$CLOUDFLARE_BUILDS_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts?per_page=100"); code=${res%%$'\t'*}; file=${res#*$'\t'}
    tag=$(jq -r --arg w "$worker" '[.result[]? | select(.id == $w) | .tag][0] // empty' "$file" 2>/dev/null)
    if [ "$code" != 200 ]; then
      echo "skipped the Workers Builds connection of $repo: Cloudflare did not list the Workers (HTTP $code; the token may lack Workers Scripts: Read)" >&2
    elif [ -z "$tag" ]; then
      echo "skipped the Workers Builds connection of $repo: the Worker $worker is not in the list this token can see" >&2
    else
      res=$(bearer_get "$CLOUDFLARE_BUILDS_TOKEN" "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/builds/workers/$tag/triggers"); code=${res%%$'\t'*}; file=${res#*$'\t'}
      if [ "$code" != 200 ]; then echo "skipped the Workers Builds connection of $repo: Cloudflare did not list the build triggers (HTTP $code)" >&2
      elif [ "$(jq '.result | length' "$file" 2>/dev/null || echo 0)" = 0 ]; then problem "The Worker \`$worker\` has no Workers Builds trigger: its Git connection is gone."; fi
    fi
  fi
  finish "cloudflare-${repo##*/}" "Cloudflare setup of ${repo##*/} is incomplete" \
    "In Cloudflare: Workers & Pages → the Worker → Settings → Build → reconnect the Git repo (check that Cloudflare still has access to the GitHub organization), then make the *Workers Builds* check required on \`main\`."
}

# ---------- Linear links ----------

check_linear_links() { # $1 = repo, $2 = project
  local repo=$1 pr id number branch res state attached cutoff
  cutoff=$(date -u -d '2 hours ago' +%FT%TZ)
  pr=$(gh pr list -R "$repo" --state merged --label agent-built --limit 20 --json number,headRefName,mergedAt 2>/dev/null \
    | jq -c --arg c "$cutoff" '[.[] | select(.mergedAt < $c)] | sort_by(.mergedAt) | last // empty') || pr=""
  if [ -n "$pr" ]; then
    number=$(jq -r .number <<<"$pr"); branch=$(jq -r .headRefName <<<"$pr")
    id=$(sed -nE 's/^([A-Za-z]+-[0-9]+)-.*/\1/p' <<<"$branch" | tr '[:lower:]' '[:upper:]')
    if [ -z "$id" ]; then
      problem "The last merged agent PR (#$number) has a branch (\`$branch\`) that doesn't start with a ticket identifier."
    else
      res=$(linear_gql 'query($id: String!) { issue(id: $id) { identifier state { name type } attachments(first: 50) { nodes { url } } } }' "$(jq -n --arg id "$id" '{id: $id}')" 2>/dev/null) || res=""
      state=$(jq -r '.data.issue.state.type // empty' <<<"$res" 2>/dev/null)
      attached=$(jq -r --arg u "$repo/pull/$number" '[.data.issue.attachments.nodes[]? | select(.url | endswith($u))] | length' <<<"$res" 2>/dev/null || echo 0)
      if [ -z "$state" ]; then problem "Linear has no ticket $id for the last merged agent PR (#$number)."
      else
        [ "$attached" != 0 ] || problem "$id has no link to the merged PR #$number: Linear's GitHub integration is not linking PRs of \`$repo\`."
        [ "$state" = completed ] || problem "$id is not Done although PR #$number is merged (state type: $state): Linear's GitHub automation for merged PRs is not working."
      fi
    fi
  fi
  finish "linear-${repo##*/}" "Linear is not linking PRs of ${repo##*/}" \
    "Linear → Settings → Integrations → GitHub: check that it still has access to \`$repo\` and that the pull request automations (opened → In Review, merged → Done) are on."
}

# ---------- Real Linear queries ----------

# Every query the relay (relay/src/index.ts) and the agents (agents/lib/linear.sh) send, one per NUL-terminated record.
extract_queries() {
  perl -0777 -ne 'print "$1\0" while /linear_gql\s+\x27(query[^\x27]*)\x27/g' "$ROOT/agents/lib/linear.sh"
  perl -0777 -ne 'print "$1\0" while /`(query\s[^`]*)`/g' "$ROOT/relay/src/index.ts"
}

# Sample variables come from the Factory project: $id = an issue, $t = its team, $p = the project, $n = its name, $l = a label name.
check_linear_queries() {
  local ctx project_id team_id issue_id q vars name v n=0 out msg
  ctx=$(linear_project_context "$HEALTH_PROJECT" 2>/dev/null) || ctx=""
  project_id=$(jq -r '.id // empty' <<<"$ctx" 2>/dev/null); team_id=$(jq -r '.team.id // empty' <<<"$ctx" 2>/dev/null)
  if [ -z "$project_id" ]; then
    problem "The Linear project \`$HEALTH_PROJECT\` was not found (or the query failed), so the other queries have no sample data."
  else
    issue_id=$(linear_gql 'query($p: ID!) { issues(first: 1, filter: { project: { id: { eq: $p } } }) { nodes { id } } }' "$(jq -n --arg p "$project_id" '{p: $p}')" 2>/dev/null | jq -r '.data.issues.nodes[0].id // empty') || issue_id=""
    [ -n "$issue_id" ] || problem "The Linear project \`$HEALTH_PROJECT\` has no issues to use as sample data."
  fi
  if [ -n "$project_id" ] && [ -n "$issue_id" ]; then
    while IFS= read -r -d '' q; do
      n=$((n + 1))
      name=$(grep -oE '^query[[:space:]]*[A-Za-z]*' <<<"$q" | head -n1)
      vars='{}'
      while IFS= read -r v; do
        case "$v" in
          id) vars=$(jq -c --arg x "$issue_id" '.id = $x' <<<"$vars") ;;
          t) vars=$(jq -c --arg x "$team_id" '.t = $x' <<<"$vars") ;;
          p) vars=$(jq -c --arg x "$project_id" '.p = $x' <<<"$vars") ;;
          n) vars=$(jq -c --arg x "$HEALTH_PROJECT" '.n = $x' <<<"$vars") ;;
          l) vars=$(jq -c '.l = "factory:follow-up"' <<<"$vars") ;;
          *) problem "A query ($name, \`${q:0:60}…\`) uses the variable \`\$$v\` and the health check has no sample value for it: add one to \`check_linear_queries\` in \`agents/health/checks.sh\`."; vars=""; break ;;
        esac
      done < <(grep -oP '\$\K\w+(?=:)' <<<"$q" | sort -u)
      [ -n "$vars" ] || continue
      if out=$(linear_gql "$q" "$vars" 2>&1); then
        msg=$(jq -r '[.errors[]?.message] | join("; ")' <<<"$out" 2>/dev/null) || msg=""
      else
        msg=$(jq -r '[.errors[]?.message] | join("; ")' <<<"$out" 2>/dev/null) || msg=""
        [ -n "$msg" ] || msg="the request failed"
      fi
      [ -z "$msg" ] || problem "Linear rejected the query \`${q:0:80}…\`: ${msg:0:300}"
    done < <(extract_queries)
    [ "$n" -ge 8 ] || problem "Only $n queries were found in the sources (expected at least 8): the extraction in \`extract_queries\` no longer matches how the queries are written."
  fi
  finish linear-queries "Linear queries fail against the real API" \
    "A query the relay or an agent sends is rejected by Linear (too complex, renamed field, missing permission). Fix the query in \`relay/src/index.ts\` or \`agents/lib/linear.sh\`, like KOE-32 did."
}
