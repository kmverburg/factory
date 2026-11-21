#!/usr/bin/env bash
# Usage: fetch.sh <worker-name> [filters-json]
# Prints the events of a Worker from Workers Logs (Workers Observability telemetry query).
# filters-json is a JSON array of {key, operation, value}; the default is the error events.
# SCOUT_WINDOW_HOURS sets how far back to look (default 24). At most 2000 events come back per query.
# SCOUT_FROM_MS and SCOUT_TO_MS (epoch milliseconds) pick an exact window instead (the deploy watch uses them).
# Needs CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_OBSERVABILITY_TOKEN (read-only). Never prints the token.
set -eo pipefail
: "${CLOUDFLARE_ACCOUNT_ID:?}" "${CLOUDFLARE_OBSERVABILITY_TOKEN:?}"
to=${SCOUT_TO_MS:-$(( $(date +%s) * 1000 ))}
from=${SCOUT_FROM_MS:-$(( to - ${SCOUT_WINDOW_HOURS:-24} * 3600 * 1000 ))}
filters=${2:-'[{"key":"$metadata.level","operation":"eq","type":"string","value":"error"}]'}
body=$(jq -n --arg w "$1" --argjson from "$from" --argjson to "$to" --argjson f "$filters" '{
  queryId: "factory-log-scout", view: "events", limit: 2000,
  timeframe: {from: $from, to: $to},
  parameters: {
    filterCombination: "and",
    filters: ([{key: "$metadata.service", operation: "eq", type: "string", value: $w}]
      + [$f[] | . + {type: (.type // (if (.value | type) == "number" then "number" elif (.value | type) == "boolean" then "boolean" else "string" end))}])
  }
}')
curl -sS --fail-with-body -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/observability/telemetry/query" \
  -H "Authorization: Bearer $CLOUDFLARE_OBSERVABILITY_TOKEN" -H "Content-Type: application/json" -d "$body"
