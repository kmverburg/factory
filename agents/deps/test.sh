#!/usr/bin/env bash
# Tests for the weekly dependency check with fake `gh`, `npm` and Linear (no network). Usage: bash agents/deps/test.sh
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }
count() { grep -c -- "$1" "$2" || true; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- target.jq: the 2-week rule and the major/minor split -------------------------------------------------------------
now=1700000000   # 2023-11-14
T='{"created":"2020-01-01T00:00:00.000Z","1.0.0":"2023-01-01T00:00:00.000Z","1.1.0":"2023-02-01T00:00:00.000Z","1.2.0":"2023-11-12T00:00:00.000Z",
    "1.3.0-beta.1":"2023-01-05T00:00:00.000Z","2.0.0":"2023-03-01T00:00:00.000Z","3.0.0":"2023-11-13T00:00:00.000Z","modified":"2023-11-13T00:00:00.000Z"}'
tgt() { jq -nc --arg c "$1" --argjson t "$T" --argjson now "$now" '{current: $c, times: $t, now: $now, min_age_days: 14}' | jq -c -f "$here/target.jq"; }
check "target: fresh version and pre-release skipped, major found" '{"same_major":"1.1.0","major":"2.0.0"}' "$(tgt 1.0.0)"
check "target: fresh major skipped" '{"same_major":null,"major":null}' "$(tgt 2.0.0)"
check "target: up to date" '{"same_major":null,"major":"2.0.0"}' "$(tgt 1.1.0)"
check "target: pre-release current is ignored" '{"same_major":null,"major":null}' "$(tgt 1.0.0-rc.1)"

# --- deps.sh end to end ------------------------------------------------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/fix"
cat > "$tmp/apps.json" <<'J'
[{"project": "App", "repo": "app", "worker": "app"}]
J
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
# gh repo clone OWNER/REPO DEST -- --depth 1 --quiet
[ "$1 $2" = "repo clone" ] || exit 1
[ "$3" != "o/broken" ] || exit 1
dest=$4
git init -q "$dest"
mkdir -p "$dest/web" "$dest/node_modules/x"
echo '{"name":"app","dependencies":{}}' > "$dest/package.json"; echo '{}' > "$dest/package-lock.json"
echo '{"name":"web"}' > "$dest/web/package.json"
echo '{}' > "$dest/node_modules/x/package.json"
git -C "$dest" add -f . >/dev/null; git -C "$dest" -c user.email=a@b -c user.name=n commit -qm c
GH
cat > "$tmp/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "$PWD npm $*" >> "$NPM_LOG"
case "$1" in
  ci) exit 0 ;;
  outdated) cat "$FIX/outdated.json"; exit 1 ;;
  audit) cat "$FIX/audit.json"; exit 1 ;;
  view) cat "$FIX/time-$2.json" ;;
esac
NPM
cat > "$tmp/bin/curl" <<'CU'
#!/usr/bin/env bash
body=$(tr '\n' ' ' <<<"$*" | tr -s " ")
echo "$body" >> "$CURL_LOG"
CTX='{"id":"p1","name":"App","teams":{"nodes":[{"id":"t1","states":{"nodes":[{"id":"s-todo","name":"Todo","type":"unstarted"},{"id":"s-ar","name":"Agent Ready","type":"unstarted"}]},"labels":{"nodes":[{"id":"o-agent","name":"Agent","parent":{"name":"Origin"}},{"id":"l-dep","name":"factory:dependencies"}]}}]}}'
case "$body" in
  *projects\(first*) echo "{\"data\":{\"projects\":{\"nodes\":[$CTX]}}}" ;;
  *"issues(first"*) cat "$FIX/open.json" ;;
  *issueCreate*) n=$(grep -c issueCreate "$CURL_LOG"); echo "{\"data\":{\"issueCreate\":{\"issue\":{\"identifier\":\"KV-$((90 + n))\",\"url\":\"https://linear.app/KV-$((90 + n))\"}}}}" ;;
  *"issue(id"*) echo '{"data":{"issue":{"id":"u1","identifier":"KV-50","url":"https://linear.app/KV-50","state":{"name":"Todo","type":"unstarted"},"labels":{"nodes":[]},"team":{"id":"t1","states":{"nodes":[{"id":"s-todo","name":"Todo","type":"unstarted"},{"id":"s-ar","name":"Agent Ready","type":"unstarted"}]},"labels":{"nodes":[]}}}}}' ;;
  *) echo '{"data":{}}' ;;
esac
CU
chmod +x "$tmp/bin/"*
tm() { jq -nc --arg a "$2" --arg b "$3" '{"1.0.0": "2023-01-01T00:00:00.000Z"} + {($a): "2023-02-01T00:00:00.000Z"} + (if $b != "" then {($b): "2023-11-12T00:00:00.000Z"} else {} end)' > "$tmp/fix/time-$1.json"; }
tm lodash 4.17.21 ""; jq -n '{"4.17.20":"2022-01-01T00:00:00.000Z","4.17.21":"2022-02-01T00:00:00.000Z"}' > "$tmp/fix/time-lodash.json"
jq -n '{"1.0.0":"2023-01-01T00:00:00.000Z","1.1.0":"2023-02-01T00:00:00.000Z","1.2.0":"2023-11-12T00:00:00.000Z"}' > "$tmp/fix/time-left-pad.json"
jq -n '{"17.0.0":"2021-01-01T00:00:00.000Z","18.3.0":"2023-01-01T00:00:00.000Z"}' > "$tmp/fix/time-react.json"
jq -n '{"2.0.0":"2023-01-01T00:00:00.000Z","2.1.0":"2023-11-13T00:00:00.000Z"}' > "$tmp/fix/time-fresh.json"
jq -n '{lodash: {current: "4.17.20", wanted: "4.17.21", latest: "4.17.21"},
        "left-pad": {current: "1.0.0", wanted: "1.2.0", latest: "1.2.0"},
        react: {current: "17.0.0", wanted: "17.0.2", latest: "18.3.0"},
        fresh: {current: "2.0.0", wanted: "2.1.0", latest: "2.1.0"}}' > "$tmp/fix/outdated.json"
jq -n '{vulnerabilities: {
  minimist: {name: "minimist", severity: "high", isDirect: false, via: [{title: "Prototype Pollution", url: "https://github.com/advisories/x"}], fixAvailable: {name: "mkdirp", version: "1.0.4", isSemVerMajor: false}},
  nofix: {name: "nofix", severity: "low", isDirect: true, via: [{title: "Meh", url: "https://y"}], fixAvailable: false}}}' > "$tmp/fix/audit.json"
echo '{"data":{"issues":{"nodes":[]}}}' > "$tmp/fix/open.json"

run() { 
  : > "$tmp/gh.log"; : > "$tmp/npm.log"; : > "$tmp/curl.log"; set +e
  OUT=$(PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" NPM_LOG="$tmp/npm.log" CURL_LOG="$tmp/curl.log" FIX="$tmp/fix" LINEAR_API_KEY=k GITHUB_OWNER=o FACTORY_REPO='' \
    DEPS_APPS="$tmp/apps.json" DEPS_NOW=$now "$@" bash "$here/deps.sh" 2>&1); CODE=$?
  set +e; set -e
}
inputs() { grep issueCreate "$tmp/curl.log" | sed 's/^.*--data //' | jq -c 'select(.query | contains("issueCreate")) | .variables.input' 2>/dev/null || true; }
run env
check "run succeeds" 0 "$CODE"
check "three tickets: security, routine, major" 3 "$(count issueCreate "$tmp/curl.log")"
check "only package.json dirs with a lockfile are installed (not node_modules, not web)" 1 "$(grep -c ' npm ci' "$tmp/npm.log")"
check "no scripts run" 1 "$(grep -c -- '--ignore-scripts' "$tmp/npm.log" | head -1)"
check "security ticket is high priority" 1 "$(grep -c '"priority": 2' "$tmp/curl.log" || true)"
check "security fix with a fixable advisory is mentioned" 1 "$(grep -c 'Prototype Pollution' "$tmp/curl.log" || true)"
check "advisory without a fix is not listed" 0 "$(grep -c 'Meh' "$tmp/curl.log" || true)"
check "routine: lodash patch listed" 1 "$(grep -c 'lodash.* 4.17.20 → 4.17.21' "$tmp/curl.log" || true)"
check "routine: version under 2 weeks old is not proposed (left-pad 1.1.0, not 1.2.0)" 1 "$(grep -c 'left-pad.* 1.0.0 → 1.1.0' "$tmp/curl.log" || true)"
check "routine: 1.2.0 never appears" 0 "$(grep -c '1\.2\.0' "$tmp/curl.log" || true)"
check "major: react 17 → 18.3.0" 1 "$(grep -c 'react.* 17.0.0 → 18.3.0' "$tmp/curl.log" || true)"
check "fresh package with only a fresh newer version is skipped" 0 "$(grep -c '`fresh`' "$tmp/curl.log" || true)"
check "unchecked directory is reported on every ticket" 3 "$(grep -c 'Could not check' "$tmp/curl.log" || true)"
check "routine and security tickets move to Agent Ready, the major one stays in Todo" 2 "$(grep -c 'stateId.*s-ar' "$tmp/curl.log" || true)"
check "week in the title" 1 "$(grep -c 'Dependency updates (2023-W46)' "$tmp/curl.log" || true)"

# Last week's tickets still open: updated, not duplicated; unchanged ones are left alone.
last_week='{"project":"App","repo":"app","week":"2023-W45","security":[],"failed":[],"updates":[{"dir":".","name":"lodash","current":"4.17.20","target":"4.17.21","kind":"patch","reason":"bug fix release"}]}'
specs=$(jq -c -f "$here/ticket.jq" <<<"$last_week")
old_desc=$(source "$root/agents/lib/linear.sh"; source "$root/agents/lib/issue-writer.sh"; issue_format "$(jq -c '.[0]' <<<"$specs")")
jq -n --arg d "$old_desc" --arg m 'Signature: `depsig-app-routine`' \
  '{data:{issues:{nodes:[{id:"i1",identifier:"KV-50",description:($d), labels:{nodes:[]}},{id:"i2",identifier:"KV-51",description:("x\n\($m)"),labels:{nodes:[]}}]}}}' \
  | sed 's/depsig-app-routine/depsig-app-routine/' > "$tmp/fix/open.json"
# KV-50 has the old routine text with the marker; make sure it carries the marker.
jq --arg m 'Signature: `depsig-app-routine`' '.data.issues.nodes[0].description += "\n\n---\n" + $m' "$tmp/fix/open.json" > "$tmp/fix/open2.json" && mv "$tmp/fix/open2.json" "$tmp/fix/open.json"
run env
check "open routine ticket is updated" 1 "$(count 'IssueUpdateInput' "$tmp/curl.log")"
check "open routine ticket gets a comment" 1 "$(count commentCreate "$tmp/curl.log")"
check "only the two other tickets are created" 2 "$(count issueCreate "$tmp/curl.log")"
check "output says updated" 1 "$(grep -c 'updated KV-50 (routine)' <<<"$OUT" || true)"

# Nothing to do: no ticket.
echo '{}' > "$tmp/fix/outdated.json"; echo '{"vulnerabilities":{}}' > "$tmp/fix/audit.json"; echo '{"data":{"issues":{"nodes":[]}}}' > "$tmp/fix/open.json"
run env
check "nothing outdated: no ticket" 0 "$(count issueCreate "$tmp/curl.log")"
check "nothing outdated: Linear not even asked" 0 "$(count projects "$tmp/curl.log")"
check "nothing outdated: success" 0 "$CODE"

# Dry run touches nothing; a failed clone fails the run.
jq -n '{lodash: {current: "4.17.20"}}' > "$tmp/fix/outdated.json"
run env DRY_RUN=1 LINEAR_API_KEY=
check "dry run: prints the ticket" 1 "$(grep -c 'Dependency updates (2023-W46)' <<<"$OUT" || true)"
check "dry run: no Linear calls" 0 "$(wc -l < "$tmp/curl.log" | tr -d ' ')"
echo '[{"project": "App", "repo": "broken"}]' > "$tmp/apps.json"
run env
check "clone failure fails the run" 1 "$CODE"
exit $fail
