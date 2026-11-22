#!/usr/bin/env bash
# Tests for the deploy watch: the comparison (compare.jq) and watch.sh with a fake gh, fake Linear, fake Workers Logs
# and a local git repository (no network). Usage: bash agents/watch/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

NOW=1760000000                       # "now" (seconds)
DEPLOY=$(( NOW - 4000 ))             # deployed 66 minutes ago
DEPLOY_MS=$(( DEPLOY * 1000 ))
S=$(cat "$here/defaults.json")

# Events: $1 = count, $2 = from (ms), $3 = to (ms), $4 = ms value, $5 = status. Prints a JSON array of request events.
reqs() { jq -nc --argjson n "$1" --argjson a "$2" --argjson b "$3" --argjson ms "$4" --argjson st "$5" \
  '[range(0; $n) | {timestamp: ($a + (. * ($b - $a) / $n | floor)), "$metadata": {level: "log"}, source: {event: "request", route: "/x", status: $st, ms: $ms}}]'; }
errs() { jq -nc --argjson n "$1" --argjson a "$2" --argjson b "$3" \
  '[range(0; $n) | {timestamp: ($a + (. * ($b - $a) / $n | floor)), "$metadata": {level: "error"}, source: {message: "boom"}}]'; }
DAY=$(( 24 * 3600 * 1000 ))
END_MS=$(( DEPLOY_MS + 3600000 ))
cmp() { # $1 requests JSON, $2 errors JSON, $3 settings (default S)
  jq -nc -L "$root/agents/scout" --argjson requests "$1" --argjson errors "$2" --argjson deploy_ms "$DEPLOY_MS" --argjson end_ms $END_MS \
    --argjson from_ms $(( DEPLOY_MS - DAY )) --argjson s "${3:-$S}" -f "$here/compare.jq"; }
before_ok=$(reqs 480 $(( DEPLOY_MS - DAY )) "$DEPLOY_MS" 100 200)
before_err=$(errs 4 $(( DEPLOY_MS - DAY )) "$DEPLOY_MS")                      # 4 errors in 480 requests
after_ok=$(reqs 60 "$DEPLOY_MS" $END_MS 105 200)

r=$(cmp "$(jq -c -n --argjson a "$before_ok" --argjson b "$after_ok" '$a + $b')" "$before_err")
check "compare: nothing changed -> ok" ok "$(jq -r .status <<<"$r")"
check "compare: counts the windows apart" "480 60" "$(jq -r '"\(.before.requests) \(.after.requests)"' <<<"$r")"

after_bad=$(errs 12 "$DEPLOY_MS" $END_MS)
r=$(cmp "$(jq -c -n --argjson a "$before_ok" --argjson b "$after_ok" '$a + $b')" "$(jq -c -n --argjson a "$before_err" --argjson b "$after_bad" '$a + $b')")
check "compare: error rate more than doubled -> bad" bad "$(jq -r .status <<<"$r")"
check "compare: the error rate row is the one that breached" "Error rate" "$(jq -r '[.rows[] | select(.breach) | .name] | join(",")' <<<"$r")"
r=$(cmp "$(jq -c -n --argjson a "$before_ok" --argjson b "$after_ok" '$a + $b')" "$(jq -c -n --argjson a "$before_err" --argjson b "$(errs 4 "$DEPLOY_MS" $END_MS)" '$a + $b')")
check "compare: only a handful of errors (below the minimum) -> ok" ok "$(jq -r .status <<<"$r")"

after_5xx=$(reqs 60 "$DEPLOY_MS" $END_MS 105 503)
r=$(cmp "$(jq -c -n --argjson a "$before_ok" --argjson b "$after_5xx" '$a + $b')" "$before_err")
check "compare: 5xx -> bad" "5xx rate" "$(jq -r '[.rows[] | select(.breach) | .name] | first' <<<"$r")"

after_slow=$(reqs 60 "$DEPLOY_MS" $END_MS 400 200)
r=$(cmp "$(jq -c -n --argjson a "$before_ok" --argjson b "$after_slow" '$a + $b')" "$before_err")
check "compare: p95 more than 50% slower -> bad" "Request time (p95)" "$(jq -r '[.rows[] | select(.breach) | .name] | first' <<<"$r")"
after_a_bit=$(reqs 60 "$DEPLOY_MS" $END_MS 140 200)
r=$(cmp "$(jq -c -n --argjson a "$before_ok" --argjson b "$after_a_bit" '$a + $b')" "$before_err")
check "compare: 40% slower is within the threshold -> ok" ok "$(jq -r .status <<<"$r")"
r=$(cmp "$(jq -c -n --argjson a "$before_ok" --argjson b "$after_a_bit" '$a + $b')" "$before_err" "$(jq -c '.p95_pct = 20 | .p95_min_ms = 10' <<<"$S")")
check "compare: thresholds are settings" bad "$(jq -r .status <<<"$r")"

few=$(reqs 10 "$DEPLOY_MS" "$END_MS" 900 503)
r=$(cmp "$(jq -c -n --argjson a "$before_ok" --argjson b "$few" '$a + $b')" "$(errs 10 "$DEPLOY_MS" "$END_MS")")
check "compare: too few requests after the deploy -> not enough traffic, no alarm" low_traffic "$(jq -r .status <<<"$r")"
r=$(cmp "$after_ok" "[]")
check "compare: no history -> not enough traffic" low_traffic "$(jq -r .status <<<"$r")"

# ---- watch.sh ----
mkdir -p "$tmp/bin"
# A local "remote": main has the app commit (a squash merge) after a base commit.
git init -q -b main "$tmp/work"
( cd "$tmp/work" && git config user.email t@t && git config user.name t \
  && echo one > f.txt && git add f.txt && git commit -qm base \
  && echo two > f.txt && git commit -qam "KV-9: Change f (#3)" )
SHA=$(git -C "$tmp/work" rev-parse HEAD)
mkdir -p "$tmp/remote/o"; git clone -q --bare "$tmp/work" "$tmp/remote/o/a.git"
cat > "$tmp/apps.json" <<'J'
[{"project": "App", "repo": "a", "worker": "w", "watch": {"min_requests": 30}}, {"project": "Off", "repo": "b", "worker": "x", "watch": false}]
J
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "api repos/o/a --jq .default_branch") echo main ;;
  "api repos/o/a/commits?"*) printf '%s\tKV-9: Change f (#3)\n' "$SHA" ;;
  "api repos/o/a/commits/$SHA/check-runs"*) jq -n --arg t "$DEPLOYED_AT" '{check_runs: [{name: "Workers Builds: a", conclusion: "success", completed_at: $t}, {name: "ci", conclusion: "success", completed_at: "2000-01-01T00:00:00Z"}]}' ;;
  "pr create"*) echo "https://github.com/o/a/pull/12" ;;
esac
GH
cat > "$tmp/bin/fetch.sh" <<'F'
#!/usr/bin/env bash
case "$2" in *request*) cat "$REQ_FILE" ;; *) cat "$ERR_FILE" ;; esac
F
cat > "$tmp/bin/curl" <<'CU'
#!/usr/bin/env bash
body=$(cat <<<"$*")
echo "$body" >> "$CURL_LOG"
case "$body" in
  *"comments(first"*) cat "$COMMENTS_FILE" ;;
  *projects\(first*) echo '{"data":{"projects":{"nodes":[{"id":"p1","name":"App","teams":{"nodes":[{"id":"t1","states":{"nodes":[{"id":"s-nh","name":"Needs Human","type":"started"}]},"labels":{"nodes":[{"id":"l1","name":"Agent","parent":{"name":"Origin"}},{"id":"l2","name":"Human involved","parent":{"name":"Delivery"}}]}}]}}]}}}' ;;
  *issueCreate*) echo '{"data":{"issueCreate":{"issue":{"identifier":"KV-60","url":"https://linear.app/x/KV-60"}}}}' ;;
  *"issue(id"*) echo '{"data":{"issue":{"id":"u1","identifier":"KV-9","title":"Change f"}}}' ;;
  *) echo '{"data":{"issues":{"nodes":[]}}}' ;;
esac
CU
chmod +x "$tmp/bin/"*
echo '{"data":{"issue":{"comments":{"nodes":[{"body":"hello"}]}}}}' > "$tmp/comments.json"

# $1 = requests array, $2 = errors array. Env: DRY_RUN. Prints the output; the logs are in $tmp.
run() {
  jq -c -n --argjson e "$1" '{result: {events: {events: $e}}}' > "$tmp/req.json"
  jq -c -n --argjson e "$2" '{result: {events: {events: $e}}}' > "$tmp/err.json"
  shift 2
  : > "$tmp/gh.log"; : > "$tmp/curl.log"
  PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" CURL_LOG="$tmp/curl.log" SHA="$SHA" DEPLOYED_AT="$(date -u -d "@$DEPLOY" +%Y-%m-%dT%H:%M:%SZ)" \
    REQ_FILE="$tmp/req.json" ERR_FILE="$tmp/err.json" COMMENTS_FILE="${COMMENTS:-$tmp/comments.json}" \
    WATCH_APPS="$tmp/apps.json" WATCH_NOW="${WNOW:-$NOW}" WATCH_FETCH="$tmp/bin/fetch.sh" WATCH_GIT_BASE="file://$tmp/remote" \
    GITHUB_OWNER=o GH_TOKEN=secrettoken LINEAR_API_KEY=k CLOUDFLARE_ACCOUNT_ID=a CLOUDFLARE_OBSERVABILITY_TOKEN=b \
    bash "$here/watch.sh" "$@" 2>&1
}
all_req() { jq -c -n --argjson a "$before_ok" --argjson b "$1" '$a + $b'; }

out=$(run "$(all_req "$after_ok")" "$before_err")
check "ok: comments on the ticket that all is normal" 1 "$(grep -c 'watched for 60 minutes after the deploy, all normal' "$tmp/curl.log" || true)"
check "ok: no revert PR" 0 "$(grep -c '^pr create' "$tmp/gh.log" || true)"
check "ok: no ticket created" 0 "$(grep -c issueCreate "$tmp/curl.log" || true)"
check "ok: a repo with watching off is skipped" 1 "$(grep -c 'Off: watching is off' <<<"$out" || true)"

out=$(run "$(all_req "$after_ok")" "$before_err" --dry-run)
check "dry run: prints the comparison" 1 "$(grep -c '^Result: ok' <<<"$out" || true)"
check "dry run: touches no ticket" 0 "$(grep -c 'commentCreate\|issueCreate' "$tmp/curl.log" || true)"
check "dry run: needs no Linear at all" 0 "$(wc -l < "$tmp/curl.log" | tr -d ' ')"

COMMENTS="$tmp/done.json"; echo "{\"data\":{\"issue\":{\"comments\":{\"nodes\":[{\"body\":\"✅ Deploy watch (\`${SHA:0:7}\`): fine\"}]}}}}" > "$COMMENTS"
out=$(run "$(all_req "$after_ok")" "$before_err")
check "already judged: nothing more is posted" 0 "$(grep -c 'commentCreate' "$tmp/curl.log" || true)"
unset COMMENTS

out=$(run "$(all_req "$(reqs 10 "$DEPLOY_MS" $END_MS 900 503)")" "$before_err")
check "low traffic: says so on the ticket" 1 "$(grep -c 'not enough traffic to judge' "$tmp/curl.log" || true)"
check "low traffic: no revert PR" 0 "$(grep -c '^pr create' "$tmp/gh.log" || true)"

out=$(WNOW=$(( DEPLOY + 1800 )) run "$(all_req "$after_ok")" "$before_err")
check "the hour isn't over: nothing happens" 0 "$(grep -c 'commentCreate' "$tmp/curl.log" || true)"
out=$(WNOW=$(( DEPLOY + 3600 + 10 * 3600 )) run "$(all_req "$after_ok")" "$before_err")
check "far too late: not judged any more" 0 "$(grep -c 'commentCreate' "$tmp/curl.log" || true)"

out=$(run "$(all_req "$after_ok")" "$(jq -c -n --argjson a "$before_err" --argjson b "$after_bad" '$a + $b')")
check "bad: revert PR opened" 1 "$(grep -c '^pr create .*--head kv-60-revert-kv-9' "$tmp/gh.log" || true)"
check "bad: PR title starts with the new ticket" 1 "$(grep -c -- '--title KV-60: Revert "KV-9: Change f (#3)"' "$tmp/gh.log" || true)"
check "bad: PR is labelled so it is never auto-merged" 1 "$(grep -c -- '--label agent-built --label deploy-revert' "$tmp/gh.log" || true)"
check "bad: ticket is Needs Human, Origin Agent" 1 "$(grep -c 'issueCreate' "$tmp/curl.log" || true)"
check "bad: ticket state" 1 "$(grep -c "stateId.*s-nh\|s-nh.*stateId" "$tmp/curl.log" || true)"
check "bad: ticket title" 1 "$(grep -c 'Revert: Change f' "$tmp/curl.log" || true)"
check "bad: ticket carries the numbers" 2 "$(grep -c 'Error rate' "$tmp/curl.log" || true)"
check "bad: original ticket gets the link" 1 "$(grep -c 'Revert PR: https://github.com/o/a/pull/12, ticket: https://linear.app/x/KV-60' "$tmp/curl.log" || true)"
check "bad: the token never shows in the output" 0 "$(grep -c secrettoken <<<"$out$(cat "$tmp/gh.log")" || true)"
branch_sha=$(git --git-dir="$tmp/remote/o/a.git" rev-parse kv-60-revert-kv-9)
check "bad: the pushed branch reverts the commit" one "$(git --git-dir="$tmp/remote/o/a.git" show "$branch_sha:f.txt")"
git --git-dir="$tmp/remote/o/a.git" branch -q -D kv-60-revert-kv-9

# A revert that conflicts: no PR, the ticket still goes to Koen with the reason.
( cd "$tmp/work" && echo three > f.txt && git commit -qam "KV-10: later" && git push -q "$tmp/remote/o/a.git" main )
out=$(run "$(all_req "$after_ok")" "$(jq -c -n --argjson a "$before_err" --argjson b "$after_bad" '$a + $b')")
check "conflict: no PR" 0 "$(grep -c '^pr create' "$tmp/gh.log" || true)"
check "conflict: the ticket says to revert by hand" 1 "$(grep -c "Revert by hand" "$tmp/curl.log" || true)"

check "base test: scripts parse" 0 "$(bash -n "$here/watch.sh"; echo $?)"
exit $fail
