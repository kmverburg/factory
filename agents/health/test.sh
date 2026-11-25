#!/usr/bin/env bash
# Tests for the daily health check with a fake `gh` and `curl` (no network). Usage: bash agents/health/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
count() { grep -c -- "$1" "$2" || true; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
tpl="$root/templates/app-repo/.github/workflows/factory.yml"

# The queries are found in the sources, and nothing else talks to Linear (a new place would need adding here).
# shellcheck source=checks.sh
export ROOT=$root; source "$here/checks.sh"
check "queries: found in linear.sh and the relay (at least 8)" 1 "$([ "$(extract_queries | tr -cd '\0' | wc -c)" -ge 8 ] && echo 1 || echo 0)"
check "queries: only linear.sh and the relay call the Linear API" "agents/lib/linear.sh relay/src/index.ts" \
  "$(cd "$root" && grep -rl 'api.linear.app' agents relay/src --include=*.sh --include=*.ts --include=*.jq | grep -v '/test' | sort | tr '\n' ' ' | sed 's/ $//')"

cat > "$tmp/wrangler.jsonc" <<'J'
{
  "name": "factory",
  "vars": { // c
    "PROJECT_REPOS": { "Factory": "factory", "Backpack": "backpack" } } }
J
echo '[{"project":"Backpack","repo":"backpack","worker":"backpack"}]' > "$tmp/apps.json"

cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "api --paginate installation/repositories"*) printf 'o/factory\no/backpack\n' ;;
  *"contents/.github/workflows/factory.yml"*) { echo "# header"; awk 'f || !/^#/ { f = 1; print }' "$TPL"; } | base64 -w0 ;;
  *"/rules/branches/main"*) printf 'build\nWorkers Builds: backpack\n' ;;
  *"required_status_checks"*) exit 1 ;;
  *"--jq .allow_auto_merge") echo "${AUTO_MERGE:-true}" ;;
  *"/actions/workflows/"*) ;;
  *"/check-runs"*) echo "Workers Builds: backpack" ;;
  *"/status"*) ;;
  "pr list"*) echo '[{"number":9,"headRefName":"kv-1-thing","mergedAt":"2020-01-01T00:00:00Z"}]' ;;
esac
GH
cat > "$tmp/bin/curl" <<'CU'
#!/usr/bin/env bash
out=""; data=""; url=""; EMPTY='{"data":{"issues":{"nodes":[]}}}'
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift ;; -d) data=$2; shift ;; -w|-K|-H|--max-time) shift ;; -*) ;; *) url=$1 ;; esac
  shift
done
echo "$url $data" >> "$CURL_LOG"
reply() { if [ -n "$out" ]; then echo "$2" > "$out"; printf '%s' "$1"; else echo "$2"; fi; }
case "$url" in
  */health) reply 200 '{"ok":true}' ;;
  *"/health?deep=1") if [ -n "$RELAY_BAD" ]; then reply 503 '{"ok":false,"github":401,"linear":200,"repos":{}}'; else reply 200 '{"ok":true}'; fi ;;
  *tokens/verify) reply 200 '{"result":{"status":"active"}}' ;;
  */workers/scripts) reply 200 '{"result":[{"id":"backpack","tag":"tb"},{"id":"factory","tag":"tf"}]}' ;;
  */triggers) reply 200 '{"result":[{"id":"t"}]}' ;;
  https://api.linear.app/graphql)
    case "$data" in
      *viewer*) echo '{"data":{"viewer":{"id":"u"}}}' ;;
      *"projects(first"*) echo '{"data":{"projects":{"nodes":[{"id":"p1","name":"Factory","teams":{"nodes":[{"id":"t1","states":{"nodes":[{"id":"s-todo","name":"Todo","type":"unstarted"}]},"labels":{"nodes":[{"id":"o-agent","name":"Agent","parent":{"name":"Origin"}},{"id":"l-health","name":"factory:health","parent":null}]}}]}}]}}}' ;;
      *"issues(first: 1"*) echo '{"data":{"issues":{"nodes":[{"id":"i1"}]}}}' ;;
      *"issues(first: 250"*) echo "${OPEN_ISSUES:-$EMPTY}" ;;
      *"identifier state"*) echo '{"data":{"issue":{"identifier":"KV-1","state":{"name":"Done","type":"completed"},"attachments":{"nodes":[{"url":"https://github.com/o/backpack/pull/9"},{"url":"https://github.com/o/factory/pull/9"}]}}}}' ;;
      *issueCreate*) echo '{"data":{"issueCreate":{"issue":{"identifier":"KV-77","url":"https://linear.app/x/KV-77"}}}}' ;;
      *) echo '{"data":{"ok":true}}' ;;
    esac ;;
  *) reply 404 '{}' ;;
esac
CU
chmod +x "$tmp/bin/"*

export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" CURL_LOG="$tmp/curl.log" TPL="$tpl" GH_TOKEN=app-token-secret-value
export FACTORY_REPO=o/factory WRANGLER_CONFIG="$tmp/wrangler.jsonc" APPS_FILE="$tmp/apps.json" RELAY_URL=https://relay.test HEALTH_TODAY=2026-01-02
export LINEAR_API_KEY=lin_api_SECRETSECRETSECRETSECRET1234 CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-SECRETSECRETSECRETSECRETSECRETSECRET
export CLOUDFLARE_ACCOUNT_ID=0123456789abcdef0123456789abcdef CLOUDFLARE_API_TOKEN=cfsecretcfsecretcfsecretcfsecret1 CLOUDFLARE_BUILDS_TOKEN=cfsecretcfsecretcfsecretcfsecret2 CLOUDFLARE_OBSERVABILITY_TOKEN=cfsecretcfsecretcfsecretcfsecret3
export HEALTH_CHECK_SECRET=healthsecrethealthsecret FACTORY_APP_ID=123 FACTORY_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----" APP_TOKEN_OUTCOME=success
run() { : > "$GH_LOG"; : > "$CURL_LOG"; bash "$here/health.sh" "$@" > "$tmp/out.txt" 2>&1 || echo "exit $?" >> "$tmp/out.txt"; }
mutations() { count "$1" "$CURL_LOG"; }

run
check "healthy: no failures" "0 of 16 checks failed." "$(grep 'checks failed' "$tmp/out.txt" | sed 's/^.*\(0 of [0-9]* checks failed\.\)$/\1/')"
check "healthy: no tickets" 0 "$(mutations issueCreate)"
check "healthy: exit code 0" 0 "$(count '^exit' "$tmp/out.txt")"

AUTO_MERGE=false run
check "failure: one ticket per failing repo (auto-merge is off for both)" 2 "$(mutations issueCreate)"
check "failure: names the problem" 1 "$(count 'Auto-merge is not allowed' "$tmp/out.txt" | sed 's/^[0-9]*$/1/')"
check "failure: ticket title" 1 "$(count 'Factory health: GitHub setup of backpack is incomplete' "$CURL_LOG")"
check "failure: in Todo with Origin and health labels" 1 "$(count 's-todo.*o-agent\|labelIds' "$CURL_LOG" | sed 's/^[0-9]*$/1/')"
check "failure: never Agent Ready" 0 "$(count 'Agent Ready' "$CURL_LOG")"

AUTO_MERGE=false run --dry-run
check "dry run: prints the failure" 1 "$(count 'FAIL  github-backpack' "$tmp/out.txt")"
check "dry run: creates and updates nothing" 0 "$(mutations 'issueCreate\|issueUpdate\|commentCreate')"

OPEN='{"data":{"issues":{"nodes":[{"id":"u9","identifier":"KV-50","description":"x\n\nHealth check: `github-backpack`\nHealth status: failing (checked 2026-01-01)"}]}}}'
OPEN_ISSUES=$OPEN AUTO_MERGE=false run
check "repeat: only the repo without a ticket gets a new one" 1 "$(mutations issueCreate)"
check "repeat: updates the existing ticket" 1 "$(count 'issueUpdate' "$CURL_LOG")"

OPEN_ISSUES=$OPEN run
check "resolved: comments once on the ticket" 1 "$(count 'commentCreate' "$CURL_LOG")"
check "resolved: marks the ticket resolved" 1 "$(count 'Health status: resolved (checked 2026-01-02)' "$CURL_LOG")"
RESOLVED='{"data":{"issues":{"nodes":[{"id":"u9","identifier":"KV-50","description":"Health check: `github-backpack`\nHealth status: resolved (checked 2026-01-01)"}]}}}'
OPEN_ISSUES=$RESOLVED run
check "resolved: no second comment the next day" 0 "$(count 'commentCreate' "$CURL_LOG")"

RELAY_BAD=1 run
check "relay: invalid GitHub token becomes a ticket" 1 "$(count 'Factory health: the relay is not healthy' "$CURL_LOG")"
LINEAR_API_KEY=short run --dry-run
check "secret: a malformed key is reported" 1 "$(count 'FAIL  secret-LINEAR_API_KEY' "$tmp/out.txt")"
CLOUDFLARE_BUILDS_TOKEN='' run --dry-run
check "secret: a missing token is reported by name" 1 "$(count 'CLOUDFLARE_BUILDS_TOKEN. is not set' "$tmp/out.txt")"
APP_TOKEN_OUTCOME=failure run --dry-run
check "secret: a failed app token is reported" 1 "$(count 'FAIL  secret-factory-app' "$tmp/out.txt")"
GH_TOKEN='' run --dry-run
check "no GitHub token: GitHub checks are skipped, not failed" 0 "$(count 'FAIL  github-' "$tmp/out.txt")"

# No secret value is ever printed.
run --dry-run
secrets_found=0
for v in "$LINEAR_API_KEY" "$CLAUDE_CODE_OAUTH_TOKEN" "$CLOUDFLARE_API_TOKEN" "$CLOUDFLARE_BUILDS_TOKEN" "$HEALTH_CHECK_SECRET" "$GH_TOKEN"; do
  secrets_found=$((secrets_found + $({ grep -cF "$v" "$tmp/out.txt" "$CURL_LOG" "$GH_LOG" || true; } | awk -F: '{s += $2} END {print s + 0}')))
done
check "secrets: no value appears in output or in the recorded requests" 0 "$secrets_found"

exit "$fail"
