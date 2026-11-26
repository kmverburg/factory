#!/usr/bin/env bash
# Learn from escalations (docs/escalation-learning.md). Looks at the repo's past escalated PRs and, for each reason
# category Koen approved unchanged 3 times in a row, files one Todo ticket (Origin › Agent) proposing a rule.
# Never for categories with "propose": false in categories.json (workflows, security, factory rules). Best effort:
# it never fails a review. Needs FACTORY_DIR, GITHUB_REPOSITORY, IDENTIFIER (the ticket whose project gets the proposal).
# Usage: learn.sh            (RULE_STREAK, default 3, is the number of approvals in a row)
set -eo pipefail
[ -n "$IDENTIFIER" ] || exit 0
# shellcheck source=/dev/null
source "$FACTORY_DIR/agents/lib/linear.sh"
# shellcheck source=/dev/null
source "$FACTORY_DIR/agents/lib/issue-writer.sh"
here="$FACTORY_DIR/agents/review"
streak=${RULE_STREAK:-3}

prs=$(gh pr list --repo "$GITHUB_REPOSITORY" --state closed --label needs-human --limit 100 \
  --json number,url,title,state,mergedAt,mergedBy,comments,commits 2>/dev/null) || { echo "::warning::Could not list past escalations" >&2; exit 0; }
found=$(jq -c --argjson prs "$prs" --argjson s "$streak" --slurpfile c "$here/categories.json" -n \
  '{prs: $prs, cats: $c[0], streak: $s}' | jq -c -f "$here/learn.jq") || { echo "::warning::Could not evaluate past escalations" >&2; exit 0; }
[ -n "$found" ] || exit 0

data=$(linear_issue "$IDENTIFIER") || { echo "::warning::Linear lookup failed" >&2; exit 0; }
ctx=$(jq -c '.data.issue | {id: (.project.id // null), team: .team}' <<<"$data")
[ "$(jq -r '.team.id // empty' <<<"$ctx")" != "" ] || exit 0
while IFS= read -r item; do
  spec=$(jq -c --arg repo "$GITHUB_REPOSITORY" '
    . as $i
    | {title: ("Propose a rule: don'"'"'t escalate a change that " + $i.label),
       goal: ("Koen approved the escalated PRs below unchanged " + ($i.streak | tostring) + " times in a row, all because the change " + $i.label
              + ". Propose making this a rule so the reviewer stops escalating it."),
       acceptance: ["The ticket says what the rule would be, exactly when it applies and when it still escalates",
                    "It lists the past PRs the rule is based on",
                    "It names the file that would change (the escalate list in agents/review/prompt.md for every repo, or the \"Factory review rules\" in the repo'"'"'s CLAUDE.md for this repo only)",
                    "Nothing changes until Koen approves this ticket"],
       out_of_scope: ["Changing any rule before Koen approves this proposal", "Workflow changes, secrets and security, which always stay with Koen"],
       agent_notes: ("Escalation rule: `" + $i.id + "`\nRepo: " + $repo + "\nBased on:\n" + ($i.prs | map("- " + .url + " " + .title) | join("\n"))),
       origin: "Agent", state: "todo", labels: ["factory:rule-proposal"],
       dedup_marker: ("Escalation rule: `" + $i.id + "`\nRepo: " + $repo),
       dedup_comment: ("Koen approved this kind of escalation unchanged " + ($i.streak | tostring) + " times in a row again.")}' <<<"$item")
  issue_write "$spec" "$ctx" >/dev/null || true
done <<<"$found"
exit 0
