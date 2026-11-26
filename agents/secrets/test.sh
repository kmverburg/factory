#!/usr/bin/env bash
# Tests for the secret scan with a fake `gh` and `curl` (no network). Usage: bash agents/secrets/test.sh
# The fake secrets are built at run time, so this file itself never holds one in a form the scan would flag.
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
count() { grep -c -- "$1" "$2" || true; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

rnd() { python3 -I -c 'import secrets,string,sys; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))))' "$1"; }
GH_LEAK="gh""p_$(rnd 40)"; LIN_LEAK="lin""_api_$(rnd 40)"; CF_VALUE="$(rnd 40)"; CL_LEAK="sk-""ant-oat01-$(rnd 50)"
KEY_LEAK="-----BEGIN ""RSA PRIVATE KEY-----"
PLACEHOLDER="gh""p_$(printf 'x%.0s' {1..40})"
LIN_VALUE=$(rnd 40)
export CLOUDFLARE_API_TOKEN="$CF_VALUE" LINEAR_API_KEY="$LIN_VALUE"

# ---- match.py: formats and values
m() { printf '%s\n' "$1" | python3 -I "$here/match.py" | jq -r '"\(.type)/\(.how)"' | paste -sd, -; }
check "format: GitHub token" "GitHub token/format" "$(m "token: $GH_LEAK")"
check "format: Linear key" "Linear API key/format" "$(m "$LIN_LEAK")"
check "format: Claude token" "Claude token/format" "$(m "x $CL_LEAK x")"
check "format: private key" "Private key/format" "$(m "$KEY_LEAK")"
check "format: placeholders are ignored" "" "$(m "$PLACEHOLDER")"
check "format: masked secrets are ignored" "" "$(m "token ghp_*** and sk-ant-***")"
check "value: the current Cloudflare token, compared as a hash" "Cloudflare token/value:CLOUDFLARE_API_TOKEN" "$(m "CLOUDFLARE_API_TOKEN=$CF_VALUE")"
check "value: in quotes" "Cloudflare token/value:CLOUDFLARE_API_TOKEN" "$(m "{\"t\":\"$CF_VALUE\"}")"
check "value: another string is not a hit" "" "$(m "$(rnd 40)")"
KEYVAL=$(printf '%s\n%s\n%s\n%s\n' "-----BEGIN ""PRIVATE KEY-----" "$(rnd 64)" "$(rnd 64)" "-----END ""PRIVATE KEY-----")
check "value: one line of a multi-line key" "Private key/value:FACTORY_APP_PRIVATE_KEY" "$(FACTORY_APP_PRIVATE_KEY="$KEYVAL" m "$(sed -n 2p <<<"$KEYVAL")")"
out=$(printf '%s\n' "$GH_LEAK $CF_VALUE" | python3 -I "$here/match.py")
check "output never contains a secret" 0 "$(grep -cF -e "$GH_LEAK" -e "$CF_VALUE" <<<"$out" || true)"

# ---- scan.sh with fakes
cat > "$tmp/wrangler.jsonc" <<'J'
{ "name": "factory", "vars": { "PROJECT_REPOS": { "Factory": "factory", "Backpack": "backpack" } } }
J
echo '[{"project":"Backpack","repo":"backpack","worker":"backpack"}]' > "$tmp/apps.json"
printf '%s\n' "deploy ok" "using $GH_LEAK here" > "$tmp/log.txt"
(cd "$tmp" && zip -q log.zip log.txt)

cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  *"actions/runs/"*"/logs"*) [ "$*" = "${*/factory/}" ] || { [ -z "$NO_LOG_LEAK" ] && cat "$ZIP" || printf 'PK'; } ;;
  *"/actions/runs?"*) echo 11 ;;
  *"/branches"*) echo main ;;
  *"/commits/c1"*"diff"*) echo "+++ b/x"; echo "+token = $COMMIT_LEAK" ;;
  *"/commits/c1"*) echo "message" ;;
  *"/commits?"*) echo c1 ;;
  "api repos/o/factory") echo '{"private":false,"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}' ;;
  "api repos/o/backpack") echo '{"private":false,"security_and_analysis":{"secret_scanning":{"status":"disabled"},"secret_scanning_push_protection":{"status":"disabled"}}}' ;;
  "api -X PATCH"*) [ -z "$PATCH_FAILS" ] || exit 1 ;;
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
  */workers/scripts*) reply 200 '{"result":[{"id":"backpack","tag":"tb"},{"id":"factory","tag":"tf"}]}' ;;
  */builds/workers/*/builds*) reply 200 '{"result":[{"build_uuid":"aaaaaaaa-1111-2222-3333-444444444444","created_on":"2999-01-01T00:00:00Z"},{"build_uuid":"bbbbbbbb-1111-2222-3333-444444444444","created_on":"2000-01-01T00:00:00Z"}]}' ;;
  */builds/builds/*/logs) reply 200 "{\"result\":{\"lines\":[[1,\"building\"],[2,\"LIN=$BUILD_LEAK\"]]}}" ;;
  https://api.linear.app/graphql)
    case "$data" in
      *"projects(first"*) echo '{"data":{"projects":{"nodes":[{"id":"p1","name":"Factory","teams":{"nodes":[{"id":"t1","states":{"nodes":[{"id":"s-todo","name":"Todo","type":"unstarted"}]},"labels":{"nodes":[{"id":"o-agent","name":"Agent","parent":{"name":"Origin"}},{"id":"l-leak","name":"factory:secret-leak","parent":null},{"id":"l-manual","name":"factory:manual","parent":null}]}}]}}]}}}' ;;
      *"issues(first: 250"*) echo "${OPEN_ISSUES:-$EMPTY}" ;;
      *"users(first"*) echo '{"data":{"users":{"nodes":[{"id":"u-koen"}]}}}' ;;
      *issueCreate*) echo '{"data":{"issueCreate":{"issue":{"identifier":"KV-77","url":"https://linear.app/x/KV-77"}}}}' ;;
      *) echo '{"data":{"ok":true}}' ;;
    esac ;;
  *) reply 404 '{}' ;;
esac
CU
chmod +x "$tmp/bin/"*

export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" CURL_LOG="$tmp/curl.log" ZIP="$tmp/log.zip" GH_TOKEN=app-token FACTORY_REPO=o/factory
export WRANGLER_CONFIG="$tmp/wrangler.jsonc" APPS_FILE="$tmp/apps.json" CLOUDFLARE_ACCOUNT_ID=0123456789abcdef0123456789abcdef CLOUDFLARE_BUILDS_TOKEN=builds-token-value-here
export COMMIT_LEAK="$LIN_LEAK" BUILD_LEAK="$CL_LEAK" SCAN_SINCE=2026-01-01T00:00:00Z
run() { : > "$GH_LOG"; : > "$CURL_LOG"; bash "$here/scan.sh" "$@" > "$tmp/out.txt" 2>&1 || echo "exit $?" >> "$tmp/out.txt"; }
leaks_in() { grep -cF -e "$GH_LEAK" -e "$LIN_LEAK" -e "$CL_LEAK" -e "$CF_VALUE" "$@" || true; }

run --dry-run
check "dry run: finds the leak in an Actions log" 1 "$(count 'LEAK  GitHub token (format) in the GitHub Actions log of run https://github.com/o/factory/actions/runs/11' "$tmp/out.txt")"
check "dry run: finds the leak in a commit on a branch" 1 "$(count 'LEAK  Linear API key (format) in the commit https://github.com/o/backpack/commit/c1' "$tmp/out.txt")"
check "dry run: finds the leak in a Workers Builds log" 1 "$(count 'LEAK  Claude token (format) in the Cloudflare Workers Builds log of build .aaaaaaaa' "$tmp/out.txt")"
check "dry run: ignores a build older than the window" 0 "$(count 'bbbbbbbb' "$tmp/out.txt")"
check "dry run: creates nothing" 0 "$(count 'issueCreate\|commentCreate' "$CURL_LOG")"
check "dry run: never prints a secret" 0 "$(leaks_in "$tmp/out.txt")"
check "dry run: turns on nothing" 0 "$(count 'PATCH' "$GH_LOG")"

run
check "tickets: one per leak (the fake commit is on both repos)" 4 "$(count 'issueCreate' "$CURL_LOG")"
check "tickets: high priority" 4 "$(grep -c '"priority": 2' "$CURL_LOG" || true)"
check "tickets: Todo, never Agent Ready" 0 "$(count 'Agent Ready' "$CURL_LOG")"
check "tickets: say where, which type, and how to rotate in Infisical" 4 "$(grep -c 'Infisical' "$CURL_LOG" || true)"
check "tickets: never contain a secret" 0 "$(leaks_in <(cat "$CURL_LOG" "$tmp/out.txt"))"
check "tickets: turns on GitHub secret scanning where it is off" 1 "$(count 'PATCH repos/o/backpack' "$GH_LOG")"
check "tickets: ...and not where it is on" 0 "$(count 'PATCH repos/o/factory' "$GH_LOG")"

# The same leak is not reported twice: the open ticket carries the fingerprint, so a comment is added instead.
fp=$(grep -o 'secretleak-[0-9a-f]\{16\}' "$CURL_LOG" | sort -u | head -n1)
OPEN="{\"data\":{\"issues\":{\"nodes\":[{\"id\":\"i1\",\"identifier\":\"KV-70\",\"url\":\"u\",\"title\":\"t\",\"description\":\"Leak: \`$fp\`\"}]}}}"
OPEN_ISSUES=$OPEN run
check "dedup: one of the four is a repeat (comment, no new ticket)" 3 "$(count 'issueCreate' "$CURL_LOG")"
check "dedup: it gets a comment instead" 1 "$(count 'commentCreate' "$CURL_LOG")"

PATCH_FAILS=1 run
check "scanning off: a manual ticket for Koen when the app may not switch it on" 1 "$(count 'Turn on GitHub secret scanning' "$CURL_LOG" | sed 's/^[0-9]*$/1/')"

# Nothing leaked: no ticket.
NO_LOG_LEAK=1 COMMIT_LEAK=nothing BUILD_LEAK=nothing run
check "clean: no leak ticket" 0 "$(count 'Secret leak' "$CURL_LOG")"
check "clean: says so" 1 "$(count '^0 leak(s) found' "$tmp/out.txt")"

[ "$fail" = 0 ] && echo "all passed"
exit $fail
