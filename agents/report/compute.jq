# Weekly factory report numbers. Input: {now: epoch seconds, issues: [Linear issues]} where an issue is
# {identifier, createdAt, completedAt, labels: [{name, group}], history: [{createdAt, to}], comments: [{createdAt, body}]}.
# Output: {this: stats, prev: stats, health, health_reasons}. All counting happens here; Claude only words suggestions.
def ts: if . == null then null else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end;
def lbl($g): [.labels[]? | select((.group // "" | ascii_downcase) == ($g | ascii_downcase)) | .name | ascii_downcase][0] // null;
def median: if length == 0 then null else (sort | if length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end) end;
def pct($a; $b): if $b == 0 then null else (($a * 1000 / $b) | round) / 10 end;
# The reason of an escalation or a failed run, normalised so the same cause groups together.
def norm: gsub("https?://[^ )]+"; "<link>") | gsub("#[0-9]+"; "#N") | gsub("[0-9]+"; "N") | gsub("[`*]"; "") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "") | .[0:120];
def escalation_reasons: [.body | split("\n")[] | select(startswith("- ")) | .[2:] | norm | select(length > 0)];
def failure_cause: if (.body | contains("Claude reported:")) then ((.body | split("Claude reported:")[1] | split("\n") | map(select(length > 0 and (startswith("`") | not))) | .[0] // "") | norm) else "" end
  | if . == "" then "no cause reported" else . end;
def top($n): group_by(.) | map({reason: .[0], count: length}) | sort_by(-.count, .reason) | .[0:$n];

def window($issues; $from; $to):
  def within: . != null and . >= $from and . < $to;
  ([$issues[] | select((.completedAt | ts) | within)]) as $done
  | [$issues[] | .identifier as $id | .comments[]? | . + {id: $id, t: (.createdAt | ts)} | select(.t | within)] as $comments
  | ([$done[] | lbl("Delivery")] | map(select(. != null))) as $deliv
  | ([$issues[] | select((.createdAt | ts) | within) | lbl("Origin")] | map(select(. != null))) as $orig
  | [$done[] | (.completedAt | ts) as $c
      | ([.history[]? | select((.to // "" | ascii_downcase) == "agent ready") | .createdAt | ts | select(. <= $c)] | max) as $r
      | select($r != null) | ($c - $r)] as $lead
  | [$done[] | [.comments[]? | select(.body | contains("Reviewer asked for fixes on"))] | length] as $rounds
  | [$comments[] | select(.body | startswith("🙋 Reviewer agent wants you to look at"))] as $esc
  | [$comments[] | select(.body | startswith("💥"))] as $fail
  | {
      finished: ($done | length),
      autonomous: ($deliv | map(select(. == "autonomous")) | length),
      human_involved: ($deliv | map(select(. == "human involved")) | length),
      autonomous_pct: pct($deliv | map(select(. == "autonomous")) | length; $deliv | length),
      ideas: ($orig | length),
      ideas_agent: ($orig | map(select(. == "agent")) | length),
      ideas_human: ($orig | map(select(. == "human")) | length),
      ideas_agent_pct: pct($orig | map(select(. == "agent")) | length; $orig | length),
      lead_time_n: ($lead | length),
      lead_time_median_hours: (if ($lead | length) == 0 then null else (($lead | median) / 360 | round) / 10 end),
      lead_time_slowest_hours: (if ($lead | length) == 0 then null else (($lead | max) / 360 | round) / 10 end),
      slowest_ticket: null,
      fix_rounds_total: ($rounds | add // 0),
      fix_rounds_per_ticket: (if ($rounds | length) == 0 then null else ((($rounds | add) * 100 / ($rounds | length)) | round) / 100 end),
      tickets_with_fixes: ($rounds | map(select(. > 0)) | length),
      round_limit_hit: ([$comments[] | select(.body | contains("automatic rounds"))] | length),
      escalations: ($esc | length),
      escalation_reasons: ([$esc[] | escalation_reasons[]] | top(5)),
      failed_runs: ($fail | length),
      failure_causes: ([$fail[] | failure_cause] | top(5))
    }
  | .slowest_ticket = (([$done[] | (.completedAt | ts) as $c
      | ([.history[]? | select((.to // "" | ascii_downcase) == "agent ready") | .createdAt | ts | select(. <= $c)] | max) as $r
      | select($r != null) | {id: .identifier, secs: ($c - $r)}] | max_by(.secs).id) // null);

def health($t; $p):
  [ (if $t.failed_runs > $p.failed_runs then "failed runs went up (\($p.failed_runs) → \($t.failed_runs))" else empty end),
    (if $t.autonomous_pct != null and $p.autonomous_pct != null and $t.autonomous_pct < $p.autonomous_pct
       then "the autonomous share went down (\($p.autonomous_pct)% → \($t.autonomous_pct)%)" else empty end) ] as $why
  | {reasons: $why,
     health: (if ($why | length) == 0 then "onTrack"
              elif ($why | length) == 2 and $t.failed_runs >= 3 then "offTrack"
              else "atRisk" end)};

. as $in | ($in.now) as $now
| window($in.issues; $now - 7 * 86400; $now + 1) as $this
| window($in.issues; $now - 14 * 86400; $now - 7 * 86400) as $prev
| health($this; $prev) as $h
| {this: $this, prev: $prev, health: $h.health, health_reasons: $h.reasons}
