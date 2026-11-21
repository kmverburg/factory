# Usage: jq -n -L agents/scout --argjson cfg C --argjson before_requests E --argjson before_errors E \
#          --argjson after_requests E --argjson after_errors E -f compare.jq
# Compares the watched hour after a deploy ("after") with the 24 hours before it ("before"). Each E is a list of
# Workers Logs events (array or telemetry response). Plain counting and thresholds, no LLM.
# Prints {status: "alert"|"ok"|"low_traffic", reasons: [...], before: {...}, after: {...}}.
include "match";

def evs: if type == "array" then . else (.result.events.events // .events.events // .events // []) end;
def p95: if length == 0 then 0 else sort | .[((length * 0.95 | ceil) - 1)] end;
def r3: (. * 1000 | round) / 1000;
def r6: (. * 1000000 | round) / 1000000;
def pct: (. * 100 | r3);
def stats($reqs; $errs):
  ($reqs | evs | map(select(matches([{key: "event", operation: "eq", value: "request"}])))) as $r
  | ($r | map(select(matches([{key: "status", operation: "gte", value: 500}, {key: "status", operation: "lt", value: 600}]))) | length) as $five
  | ($r | map(getf("ms") | num | select(type == "number"))) as $ms
  | ($errs | evs | length) as $e
  | {requests: ($r | length), errors: $e, errors_5xx: $five,
     error_rate: (if ($r | length) == 0 then 0 else ($e / ($r | length)) | r6 end),
     rate_5xx: (if ($r | length) == 0 then 0 else ($five / ($r | length)) | r6 end),
     p95_ms: ($ms | p95 | r3)};

def worse($a; $b; $name; $count; $min; $ratio; $key):
  if $a[$count] >= $min and $a[$key] > $b[$key] * $ratio
  then ["\($name) went from \($b[$key] | pct)% to \($a[$key] | pct)% (\($a[$count]) in the watched time; the limit is more than \($ratio)x and at least \($min))"]
  else [] end;

stats($before_requests; $before_errors) as $b
| stats($after_requests; $after_errors) as $a
| (if $a.requests < $cfg.min_requests or $b.requests < $cfg.min_requests then
    ["not enough traffic to judge (\($a.requests) requests in the watched time, \($b.requests) before; at least \($cfg.min_requests) in both are needed)"]
  else [] end) as $traffic
| (if ($traffic | length) > 0 then []
   else
     worse($a; $b; "Error rate"; "errors"; $cfg.min_errors; $cfg.error_ratio; "error_rate")
     + worse($a; $b; "5xx rate"; "errors_5xx"; $cfg.min_5xx; $cfg.error_5xx_ratio; "rate_5xx")
     + (if $a.p95_ms > $b.p95_ms * (1 + $cfg.p95_slower_pct / 100) and ($a.p95_ms - $b.p95_ms) >= $cfg.p95_min_increase_ms
        then ["Request time (p95) went from \($b.p95_ms) ms to \($a.p95_ms) ms (the limit is more than \($cfg.p95_slower_pct)% slower and at least \($cfg.p95_min_increase_ms) ms)"]
        else [] end)
   end) as $reasons
| {status: (if ($traffic | length) > 0 then "low_traffic" elif ($reasons | length) > 0 then "alert" else "ok" end),
   reasons: ($traffic + $reasons), before: $b, after: $a}
