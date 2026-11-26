#!/usr/bin/env bash
# Tests for update.sh (KV-49) with real local git repos and a fake `gh`. Usage: bash agents/update/test.sh
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
  "pr list") cat "$PRS_JSON" ;;
  "api repos/o/r/dispatches") cp "$4" "$DISPATCH_COPY" ;;
esac
exit 0
GH
# A fake Linear: the ticket's current status comes from $STATE; status changes and comments are logged.
cat > "$tmp/bin/curl" <<'CU'
#!/usr/bin/env bash
body=""; while [ $# -gt 0 ]; do [ "$1" = "-d" ] && { body=$2; break; }; shift; done
q=$(jq -r .query <<<"$body")
case "$q" in
  *issueUpdate*) echo "state $(jq -r .variables.s <<<"$body")" >> "$LINEAR_LOG"; echo '{"data":{}}' ;;
  *commentCreate*) echo "comment $(jq -r .variables.b <<<"$body" | tr '\n' ' ')" >> "$LINEAR_LOG"; echo '{"data":{}}' ;;
  *"issue(id"*) echo '{"data":{"issue":{"id":"u1","identifier":"KV-X","state":{"name":"'"${STATE:-In Review}"'","type":"'"${STATE_TYPE:-started}"'"},"team":{"states":{"nodes":[{"id":"S-Conflicts","name":"Conflicts"},{"id":"S-Needs Human","name":"Needs Human"},{"id":"S-In Review","name":"In Review"}]}}}}}' ;;
esac
CU
chmod +x "$tmp/bin/gh" "$tmp/bin/curl"
G="git -c user.name=t -c user.email=t@t"

# A repo with main, a clean branch (new file) and a conflicting branch (edits a.txt like main does).
git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work"
echo one > a.txt; git add -A; $G commit -qm init; git push -q origin main
git checkout -q -b kv-1-clean; echo new > b.txt; git add -A; $G commit -qm clean; git push -q origin kv-1-clean
git checkout -q main; git checkout -q -b kv-2-conflict; echo mine > a.txt; git add -A; $G commit -qm mine; git push -q origin kv-2-conflict
git checkout -q main; echo theirs > a.txt; git add -A; $G commit -qm "main change"; git push -q origin main
git checkout -q main; echo more > c.txt; git add -A; $G commit -qm "main more"; git push -q origin main
git checkout -q -b kv-3-current main; git push -q origin kv-3-current
git checkout -q -b scratch

pr() { # number branch labels-json [extra jq object]
  jq -n --argjson n "$1" --arg h "$2" --argjson l "$3" \
    '{number: $n, headRefName: $h, baseRefName: "main", isDraft: false, labels: $l, autoMergeRequest: {mergeMethod: "SQUASH"}, comments: [{body: "### 🔧 Builder applied review fixes (round 1)\nx"}]}'
}
built='[{"name":"agent-built"}]'
run() { # PRs JSON array; env PR_NUMBER optional
  : > "$tmp/gh.log"; : > "$tmp/linear.log"; rm -f "$tmp/dispatch.json"
  echo "$1" > "$tmp/prs.json"
  PATH="$tmp/bin:$PATH" LINEAR_API_KEY=lin_test LINEAR_LOG="$tmp/linear.log" STATE="${STATE:-In Review}" GH_LOG="$tmp/gh.log" PRS_JSON="$tmp/prs.json" DISPATCH_COPY="$tmp/dispatch.json" \
    GITHUB_REPOSITORY=o/r BASE_BRANCH=main RUNNER_TEMP="$tmp" PR_NUMBER="${PR_NUMBER:-}" bash "$here/update.sh" >/dev/null 2>&1
}
remote() { git --git-dir="$tmp/origin.git" "$@"; }

run "[$(pr 1 kv-1-clean "$built"),$(pr 2 kv-2-conflict "$built"),$(pr 3 kv-3-current "$built")]"
check "clean PR gets main merged" yes "$(remote merge-base --is-ancestor main kv-1-clean && echo yes || echo no)"
check "clean merge keeps the PR's own file" b.txt "$(remote ls-tree --name-only kv-1-clean | grep b.txt)"
check "clean PR gets a comment" 1 "$(grep -c '^pr comment 1 ' "$tmp/gh.log" || true)"
check "conflicting PR is not pushed to" no "$(remote merge-base --is-ancestor main kv-2-conflict && echo yes || echo no)"
check "conflict: auto-merge cancelled" 1 "$(grep -c '^pr merge 2 --disable-auto' "$tmp/gh.log" || true)"
check "conflict: agent-fixing label" 1 "$(grep -c '^pr edit 2 --add-label agent-fixing' "$tmp/gh.log" || true)"
check "conflict: event type" factory-fix "$(jq -r .event_type "$tmp/dispatch.json")"
check "conflict: flag" true "$(jq -r .client_payload.conflict "$tmp/dispatch.json")"
check "conflict: round stays at the rounds so far" 1 "$(jq -r .client_payload.round "$tmp/dispatch.json")"
check "conflict: identifier from branch" KV-2 "$(jq -r .client_payload.identifier "$tmp/dispatch.json")"
check "conflict: files listed" 1 "$(jq -r .client_payload.feedback "$tmp/dispatch.json" | grep -c -- '- a.txt' || true)"
check "conflict: main commits listed" 1 "$(jq -r .client_payload.feedback "$tmp/dispatch.json" | grep -c 'main change' || true)"
check "up to date PR untouched" 0 "$(grep -c '^pr comment 3 ' "$tmp/gh.log" || true)"
check "the checkout is left clean" "" "$(git status --porcelain)"

run "[$(pr 2 kv-2-conflict '[{"name":"agent-built"},{"name":"agent-fixing"}]')]"
check "fix round running: skipped" "" "$(cat "$tmp/gh.log" | grep -v 'label create\|auth setup\|pr list' || true)"
check "conflict: ticket moved to Conflicts" 1 "$(run "[$(pr 2 kv-2-conflict "$built")]"; grep -c '^state S-Conflicts' "$tmp/linear.log" || true)"
check "conflict: comment lists the files" 1 "$(grep -c '^comment .*Conflicting files: - a.txt' "$tmp/linear.log" || true)"
STATE=Conflicts run "[$(pr 2 kv-2-conflict "$built")]"
check "already in Conflicts: no second comment or move" 0 "$(grep -c . "$tmp/linear.log" || true)"
STATE=conflicts run "[$(pr 2 kv-2-conflict "$built")]"
check "status name matched case-insensitively" 0 "$(grep -c . "$tmp/linear.log" || true)"

# An escalated PR with a conflict is sent to the builder like any other, and keeps needs-human.
nh='[{"name":"agent-built"},{"name":"needs-human"}]'
run "[$(pr 2 kv-2-conflict "$nh")]"
check "needs-human: dispatched" factory-fix "$(jq -r .event_type "$tmp/dispatch.json")"
check "needs-human: conflict flag" true "$(jq -r .client_payload.conflict "$tmp/dispatch.json")"
check "needs-human: round not counted" 1 "$(jq -r .client_payload.round "$tmp/dispatch.json")"
check "needs-human: label kept" 0 "$(grep -c 'remove-label needs-human' "$tmp/gh.log" || true)"
check "needs-human: agent-fixing added" 1 "$(grep -c '^pr edit 2 --add-label agent-fixing' "$tmp/gh.log" || true)"
check "needs-human: auto-merge cancelled" 1 "$(grep -c '^pr merge 2 --disable-auto' "$tmp/gh.log" || true)"
check "needs-human: ticket moved to Conflicts" 1 "$(grep -c '^state S-Conflicts' "$tmp/linear.log" || true)"
run "[$(pr 2 kv-2-conflict '[{"name":"agent-built"},{"name":"needs-human"},{"name":"agent-fixing"}]')]"
check "needs-human with a round running: not sent again" no "$([ -f "$tmp/dispatch.json" ] && echo yes || echo no)"

# Left to Koen: a deploy-watch revert and a PR without a ticket identifier.
rv='[{"name":"agent-built"},{"name":"deploy-revert"}]'
run "[$(pr 2 kv-2-conflict "$rv")]"
check "revert: no dispatch" no "$([ -f "$tmp/dispatch.json" ] && echo yes || echo no)"
check "revert: stays in Conflicts (moved there)" 1 "$(grep -c '^state S-Conflicts' "$tmp/linear.log" || true)"
check "revert: comment says the factory won't resolve it" 1 "$(grep -c "won't resolve" "$tmp/linear.log" || true)"
STATE=Conflicts run "[$(pr 2 kv-2-conflict "$rv")]"
check "revert: already in Conflicts, left alone" 0 "$(grep -c . "$tmp/linear.log" || true)"
git push -q "$tmp/origin.git" kv-2-conflict:refs/heads/nokey 2>/dev/null || true
run "[$(pr 2 nokey-branch "$built")]"
check "no ticket identifier: no dispatch" no "$([ -f "$tmp/dispatch.json" ] && echo yes || echo no)"

# Resolved: the ticket goes back to where it was (Needs Human for escalated PRs, In Review otherwise).
STATE=Conflicts run "[$(pr 3 kv-3-current "$built")]"
check "resolved, normal PR: back to In Review" 1 "$(grep -c '^state S-In Review' "$tmp/linear.log" || true)"
STATE=Conflicts run "[$(pr 3 kv-3-current "$nh")]"
check "resolved, escalated PR: back to Needs Human" 1 "$(grep -c '^state S-Needs Human' "$tmp/linear.log" || true)"
STATE="In Review" run "[$(pr 3 kv-3-current "$built")]"
check "up to date, not in Conflicts: Linear untouched" 0 "$(grep -c . "$tmp/linear.log" || true)"
STATE=Conflicts run "[$(pr 1 kv-1-clean "$built")]"
check "clean merge pushed: back to In Review" 1 "$(grep -c '^state S-In Review' "$tmp/linear.log" || true)"
STATE=Done STATE_TYPE=completed run "[$(pr 2 kv-2-conflict "$built")]"
check "finished ticket: not moved" 0 "$(grep -c '^state ' "$tmp/linear.log" || true)"
PR_NUMBER=2 run "[$(pr 1 kv-1-clean "$built"),$(pr 2 kv-2-conflict "$built")]"
check "PR_NUMBER limits to that PR" 1 "$(jq -r .client_payload.pr_number "$tmp/dispatch.json" | grep -c '^2$' || true)"
exit $fail
