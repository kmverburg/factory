#!/usr/bin/env bash
# Issue writer for rough notes: rewrites a new Triage ticket Koen typed (relay event factory-issue-writer) into a proper
# ticket in the right project (Origin › Human, Koen's own words kept at the bottom), or comments questions and leaves it
# in Triage. Claude only writes the text; this script checks the project and does every Linear call.
# Env: LINEAR_API_KEY, CLAUDE_CODE_OAUTH_TOKEN, IDENTIFIER, ISSUE_TITLE, ISSUE_DESCRIPTION, ISSUE_PROJECT, PROJECTS (JSON list of names).
# Optional: WRITER_CLAUDE (command that answers the prompt on stdin, default `claude -p`).
set -eo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/../lib/linear.sh"
source "$here/../lib/issue-writer.sh"

projects=${PROJECTS:-[]}
note=$ISSUE_DESCRIPTION
# Already rewritten (the original words are kept under this heading): never do it twice.
if grep -qF "Original note from Koen" <<<"$note"; then echo "$IDENTIFIER was already rewritten; nothing to do."; exit 0; fi

prompt=$(python3 -c '
import os, re, sys
v = {"PROJECTS": ", ".join(__import__("json").loads(os.environ.get("PROJECTS") or "[]")), "PROJECT": os.environ.get("ISSUE_PROJECT") or "(none)",
     "TITLE": os.environ.get("ISSUE_TITLE", ""), "NOTE": os.environ.get("ISSUE_DESCRIPTION") or "(no description)"}
print(re.sub(r"\{\{([A-Z]+)\}\}", lambda m: v.get(m.group(1), ""), open(sys.argv[1]).read().replace("\r", "")))
' "$here/prompt.md")

# Claude never sees the Linear key.
if [ -n "$WRITER_CLAUDE" ]; then answer=$(env -u LINEAR_API_KEY bash -c "$WRITER_CLAUDE" <<<"$prompt") || answer=""
else answer=$(env -u LINEAR_API_KEY claude -p --max-turns 3 <<<"$prompt" 2>/dev/null) || answer=""; fi
# Take the JSON object out of the answer, even when it is wrapped in a code fence.
result=$(printf '%s\n' "$answer" | sed '/^```/d' | jq -c -s 'try (map(select(type == "object"))[0]) // empty' 2>/dev/null) || result=""
if [ -z "$result" ]; then result=$(printf '%s' "$answer" | python3 -c '
import json, sys
t = sys.stdin.read(); a = t.find("{"); b = t.rfind("}")
try: print(json.dumps(json.loads(t[a:b+1])))
except Exception: pass'); fi

ask() { # $1 = questions JSON array
  linear_comment "$IDENTIFIER" "$(printf '🤔 The issue writer needs a bit more before it can turn this note into a ticket:\n\n'; jq -r '.[] | "- \(.)"' <<<"$1"; printf '\nThe ticket stays in Triage. Edit the note, or create a new ticket with the answers.')"
  echo "Asked questions on $IDENTIFIER"
}

if [ -z "$result" ] || ! jq -e '.status == "ready" or .status == "questions"' <<<"$result" >/dev/null 2>&1; then
  echo "::warning::The issue writer got no usable answer for $IDENTIFIER"
  ask '["I could not make a ticket out of this note. Could you say a bit more about what you want, and for which app?"]'
  exit 0
fi
if [ "$(jq -r .status <<<"$result")" = questions ]; then
  q=$(jq -c '[.questions[]? | select(type == "string" and . != "")] | .[:3]' <<<"$result")
  [ "$q" != "[]" ] || q='["Could you say a bit more about what you want, and for which app?"]'
  ask "$q"; exit 0
fi

# The project: must be one of the known projects, and named in the note unless the ticket is already in one. Never guessed.
project=$(jq -r --argjson p "$projects" '. as $r | ($p | map(select(ascii_downcase == ($r.project // "" | ascii_downcase)))[0]) // empty' <<<"$result")
if [ -z "$project" ]; then
  ask "$(jq -nc --argjson p "$projects" '["Which app is this for? I know: \($p | join(", "))."]')"; exit 0
fi
if [ -z "$ISSUE_PROJECT" ] && ! grep -qiF -- "$project" <<<"$ISSUE_TITLE $note"; then
  ask "$(jq -nc --arg p "$project" '["The note does not say which app it is for (my guess would be \($p), but I do not guess). Which app?"]')"; exit 0
fi
if [ -n "$ISSUE_PROJECT" ] && [ "$(tr '[:upper:]' '[:lower:]' <<<"$ISSUE_PROJECT")" != "$(tr '[:upper:]' '[:lower:]' <<<"$project")" ] && ! grep -qiF -- "$project" <<<"$ISSUE_TITLE $note"; then
  project=$ISSUE_PROJECT
fi

original=$(printf '%s' "$ISSUE_TITLE${note:+$'\n\n'$note}" | sed 's/^/> /')
spec=$(jq -c --arg p "$project" --arg id "$IDENTIFIER" --arg o "Original note from Koen (title and text as he typed them):
$original" '
  {update: $id, project: $p, title: (.title // ""), goal: (.goal // ""), acceptance: (.acceptance // []), out_of_scope: (.out_of_scope // []),
   agent_notes: (.agent_notes // ""), steps: (.steps // []), manual: (.manual == true and ((.steps // []) | length) > 0),
   origin: "Human", footer: $o}' <<<"$result")
if [ "$(jq -r '.title == "" or .goal == ""' <<<"$spec")" = true ]; then
  ask '["I could not make a ticket out of this note. Could you say a bit more about what you want?"]'; exit 0
fi
out=$(issue_write "$spec") || out=""
case "$out" in
  "updated "*) echo "Rewrote $IDENTIFIER in $project"
    linear_comment "$IDENTIFIER" "🏭 The issue writer turned your note into a ticket in **$project**. Your original words are at the bottom. Check it, then move it to **Agent Ready** when it is right." ;;
  *) echo "::error::Could not rewrite $IDENTIFIER"; exit 1 ;;
esac
