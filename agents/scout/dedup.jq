# Usage: jq -n --argjson groups G --argjson open O -f dedup.jq
# O = open source:logs issues [{id, identifier, description}]. A group matches an issue whose
# description contains the group's signature. Output: {existing: [{group, issue}], new: [group]}.
{
  existing: [ $groups[] as $g | ($open | map(select((.description // "") | contains($g.signature))) | .[0]) as $i
              | select($i != null) | {group: $g, issue: $i} ],
  new: [ $groups[] as $g | select(($open | map(select((.description // "") | contains($g.signature))) | length) == 0) ]
}
