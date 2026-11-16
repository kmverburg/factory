# Usage: jq -n -L . --argjson metrics M --argjson prev P --argjson findings F --arg date D -f report.jq
# Prints {table, summary, snapshot, health}: the numbers for the weekly report. Plain code, no LLM.
include "fmt";

def pct($now; $old): if $old == 0 then null else (($now - $old) / $old * 100 | round) end;

($prev // []) as $p
| [ $metrics[] | . as $m | . + {old: ($p | map(select(.id == $m.id))[0])} ] as $rows
| ([ $metrics[].signal ] | reduce .[] as $s ([]; if index($s) then . else . + [$s] end)) as $order
| [ $order[] as $s | [ $rows[] | select(.signal == $s) ] | sort_by(-.n) | .[0:5][] ] as $shown
| { table: (
    "| Signal | Now | Events | Last week | Change |\n|---|---|---|---|---|\n"
    + ( [ $shown[] | select(.n > 0 or .group == "" or .ticket == false)
          | "| \(.id | gsub("\\|"; "/")) | \(fmt) | \(.n) | \(if .old then fmtv(.old.value; .unit) else "–" end) | "
            + (if .old == null then "–" else (pct(.value; .old.value) | if . == null then "–" elif . > 0 then "+\(.)%" else "\(.)%" end) end) + " |" ] | join("\n")) ),
    changes: [ $rows[] | select(.old != null and .old.value > 0 and (.n >= .min_count or .value >= .floor))
               | {id, now: fmt, before: fmtv(.old.value; .unit), change_pct: pct(.value; .old.value),
                  worse: (if .direction == "above" then .value > .old.value else .value < .old.value end)}
               | select((.change_pct | fabs) >= 25) ] | sort_by(-(.change_pct | fabs)) | .[0:10],
    breaches: [ $findings[] | {id, value: .display, reasons} ] | .[0:10],
    quiet: ( [ $rows[] | select(.group != "" and .measure == "count" and .n == 0 and .ticket == false) | {id, why: "never used in the window"} ]
             + [ $p[] | select(.group != "" and .measure == "count" and .value > 0) | . as $o
                 | select(($rows | map(select(.id == $o.id and .value > 0)) | length) == 0)
                 | {id, why: "used last week, not this week"} ] ) | .[0:10],
    no_data: [ $rows | group_by(.signal)[] | select(all(.[]; .n == 0)) | .[0].signal ],
    snapshot: [ $rows[] | select(.n > 0) | {id, value, n, measure} ] | sort_by(-.n) | .[0:200]
  }
| .health = (if ($findings | length) == 0 then "onTrack" elif ($findings | length) < 3 then "atRisk" else "offTrack" end)
| .summary = {date: $date, changes: .changes, breaches: .breaches, quiet: .quiet, no_data: .no_data,
              numbers: [ $shown[] | select(.n > 0) | {id, now: fmt, events: .n, before: (if .old then fmtv(.old.value; .unit) else null end)} ] | .[0:40]}
| del(.changes, .breaches, .quiet, .no_data)
