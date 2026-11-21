#!/usr/bin/env bash
# Tests for the deploy watch (agents/deploywatch/) with recorded fixture data: the comparison and a dry run with a fake gh. No network.
# Usage: bash agents/deploywatch/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
fx="$here/fixtures"
cfg=$(cat "$here/defaults.json")
compare() { # $1 = after name prefix, $2 = config JSON
  jq -n -L "$root/agents/scout" -L "$here" --argjson cfg "${2:-$cfg}" \
    --argjson before_requests "$(cat "$fx/before-requests.json")" --argjson before_errors "$(cat "$fx/before-errors.json")" \
    --argjson after_requests "$(cat "$fx/$1-requests.json")" --argjson after_errors "$(cat "$fx/$1-errors.json")" -f "$here/compare.jq"
}
r=$(compare after-ok)
check "compare: a normal hour is ok" ok "$(jq -r .status <<<"$r")"
check "compare: counts requests" 60 "$(jq .after.requests <<<"$r")"
r=$(compare after-bad)
check "compare: worse hour is an alert" alert "$(jq -r .status <<<"$r")"
check "compare: names error rate, 5xx rate and p95" 3 "$(jq '.reasons | length' <<<"$r")"
check "compare: p95 numbers" "true" "$(jq '.after.p95_ms > 300 and .before.p95_ms < 120' <<<"$r")"
r=$(compare after-few)
check "compare: too few requests is not judged" low_traffic "$(jq -r .status <<<"$r")"
check "compare: says not enough traffic" 1 "$(jq '.reasons[0] | contains("not enough traffic to judge") | if . then 1 else 0 end' <<<"$r")"
r=$(compare after-bad "$(jq -c '. + {min_errors: 100, min_5xx: 100, p95_slower_pct: 1000}' <<<"$cfg")")
check "compare: per-app thresholds apply" ok "$(jq -r .status <<<"$r")"
r=$(compare after-bad "$(jq -c '. + {min_requests: 500}' <<<"$cfg")")
check "compare: min_requests is a setting" low_traffic "$(jq -r .status <<<"$r")"

# Dry run: fake gh (deploy runs, commit message) and a fake fetch that picks fixtures by time and filter.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "run list"*) cat "$RUNS" ;;
  "api repos/o/app/commits/"*) echo "KV-9: Add a thing" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
cat > "$tmp/fetch.sh" <<'F'
#!/usr/bin/env bash
# Window before the deploy ends at the deploy time (T); the watched window starts at T.
kind=requests; case "$2" in *error*) kind=errors ;; esac
if [ "$SCOUT_TO_MS" = "$DEPLOY_MS" ]; then w=before; else w=$AFTER; fi
cat "$FX/$w-$kind.json" | jq '{result: {events: {events: .}}}'
F
cat > "$tmp/apps.json" <<'A'
[{"project": "App", "repo": "app", "worker": "app", "watch": {"min_requests": 50}},
 {"project": "Off", "repo": "off", "worker": "off", "watch": {"enabled": false}}]
A
deploy="2025-10-09T08:00:00Z"
deploy_ms=$(( $(date -d "$deploy" +%s) * 1000 ))
echo "[{\"headSha\":\"abcdef1234567890\",\"updatedAt\":\"$deploy\",\"url\":\"https://github.com/o/app/actions/runs/1\"}]" > "$tmp/runs.json"
export GH_LOG="$tmp/gh.log" RUNS="$tmp/runs.json" FX="$fx" DEPLOY_MS="$deploy_ms" GITHUB_OWNER=o
run_watch() { # $1 = after fixture prefix, $2 = now offset in minutes
  PATH="$tmp/bin:$PATH" AFTER=$1 WATCH_NOW_MS=$(( deploy_ms + $2 * 60000 )) WATCH_APPS="$tmp/apps.json" WATCH_FETCH="$tmp/fetch.sh" \
    env -u LINEAR_API_KEY -u GH_TOKEN bash "$here/watch.sh" --dry-run
}
out=$(run_watch after-bad 70)
check "dry run: alert is reported with the original ticket" 1 "$(grep -c 'would open a revert PR for abcdef1.*comment on KV-9' <<<"$out")"
check "dry run: shows the numbers" 1 "$(grep -c 'p95 request time' <<<"$out")"
check "dry run: lists deploy runs of the app's workflow" 1 "$(grep -c -- 'run list -R o/app --workflow deploy.yml --branch main' "$GH_LOG")"
check "dry run: app with watch off is skipped" 1 "$(grep -c '== Off: deploy watch is off' <<<"$out" || true)"
check "dry run: opens nothing" 0 "$(grep -c 'pr create\|git/refs' "$GH_LOG" || true)"
out=$(run_watch after-ok 70)
check "dry run: ok hour" 1 "$(grep -c 'would comment "all normal" on KV-9' <<<"$out")"
out=$(run_watch after-few 70)
check "dry run: low traffic" 1 "$(grep -c 'would comment "not enough traffic to judge"' <<<"$out")"
out=$(run_watch after-ok 20)
check "dry run: marks an hour that isn't over" 1 "$(grep -c 'hour is not over yet' <<<"$out")"
out=$(run_watch after-ok 600)
check "dry run: deploys older than the lookback are ignored" 0 "$(grep -c 'abcdef1' <<<"$out" || true)"
# Real run before the hour is over judges nothing.
out=$(PATH="$tmp/bin:$PATH" AFTER=after-bad WATCH_NOW_MS=$(( deploy_ms + 20 * 60000 )) WATCH_APPS="$tmp/apps.json" WATCH_FETCH="$tmp/fetch.sh" env -u LINEAR_API_KEY bash "$here/watch.sh")
check "real run: still watching during the hour" 1 "$(grep -c 'still watching' <<<"$out")"
# A newer deploy within the hour: the first is judged with the second.
echo "[{\"headSha\":\"abcdef1234567890\",\"updatedAt\":\"$deploy\",\"url\":\"u\"},{\"headSha\":\"1234567abcdef\",\"updatedAt\":\"2025-10-09T08:30:00Z\",\"url\":\"u2\"}]" > "$tmp/runs.json"
out=$(run_watch after-ok 120)
check "dry run: a newer deploy within the hour" 1 "$(grep -c 'abcdef1: a newer deploy came within the hour' <<<"$out")"
check "dry run: the newer deploy is judged" 1 "$(grep -c -- '-- App: 1234567' <<<"$out")"

# Real run with a worse hour: opens a ticket and a revert PR (local bare repo as "GitHub", fake gh and Linear).
git init -q --bare "$tmp/git/o/app.git" -b main
git clone -q "$tmp/git/o/app.git" "$tmp/work" 2>/dev/null
( cd "$tmp/work" && git config user.email t@t && git config user.name t && echo one > f.txt && git add f.txt && git commit -qm "first" \
  && echo two > f.txt && git commit -qam "KV-9: Add a thing (#4)" && git push -q origin main 2>/dev/null )
sha=$(git -C "$tmp/work" rev-parse HEAD)
echo "[{\"headSha\":\"$sha\",\"updatedAt\":\"$deploy\",\"url\":\"https://github.com/o/app/actions/runs/1\"}]" > "$tmp/runs.json"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "run list"*) cat "$RUNS" ;;
  "api repos/o/app/commits/"*) echo "KV-9: Add a thing (#4)" ;;
  "pr list"*) echo "" ;;
  "label create"*) ;;
  "pr create"*) echo "https://github.com/o/app/pull/5" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
cat > "$tmp/bin/curl" <<'CU'
#!/usr/bin/env bash
body=$(cat <<<"$*")
echo "$body" >> "$CURL_LOG"
case "$body" in
  *comments\(first*) echo '{"data":{"issue":{"comments":{"nodes":[]}}}}' ;;
  *projects\(first*) echo '{"data":{"projects":{"nodes":[{"id":"p1","name":"App","teams":{"nodes":[{"id":"t1","states":{"nodes":[{"id":"s-nh","name":"Needs Human","type":"started"}]},"labels":{"nodes":[{"id":"l1","name":"Agent","parent":{"name":"Origin"}},{"id":"l2","name":"Human involved","parent":{"name":"Delivery"}}]}}]}}]}}}' ;;
  *issueCreate*) echo '{"data":{"issueCreate":{"issue":{"identifier":"KV-50","url":"https://linear.app/x/KV-50"}}}}' ;;
  *"issue(id"*) echo '{"data":{"issue":{"id":"u1","title":"Add a thing"}}}' ;;
  *) echo '{"data":{}}' ;;
esac
CU
chmod +x "$tmp/bin/gh" "$tmp/bin/curl"
: > "$GH_LOG"; export CURL_LOG="$tmp/curl.log"; : > "$CURL_LOG"
out=$(PATH="$tmp/bin:$PATH" AFTER=after-bad WATCH_NOW_MS=$(( deploy_ms + 70 * 60000 )) WATCH_APPS="$tmp/apps.json" WATCH_FETCH="$tmp/fetch.sh" \
  WATCH_GIT_BASE="$tmp/git" LINEAR_API_KEY=k GH_TOKEN=t bash "$here/watch.sh")
check "real run: opens a revert PR" 1 "$(grep -c '^pr create .*--head kv-50-revert-' "$GH_LOG")"
check "real run: PR title names ticket and original change" 1 "$(grep -c -- '--title KV-50: Revert: KV-9: Add a thing (#4)' "$GH_LOG")"
check "real run: PR is labelled and never agent-built" 0 "$(grep -c 'agent-built' "$GH_LOG" || true)"
check "real run: branch holds the revert" "one" "$(git --git-dir="$tmp/git/o/app.git" show kv-50-revert-${sha:0:7}:f.txt)"
check "real run: ticket is created in Needs Human, Origin Agent" 1 "$(grep -c 'issueCreate' "$CURL_LOG")"
check "real run: ticket carries the numbers" 1 "$(tr "\n" " " < "$CURL_LOG" | grep -c "issueCreate.*Error rate went from")"
check "real run: original ticket gets a comment with the marker" 1 "$(grep -c "deploy-watch:$sha" "$CURL_LOG")"
check "real run: nothing merged" 0 "$(grep -c 'pr merge' "$GH_LOG" || true)"
exit "$fail"
