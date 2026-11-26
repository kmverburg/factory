#!/usr/bin/env bash
# Tests for usage limit retries (agents/lib/usage-limit.sh, agents/retry/retry.sh, the failure reporters and
# agents/scout/run.sh) with fake `gh`, `curl` and `claude` (no network). Usage: bash agents/retry/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$here/../.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/dispatch"
source "$ROOT/agents/lib/usage-limit.sh"

# --- Recognising the limit and its reset time
NOW=$(date -u -d 2026-01-02T12:00:00Z +%s)
usage_limit_hit "Claude AI usage limit reached|1767355200"; check "usage limit message is recognised" 0 $?
usage_limit_hit "API Error: 429 rate_limit_error"; check "rate limit is recognised" 0 $?
rc=0; usage_limit_hit "Error: tests failed in 3 files" || rc=$?; check "other failures are not" 1 "$rc"
check "reset time from the epoch in the message" $((NOW + 600)) "$(usage_limit_reset "Claude AI usage limit reached|$((NOW + 600))" "$NOW")"
check "reset time from 'resets 3pm (zone)'" "$(TZ=Europe/Amsterdam date -d '2026-01-02 15:00' +%s)" "$(usage_limit_reset 'limit reached, resets 3pm (Europe/Amsterdam)' "$NOW")"
check "unknown reset: an hour" $((NOW + 3600)) "$(usage_limit_reset '5-hour limit reached' "$NOW")"
check "reset in the past: an hour" $((NOW + 3600)) "$(usage_limit_reset 'usage limit reached|1700000000' "$NOW")"
check "reset days away: an hour" $((NOW + 3600)) "$(usage_limit_reset 'usage limit reached|1768000000' "$NOW")"

# --- Fakes
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
input=""; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = "--input" ] && input=${args[$((i + 1))]}; done
case "$*" in "api repos/o/backpack/dispatches"*) cp "$input" "$DISPATCH_DIR/$(date +%s%N).json" ;; esac
GH
cat > "$tmp/bin/curl" <<'CU'
#!/usr/bin/env bash
data=""
while [ $# -gt 0 ]; do case "$1" in -d) data=$2; shift ;; esac; shift; done
echo "$data" >> "$CURL_LOG"
case "$data" in
  *"projects(first"*) echo '{"data":{"projects":{"nodes":[{"id":"p1","name":"Backpack","teams":{"nodes":[{"id":"t1","states":{"nodes":[{"id":"s-nh","name":"Needs Human","type":"started"}]},"labels":{"nodes":[]}}]}}]}}}' ;;
  *'"s": "Agent Working"'*) cat "$TICKETS" ;;
  *"state: { name:"*) echo '{"data":{"issues":{"nodes":[]}}}' ;;
  *"comments(first: 100)"*) cat "$COMMENTS" ;;
  *"issue(id"*) echo '{"data":{"issue":{"id":"uuid","identifier":"KV-1","state":{"name":"Agent Working","type":"started"},"labels":{"nodes":[]},"team":{"id":"t1","labels":{"nodes":[]},"states":{"nodes":[{"id":"s-nh","name":"Needs Human","type":"started"}]}}}}}' ;;
  *) echo '{"data":{"ok":true}}' ;;
esac
CU
cat > "$tmp/bin/claude" <<'CL'
#!/usr/bin/env bash
echo "$*" >> "$CLAUDE_LOG"
echo "Claude AI usage limit reached|$(( $(date +%s) + 120 ))"; exit 1
CL
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" CURL_LOG="$tmp/curl.log" CLAUDE_LOG="$tmp/claude.log" DISPATCH_DIR="$tmp/dispatch"
export TICKETS="$tmp/tickets.json" COMMENTS="$tmp/comments.json"
export GH_TOKEN=token-value LINEAR_API_KEY=lin_api_SECRETSECRETSECRET1234 FACTORY_REPO=o/factory RUNNER_TEMP="$tmp" FACTORY_DIR="$ROOT"
cat > "$tmp/wrangler.jsonc" <<'J'
{
  "name": "factory",
  "vars": {
    "PROJECT_REPOS": { "Backpack": "backpack" } } }
J
echo '[]' > "$tmp/apps.json"
export WRANGLER_CONFIG="$tmp/wrangler.jsonc" APPS_FILE="$tmp/apps.json"
reset() {
  rm -rf "$DISPATCH_DIR"; mkdir -p "$DISPATCH_DIR"; : > "$GH_LOG"; : > "$CURL_LOG"; : > "$CLAUDE_LOG"
  echo '{"data":{"issues":{"nodes":[]}}}' > "$TICKETS"; echo '{"data":{"issue":{"comments":{"nodes":[]}}}}' > "$COMMENTS"
}
comments() { jq -nc --argjson c "$1" '{data: {issue: {comments: {nodes: $c}}}}' > "$COMMENTS"; }
sent() { grep -c -- "$1" "$CURL_LOG" || true; }
claude_says() { # $1 = text Claude printed
  jq -nc --arg t "$1" '[{type: "result", is_error: true, result: $t}]' > "$tmp/claude-execution-output.json"
}
payload='{"identifier":"KV-1","title":"T","description":"D","url":"u"}'

# --- Builder: usage limit schedules a retry and does not fail the ticket
reset
claude_says "Claude AI usage limit reached|$((NOW + 600))"
RETRY_NOW=$NOW EVENT_TYPE=factory-build ISSUE_IDENTIFIER=KV-1 FACTORY_PAYLOAD="$payload" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/backpack GITHUB_RUN_ID=9 \
  bash "$ROOT/agents/build/report-failure.sh" >/dev/null 2>&1
check "builder: comment says when it tries again" 1 "$(sent "Claude's usage limit was reached; trying again at 2026-01-02 12:10 UTC")"
check "builder: payload is kept in the marker" "$payload" "$(grep -o 'payload=[A-Za-z0-9+/=]*' "$CURL_LOG" | head -n1 | cut -d= -f2- | base64 -d)"
check "builder: ticket is not moved to Needs Human" 0 "$(sent 'issueUpdate')"
check "builder: no failure comment" 0 "$(sent 'build failed')"

# --- Builder: after 3 retries, Needs Human
reset
fresh=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
comments "$(jq -nc --arg t "$fresh" '[range(3) | {body: "x <!-- factory-retry key=factory-build event=factory-build n=\(. + 1) at=1 payload=e30= -->", createdAt: $t}]')"
RETRY_NOW=$(date +%s) EVENT_TYPE=factory-build ISSUE_IDENTIFIER=KV-1 FACTORY_PAYLOAD="$payload" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/backpack GITHUB_RUN_ID=9 \
  bash "$ROOT/agents/build/report-failure.sh" >/dev/null 2>&1
check "builder: fourth failure moves the ticket to Needs Human" 1 "$(sent '"s": "s-nh"')"
check "builder: explains the retries" 1 "$(sent 'still reached after 3 retries')"
check "builder: no new retry" 0 "$(sent 'factory-retry key')"

# --- Builder: other failures as before
reset
claude_says "Error: the tests failed"
EVENT_TYPE=factory-build ISSUE_IDENTIFIER=KV-1 FACTORY_PAYLOAD="$payload" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/backpack GITHUB_RUN_ID=9 \
  bash "$ROOT/agents/build/report-failure.sh" >/dev/null 2>&1
check "builder: other failure moves to Needs Human" 1 "$(sent '"s": "s-nh"')"
check "builder: other failure has no retry" 0 "$(sent 'factory-retry key')"

# --- Reviewer
reset
claude_says "Claude AI usage limit reached"
RETRY_NOW=$NOW PR_NUMBER=5 FIX_ROUND=1 IDENTIFIER=KV-1 bash "$ROOT/agents/review/report-failure.sh" >/dev/null 2>&1
check "reviewer: retry is scheduled for the same review" 1 "$(sent 'key=factory-review-5-1 event=factory-review n=1')"
reset
claude_says "Error: something else"
PR_NUMBER=5 FIX_ROUND=1 IDENTIFIER=KV-1 bash "$ROOT/agents/review/report-failure.sh" >/dev/null 2>&1
check "reviewer: other failures are left as before" 0 "$(sent 'commentCreate')"

# --- The retry job
b64=$(jq -c . <<<"$payload" | base64 -w0)
echo '{"data":{"issues":{"nodes":[{"id":"u1","identifier":"KV-1","updatedAt":"2026-01-02T10:00:00Z"}]}}}' > "$TICKETS"
req() { # $1 = at, $2 = created
  comments "[{\"body\":\"⏳ x\n<!-- factory-retry key=factory-build event=factory-build n=1 at=$1 payload=$b64 -->\",\"createdAt\":\"$2\"}]"
}
reset; echo '{"data":{"issues":{"nodes":[{"id":"u1","identifier":"KV-1","updatedAt":"2026-01-02T10:00:00Z"}]}}}' > "$TICKETS"
req $((NOW - 60)) 2026-01-02T11:00:00.000Z
RETRY_NOW=$NOW bash "$ROOT/agents/retry/retry.sh" >/dev/null 2>&1
check "retry: due request is dispatched" 1 "$(ls "$DISPATCH_DIR" | wc -l | tr -d ' ')"
check "retry: same event and payload" "factory-build $payload" "$(jq -r '"\(.event_type) \(.client_payload | tojson)"' "$DISPATCH_DIR"/*.json)"
check "retry: marked as started" 1 "$(sent 'factory-retry-started key=factory-build n=1')"

reset; echo '{"data":{"issues":{"nodes":[{"id":"u1","identifier":"KV-1","updatedAt":"2026-01-02T10:00:00Z"}]}}}' > "$TICKETS"
req $((NOW + 600)) 2026-01-02T11:00:00.000Z
RETRY_NOW=$NOW bash "$ROOT/agents/retry/retry.sh" >/dev/null 2>&1
check "retry: not due yet, nothing sent" 0 "$(ls "$DISPATCH_DIR" | wc -l | tr -d ' ')"

reset; echo '{"data":{"issues":{"nodes":[{"id":"u1","identifier":"KV-1","updatedAt":"2026-01-02T10:00:00Z"}]}}}' > "$TICKETS"
comments "[{\"body\":\"x <!-- factory-retry key=factory-build event=factory-build n=1 at=$((NOW - 60)) payload=$b64 -->\",\"createdAt\":\"2026-01-02T11:00:00.000Z\"},{\"body\":\"🔁 <!-- factory-retry-started key=factory-build n=1 -->\",\"createdAt\":\"2026-01-02T11:05:00.000Z\"}]"
RETRY_NOW=$NOW bash "$ROOT/agents/retry/retry.sh" >/dev/null 2>&1
check "retry: started request is not sent twice" 0 "$(ls "$DISPATCH_DIR" | wc -l | tr -d ' ')"

reset; echo '{"data":{"issues":{"nodes":[{"id":"u1","identifier":"KV-1","updatedAt":"2026-01-02T10:00:00Z"}]}}}' > "$TICKETS"
req $((NOW - 60)) 2026-01-02T11:00:00.000Z
RETRY_NOW=$NOW bash "$ROOT/agents/retry/retry.sh" --dry-run >/dev/null 2>&1
check "retry: dry run sends nothing" 0 "$(ls "$DISPATCH_DIR" | wc -l | tr -d ' ')"

# --- The stuck check leaves tickets that wait for a retry alone
reset; echo '{"data":{"issues":{"nodes":[{"id":"u1","identifier":"KV-1","updatedAt":"2026-01-02T10:00:00Z"}]}}}' > "$TICKETS"
req $((NOW + 600)) 2026-01-02T11:00:00.000Z
echo '{"workflow_runs":[{"id":11,"status":"completed","conclusion":"failure","event":"repository_dispatch","head_branch":"main","display_title":"Factory KV-1","html_url":"u","created_at":"2026-01-02T09:00:00Z"}]}' > "$tmp/runs.json"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  "api repos/o/backpack/actions/workflows/factory.yml/runs"*) jq -c '[.workflow_runs[] | {id, status, conclusion, event, branch: .head_branch, title: .display_title, url: .html_url, created: .created_at}]' "$TMP_RUNS" ;;
  "pr list"*) echo '[]' ;;
esac
GH
TMP_RUNS="$tmp/runs.json" STUCK_NOW=$NOW bash "$ROOT/agents/health/stuck.sh" > "$tmp/out.txt" 2>&1 || true
check "stuck check: waits for the retry" 1 "$(grep -c 'waiting for a retry' "$tmp/out.txt")"
check "stuck check: ticket is not touched" 0 "$(sent 'issueUpdate')"

# --- Scout: waits out the limit, tries again at most 3 times, passes other exit codes on
cp "$ROOT/agents/scout/apps.json" "$tmp/apps-scout.json" 2>/dev/null || true
reset
sleeps="$tmp/sleeps"; : > "$sleeps"
cat > "$tmp/sleep.sh" <<'S'
#!/usr/bin/env bash
echo "$1" >> "$SLEEPS"
S
chmod +x "$tmp/sleep.sh"
echo '[]' > "$tmp/no-apps.json"
rc=0; SLEEPS="$sleeps" SCOUT_SLEEP="$tmp/sleep.sh" SCOUT_APPS="$tmp/no-apps.json" bash "$ROOT/agents/scout/run.sh" > "$tmp/scout.txt" 2>&1 || rc=$?
check "scout: runs four times, then fails" "1 4" "$rc $(wc -l < "$CLAUDE_LOG" | tr -d ' ')"
check "scout: waited three times" 3 "$(wc -l < "$sleeps" | tr -d ' ')"
check "scout: says why it failed" 1 "$(grep -c 'still reached after 3 retries' "$tmp/scout.txt")"
rc=0; SCOUT_NO_LLM=1 SCOUT_APPS="$tmp/no-apps.json" bash "$ROOT/agents/scout/run.sh" > /dev/null 2>&1 || rc=$?
check "scout: no limit, no retries" 0 "$rc"

exit $fail
