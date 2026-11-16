#!/usr/bin/env bash
# Usage: sign.sh < array-of-objects-with-.key > array-with-.signature
# Adds a stable `logsig-…` signature (hash of .key) to each object, like group.sh does for errors.
set -eo pipefail
items=$(cat)
sigs=$(jq -r '.[].key' <<<"$items" | while IFS= read -r k; do
  jq -n --arg k "$k" '$k' | tr -d '\n' | sha256sum | cut -c1-12
done | jq -R . | jq -s .)
jq --argjson s "$sigs" 'to_entries | map(.value + {signature: ("logsig-" + $s[.key])})' <<<"$items"
