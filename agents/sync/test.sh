#!/usr/bin/env bash
# Tests for sync-caller.sh with a fake `gh` (no network). Usage: bash agents/sync/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
tpl="$root/templates/app-repo/.github/workflows/factory.yml"
{ echo "# repo-specific header"; awk 'f || !/^#/ { f = 1; print }' "$tpl"; } > "$tmp/same.yml"
{ echo "# repo-specific header"; echo "name: Old"; } > "$tmp/old.yml"
cat > "$tmp/config.jsonc" <<'J'
{ "vars": { // c
  "PROJECT_REPOS": { "Factory": "o/factory", "A": "a", "B": "o/b", "C": "o/c", "D": "o/d" } },
  "env": { "preview": { "vars": { "PROJECT_REPOS": { "X": "o/x" } } } } }
J
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "api repos/o/b"*) exit 1 ;;                       # b: fails
  "api repos/o/"?" --jq .default_branch") echo main ;;
  *"repos/o/a/contents/"*"ref=main") jq -n --rawfile c "$SAME" '{sha:"s1",content:($c|@base64)}' ;;
  *"repos/o/c/contents/"*"ref=main") jq -n --rawfile c "$OLD" '{sha:"s2",content:($c|@base64)}' ;;
  *"git/ref/heads/main"*) echo abc ;;
  *"repos/o/d/contents/"*"ref=main") jq -n --rawfile c "$OLD" '{sha:"s3",content:($c|@base64)}' ;;
  "pr list -R o/d"*) echo "7 kv-9-factory-caller-update" ;;
  "pr create"*) echo "https://github.com/o/c/pull/1" ;;
esac
GH
# Fake Linear: logs the query, answers each call.
cat > "$tmp/bin/curl" <<'CU'
#!/usr/bin/env bash
body=$(cat <<<"$*")
echo "$body" >> "$CURL_LOG"
case "$body" in
  *projects\(first*) echo '{"data":{"projects":{"nodes":[{"id":"p1","name":"C","teams":{"nodes":[{"id":"t1","states":{"nodes":[{"id":"s-nh","name":"Needs Human","type":"started"}]},"labels":{"nodes":[{"id":"l1","name":"Agent","parent":{"name":"Origin"}},{"id":"l2","name":"Human involved","parent":{"name":"Delivery"}}]}}]}}]}}}' ;;
  *issueCreate*) echo '{"data":{"issueCreate":{"issue":{"identifier":"KV-41","url":"https://linear.app/x/KV-41"}}}}' ;;
  *"issue(id"*) echo '{"data":{"issue":{"id":"u1"}}}' ;;
  *) echo '{"data":{}}' ;;
esac
CU
chmod +x "$tmp/bin/gh" "$tmp/bin/curl"
: > "$tmp/gh.log"; : > "$tmp/curl.log"
set +e
out=$(PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" CURL_LOG="$tmp/curl.log" LINEAR_API_KEY=k TRIGGER_TITLE="KV-35: Move org (#20)" SAME="$tmp/same.yml" OLD="$tmp/old.yml" FACTORY_REPO=o/factory \
  WRANGLER_CONFIG="$tmp/config.jsonc" bash "$here/sync-caller.sh" 2>&1); code=$?
set -e
check "one failure -> exit 1" 1 "$code"
check "up to date repo: no PR" 0 "$(grep -c 'pr create -R o/a' "$tmp/gh.log" || true)"
check "differing repo: PR opened with ticket id in title" 1 "$(grep -c 'pr create -R o/c .*--title KV-41: Update factory caller workflow --label factory-sync' "$tmp/gh.log" || true)"
check "branch starts with ticket id" 1 "$(grep -c 'pr create -R o/c --head kv-41-factory-caller-update' "$tmp/gh.log" || true)"
check "ticket created once (open PR keeps its ticket)" 1 "$(grep -c issueCreate "$tmp/curl.log" || true)"
check "open PR updated, no new PR" 0 "$(grep -c 'pr create -R o/d' "$tmp/gh.log" || true)"
check "open PR branch reused" 1 "$(grep -c 'ref=refs/heads/kv-9-factory-caller-update' "$tmp/gh.log" || true)"
check "trigger ticket commented" 1 "$(grep -c 'commentCreate' "$tmp/curl.log" || true)"
check "failure doesn't stop later repos" 1 "$(grep -c 'o/c: opened PR' <<<"$out" || true)"
check "factory and preview repos skipped" 0 "$(grep -cE '(repos/|-R )o/(factory|x)' "$tmp/gh.log" || true)"
# Linear unreachable: the PR is still opened, with the fallback branch.
printf '#!/usr/bin/env bash\nexit 22\n' > "$tmp/bin/curl"
: > "$tmp/gh.log"
set +e
out=$(PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" LINEAR_API_KEY=k SAME="$tmp/same.yml" OLD="$tmp/old.yml" FACTORY_REPO=o/factory \
  WRANGLER_CONFIG="$tmp/config.jsonc" bash "$here/sync-caller.sh" 2>&1)
set -e
check "Linear down: PR still opened" 1 "$(grep -c 'pr create -R o/c --head factory/sync-caller-workflow .*--title Update factory caller workflow' "$tmp/gh.log" || true)"
check "Linear down: warning logged" 1 "$(grep -c '::warning::' <<<"$out" | awk '{ print ($1 > 0) }')"
exit "$fail"
