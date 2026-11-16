# Usage: jq -n -L . --argjson theme T --argjson events E -f texts.jq
# Prints up to 60 short masked texts (theme.text_field) of the events matching theme.filters and theme.where.
include "mask";
include "match";
($events | if type == "array" then . else (.result.events.events // .events.events // .events // []) end)
| map(select(matches($theme.filters // []) and matches($theme.where // [])))
| map(getf($theme.text_field) | select(. != null) | tostring | mask | gsub("\\s+"; " ") | gsub("`"; "'") | .[0:150] | select(. != ""))
| .[0:60]
