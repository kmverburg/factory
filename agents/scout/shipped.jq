# Usage: jq -nr --argjson items I --argjson lines L -f shipped.jq
# $items = output of shipped.sh (array, or null when unreadable); $lines = {TICKET: "user-facing line"} (may be empty).
# Prints the "Shipped this week" markdown section. Plain code: Claude only supplies the wording in $lines.
def line: (($lines[.ticket] // .title) | gsub("[\r\n]+"; " ") | .[0:160]) as $t
  | "- \($t) ([\(.ticket)](https://linear.app/issue/\(.ticket)))";
def part($head; $kind): [$items[] | select(.kind == $kind)] | if length == 0 then "" else "\n\n**\($head)**\n" + (map(line) | join("\n")) end;
"### Shipped this week\n"
+ (if $items == null then "Could not read what was deployed this week."
   elif ($items | length) == 0 then "Nothing shipped this week."
   else (part("New"; "feature") + part("Fixes"; "fix") + part("Reverts"; "revert")) | ltrimstr("\n\n") end)
