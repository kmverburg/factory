# Input: {prs: [{number, url, title, state, mergedAt, mergedBy: {login, is_bot}, comments: [{body, createdAt}],
#                commits: [{committedDate, messageHeadline}]}], cats: [{id, label, propose}], streak: 3}
# Output: one entry per category whose latest escalations were approved unchanged `streak` times in a row (and again
# after every further `streak`), for categories that may become a rule: {id, label, streak, prs: [{number, url, title}]}.
# "Approved unchanged" = merged by a human (not a bot) with no commit after the escalation comment (merges of the base
# branch don't count). A PR that was escalated and then changed, or closed without merging, breaks the streak;
# PRs that are still open are ignored.
def marker: "<!-- factory-escalation:";
def escalation:
  ([.comments[]? | select((.body // "") | contains(marker))] | sort_by(.createdAt) | last) as $c
  | if $c == null then null else
      {at: $c.createdAt,
       cats: ($c.body | capture("<!-- factory-escalation: (?<c>[a-z-,]+) -->").c // "" | split(",") | map(select(. != "")))}
    end;
. as $in
| [ .prs[]
    | . as $pr
    | escalation as $e
    | select($e != null and (.state == "MERGED" or .state == "CLOSED"))
    | {number, url, title, at: $e.at, cats: $e.cats,
       unchanged: (.state == "MERGED" and (.mergedBy.is_bot == false)
                   and ([.commits[]? | select(.committedDate > $e.at and ((.messageHeadline // "") | test("^Merge (branch|remote-tracking)") | not))] | length == 0))} ]
| sort_by(.at) as $esc
| $in.cats[] | select(.propose) | . as $cat
| [$esc[] | select(.cats | index($cat.id))] as $mine
| ([$mine | reverse | .[].unchanged] | (index(false) // length)) as $streak
| select($streak >= $in.streak and ($streak % $in.streak) == 0)
| {id: $cat.id, label: $cat.label, streak: $streak, prs: [$mine[-$in.streak:][] | {number, url, title}]}
