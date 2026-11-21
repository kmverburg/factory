#!/usr/bin/env bash
# Tests for the health check with a fake `gh` and a fake `curl` (no network). Usage: bash agents/health/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
count() { grep -c -- "$1" "$2" || true; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# Every query the relay and agents send must have sample values in the health check.
bad=$(node "$here/queries.mjs" "$root" | jq -r '[.[].variables[].name | select(. != "id" and . != "t" and . != "p" and . != "n" and . != "l")] | unique | join(",")')
check "all query variables have sample values" "" "$bad"
check "queries are found in the relay and the agents" 1 "$(node "$here/queries.mjs" "$root" | jq '[.[].file | select(startswith("relay/") or startswith("agents/lib/"))] | length > 5 | if . then 1 else 0 end')"

cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
repo=$(grep -oE 'repos/o/[a-z]+' <<<"$*" | head -n1 | cut -d/ -f3 || true)
case "$*" in
  *installation/repositories*) printf 'o/backpack\no/feast\no/factory\n' ;;
  *"--jq .default_branch"*) echo main ;;
  *"--jq .allow_auto_merge"*) [ "$repo" = "${NO_AUTO_MERGE:-none}" ] && echo false || echo true ;;
  *contents/.github/workflows/factory.yml*) base64 -w0 "$CALLER" ;;
  *rules/branches*) printf 'build\nWorkers Builds: %s\n' "$repo" ;;
  *protection/required_status_checks*) exit 1 ;;
  *check-runs*) printf 'build\nWorkers Builds: %s\n' "$repo" ;;
  "pr list -R o/"*) echo '{"number":7,"title":"KV-9: thing","headRefName":"kv-9-thing","mergedAt":"2020-01-01T00:00:00Z"}' ;;
  *orgs/*/installations*) exit 1 ;;
esac
GH
cat > "$tmp/bin/curl" <<'CU'
#!/usr/bin/env bash
args="$*"
case "$args" in *"-K -"*) cat >/dev/null ;; esac
payload=""
while [ $# -gt 0 ]; do if [ "$1" = "-d" ]; then payload=$2; fi; shift; done
echo "$(grep -oE 'https://[^ ]+' <<<"$args" | head -n1) $(jq -c . <<<"$payload" 2>/dev/null || true)" >> "$CURL_LOG"
q=$(jq -r '.query // empty' <<<"$payload" 2>/dev/null || true)
case "$args" in
  *api.linear.app*)
    case "$q" in
      *viewer*) echo '{"data":{"viewer":{"id":"v1"}}}' ;;
      *"projects(first"*) echo '{"data":{"projects":{"nodes":[{"id":"p1","name":"Factory","teams":{"nodes":[{"id":"t1","states":{"nodes":[{"id":"s-todo","name":"Todo","type":"unstarted"}]},"labels":{"nodes":[{"id":"l-src","name":"source:health"},{"id":"l-agent","name":"Agent","parent":{"name":"Origin"}}]}}]}}]}}}' ;;
      *"team(id"*) echo '{"data":{"team":{"issues":{"nodes":[{"identifier":"KV-1"}]}}}}' ;;
      *"issues(first: 250"*) cat "$OPEN_FILE" ;;
      *attachments*) echo '{"data":{"issue":{"identifier":"KV-9","state":{"name":"Done","type":"completed"},"attachments":{"nodes":[{"url":"https://github.com/o/backpack/pull/7"},{"url":"https://github.com/o/feast/pull/7"},{"url":"https://github.com/o/factory/pull/7"}]}}}}' ;;
      *issueCreate*) echo '{"data":{"issueCreate":{"issue":{"identifier":"KV-50","url":"https://linear.app/x/KV-50"}}}}' ;;
      *mutation*) echo '{"data":{"ok":{"success":true}}}' ;;
      *) echo '{"data":{"x":{"id":"1"}}}' ;;
    esac ;;
  *tokens/verify*) echo '{"result":{"status":"active"}}' ;;
  *workers/scripts) echo '{"result":[{"id":"backpack","tag":"t1"},{"id":"feast","tag":"t2"},{"id":"factory","tag":"t3"}]}' ;;
  *triggers*) echo '{"result":[{"repo_connection":{"repo_name":"x"}}]}' ;;
  *api.anthropic.com*) echo 200 ;;
  *"/health?deep=1"*) printf '%s\n200' '{"ok":true,"github":{"ok":true,"status":200},"linear":{"ok":true},"secrets":{"LINEAR_API_KEY":true,"LINEAR_WEBHOOK_SECRET":true,"GITHUB_TOKEN":true}}' ;;
  *relay.test*) printf 'factory-relay is running' ;;
esac
CU
chmod +x "$tmp/bin/gh" "$tmp/bin/curl"

# A run in the repo root with every secret set to a recognisable fake value.
run() { # $@ = extra args for health.sh; output in $out, exit code in $code
  : > "$tmp/gh.log"; : > "$tmp/curl.log"
  set +e
  out=$(cd "$root" && env PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" CURL_LOG="$tmp/curl.log" CALLER="$root/templates/app-repo/.github/workflows/factory.yml" OPEN_FILE="$tmp/open.json" \
    FACTORY_REPO=o/factory RELAY_URL=https://relay.test HEALTH_CHECK_SECRET=hc-secret-value-1 GH_TOKEN=gh-secret-value-2 APP_TOKEN_OK=true \
    LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwx CLOUDFLARE_ACCOUNT_ID=0123456789abcdef0123456789abcdef \
    CLOUDFLARE_API_TOKEN=cfapitokenabcdefghijklmnopqrstuvwxyz1 CLOUDFLARE_BUILDS_TOKEN=cfbuildstokenabcdefghijklmnopqrstuvw CLOUDFLARE_OBSERVABILITY_TOKEN=cfobservtokenabcdefghijklmnopqrstuvw \
    CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-abcdefghijklmnopqrstuvwxyz FACTORY_APP_ID=12345 FACTORY_APP_PRIVATE_KEY='-----BEGIN RSA PRIVATE KEY-----' \
    ${EXTRA_ENV:-} bash agents/health/health.sh "$@" 2>&1); code=$?
  set -e
}
echo '{"data":{"issues":{"nodes":[]}}}' > "$tmp/open.json"

run --dry-run
check "healthy dry run: exit 0" 0 "$code"
check "healthy dry run: no failures" "0 failed" "$(grep -oE '[0-9]+ failed' <<<"$out")"
check "healthy dry run: no ticket created or changed" 0 "$(grep -cE 'issueCreate|issueUpdate|commentCreate' "$tmp/curl.log" || true)"
for secret in hc-secret-value-1 gh-secret-value-2 lin_api_abcdefghijklmnopqrstuvwx cfapitokenabcdefghijklmnopqrstuvwxyz1 sk-ant-oat01-abcdefghijklmnopqrstuvwxyz; do
  check "no secret value in the output: ${secret:0:8}…" 0 "$(grep -cF "$secret" <<<"$out" || true)"
done
check "every Linear query ran" 1 "$(grep -c 'All Linear queries run' <<<"$out")"

# A failing check without --dry-run: one ticket in Todo, labelled, with a signature.
EXTRA_ENV="NO_AUTO_MERGE=feast" run
check "failure: one failed check" "1 failed" "$(grep -oE '[0-9]+ failed' <<<"$out")"
check "failure: exit 0 (the ticket is the report)" 0 "$code"
check "failure: one ticket created" 1 "$(count issueCreate "$tmp/curl.log")"
check "failure: ticket title" 1 "$(grep -c 'Factory health: Auto-merge is not allowed on feast' <<<"$out" || true)"
check "failure: ticket in Todo with labels" 1 "$(grep issueCreate "$tmp/curl.log" | grep -c 's-todo.*l-src\|l-src.*s-todo\|"labelIds"' || true)"
check "failure: signature in the ticket" 1 "$(grep issueCreate "$tmp/curl.log" | grep -c 'healthsig-github-feast-auto-merge' || true)"

# The same failure with an open ticket: updated, not created again.
jq -n '{data:{issues:{nodes:[{id:"u1",identifier:"KV-50",description:"x\nHealth status: failing\nSignature: `healthsig-github-feast-auto-merge`"}]}}}' > "$tmp/open.json"
EXTRA_ENV="NO_AUTO_MERGE=feast" run
check "repeat: no new ticket" 0 "$(count issueCreate "$tmp/curl.log")"
check "repeat: existing ticket updated" 1 "$(grep -c 'updated KV-50' <<<"$out")"
check "repeat: no comment" 0 "$(count commentCreate "$tmp/curl.log")"

# The problem is gone: one comment, ticket marked recovered; the next run stays quiet.
run
check "recovered: comment added" 1 "$(count commentCreate "$tmp/curl.log")"
check "recovered: ticket marked" 1 "$(grep -c 'recovered KV-50' <<<"$out" || true)"
jq -n '{data:{issues:{nodes:[{id:"u1",identifier:"KV-50",description:"x\nHealth status: recovered (2025-01-01)\nSignature: `healthsig-github-feast-auto-merge`"}]}}}' > "$tmp/open.json"
run
check "recovered ticket: no more comments" 0 "$(count commentCreate "$tmp/curl.log")"

# Other failures are found: a missing secret and an out-of-date caller.
echo '{"data":{"issues":{"nodes":[]}}}' > "$tmp/open.json"
EXTRA_ENV="CLAUDE_CODE_OAUTH_TOKEN=" run --dry-run
check "missing secret is a failure" 1 "$(grep -c 'Secret CLAUDE_CODE_OAUTH_TOKEN is missing' <<<"$out")"
echo "name: Old" > "$tmp/old.yml"
set +e; : > "$tmp/gh.log"; : > "$tmp/curl.log"
out=$(cd "$root" && env PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" CURL_LOG="$tmp/curl.log" CALLER="$tmp/old.yml" OPEN_FILE="$tmp/open.json" FACTORY_REPO=o/factory LINEAR_API_KEY=lin_api_abcdefghijklmnopqrstuvwx bash agents/health/health.sh --dry-run 2>&1)
set -e
check "out-of-date caller is a failure" 1 "$(grep -c "backpack's factory caller workflow is out of date" <<<"$out")"
check "factory repo's own caller isn't compared to the template" 0 "$(grep -c "factory's factory caller workflow is out of date" <<<"$out")"
check "unset relay URL is a failure" 1 "$(grep -c 'Relay URL is not set' <<<"$out")"

exit "$fail"
