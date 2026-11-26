# shellcheck shell=bash
# Recognises Claude's usage / rate limit messages and schedules a retry of the same step (docs/usage-limits.md).
# Sourced by the failure reporters. Needs agents/lib/linear.sh.
RETRY_MAX=3            # retries before the ticket goes to Needs Human
RETRY_DEFAULT_WAIT=3600 # seconds to wait when the reset time isn't known
RETRY_MAX_WAIT=28800   # a reset further away than this is treated as unknown (probably misread)

# $1 = text Claude printed. Succeeds when it is a usage or rate limit message.
usage_limit_hit() {
  grep -qiE 'usage limit|rate[ _-]?limit|limit reached|limit will reset|too many requests|overloaded_error|quota exceeded|credit balance is too low|\b429\b' <<<"$1"
}

# $1 = text Claude printed, $2 = now (epoch seconds, default: now). Prints when the limit resets (epoch seconds):
# from "…limit reached|1760000000" or "resets 3pm (Europe/Amsterdam)", else now + one hour.
usage_limit_reset() {
  local text=$1 now=${2:-$(date +%s)} at="" t tz time
  t=$(grep -oE '\|[0-9]{10}\b' <<<"$text" | head -n1 | tr -d '|') || true
  [ -z "$t" ] || at=$t
  if [ -z "$at" ]; then
    time=$(grep -oiE 'resets?( at)? [0-9]{1,2}(:[0-9]{2})? ?(am|pm)' <<<"$text" | head -n1 | sed -E 's/^resets?( at)? //') || true
    tz=$(grep -oE '\([A-Za-z_]+/[A-Za-z_]+\)' <<<"$text" | head -n1 | tr -d '()') || true
    if [ -n "$time" ]; then
      at=$(TZ=${tz:-UTC} date -d "$(TZ=${tz:-UTC} date -d "@$now" +%F) $time" +%s 2>/dev/null) || at=""
      [ -z "$at" ] || [ "$at" -gt "$now" ] || at=$((at + 86400))
    fi
  fi
  if [ -z "$at" ] || [ "$at" -le "$now" ] || [ $((at - now)) -gt "$RETRY_MAX_WAIT" ]; then at=$((now + RETRY_DEFAULT_WAIT)); fi
  echo "$at"
}

# Retry requests are Linear comments with a hidden marker: key = what is retried (e.g. "factory-fix-12-1"), event = the
# repository_dispatch event type, n = retry number, at = when to retry, payload = the original client_payload (base64).
# $1 = comments JSON [{body, createdAt}], $2 = key, $3 = now. Prints how many retries of that key were requested in the last 24 hours.
retry_count() {
  jq -r --arg k "<!-- factory-retry key=$2 " --argjson now "$3" \
    '[.[]? | select((.body | contains($k)) and (($now - (.createdAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0)) <= 86400))] | length' <<<"$1"
}

# $1 = comments JSON, $2 = now. Prints the pending retry request {key, event, n, at, payload} (the latest one that wasn't
# started yet and is at most 3 hours past due), or nothing.
retry_pending() {
  jq -c --argjson now "$2" '
    [.[]? | .body as $b | select($b | contains("<!-- factory-retry key="))
      | ($b | capture("<!-- factory-retry key=(?<key>[^ ]+) event=(?<event>[^ ]+) n=(?<n>[0-9]+) at=(?<at>[0-9]+) payload=(?<payload>[A-Za-z0-9+/=]*) -->")) + {createdAt}] as $reqs
    | [.[]? | .body | select(contains("<!-- factory-retry-started ")) | capture("<!-- factory-retry-started key=(?<key>[^ ]+) n=(?<n>[0-9]+) -->")] as $done
    | [$reqs[] | . as $r | select(($done | map(select(.key == $r.key and .n == $r.n)) | length) == 0)
        | select(($now - (.at | tonumber)) <= 10800)] | sort_by(.at | tonumber) | last // empty' <<<"$1"
}

# $1 = identifier, $2 = event type, $3 = key, $4 = payload JSON, $5 = Claude's text. Records a retry request on the ticket
# (comment with the original payload) and returns 0; returns 2 when the retries are used up, 1 when it can't be scheduled.
usage_limit_schedule() {
  local id=$1 event=$2 key=$3 payload=$4 text=$5 comments now at n
  now=${RETRY_NOW:-$(date +%s)}
  [ -n "$payload" ] && jq -e type <<<"$payload" >/dev/null 2>&1 || return 1
  comments=$(linear_issue_comments "$id" 2>/dev/null) || return 1
  [ -n "$comments" ] || comments="[]"
  n=$(retry_count "$comments" "$key" "$now")
  [ "$n" -lt "$RETRY_MAX" ] || return 2
  n=$((n + 1))
  at=$(usage_limit_reset "$text" "$now")
  linear_comment "$id" "⏳ Claude's usage limit was reached; trying again at $(date -u -d "@$at" '+%Y-%m-%d %H:%M UTC') (retry $n of $RETRY_MAX).
<!-- factory-retry key=$key event=$event n=$n at=$at payload=$(jq -c . <<<"$payload" | base64 -w0) -->"
}
