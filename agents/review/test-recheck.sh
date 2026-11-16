#!/usr/bin/env bash
# Tests for the re-review gate (recheck.sh). Fake `gh`, no network. Usage: bash agents/review/test-recheck.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view") cat "$PR_JSON" ;;
  "api repos/o/r/commits/abc/pulls") echo 7 ;;
esac
GH
chmod +x "$tmp/bin/gh"

# $1 = check name, $2 = PR JSON, $3 = PR number from the event. Prints "pr_number|fix_round".
run() {
  printf '%s' "$2" > "$tmp/pr.json"; : > "$tmp/gh.log"; : > "$tmp/out"
  PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" PR_JSON="$tmp/pr.json" GITHUB_OUTPUT="$tmp/out" GITHUB_REPOSITORY=o/r \
    CHECK_NAME="$1" HEAD_SHA=abc PR_NUMBER="$3" bash "$here/recheck.sh" >/dev/null
  printf '%s|%s' "$(sed -n 's/^pr_number=//p' "$tmp/out")" "$(sed -n 's/^fix_round=//p' "$tmp/out")"
}
pr() { # $1 labels JSON, $2 comments JSON, $3 autoMergeRequest JSON, $4 state, $5 head
  printf '{"state":"%s","isDraft":false,"labels":%s,"comments":%s,"autoMergeRequest":%s,"headRefOid":"%s"}' "${4:-OPEN}" "$1" "$2" "$3" "${5:-abc}"
}
built='[{"name":"agent-built"}]'
none='[]'

check "failed check on agent PR -> review, round 0" "7|0" "$(run "Workers Builds: app" "$(pr "$built" "$none" null)" 7)"
check "no auto-merge to cancel" 0 "$(grep -c 'disable-auto' "$tmp/gh.log" || true)"
check "round read from builder comments" "7|2" "$(run "Workers Builds: app" "$(pr "$built" '[{"body":"### 🔧 Builder applied review fixes (round 1)\nx"},{"body":"### 🔧 Builder applied review fixes (round 2)\nx"}]' null)" 7)"
check "PR number found through the commit" "7|0" "$(run "Workers Builds: app" "$(pr "$built" "$none" null)" "")"
check "factory 'build' check ignored" "|" "$(run "build / build" "$(pr "$built" "$none" null)" 7)"
check "factory 'review' check ignored" "|" "$(run "review" "$(pr "$built" "$none" null)" 7)"
check "app check named build-web is not ignored" "7|0" "$(run "build-web" "$(pr "$built" "$none" null)" 7)"
check "not an agent PR" "|" "$(run "ci" "$(pr "$none" "$none" null)" 7)"
check "closed PR" "|" "$(run "ci" "$(pr "$built" "$none" null CLOSED)" 7)"
check "check on an older commit" "|" "$(run "ci" "$(pr "$built" "$none" null OPEN old)" 7)"
check "fix round already running" "|" "$(run "ci" "$(pr '[{"name":"agent-built"},{"name":"agent-fixing"}]' "$none" null)" 7)"
check "auto-merge on: review starts" "7|0" "$(run "ci" "$(pr "$built" "$none" '{"mergeMethod":"SQUASH"}')" 7)"
check "auto-merge cancelled" 1 "$(grep -c 'pr merge 7 --disable-auto' "$tmp/gh.log" || true)"
check "auto-merge cancelled even while fixing" 1 "$(run "ci" "$(pr '[{"name":"agent-built"},{"name":"agent-fixing"}]' "$none" '{"mergeMethod":"SQUASH"}')" 7 >/dev/null; grep -c 'disable-auto' "$tmp/gh.log" || true)"
exit $fail
