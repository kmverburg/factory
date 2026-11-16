# Usage: jq -n --argjson signal S --argjson events E -f metrics.jq     (run with -L <this dir>)
# S = one signal from signals.json / apps.json, E = the raw events (array or telemetry response).
# Prints one row per group: {id, signal, group, measure, value, n, kind, unit, threshold, ...}.
# Plain counting, no LLM. Group names come from logs, so they are masked and normalised.
include "mask";
include "match";

def gname($by): if $by == null then "" else
  (getf($by) | if . == null then "(none)" else tostring end | mask | normalize_message | gsub("`"; "'") | .[0:80]) end;
def p95: sort | .[((length * 0.95 | ceil) - 1)];
def r3: (. * 1000 | round) / 1000;

def measure($s):
  . as $evs
  | ($evs | map(select(matches($s.where // [])))) as $hit
  | ($s.measure // "count") as $m
  | if $m == "count" then {value: ($hit | length), n: ($hit | length), kind: "sum"}
    elif $m == "share" then {value: (if ($evs | length) == 0 then 0 else ($hit | length) / ($evs | length) end), n: ($evs | length), kind: "mean"}
    else
      ($hit | map(getf($s.field) | num | select(type == "number"))) as $vals
      | {n: ($vals | length),
         kind: (if $m == "sum" then "sum" else "mean" end),
         value: (if ($vals | length) == 0 then 0
                 elif $m == "sum" then ($vals | add) elif $m == "avg" then (($vals | add) / ($vals | length))
                 elif $m == "max" then ($vals | max) else ($vals | p95) end)}
    end
  | .value |= r3;


($events | if type == "array" then . else (.result.events.events // .events.events // .events // []) end) as $all
| ($all | map(select(matches($signal.filters // [])))) as $evs
| ($signal.by // null) as $by
| ($evs | group_by(gname($by)) | map({g: (.[0] | gname($by)), evs: .}) | sort_by(-(.evs | length)) | .[0:25]) as $groups
| ($groups + [ ($signal.expect // [])[] as $e | select(($groups | map(.g) | index($e)) == null) | {g: $e, evs: []} ]) as $rows
| (if ($rows | length) == 0 then [{g: "", evs: []}] else $rows end)[]
| . as $r
| ($r.evs | measure($signal)) as $v
| {id: ($signal.name + (if $r.g == "" then "" else " › " + $r.g end)),
   signal: $signal.name, group: $r.g, measure: ($signal.measure // "count")}
  + $v
  + {unit: ($signal.unit // ""), threshold: ($signal.threshold // null), direction: ($signal.direction // "above"),
     min_count: ($signal.min_count // 1), ticket: (if $signal.ticket == null then true else $signal.ticket end), worse_pct: ($signal.worse_pct // 50),
     floor: ($signal.floor // (if $signal.threshold then $signal.threshold / 2 else 1 end)),
     description: ($signal.description // "")}
