# Usage: jq -n --argjson metrics M --argjson prev P -f evaluate.jq
# M = rows from metrics.jq, P = last week's snapshot rows [{id, value, n}] (or null).
# Prints findings: rows that crossed their threshold or got clearly worse than last week (tickets only for ticket:true signals).
include "fmt";

($prev // []) as $p
| [ $metrics[]
    | select(.ticket and .direction == "above")
    | . as $m
    | ($p | map(select(.id == $m.id))[0]) as $old
    | ( if .threshold != null and .n >= .min_count and .value > .threshold
        then ["above the threshold of \(fmtv(.threshold; .unit))"] else [] end
      + if $old != null and .n >= .min_count and .value >= .floor
           and .value >= ($old.value * (1 + .worse_pct / 100)) and .value > $old.value
        then ["clearly worse than last week (\(fmtv($old.value; .unit)))"] else [] end ) as $why
    | select($why | length > 0)
    | { key: ("signal\n" + .signal + "\n" + .group), kind: "signal",
        title: ("[logs] " + (.id | .[0:70]) + ": " + fmt),
        id, signal, group, value, unit, n, threshold, previous: ($old.value // null), previous_display: (if $old then fmtv($old.value; .unit) else null end),
        reasons: $why, display: fmt,
        severity: (if .threshold then .value / .threshold else (if ($old.value // 0) > 0 then .value / $old.value else .value end) end) } ]
| sort_by(-.severity, .id)
