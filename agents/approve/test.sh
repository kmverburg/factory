#!/usr/bin/env bash
# Tests for approve.sh. Fake `gh` and Linear, no network. Usage: bash agents/approve/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/factory/agents/lib"
cp "$here/../lib/linear.sh" "$tmp/factory/agents/lib/linear.sh"
# Fake gh: PR_JSON for pr view, CHECKS_JSON for pr checks, MERGE_FAILS=1 makes the plain merge fail.
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view") cat "$PR_JSON" ;;
  "pr checks") cat "$CHECKS_JSON"; exit 8 ;;
  "pr merge")
    case " $* " in *" --auto "*) [ "$AUTO_FAILS" != 1 ] || { echo "auto nope" >&2; exit 1; } ;;
      *) [ "$MERGE_FAILS" != 1 ] || { echo "not mergeable" >&2; exit 1; } ;; esac ;;
esac
GH
chmod +x "$tmp/bin/gh"
# Fake curl (what linear.sh calls): comment bodies go to $LINEAR_LOG, any other query gets an issue back.
cat > "$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = "-d" ] && data=$2; shift; done
if grep -q commentCreate <<<"$data"; then jq -r '.variables.b' <<<"$data" >> "$LINEAR_LOG"; echo '{"data":{}}'
else echo '{"data":{"issue":{"id":"uuid"}}}'; fi
CURL
chmod +x "$tmp/bin/curl"

# $1 = PR JSON, $2 = checks JSON, $3 = extra env. Prints the last Linear comment; the gh calls are in $tmp/gh.log.
run() {
  printf '%s' "$1" > "$tmp/pr.json"; printf '%s' "$2" > "$tmp/checks.json"; : > "$tmp/gh.log"; : > "$tmp/linear.log"
  # shellcheck disable=SC2086
  env $3 PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" PR_JSON="$tmp/pr.json" CHECKS_JSON="$tmp/checks.json" LINEAR_LOG="$tmp/linear.log" \
    FACTORY_DIR="$tmp/factory" LINEAR_API_KEY=k GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 \
    PR_NUMBER=7 IDENTIFIER=KV-45 CHECK_WAIT_SECONDS=0 CHECK_POLL_SECONDS=0 \
    bash "$here/approve.sh" >/dev/null
  tail -n1 "$tmp/linear.log"
}
built='[{"name":"agent-built"}]'
pr() { printf '{"state":"%s","url":"https://github.com/o/r/pull/7","labels":%s,"headRefName":"%s"}' "${1:-OPEN}" "${2:-$built}" "${3:-kv-45-thing}"; }
merged() { grep -c 'pr merge 7 --squash --delete-branch$' "$tmp/gh.log" || true; }

check "merges when checks pass" "✅ Merged https://github.com/o/r/pull/7 (squash, branch deleted) on your approval." \
  "$(run "$(pr)" '[{"name":"ci","bucket":"pass"},{"name":"lint","bucket":"skipping"}]')"
check "  with a squash merge that deletes the branch" 1 "$(merged)"
check "merges when no required checks exist" "✅ Merged https://github.com/o/r/pull/7 (squash, branch deleted) on your approval." \
  "$(run "$(pr)" 'no required checks reported')"
case "$(run "$(pr)" '[{"name":"ci","bucket":"fail"}]')" in *"required check failed: ci"*) r=ok ;; *) r=no ;; esac
check "a failing check refuses" ok "$r"
check "  and doesn't merge" 0 "$(grep -c 'pr merge' "$tmp/gh.log" || true)"
case "$(run "$(pr)" '[{"name":"ci","bucket":"pending"}]')" in *"still running"*) r=ok ;; *) r=no ;; esac
check "pending checks time out" ok "$r"
check "  without merging" 0 "$(grep -c 'pr merge' "$tmp/gh.log" || true)"
case "$(run "$(pr OPEN '[]')" '[]')" in *"isn't a factory PR"*) r=ok ;; *) r=no ;; esac
check "a PR without agent-built is refused" ok "$r"
check "  and not merged" 0 "$(grep -c 'pr merge' "$tmp/gh.log" || true)"
case "$(run "$(pr OPEN '[{"name":"agent-built"}]' kv-99-other)" '[]')" in *"doesn't belong to KV-45"*) r=ok ;; *) r=no ;; esac
check "a PR of another ticket is refused" ok "$r"
case "$(run "$(pr MERGED)" '[]')" in *"already merged"*) r=ok ;; *) r=no ;; esac
check "a merged PR is reported" ok "$r"
case "$(run "$(pr CLOSED)" '[]')" in *"it is closed"*) r=ok ;; *) r=no ;; esac
check "a closed PR is refused" ok "$r"
case "$(run "$(pr)" '[]' MERGE_FAILS=1)" in *"auto-merge is on"*) r=ok ;; *) r=no ;; esac
check "falls back to auto-merge" ok "$r"
case "$(run "$(pr)" '[]' "MERGE_FAILS=1 AUTO_FAILS=1")" in *"Couldn't merge"*"not mergeable"*) r=ok ;; *) r=no ;; esac
check "reports why a merge failed" ok "$r"
exit $fail
