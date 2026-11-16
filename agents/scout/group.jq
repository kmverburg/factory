# Input: a Workers Observability telemetry query response (or a bare array of events).
# Output: error groups, most frequent first, with {key, count, first_seen, last_seen, message, frame, sample}.
# Everything is masked first, so no group (or signature key) contains emails or tokens.

include "mask";

def first_frame:
  ((. // "") | split("\n") | map(select(test("^\\s*at\\s"))) | .[0] // "")
  | sub("^\\s+"; "")
  | gsub(":[0-9]+(:[0-9]+)?"; "")
  | gsub("\\?[^)\\s]*"; "");

def iso: (. / 1000 | floor | todate);

[ events[]
  | (."$metadata" // {}) as $m
  | (.source // {}) as $s
  | (($m.error // $m.message // $s.message // "") | tostring) as $raw
  | (($m.stack // $s.stack // $raw) | tostring) as $stack
  | { message: ($raw | mask | split("\n")[0] | .[0:500]),
      stack: ($stack | mask | .[0:2000]),
      ts: (.timestamp // $m.timestamp // 0) }
  | select(.message != "")
]
| group_by((.message | normalize_message) + "\n" + (.stack | first_frame))
| map(sort_by(.ts)
  | { key: ((.[0].message | normalize_message) + "\n" + (.[0].stack | first_frame)),
      count: length,
      first_seen: (.[0].ts | iso),
      last_seen: (.[-1].ts | iso),
      message: .[-1].message,
      frame: (.[-1].stack | first_frame),
      sample: { message: .[-1].message, stack: .[-1].stack, timestamp: (.[-1].ts | iso) } })
| sort_by(-.count, .key)
