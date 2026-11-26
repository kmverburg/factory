# Input: {report: compute.jq output, suggestions: markdown, date: "YYYY-MM-DD"}. Prints the project update markdown.
def n: if . == null then "–" else tostring end;
def pc: if . == null then "–" else "\(.)%" end;
def hrs: if . == null then "–" else (if . >= 48 then "\((. / 24 * 10 | round) / 10) days" else "\(.) h" end) end;
def row($name; f): "| \($name) | \(.this | f) | \(.prev | f) |";
def reasons($l; $empty): if ($l | length) == 0 then "- \($empty)" else ($l | map("- \(.count)× \(.reason)") | join("\n")) end;
.report as $r | $r.this as $t |
"## Weekly factory report, week to \(.date)\n\nCounted from Linear (labels, state history, comments) over the last 7 days, compared with the 7 days before. See docs/weekly-report.md.\n\n"
+ "**Health: " + ({onTrack: "on track", atRisk: "at risk", offTrack: "off track"}[$r.health]) + "**"
+ (if ($r.health_reasons | length) > 0 then " (" + ($r.health_reasons | join("; ")) + ")" else "" end) + "\n\n"
+ "| | This week | Week before |\n|---|---|---|\n"
+ ($r | [
    row("Tickets finished"; .finished | n),
    row("Autonomous"; "\(.autonomous) (\(.autonomous_pct | pc))"),
    row("Human involved"; .human_involved | n),
    row("New tickets, idea from Agent"; "\(.ideas_agent) (\(.ideas_agent_pct | pc))"),
    row("New tickets, idea from Human"; .ideas_human | n),
    row("Lead time, median (Agent Ready → merged)"; .lead_time_median_hours | hrs),
    row("Lead time, slowest"; .lead_time_slowest_hours | hrs),
    row("Fix rounds per finished ticket"; .fix_rounds_per_ticket | n),
    row("Tickets that needed fixes"; .tickets_with_fixes | n),
    row("2-round limit hit"; .round_limit_hit | n),
    row("Escalations to a human"; .escalations | n),
    row("Failed runs"; .failed_runs | n)
  ] | join("\n"))
+ (if $t.slowest_ticket != null then "\n\nSlowest ticket this week: \($t.slowest_ticket)." else "" end)
+ "\n\n### Most common escalation reasons\n" + reasons($t.escalation_reasons; "No escalations this week.")
+ "\n\n### Failed runs and their causes\n" + reasons($t.failure_causes; "No failed runs this week.")
+ "\n\n" + .suggestions
