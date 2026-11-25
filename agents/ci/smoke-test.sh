#!/usr/bin/env bash
# Smoke tests for the two publish scripts, run on every PR (the "Agent scripts" workflow): agents/review/publish.sh
# and agents/build/publish.sh run with sample inputs, with `gh`, `git push` and the Linear helpers stubbed. They check
# the exit code and what would be posted, so a broken filter or a typo in these scripts fails here and not in a live review.
# New scripts that talk to GitHub or Linear need a smoke test like these. Usage: bash agents/ci/smoke-test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
count() { grep -cF -- "$1" "$2" || true; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# A copy of agents/ with the real publish scripts but stubbed Linear helpers (they only record their calls).
fd="$tmp/factory"; mkdir -p "$fd/agents/lib" "$fd/agents/review" "$fd/agents/build" "$tmp/bin"
cp "$root"/agents/review/{publish,workflows}.sh "$fd/agents/review/"
cp "$root/agents/build/publish.sh" "$fd/agents/build/"
cat > "$fd/agents/lib/linear.sh" <<'STUB'
for f in linear_comment linear_set_state linear_set_group_label linear_upload_image; do
  eval "$f() { echo \"$f \$*\" >> \"\$LINEAR_LOG\"; }"
done
STUB
cat > "$fd/agents/lib/issue-writer.sh" <<'STUB'
# Records the call and prints one line per ticket it was given, like the real helper.
linear_create_follow_ups() { echo "linear_create_follow_ups $1" >> "$LINEAR_LOG"; jq -r '.[] | "- KV-9 " + .title' "$2"; }
linear_create_manual_tickets() { echo "linear_create_manual_tickets $1 $3" >> "$LINEAR_LOG"; jq -r '.[] | "- KV-8 " + .title' "$2"; }
STUB
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in "pr view") echo 7 ;; esac
GH
# git is real, except that nothing is pushed and the remote isn't touched.
real_git=$(command -v git)
cat > "$tmp/bin/git" <<GIT
#!/usr/bin/env bash
case "\$*" in "remote set-url"*|push*) echo "git \$*" >> "\$GH_LOG" ;; *) exec "$real_git" "\$@" ;; esac
GIT
chmod +x "$tmp/bin/gh" "$tmp/bin/git"

# ---- review/publish.sh ----------------------------------------------------------------------------------------
# $1 = name, $2 = verdict JSON, then optional VAR=value overrides. Prints the exit code; logs are in $tmp/$1.*
review() {
  local name=$1 verdict=$2; shift 2
  local w="$tmp/w-$name"; mkdir -p "$w/.factory-review"
  printf '{"files":[{"path":"src/app.ts"}]}' > "$w/.factory-review/pr.json"
  printf 'diff --git a/src/app.ts b/src/app.ts\n' > "$w/.factory-review/diff.patch"
  printf '%s' "$verdict" > "$w/.factory-review/verdict.json"
  : > "$tmp/$name.gh"; : > "$tmp/$name.linear"
  local rc=0
  (cd "$w" && env PATH="$tmp/bin:$PATH" GH_LOG="$tmp/$name.gh" LINEAR_LOG="$tmp/$name.linear" FACTORY_DIR="$fd" \
    RUNNER_TEMP="$w" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r PR_NUMBER=1 AGENT_PR=true \
    IDENTIFIER=KV-1 IS_FOLLOW_UP=false MAX_FIX_ROUNDS=2 MAX_FOLLOW_UPS=3 FIX_ROUND=0 FACTORY_APP_TOKEN=x "$@" \
    bash "$fd/agents/review/publish.sh" >"$tmp/$name.out" 2>&1) || rc=$?
  echo "$rc"
}
fu='[{"title":"First","goal":"g1"},{"title":"Second","description":"d2"},{"title":"No goal"},{"goal":"No title"},{"title":"Fourth","goal":"g4"},{"title":"Fifth","goal":"g5"}]'
approve='{"decision":"approve","risk":"low","summary":"All good.","reasons":[],"fix_requests":[],"follow_ups":'$fu',"checks":"c"}'
fix='{"decision":"fix","risk":"low","summary":"s","reasons":[],"fix_requests":["change x","change y"],"follow_ups":[],"checks":"c"}'
escalate='{"decision":"escalate","risk":"high","summary":"s","reasons":["too risky"],"fix_requests":[],"follow_ups":[],"manual_tasks":[{"title":"Add secret","steps":["do it"]},{"title":"No steps","steps":[]}],"checks":"c"}'

check "review approve: exit code" 0 "$(review ra "$approve")"
check "review approve: auto-merge enabled" 1 "$(count 'pr merge 1 --auto' "$tmp/ra.gh")"
check "review approve: agent-approved label" 1 "$(count 'add-label agent-approved' "$tmp/ra.gh")"
check "review approve: Linear moved to In Review" 1 "$(count 'linear_set_state KV-1 In Review' "$tmp/ra.linear")"
check "review approve: only valid follow-ups, capped at 3" 3 "$(count '- KV-9' "$tmp/w-ra/comment.md")"
check "review approve: follow-up without goal is dropped" 0 "$(count 'No goal' "$tmp/w-ra/comment.md")"
check "review approve: PR comment says approved" 1 "$(count 'Factory review: approved' "$tmp/w-ra/comment.md")"
check "review approve, not an agent PR: no auto-merge" 0 "$(review rb "$approve" AGENT_PR=false >/dev/null; count 'pr merge' "$tmp/rb.gh")"
check "review approve, follow-up PR: no follow-ups" 0 "$(review rc "$approve" IS_FOLLOW_UP=true >/dev/null; count 'linear_create_follow_ups' "$tmp/rc.linear")"
check "review approve, no ticket: exit code" 0 "$(review rd "$approve" IDENTIFIER=)"
check "review fix: exit code" 0 "$(review rf "$fix")"
check "review fix: sends factory-fix dispatch" 1 "$(count 'repos/o/r/dispatches' "$tmp/rf.gh")"
check "review fix: dispatch has both requests" 1 "$(jq '.client_payload.feedback | contains("change x") and contains("change y")' "$tmp/w-rf/dispatch.json" | grep -c true || true)"
check "review fix: agent-fixing label" 1 "$(count 'add-label agent-fixing' "$tmp/rf.gh")"
check "review fix, last round: escalates, no dispatch" 0 "$(review rg "$fix" FIX_ROUND=2 >/dev/null; count 'dispatches' "$tmp/rg.gh")"
check "review fix, last round: needs-human" 1 "$(count 'add-label needs-human' "$tmp/rg.gh")"
check "review escalate: exit code" 0 "$(review re "$escalate")"
check "review escalate: needs-human label" 1 "$(count 'add-label needs-human' "$tmp/re.gh")"
check "review escalate: no auto-merge" 0 "$(count 'pr merge' "$tmp/re.gh")"
check "review escalate: manual ticket blocks the original" 1 "$(count 'linear_create_manual_tickets KV-1 blocking' "$tmp/re.linear")"
check "review escalate: only the manual task with steps" 1 "$(count '- KV-8' "$tmp/w-re/comment.md")"
check "review escalate: Linear moved to Blocked" 1 "$(count 'linear_set_state KV-1 Blocked' "$tmp/re.linear")"
check "review no verdict: escalates" 1 "$(review rh 'not json' >/dev/null; count 'add-label needs-human' "$tmp/rh.gh")"

# ---- build/publish.sh -----------------------------------------------------------------------------------------
# $1 = name, $2 = setup commands run in the repo (before the script), then VAR=value overrides.
build() {
  local name=$1 setup=$2; shift 2
  local w="$tmp/b-$name"; rm -rf "$w"; mkdir -p "$w"
  (cd "$w" && git init -q -b main && git config user.email t@t && git config user.name t && echo base > f.txt \
    && git add -A && git commit -qm base && mkdir -p .factory && echo '- sample' > .factory/PR_BODY.md) >/dev/null
  # The agent's work comes after the base commit (BASE_SHA), as in the real workflow.
  local base; base=$(git -C "$w" rev-parse HEAD)
  (cd "$w" && eval "$setup") >/dev/null
  : > "$tmp/$name.gh"; : > "$tmp/$name.linear"; : > "$tmp/$name.out"; : > "$tmp/$name.output"
  local rc=0; mkdir -p "$tmp/rt-$name"
  (cd "$w" && env PATH="$tmp/bin:$PATH" GH_LOG="$tmp/$name.gh" LINEAR_LOG="$tmp/$name.linear" FACTORY_DIR="$fd" \
    RUNNER_TEMP="$tmp/rt-$name" GITHUB_OUTPUT="$tmp/$name.output" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r \
    GITHUB_RUN_ID=5 GITHUB_REF_NAME=main BRANCH=factory/kv-1 BASE_SHA="$base" ISSUE_IDENTIFIER=KV-1 ISSUE_TITLE=Title \
    ISSUE_URL=https://linear.app/x/KV-1 EVENT_TYPE=factory-build FIX_ROUND= FIX_CONFLICT= FIX_REQUESTED= PR_NUMBER= "$@" \
    bash "$fd/agents/build/publish.sh" >"$tmp/$name.out" 2>&1) || rc=$?
  echo "$rc"
}
change='echo new >> f.txt'
check "build new PR: exit code" 0 "$(build ba "$change")"
check "build new PR: opens a PR" 1 "$(count 'pr create --base main --head factory/kv-1' "$tmp/ba.gh")"
check "build new PR: pushes the branch" 1 "$(count 'git push --force -u origin factory/kv-1' "$tmp/ba.gh")"
check "build new PR: reports the PR number" 1 "$(count 'pr_number=7' "$tmp/ba.output")"
check "build new PR: Linear comment links it" 1 "$(count 'pull/7' "$tmp/ba.linear")"
check "build questions: exit code" 0 "$(build bq 'echo "Which colour?" > .factory/QUESTIONS.md')"
check "build questions: Linear moved to Needs Human" 1 "$(count 'linear_set_state KV-1 Needs Human' "$tmp/bq.linear")"
check "build questions: nothing pushed" 0 "$(count 'git push' "$tmp/bq.gh")"
check "build manual tasks: exit code" 0 "$(build bm 'echo "[{\"title\":\"Add secret\",\"why\":\"w\",\"steps\":[\"s\"]}]" > .factory/MANUAL_TASKS.json')"
check "build manual tasks: blocking ticket created" 1 "$(count 'linear_create_manual_tickets KV-1 blocking' "$tmp/bm.linear")"
check "build no changes: Needs Human" 1 "$(build bn 'true' >/dev/null; count 'linear_set_state KV-1 Needs Human' "$tmp/bn.linear")"
check "build fix round: exit code" 0 "$(build bf "$change" EVENT_TYPE=factory-fix PR_NUMBER=3 FIX_ROUND=1)"
check "build fix round: comments on the PR" 1 "$(count 'pr comment 3 --body-file' "$tmp/bf.gh")"
check "build fix round: pushes without force" 1 "$(count 'git push origin factory/kv-1' "$tmp/bf.gh")"
check "build conflict markers: nothing pushed" 0 "$(build bc 'printf "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n" > f.txt; git add f.txt' EVENT_TYPE=factory-fix PR_NUMBER=3 FIX_CONFLICT=true >/dev/null; count 'git push' "$tmp/bc.gh")"
exit $fail
