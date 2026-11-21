#!/usr/bin/env bash
# Daily factory health check: tests the relay, GitHub, Cloudflare, Linear and the secrets, and turns every failed
# check into a Linear ticket in the Factory project (see docs/health-check.md). It only reads; it never fixes anything.
# Usage: bash agents/health/health.sh [--dry-run]   (a dry run prints the results and creates no tickets)
# Env: see checks.sh. FACTORY_REPO is "owner/repo" of this repo. DRY_RUN=1 works like --dry-run.
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root"
# shellcheck source=../lib/linear.sh
source "$root/agents/lib/linear.sh"
# shellcheck source=checks.sh
source "$here/checks.sh"
# shellcheck source=tickets.sh
source "$here/tickets.sh"
[ "$1" != "--dry-run" ] || DRY_RUN=1
: "${FACTORY_REPO:?FACTORY_REPO is required}"

RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT
export RESULTS

# Each group runs on its own: a crash in one is a failed check, not the end of the run.
for group in check_relay check_github check_cloudflare_builds check_linear_integration check_secrets check_linear_queries; do
  "$group" || record fail "health-$group" "Health check step $group crashed" "The step $group stopped unexpectedly." "Open the run log of the health check workflow and fix agents/health/checks.sh."
done

echo "Factory health check: $(jq -s '[.[] | select(.status == "ok")] | length' "$RESULTS") ok, $(jq -s '[.[] | select(.status == "skip")] | length' "$RESULTS") skipped, $(jq -s '[.[] | select(.status == "fail")] | length' "$RESULTS") failed"
jq -r '"\(if .status == "ok" then "ok  " elif .status == "fail" then "FAIL" else "skip" end)  \(.title)" + (if .status == "ok" then "" else "\n      \(.detail)" end)' "$RESULTS"

failed=$(jq -s '[.[] | select(.status == "fail")] | length' "$RESULTS")
if [ -n "$DRY_RUN" ]; then
  echo "Dry run: no Linear tickets created or updated."
  exit 0
fi
health_sync_tickets "$RESULTS" || { [ "$failed" = "0" ] || exit 1; }
