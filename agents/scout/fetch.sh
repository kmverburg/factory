#!/usr/bin/env bash
# Usage: fetch.sh <worker-name>
# Prints the last 24 hours of error events for a Worker from Workers Logs (Workers Observability telemetry query).
# Needs CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_OBSERVABILITY_TOKEN (read-only). Never prints the token.
set -eo pipefail
: "${CLOUDFLARE_ACCOUNT_ID:?}" "${CLOUDFLARE_OBSERVABILITY_TOKEN:?}"
to=$(( $(date +%s) * 1000 ))
from=$(( to - 24 * 3600 * 1000 ))
body=$(jq -n --arg w "$1" --argjson from "$from" --argjson to "$to" '{
  queryId: "factory-log-scout", view: "events", limit: 2000,
  timeframe: {from: $from, to: $to},
  parameters: {
    filterCombination: "and",
    filters: [
      {key: "$metadata.service", operation: "eq", type: "string", value: $w},
      {key: "$metadata.level", operation: "eq", type: "string", value: "error"}
    ]
  }
}')
curl -sS --fail-with-body -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/observability/telemetry/query" \
  -H "Authorization: Bearer $CLOUDFLARE_OBSERVABILITY_TOKEN" -H "Content-Type: application/json" -d "$body"
