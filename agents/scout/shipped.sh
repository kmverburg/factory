#!/usr/bin/env bash
# Prints what was deployed from an app's default branch in the last 7 days, as a JSON array of
# {ticket, title, kind} (kind: feature | fix | revert), oldest first. Prints "null" when GitHub can't be read.
# A commit counts as deployed when its Workers Builds check run succeeded (the same rule the deploy watch uses).
# Usage: shipped.sh <owner/repo> [deploy check name regex]   Env: SHIPPED_NOW (epoch seconds, for tests)
set -eo pipefail
repo=$1; check=${2:-Workers Builds}
now=${SHIPPED_NOW:-$(date -u +%s)}
since=$(date -u -d "@$((now - 7 * 86400))" +%Y-%m-%dT%H:%M:%SZ)
fail() { echo "::warning::Could not read what shipped in $repo ($1)" >&2; echo null; exit 0; }
branch=$(gh api "repos/$repo" --jq .default_branch 2>/dev/null) || fail "repository"
commits=$(gh api "repos/$repo/commits?sha=$branch&since=$since&per_page=100" --jq '.[] | [.sha, (.commit.message | split("\n")[0])] | @tsv' 2>/dev/null) || fail "commits"
out="[]"
while IFS=$'\t' read -r sha subject; do
  [ -n "$sha" ] || continue
  runs=$(gh api "repos/$repo/commits/$sha/check-runs?per_page=100" 2>/dev/null) || fail "check runs"
  jq -e --arg re "$check" '[.check_runs[]? | select((.name | test($re; "i")) and .conclusion == "success")] | length > 0' <<<"$runs" >/dev/null || continue
  out=$(jq -c --arg s "$subject" '
    ($s | sub(" \\(#[0-9]+\\)$"; "")) as $t
    | ([$t | capture("^(?<id>[A-Za-z][A-Za-z0-9]*-[0-9]+): *(?<title>.*)$")] | first // null) as $m
    | if $m == null then . else
        . + [{ticket: ($m.id | ascii_upcase), title: $m.title,
              kind: (if ($m.title | test("^revert\\b"; "i")) then "revert"
                     elif ($m.title | test("^(bug|fix)\\b"; "i")) then "fix" else "feature" end)}] end' <<<"$out")
done <<<"$commits"
jq -c 'reverse' <<<"$out"
