#!/usr/bin/env bash
# Tests for the rough-note issue writer (fake curl and fake Claude, no network). Usage: bash agents/issue-writer/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
count() { grep -c -- "$1" "$2" || true; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'CU'
#!/usr/bin/env bash
data=""
while [ $# -gt 0 ]; do case "$1" in -d) data=$2; shift ;; esac; shift; done
echo "$data" | jq -c . >> "$CURL_LOG"
case "$data" in
  *"projects(first"*) echo '{"data":{"projects":{"nodes":[{"id":"p-bp","name":"Backpack","teams":{"nodes":[{"id":"t1","states":{"nodes":[{"id":"s-triage","name":"Triage","type":"triage"}]},"labels":{"nodes":[{"id":"o-human","name":"Human","parent":{"name":"Origin"}}]}}]}}]}}}' ;;
  *issueLabelCreate*) echo '{"data":{"issueLabelCreate":{"issueLabel":{"id":"l-new"}}}}' ;;
  *"issue(id"*) echo '{"data":{"issue":{"id":"uuid-7","identifier":"KV-7","url":"https://linear.app/KV-7","labels":{"nodes":[{"id":"o-human","name":"Human","parent":{"name":"Origin"}},{"id":"l-keep","name":"Idea","parent":null}]},"team":{"states":{"nodes":[]}}}}}' ;;
  *) echo '{"data":{"ok":true}}' ;;
esac
CU
cat > "$tmp/bin/claude" <<'CL'
#!/usr/bin/env bash
cat > "$PROMPT_LOG"
printf '%s\n' "$CLAUDE_ANSWER"
CL
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" CURL_LOG="$tmp/curl.log" PROMPT_LOG="$tmp/prompt.txt" LINEAR_API_KEY=lin_api_x CLAUDE_CODE_OAUTH_TOKEN=tok
export IDENTIFIER=KV-7 PROJECTS='["Backpack","Feast"]'
run() { : > "$CURL_LOG"; bash "$here/run.sh" > "$tmp/out.txt" 2>&1 || echo "exit $?" >> "$tmp/out.txt"; }
updates() { grep issueUpdate "$CURL_LOG" | jq -c '.variables.i' ; }
READY='{"status":"ready","project":"Backpack","title":"Show the weight per item","goal":"Koen wants to see how heavy each item is.","acceptance":["Each item shows its weight"],"out_of_scope":["Total weight"],"agent_notes":"","manual":false,"steps":[]}'

ISSUE_TITLE="backpack: weight per item?" ISSUE_DESCRIPTION="" ISSUE_PROJECT="" CLAUDE_ANSWER="$READY" run
check "ready: rewrites the ticket" 1 "$(count issueUpdate "$CURL_LOG")"
check "ready: new title" "Show the weight per item" "$(updates | jq -r .title)"
check "ready: description has the sections" 3 "$(updates | jq -r .description | grep -cE '^## (Goal|Acceptance criteria|Out of scope)')"
check "ready: Koen's words are kept at the bottom" "> backpack: weight per item?" "$(updates | jq -r .description | tail -n 1)"
check "ready: the right project" p-bp "$(updates | jq -r .projectId)"
check "ready: Origin › Human and the existing label are kept" '["l-keep","o-human"]' "$(updates | jq -c '.labelIds | sort')"
check "ready: state unchanged (stays in Triage)" null "$(updates | jq -c '.stateId // null')"
check "ready: never moved to Agent Ready" 0 "$(count 'stateId' "$CURL_LOG")"
check "ready: no assignee for agent work" null "$(updates | jq -c '.assigneeId // null')"
check "ready: comments that it is done" 1 "$(count 'turned your note into a ticket' "$CURL_LOG")"
check "prompt holds the title" 1 "$(grep -c '^Title: backpack: weight per item?' "$PROMPT_LOG")"
check "prompt holds the projects" 1 "$(grep -c 'Backpack, Feast' "$PROMPT_LOG")"
check "Claude never sees the Linear key" 0 "$(count 'lin_api_x' "$PROMPT_LOG")"

echo "$READY" | jq -c '.title = "Wrapped"' > "$tmp/r.json"
ISSUE_TITLE="backpack: weight" ISSUE_DESCRIPTION="" ISSUE_PROJECT="" CLAUDE_ANSWER="$(printf 'Here you go:\n```json\n%s\n```' "$(cat "$tmp/r.json")")" run
check "an answer in a code fence is understood" Wrapped "$(updates | jq -r .title)"

ISSUE_TITLE="weight per item?" ISSUE_DESCRIPTION="" ISSUE_PROJECT="" CLAUDE_ANSWER="$READY" run
check "no app in the note: asks instead of guessing" 0 "$(count issueUpdate "$CURL_LOG")"
check "no app in the note: question is a comment" 1 "$(count 'which app' "$CURL_LOG")"
ISSUE_TITLE="weight per item?" ISSUE_DESCRIPTION="" ISSUE_PROJECT="Backpack" CLAUDE_ANSWER="$READY" run
check "ticket already in a project: no need to name it" 1 "$(count issueUpdate "$CURL_LOG")"

ISSUE_TITLE="backpack: stuff" ISSUE_DESCRIPTION="" ISSUE_PROJECT="" CLAUDE_ANSWER='{"status":"questions","questions":["What stuff?","Which screen?"]}' run
check "unclear: asks the questions as a comment" 1 "$(count 'What stuff?' "$CURL_LOG")"
check "unclear: the ticket is not rewritten or moved" 0 "$(count 'issueUpdate' "$CURL_LOG")"
ISSUE_TITLE="backpack: stuff" ISSUE_DESCRIPTION="" ISSUE_PROJECT="" CLAUDE_ANSWER='not json at all' run
check "no usable answer: asks, never fails" 1 "$(count 'commentCreate' "$CURL_LOG")"
check "no usable answer: exit code 0" 0 "$(count '^exit' "$tmp/out.txt")"
ISSUE_TITLE="nope: stuff" ISSUE_DESCRIPTION="" ISSUE_PROJECT="" CLAUDE_ANSWER="$(jq -c '.project = "Elsewhere"' <<<"$READY")" run
check "unknown project: asks which app" 0 "$(count 'issueUpdate' "$CURL_LOG")"

MANUAL=$(jq -c '.manual = true | .steps = ["Open Cloudflare","Create a token"] | .title = "Create a token"' <<<"$READY")
ISSUE_TITLE="backpack: need a token" ISSUE_DESCRIPTION="" ISSUE_PROJECT="" CLAUDE_ANSWER="$MANUAL" run
check "manual note: factory:manual label is requested" 1 "$(count 'factory:manual' "$CURL_LOG")"
check "manual note: exact steps in the ticket" 1 "$(updates | jq -r .description | grep -c '^1. Open Cloudflare')"

ISSUE_TITLE="Show the weight" ISSUE_DESCRIPTION="Original note from Koen (x)" ISSUE_PROJECT="Backpack" CLAUDE_ANSWER="$READY" run
check "already rewritten: nothing happens" 0 "$(count 'issueUpdate' "$CURL_LOG")"
exit $fail
