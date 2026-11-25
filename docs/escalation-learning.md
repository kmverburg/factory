# Short escalations and learning from approvals

## What Koen sees

Every escalated PR comment and Linear comment from the reviewer starts with **What you need to decide**: one or two sentences, a yes/no question where possible ("Allow adding Vitest as a dev-only dependency?"). Below it come the details, kept short: what changed (`summary`, two sentences), why it was escalated (`reasons`, three items) and what was checked (`checks`, one line). The reviewer writes the question as `decision_needed` in its verdict; if it leaves it out, `agents/review/publish.sh` uses "Approve this PR anyway?" plus the first reason.

## Reason categories

The reviewer gives each escalation one or more fixed categories (`categories` in the verdict, listed in `agents/review/categories.json`): `dependency-dev`, `dependency-runtime`, `schema`, `data-deletion`, `infra-config`, `large-change`, `off-ticket`, `unverifiable`, `failed-check`, `fix-cap`, `workflow-change`, `security`, `factory-rule`, `other`. `publish.sh` drops unknown ids, uses `other` when none is left, adds `workflow-change` itself for any change under `.github/` and `fix-cap` when fix rounds ran out. The categories go into the PR comment as a hidden marker, `<!-- factory-escalation: dependency-dev -->`.

## Learning

Nothing is stored separately; the counts are computed from GitHub each time. After every review, `agents/review/learn.sh` reads the repo's closed PRs with the `needs-human` label (last 100) and uses `agents/review/learn.jq` to work out, per category, the escalations in order. An escalation counts as **approved unchanged** when the PR was merged by a human (not a bot) and has no commit after its (last) escalation comment; merging the base branch in doesn't count as a change. A PR that was changed after the escalation, or closed without merging, ends the streak; open PRs are ignored.

When a category has 3 approvals unchanged in a row (and again at 6, 9, …), `learn.sh` files a ticket through the issue writer in the project of the ticket being reviewed: Todo, **Origin › Agent**, label `factory:rule-proposal`, never Agent Ready. It says what the rule would be, lists the PRs it is based on and names the file that would change (the escalate list in `agents/review/prompt.md` for every repo, or the "Factory review rules" in the repo's `CLAUDE.md`). It carries `Escalation rule: <category>` so an open proposal gets a comment instead of a duplicate. **Nothing changes until Koen approves the ticket.**

Categories with `"propose": false` in `categories.json` never get a proposal: `workflow-change`, `security` (authentication, authorisation, payments, secrets, encryption, personal data), `factory-rule` and `other`. These always stay with Koen.

Tests: `bash agents/review/test-learn.sh` (streaks, breaks, never-categories, the ticket), plus the escalation checks in `agents/ci/smoke-test.sh`.
