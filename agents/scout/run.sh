#!/usr/bin/env bash
# Runs the log scout and waits out Claude's usage limit (docs/usage-limits.md): scout.sh exits 75 (before it wrote
# anything) when the limit is reached; this waits until it resets (an hour when unknown) and starts it again, up to 3
# times. After that the run fails like any other failure. Other exit codes are passed on as they are.
# Optional: SCOUT_SLEEP (command used to wait, default sleep; for tests).
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/../lib/usage-limit.sh"
retries=0
while :; do
  rc=0; out=$(bash "$here/scout.sh" "$@" | tee /dev/stderr) || rc=$?
  [ "$rc" = 75 ] || exit "$rc"
  retries=$((retries + 1))
  if [ "$retries" -gt "$RETRY_MAX" ]; then echo "::error::Claude's usage limit was still reached after $RETRY_MAX retries; the scout did not run"; exit 1; fi
  at=$(sed -n 's/^SCOUT_RETRY_AT=//p' <<<"$out" | tail -n1)
  now=$(date +%s)
  if ! [[ "$at" =~ ^[0-9]+$ ]] || [ "$at" -le "$now" ]; then at=$((now + RETRY_DEFAULT_WAIT)); fi
  echo "Claude's usage limit was reached; trying again at $(date -u -d "@$at" '+%Y-%m-%d %H:%M UTC') (retry $retries of $RETRY_MAX)"
  ${SCOUT_SLEEP:-sleep} $((at - now))
done
