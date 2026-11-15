# Input: a Workers Observability telemetry query response (or a bare array of events).
# Output: error groups, most frequent first, with {key, count, first_seen, last_seen, message, frame, sample}.
# Everything is masked first, so no group (or signature key) contains emails or tokens.

def mask:
  gsub("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"; "[email]")
  | gsub("eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*"; "[token]")
  | gsub("(?<k>bearer|basic)\\s+[A-Za-z0-9._~+/=-]{8,}"; "\(.k) [token]"; "i")
  | gsub("(?<k>(token|secret|password|passwd|api[_-]?key|authorization|cookie|session)[\"'\\]]?\\s*[:=]\\s*)[\"']?[^\\s\"',;&]+"; "\(.k)[masked]"; "i")
  | gsub("\\b(sk|pk|ghp|gho|ghs|ghu|github_pat|xox[a-z]|glpat)[-_][A-Za-z0-9_-]{10,}"; "[token]")
  | gsub("\\bAKIA[0-9A-Z]{12,}"; "[token]")
  | gsub("[A-Za-z0-9_+=]{32,}"; "[token]");

def events:
  if type == "array" then . else (.result.events.events // .events.events // .events // []) end;

def first_frame:
  ((. // "") | split("\n") | map(select(test("^\\s*at\\s"))) | .[0] // "")
  | sub("^\\s+"; "")
  | gsub(":[0-9]+(:[0-9]+)?"; "")
  | gsub("\\?[^)\\s]*"; "");

def normalize_message:
  split("\n")[0]
  | gsub("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"; "<id>")
  | gsub("\\b[0-9a-fA-F]{8,}\\b"; "<id>")
  | gsub("[0-9]+"; "N")
  | gsub("\\s+"; " ")
  | .[0:200];

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
