#!/usr/bin/env bash
# Usage: group.sh < telemetry-response.json > groups.json
# Groups errors by signature (message + top stack frame) and adds a stable `signature` to each group.
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
groups=$(jq -f "$here/group.jq")
sigs=$(jq -r '.[].key' <<<"$groups" | while IFS= read -r k; do
  jq -n --arg k "$k" '$k' | tr -d '\n' | sha256sum | cut -c1-12
done | jq -R . | jq -s .)
jq --argjson s "$sigs" 'to_entries | map(.value + {signature: ("logsig-" + $s[.key])} | del(.key))' <<<"$groups"
