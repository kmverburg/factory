#!/usr/bin/env bash
# Tests for the start of every fix round (agents/build/prepare.sh, KV-80): the base branch is merged into the branch first.
# Real local git repos and a fake `gh`, no network. Usage: bash agents/build/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  "pr view"*"headRefName"*) jq -nc --arg h "$HEAD_BRANCH" '{headRefName: $h, baseRefName: "main", state: "OPEN", body: "ticket body"}' ;;
  *) echo '[]' ;;
esac
GH
chmod +x "$tmp/bin/gh"
G="git -c user.name=t -c user.email=t@t"

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/seed" 2>/dev/null
cd "$tmp/seed"
printf 'one\n' > a.txt; printf 'x\n' > list.txt; git add -A; $G commit -qm init; git push -q origin main
git checkout -q -b kv-1-conflict; printf 'mine\n' > a.txt; git add -A; $G commit -qm mine; git push -q origin kv-1-conflict
git checkout -q main; git checkout -q -b kv-2-clean; printf 'new\n' > b.txt; git add -A; $G commit -qm clean; git push -q origin kv-2-clean
git checkout -q main; git checkout -q -b kv-3-current; printf 'cur\n' > c.txt; git add -A; $G commit -qm cur; git push -q origin kv-3-current
git checkout -q main; printf 'theirs\n' > a.txt; git add -A; $G commit -qm "main edits a.txt"; git push -q origin main
git checkout -q kv-3-current; $G merge -q --no-edit main >/dev/null; git push -q origin kv-3-current

# $1 = name, $2 = branch, $3.. = env overrides. Runs prepare.sh in a fresh clone; the clone is $tmp/w-<name>.
prepare() {
  local name=$1 branch=$2; shift 2
  rm -rf "$tmp/w-$name"; git clone -q "$tmp/origin.git" "$tmp/w-$name" 2>/dev/null
  : > "$tmp/$name.out"
  (cd "$tmp/w-$name" && env PATH="$tmp/bin:$PATH" HEAD_BRANCH="$branch" FACTORY_DIR="$root" GITHUB_OUTPUT="$tmp/$name.out" \
    LINEAR_API_KEY= EVENT_TYPE=factory-fix ISSUE_IDENTIFIER=KV-9 PR_NUMBER=5 FIX_ROUND=1 FIX_FEEDBACK="Please change x." \
    FIX_CONFLICT= FIX_REQUESTED= "$@" bash "$here/prepare.sh" >/dev/null 2>&1)
}
w() { echo "$tmp/w-$1"; }
fb() { cat "$tmp/w-$1/.factory/review-feedback.md"; }

# A reviewer fix round (no conflict flag) on a branch that conflicts with main: markers and file list anyway.
prepare rc kv-1-conflict
check "review round, conflicting main: merge started" yes "$([ -f "$(w rc)/.git/MERGE_HEAD" ] && echo yes || echo no)"
check "review round, conflicting main: markers present" 1 "$(grep -c '^<<<<<<< ' "$(w rc)/a.txt" || true)"
check "review round, conflicting main: files listed" 1 "$(fb rc | grep -c -- '- a.txt' || true)"
check "review round, conflicting main: says CONFLICTS" 1 "$(fb rc | grep -c 'it CONFLICTS' || true)"
check "review round, conflicting main: reviewer's feedback kept" 1 "$(fb rc | grep -c 'Please change x.' || true)"
check "review round, conflicting main: main's commits listed" 1 "$(fb rc | grep -c 'main edits a.txt' || true)"
check "review round, conflicting main: step output" conflict "$(sed -n 's/^merge_state=//p' "$tmp/rc.out")"

# A comment from Koen ("Resolve merge conflict") gets the same: git decides, not the builder.
prepare rk kv-1-conflict FIX_REQUESTED=true FIX_FEEDBACK="Resolve merge conflict"
check "Koen's comment: markers present" 1 "$(grep -c '^<<<<<<< ' "$(w rk)/a.txt" || true)"
check "Koen's comment: his words kept" 1 "$(fb rk | grep -c 'Resolve merge conflict' || true)"

# The update job's round.
prepare ru kv-1-conflict FIX_CONFLICT=true
check "conflict round: markers present" 1 "$(grep -c '^<<<<<<< ' "$(w ru)/a.txt" || true)"
check "conflict round: not committed" yes "$([ -f "$(w ru)/.git/MERGE_HEAD" ] && echo yes || echo no)"

# A clean merge: merged result in the working tree, no markers, and the instructions say so.
prepare rm kv-2-clean
check "clean merge: merge started" yes "$([ -f "$(w rm)/.git/MERGE_HEAD" ] && echo yes || echo no)"
check "clean merge: main's change is there" theirs "$(cat "$(w rm)/a.txt")"
check "clean merge: no markers" 0 "$(grep -c '^<<<<<<< ' "$(w rm)/a.txt" || true)"
check "clean merge: instructions say clean" 1 "$(fb rm | grep -c 'it is CLEAN' || true)"
check "clean merge: step output" clean "$(sed -n 's/^merge_state=//p' "$tmp/rm.out")"
check "clean merge: base branch output" main "$(sed -n 's/^base=//p' "$tmp/rm.out")"

# Already up to date: nothing to merge.
prepare rn kv-3-current
check "up to date: no merge" no "$([ -f "$(w rn)/.git/MERGE_HEAD" ] && echo yes || echo no)"
check "up to date: instructions say so" 1 "$(fb rn | grep -c 'nothing to merge' || true)"
exit $fail
