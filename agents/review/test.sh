#!/usr/bin/env bash
# Tests for the reviewer's publish step: a diff touching .github/ must escalate and never auto-merge.
# Uses a fake `gh` and no Linear key, so it needs no network. Usage: bash agents/review/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
GH
chmod +x "$tmp/bin/gh"

# $1 = name, $2 = changed file, $3 = verdict JSON. Prints the final decision; the gh calls go to $tmp/gh.log.
run() {
  local w="$tmp/work-$1"; mkdir -p "$w/.factory-review"
  printf '{"files":[{"path":"%s"}]}' "$2" > "$w/.factory-review/pr.json"
  printf 'diff --git a/%s b/%s\n' "$2" "$2" > "$w/.factory-review/diff.patch"
  printf '%s' "$3" > "$w/.factory-review/verdict.json"
  : > "$tmp/gh.log"
  (cd "$w" && PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" FACTORY_DIR="$root" RUNNER_TEMP="$tmp" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r PR_NUMBER=1 AGENT_PR=true IDENTIFIER="" \
    MAX_FIX_ROUNDS=2 MAX_FOLLOW_UPS=3 FACTORY_APP_TOKEN=x LINEAR_API_KEY="" bash "$root/agents/review/publish.sh" >/dev/null)
  jq -r .decision "$w/.factory-review/verdict.json"
}
approve='{"decision":"approve","risk":"low","summary":"s","reasons":[],"fix_requests":[],"follow_ups":[],"checks":"c"}'
fix='{"decision":"fix","risk":"low","summary":"s","reasons":[],"fix_requests":["x"],"follow_ups":[],"checks":"c"}'

check "workflow change, approve/low -> escalate" escalate "$(run a .github/workflows/x.yml "$approve")"
check "workflow change: no auto-merge call" 0 "$(grep -c 'pr merge' "$tmp/gh.log" || true)"
check "workflow change: needs-human label" 1 "$(grep -c 'add-label needs-human' "$tmp/gh.log" || true)"
check "workflow change: reason names the file" 1 "$(jq '[.reasons[] | select(contains(".github/workflows/x.yml"))] | length' "$tmp/work-a/.factory-review/verdict.json")"
check "workflow change, fix -> escalate" escalate "$(run b .github/workflows/x.yml "$fix")"
check "workflow change: no fix dispatch" 0 "$(grep -c 'dispatches' "$tmp/gh.log" || true)"
check "rename out of .github/ -> escalate" escalate "$(
  w="$tmp/work-c"; mkdir -p "$w/.factory-review"
  echo '{"files":[]}' > "$w/.factory-review/pr.json"
  printf 'diff --git a/.github/workflows/old.yml b/docs/old.yml\n' > "$w/.factory-review/diff.patch"
  printf '%s' "$approve" > "$w/.factory-review/verdict.json"
  (cd "$w" && PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" FACTORY_DIR="$root" RUNNER_TEMP="$tmp" GITHUB_SERVER_URL=u GITHUB_REPOSITORY=o/r \
    PR_NUMBER=1 AGENT_PR=true IDENTIFIER="" MAX_FIX_ROUNDS=2 MAX_FOLLOW_UPS=3 FACTORY_APP_TOKEN=x LINEAR_API_KEY="" bash "$root/agents/review/publish.sh" >/dev/null)
  jq -r .decision "$w/.factory-review/verdict.json")"
check "normal change, approve/low -> approve" approve "$(run d src/app.ts "$approve")"
check "normal change: auto-merge enabled" 1 "$(grep -c 'pr merge' "$tmp/gh.log" || true)"
check "lookalike path is not .github/" approve "$(run e docs/.github/x.md "$approve")"

# Preview link and screenshots in the PR comment (no Linear here, so nothing is uploaded).
withprev='{"decision":"approve","risk":"low","summary":"s","reasons":[],"fix_requests":[],"follow_ups":[],"checks":"c","preview_url":"https://pr-1.example.dev","screenshots":[{"path":"/etc/passwd","caption":"x"}]}'
run f src/app.ts "$withprev" >/dev/null
check "PR comment has the preview link" 1 "$(grep -c 'Preview:\*\* https://pr-1.example.dev' "$tmp/comment.md" || true)"
check "no image without Linear upload" 0 "$(grep -c '!\[' "$tmp/comment.md" || true)"
run g src/app.ts "$approve" >/dev/null
check "no preview: says it wasn't available" 1 "$(grep -c 'Preview:\*\* not available' "$tmp/comment.md" || true)"
run h src/app.ts "${withprev/https:\/\/pr-1.example.dev/javascript:alert(1)}" >/dev/null
check "non-https preview URL is dropped" 1 "$(grep -c 'Preview:\*\* not available' "$tmp/comment.md" || true)"
exit $fail
