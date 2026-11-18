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
  "PROJECT_REPOS": { "Factory": "o/factory", "A": "a", "B": "o/b", "C": "o/c" } },
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
  "pr list"*) ;;
esac
GH
chmod +x "$tmp/bin/gh"
: > "$tmp/gh.log"
set +e
out=$(PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" SAME="$tmp/same.yml" OLD="$tmp/old.yml" FACTORY_REPO=o/factory \
  WRANGLER_CONFIG="$tmp/config.jsonc" bash "$here/sync-caller.sh" 2>&1); code=$?
set -e
check "one failure -> exit 1" 1 "$code"
check "up to date repo: no PR" 0 "$(grep -c 'pr create -R o/a' "$tmp/gh.log" || true)"
check "differing repo: PR opened" 1 "$(grep -c 'pr create -R o/c .*--title Update factory caller workflow --label factory-sync' "$tmp/gh.log" || true)"
check "failure doesn't stop later repos" 1 "$(grep -c 'o/c: opened PR' <<<"$out" || true)"
check "factory and preview repos skipped" 0 "$(grep -cE '(repos/|-R )o/(factory|x)' "$tmp/gh.log" || true)"
exit "$fail"
