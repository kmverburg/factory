# Merge conflicts and the Conflicts status

Koen never has to resolve a merge conflict on an agent PR, including PRs that wait for his decision (`needs-human`). The flow is described in the README under "Keeping PRs up to date"; this page has the details that are easy to get wrong.

- **Update job** (`agents/update/update.sh`): a PR that conflicts with its base gets the ticket in **Conflicts** (comment with the files), `agent-fixing`, and a `factory-fix` event with `conflict: true`. `needs-human` is never removed. A PR with `agent-fixing` is not sent again. Deploy-watch reverts and PRs without a ticket identifier are left to Koen; their ticket stays in Conflicts with a comment (said once).
- **Builder** (`agents/build/prepare.sh`, `publish.sh`): every fix round starts with `git merge --no-commit --no-ff origin/<base>`. Markers and the file list, or "clean", go into `.factory/review-feedback.md`. Publish refuses to push markers, checks `git merge-base --is-ancestor origin/<base> HEAD` and then GitHub's `mergeable` field; a failed check counts as a failed round (Needs Human).
- **Reviewer** (`agents/review/gather.sh`, `publish.sh`): reads `gh pr view --json mergeable`. A conflicting PR is never approved (conflict round instead). After a conflict round it comments which files conflicted and how they were resolved, and an escalated PR stays escalated with its earlier question.
- **Status** (`agents/lib/conflicts.sh`): Conflicts, then Agent Working during the round, then Needs Human (escalated) or In Review. Matched case-insensitively; Done and Canceled tickets are never moved. The relay only builds from Agent Ready; the stuck check never treats Conflicts as stuck while a round runs.
- **Secrets**: the update job needs `LINEAR_API_KEY`; the callers pass it with `secrets: inherit`.

Tests: `bash agents/update/test.sh`, `bash agents/build/test.sh`, `bash agents/ci/smoke-test.sh`, `bash agents/health/test-stuck.sh`.
