#!/usr/bin/env bash
# Tests for the hourly stuck check (agents/health/stuck.sh) with a fake `gh` and `curl` (no network).
# Usage: bash agents/health/test-stuck.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
count() { grep -c -- "$1" "$2" || true; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/wrangler.jsonc" <<'J'
{
  "name": "factory",
  "vars": {
    "PROJECT_REPOS": { "Backpack": "backpack" } } }
J
echo '[]' > "$tmp/apps.json"

# gh: runs, PRs and jobs come from files; dispatches and PR edits are recorded.
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
jqexpr=""; input=""; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in --jq) jqexpr=${args[$((i + 1))]} ;; --input) input=${args[$((i + 1))]} ;; esac
done
case "$*" in
  "api repos/o/backpack/actions/workflows/factory.yml/runs"*)
    [ -z "$RUNS_BROKEN" ] || exit 1
    jq -c "$jqexpr" "$RUNS" ;;
  "api repos/o/backpack/actions/runs/"*"/jobs"*) jq -c "$jqexpr" <<<'{"jobs":[{"id":77,"name":"build","conclusion":"failure","steps":[{"name":"Build with Claude","conclusion":"failure"}]}]}' ;;
  *"/annotations"*) echo "The runner lost communication with the server" ;;
  "api repos/o/backpack/dispatches"*) cp "$input" "$DISPATCH_DIR/$(date +%s%N).json" ;;
  "pr list"*) cat "$PRS" ;;
esac
GH
cat > "$tmp/bin/curl" <<'CU'
#!/usr/bin/env bash
data=""
while [ $# -gt 0 ]; do case "$1" in -d) data=$2; shift ;; esac; shift; done
echo "$data" >> "$CURL_LOG"
case "$data" in
  *"projects(first"*) echo '{"data":{"projects":{"nodes":[{"id":"p1","name":"Backpack","teams":{"nodes":[{"id":"t1","states":{"nodes":[{"id":"s-ready","name":"Agent Ready","type":"unstarted"},{"id":"s-nh","name":"Needs Human","type":"started"}]},"labels":{"nodes":[]}}]}}]}}}' ;;
  *"state: { name:"*) cat "$TICKETS" ;;
  *"comments(first: 100)"*) cat "$COMMENTS" ;;
  *"issue(id"*) echo '{"data":{"issue":{"id":"uuid","identifier":"KV-X","state":{"name":"'"${STATE:-In Review}"'","type":"'"${STATE_TYPE:-started}"'"},"labels":{"nodes":[]},"team":{"id":"t1","labels":{"nodes":[]},"states":{"nodes":[{"id":"s-ready","name":"Agent Ready","type":"unstarted"},{"id":"s-nh","name":"Needs Human","type":"started"}]}}}}}' ;;
  *) echo '{"data":{"ok":true}}' ;;
esac
CU
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" CURL_LOG="$tmp/curl.log" DISPATCH_DIR="$tmp/dispatch"
export RUNS="$tmp/runs.json" PRS="$tmp/prs.json" TICKETS="$tmp/tickets.json" COMMENTS="$tmp/comments.json"
export GH_TOKEN=app-token-secret-value LINEAR_API_KEY=lin_api_SECRETSECRETSECRETSECRET1234 FACTORY_REPO=o/factory
export WRANGLER_CONFIG="$tmp/wrangler.jsonc" APPS_FILE="$tmp/apps.json"
STUCK_NOW=$(date -u -d 2026-01-02T12:00:00Z +%s); export STUCK_NOW

run_obj() { # $1 = id, $2 = status, $3 = conclusion, $4 = event, $5 = title, $6 = branch
  jq -nc --argjson id "$1" --arg s "$2" --arg c "$3" --arg e "$4" --arg t "$5" --arg b "$6" \
    '{id: $id, status: $s, conclusion: (if $c == "" then null else $c end), event: $e, head_branch: $b, display_title: $t, html_url: "https://github.com/o/backpack/actions/runs/\($id)", created_at: "2026-01-02T09:00:00Z"}'
}
runs() { jq -sc '{workflow_runs: .}' > "$RUNS"; }
ticket() { echo '{"data":{"issues":{"nodes":[{"id":"u1","identifier":"'"$1"'","updatedAt":"'"${2:-2026-01-02T10:00:00Z}"'"}]}}}' > "$TICKETS"; }
pr() { # $1 = branch, $2 = labels (comma separated), $3 = updatedAt
  jq -nc --arg b "$1" --arg l "$2" --arg u "${3:-2026-01-02T08:00:00Z}" \
    '[{number: 5, headRefName: $b, isDraft: false, updatedAt: $u, comments: [], labels: ($l | split(",") | map(select(. != "") | {name: .}))}]' > "$PRS"
}
reset() {
  rm -rf "$DISPATCH_DIR"; mkdir -p "$DISPATCH_DIR"
  : > "$GH_LOG"; : > "$CURL_LOG"
  echo '{"data":{"issues":{"nodes":[]}}}' > "$TICKETS"; echo '[]' > "$PRS"; echo '{"data":{"issue":{"comments":{"nodes":[]}}}}' > "$COMMENTS"
  : | runs
}
comments() { jq -nc --argjson c "$1" '{data: {issue: {comments: {nodes: $c}}}}' > "$COMMENTS"; }
run() { bash "$here/stuck.sh" "$@" > "$tmp/out.txt" 2>&1 || echo "exit $?" >> "$tmp/out.txt"; }
dispatches() { find "$DISPATCH_DIR" -name '*.json' | wc -l | tr -d ' '; }
dtype() { jq -r .event_type "$(find "$DISPATCH_DIR" -name '*.json' | head -n1)"; }
moved_to() { grep -c "\"s\": \"$1\"" "$CURL_LOG" || true; }
sent() { grep -c "$1" "$CURL_LOG" || true; }

# --- Tickets ---
reset; ticket KV-1
{ run_obj 11 completed failure repository_dispatch "Factory KV-1" main; } | runs
run
check "stuck once: goes back to Agent Ready" 1 "$(moved_to s-ready)"
check "stuck once: comment names the run and conclusion" 1 "$(sent 'The last run stopped without reporting back (\[run 11, failure\](https://github.com/o/backpack/actions/runs/11)); starting it again')"
check "stuck once: remembered for the next check" 1 "$(sent 'stuck-check:ticket prev=https://github.com/o/backpack/actions/runs/11')"
check "stuck once: no dispatch (the relay starts the build)" 0 "$(dispatches)"
check "stuck once: exit code 0" 0 "$(count '^exit' "$tmp/out.txt")"

reset; ticket KV-1
{ run_obj 12 completed cancelled repository_dispatch "Factory KV-1" main; } | runs
comments '[{"body":"🏭 starting it again.\n<!-- stuck-check:ticket prev=https://github.com/o/backpack/actions/runs/11 -->","createdAt":"2026-01-02T05:00:00Z"}]'
run
check "stuck twice: goes to Needs Human" 1 "$(moved_to s-nh)"
check "stuck twice: not started again" 0 "$(moved_to s-ready)"
check "stuck twice: comment links both runs" 2 "$(sent 'actions/runs/1[12]' | sed 's/^1$/1/;s/^0$/0/' | awk '{print ($1>=1) ? 2 : 0}')"
check "stuck twice: comment says why" 1 "$(sent 'The runner lost communication')"

reset; ticket KV-1
{ run_obj 12 completed failure repository_dispatch "Factory KV-1" main; } | runs
comments '[{"body":"x\n<!-- stuck-check:ticket prev=https://github.com/o/backpack/actions/runs/11 -->","createdAt":"2025-12-30T05:00:00Z"}]'
run
check "stuck again after more than 24 hours: retried, not escalated" 1 "$(moved_to s-ready)"

reset; ticket KV-1
{ run_obj 13 in_progress "" repository_dispatch "Factory KV-1" main; } | runs
run
check "still running: left alone" 0 "$(sent 'issueUpdate\|commentCreate')"
check "still running: says so" 1 "$(count 'KV-1: a run is in progress' "$tmp/out.txt")"

reset; ticket KV-1
{ run_obj 14 queued "" repository_dispatch "Factory KV-1" main; } | runs
run
check "queued: left alone" 0 "$(sent 'issueUpdate\|commentCreate')"

reset; ticket KV-1
{ run_obj 15 in_progress "" repository_dispatch "Factory" main; } | runs
run
check "a dispatch run without a ticket name in progress: nothing in the repo counts as stuck" 0 "$(sent 'issueUpdate\|commentCreate')"

reset; ticket KV-1 2026-01-02T11:30:00Z
run
check "changed less than an hour ago: left alone" 0 "$(sent 'issueUpdate\|commentCreate')"

reset; ticket KV-1
RUNS_BROKEN=1 run
check "runs unreadable: nothing is judged" 0 "$(sent 'issueUpdate\|commentCreate')"

reset; ticket KV-1
{ run_obj 16 completed failure repository_dispatch "Factory KV-1" main; } | runs
pr kv-1-thing agent-built
run
check "stuck with an open PR: a fix round is sent" factory-fix "$(dtype)"
check "stuck with an open PR: for that PR and ticket" "5 KV-1" "$(jq -r '"\(.client_payload.pr_number) \(.client_payload.identifier)"' "$(find "$DISPATCH_DIR" -name '*.json' | head -n1)")"
check "stuck with an open PR: not a fresh build" 0 "$(moved_to s-ready)"
check "stuck with an open PR: PR is marked as being fixed" 1 "$(count 'pr edit 5 .*--add-label agent-fixing' "$GH_LOG")"
check "stuck with an open PR: comment on the ticket" 1 "$(sent 'as a fix round on PR #5')"

reset; ticket KV-1
{ run_obj 16 completed failure repository_dispatch "Factory KV-1" main; } | runs
pr kv-1-thing agent-built
comments '[{"body":"x\n<!-- stuck-check:ticket prev=https://github.com/o/backpack/actions/runs/11 -->","createdAt":"2026-01-02T05:00:00Z"}]'
run
check "stuck twice with an open PR: Needs Human, no second fix round" "1 0" "$(moved_to s-nh) $(dispatches)"

reset; ticket KV-1
{ run_obj 11 completed failure repository_dispatch "Factory KV-1" main; } | runs
run --dry-run
check "dry run: lists the stuck ticket" 1 "$(count 'KV-1: stuck' "$tmp/out.txt")"
check "dry run: changes nothing" 0 "$(sent 'issueUpdate\|commentCreate')"
check "dry run: sends nothing" 0 "$(dispatches)"

# --- PRs without a verdict ---
reset
{ run_obj 21 completed failure repository_dispatch "Factory KV-2" main; } | runs
pr kv-2-thing agent-built
run
check "no verdict: the review is started again" factory-review "$(dtype)"
check "no verdict: for that PR" "5 KV-2" "$(jq -r '"\(.client_payload.pr_number) \(.client_payload.identifier)"' "$(find "$DISPATCH_DIR" -name '*.json' | head -n1)")"
check "no verdict: comment on the ticket" 1 "$(sent 'no review is running (last run: \[run 21, failure\]')"
check "no verdict: remembered for the next check" 1 "$(sent 'stuck-check:review prev=https://github.com/o/backpack/actions/runs/21')"
check "no verdict: the ticket is not moved" 0 "$(sent 'issueUpdate')"

for label in agent-approved needs-human agent-fixing; do
  reset; pr kv-2-thing "agent-built,$label"
  run
  check "verdict label $label: left alone" 0 "$(dispatches)"
done
reset; pr kv-2-thing agent-built 2026-01-02T11:30:00Z
run
check "no verdict for less than an hour: left alone" 0 "$(dispatches)"
reset; pr kv-2-thing agent-built
{ run_obj 22 in_progress "" pull_request "Add thing" kv-2-thing; } | runs
run
check "review running: left alone" 0 "$(dispatches)"
reset; pr kv-2-thing agent-built
{ run_obj 23 queued "" repository_dispatch "Factory KV-2" main; } | runs
run
check "review queued: left alone" 0 "$(dispatches)"
reset; pr kv-2-thing agent-built
STATE=Done STATE_TYPE=completed run
check "ticket already done: left alone" 0 "$(dispatches)"

reset; pr kv-2-thing agent-built
{ run_obj 24 completed failure repository_dispatch "Factory KV-2" main; } | runs
comments '[{"body":"x\n<!-- stuck-check:review prev=https://github.com/o/backpack/actions/runs/21 -->","createdAt":"2026-01-02T10:00:00Z"}]'
run
check "still no verdict after the second review: Needs Human" 1 "$(moved_to s-nh)"
check "still no verdict after the second review: both review runs linked" 1 "$(sent 'first\](https://github.com/o/backpack/actions/runs/21).*run 24')"
check "still no verdict after the second review: no third review" 0 "$(dispatches)"
check "still no verdict after the second review: PR labelled needs-human" 1 "$(count 'pr edit 5 .*--add-label needs-human' "$GH_LOG")"

reset; pr kv-2-thing agent-built
comments '[{"body":"x\n<!-- stuck-check:review prev=https://github.com/o/backpack/actions/runs/21 -->","createdAt":"2026-01-02T11:30:00Z"}]'
run
check "second review started less than an hour ago: waits" "0 0" "$(moved_to s-nh) $(dispatches)"

reset; pr kv-2-thing agent-built
run --dry-run
check "dry run: a PR without a verdict is listed, nothing is sent" "1 0" "$(count 'PR #5 (KV-2): no verdict' "$tmp/out.txt") $(dispatches)"

# A ticket in Agent Working with an open PR is handled once (as a fix round), not also as a PR without a verdict.
reset; ticket KV-3
{ run_obj 31 completed failure repository_dispatch "Factory KV-3" main; } | runs
pr kv-3-thing agent-built
run
check "ticket and PR: one dispatch only" 1 "$(dispatches)"

# Nothing is printed that looks like a secret.
check "no token in the output or the requests" 0 "$({ grep -c "$GH_TOKEN\|$LINEAR_API_KEY" "$tmp/out.txt" "$CURL_LOG" "$GH_LOG" || true; } | awk -F: '{s += $2} END {print s + 0}')"

exit "$fail"
