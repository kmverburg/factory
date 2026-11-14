#!/usr/bin/env bash
# Prints why the last Claude run failed (from the action's execution log), or nothing.
# The action hides Claude's output in the job log, so failure reports use this instead.
set -eo pipefail
out="$RUNNER_TEMP/claude-execution-output.json"
[ -f "$out" ] || exit 0
jq -r '
  [ (if type == "array" then .[] else . end) as $m
    | ( ($m | select(.type == "result") | .result // empty),
        ($m | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text) )
  ] | map(select(type == "string" and length > 0)) | last // empty
' "$out" 2>/dev/null | head -c 600
