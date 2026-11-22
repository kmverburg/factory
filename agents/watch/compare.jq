# Usage: jq -n -L agents/scout --argjson requests R --argjson errors E --argjson deploy_ms N --argjson end_ms N --argjson from_ms N \
#          --argjson s SETTINGS -f compare.jq
# R, E = Workers Logs events (arrays or telemetry responses): the request lines (event = request) and the error lines.
# The window after the deploy is [deploy_ms, end_ms); the window before is [from_ms, deploy_ms).
# Prints {status: ok | bad | low_traffic | unreadable, rows, reasons, ...}. Plain counting and thresholds, no LLM.
include "match";

def evs: if type == "array" then . else (.result.events.events // .events.events // .events // []) end;
def p95: sort | .[((length * 0.95 | ceil) - 1)];
def pct: (. * 1000 | round) / 10;
def stats($reqs; $errs):
  ($reqs | length) as $n
  | ([$reqs[] | select((getf("status") | num) as $x | ($x | type) == "number" and $x >= 500 and $x < 600)] | length) as $five
  | ([$reqs[] | getf("ms") | num | select(type == "number")]) as $ms
  | {requests: $n, errors: ($errs | length), five_xx: $five, ms_n: ($ms | length), p95: (if ($ms | length) == 0 then null else ($ms | p95) end),
     error_rate: (if $n == 0 then 0 else ($errs | length) / $n end), five_rate: (if $n == 0 then 0 else $five / $n end)};

($requests | evs) as $R | ($errors | evs) as $E
| def within($a; $b): map(select(.timestamp >= $a and .timestamp < $b));
  ($R | within($deploy_ms; $end_ms)) as $ra | ($R | within($from_ms; $deploy_ms)) as $rb
| ($E | within($deploy_ms; $end_ms)) as $ea | ($E | within($from_ms; $deploy_ms)) as $eb
| stats($ra; $ea) as $a | stats($rb; $eb) as $b
| ($s.min_requests) as $min
| def rate_row($name; $ka; $kc; $minc):
    ($a[$ka]) as $x | ($b[$ka]) as $y
    | {name: $name, before: $y, after: $x, unit: "rate",
       before_display: "\($y | pct)% (\($b[$kc]) of \($b.requests))", after_display: "\($x | pct)% (\($a[$kc]) of \($a.requests))",
       breach: ($a[$kc] >= $minc and $x > $y * $s.factor)}
    | .reason = (if .breach then "\($name) went from \(.before_display) to \(.after_display), more than \($s.factor)× and at least \($minc) events" else "" end);
  [ rate_row("Error rate"; "error_rate"; "errors"; $s.min_errors),
    rate_row("5xx rate"; "five_rate"; "five_xx"; $s.min_5xx),
    ({name: "Request time (p95)", before: $b.p95, after: $a.p95, unit: "ms",
      before_display: (if $b.p95 == null then "n/a" else "\($b.p95) ms" end), after_display: (if $a.p95 == null then "n/a" else "\($a.p95) ms" end)}
     | .breach = ($a.p95 != null and $b.p95 != null and $a.ms_n >= $min and $b.ms_n >= $min and $a.p95 > $b.p95 * (1 + $s.p95_pct / 100) and ($a.p95 - $b.p95) >= $s.p95_min_ms)
     | .reason = (if .breach then "Request time (p95) went from \(.before_display) to \(.after_display), more than \($s.p95_pct)% slower" else "" end)) ] as $rows
| {after: $a, before: $b, rows: $rows, reasons: [$rows[] | select(.breach) | .reason],
   status: (if $a.requests < $min or $b.requests < $min then "low_traffic"
            elif ($rows | any(.breach)) then "bad" else "ok" end)}
