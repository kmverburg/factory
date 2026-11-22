# Issue writer

One way to create Linear tickets, so every ticket the factory creates looks and behaves the same, and a rough note from Koen becomes a proper ticket in seconds.

Code: `agents/lib/issue-writer.sh` (`issue_write`, `issue_format`, `linear_create_follow_ups`, `linear_create_manual_tickets`), tests in `agents/lib/test-issue-writer.sh`. Rough notes: `agents/issue-writer/` and `.github/workflows/issue-writer.yml`, tests in `agents/issue-writer/test.sh`.

## What every ticket looks like

```
## Goal
## Steps                  (only for manual tickets: numbered, exact)
## Acceptance criteria    (checklist; "The goal above is met." when none is given)
## Out of scope
+++ Agent notes ... +++   (collapsible; "None." when empty; lists related tickets)
---
footer                    (for example the signature, or Koen's original words)
```

## Rules it applies

| | |
|---|---|
| **Labels** | **Origin** (Agent by default, Human for Koen's notes), `factory:manual` for manual work, **Delivery** only when known (`Human involved` or `Autonomous`), plus extra labels (`source:logs`, `factory:follow-up`, …), created when missing. |
| **Assignee** | Koen (`FACTORY_OWNER_EMAIL`, default `linear@kmverburg.nl`) for manual work, nobody for agent work. |
| **Status** | `triage` (Todo when the team has no triage), `todo`, `needs human` or `blocked`. `blocked` needs at least one `blocked_by` ticket and gets a *blocked by* relation for each; without one it becomes Todo with a warning. It never uses Agent Ready: Koen moves tickets there. |
| **Relations** | `blocked_by` (those block the new ticket), `blocks` (the new ticket blocks those, which move to Blocked), `related`. |
| **Deduplication** | `dedup: true` matches an open ticket in the same project with the same title; `dedup_marker` matches text in the description (a signature). A match gets a comment instead of a new ticket. If the open tickets can't be listed, nothing is created. |

## Who uses it

- The reviewer's follow-ups (`agents/review/publish.sh` → `linear_create_follow_ups`): Todo, Origin › Agent, `factory:follow-up`, deduplicated by title.
- The log scout (`agents/scout/scout.sh`): Triage, `source:logs`. It matches open tickets by signature itself first (to post its richer "seen again" comment), then lets the writer create the rest.
- The caller sync (`agents/sync/sync-caller.sh`): Needs Human, Delivery › Human involved.
- The health check (`agents/health/health.sh`): Todo, `factory:health`. It updates its own open ticket in place with the same format.
- Manual tickets from the builder and the reviewer (below).
- Rough notes from Koen (below).

- The deploy watch (`agents/watch/watch.sh`): "Revert: …" tickets, Needs Human, Delivery › Human involved, related to the original, deduplicated by commit.

**Every part of the factory that creates a ticket must use the issue writer.** So does anything new.

## Manual work becomes its own ticket

The builder and the reviewer may only call something manual after checking they can't do or confirm it themselves (read a public repo, call the GitHub or Linear API, run the command). The prompts say so.

- **Builder:** if the ticket can't be done without manual work, it makes no code changes and writes `.factory/MANUAL_TASKS.json` (`[{title, why, steps}]`). `agents/build/publish.sh` creates one ticket per task: `factory:manual`, assigned to Koen, exact steps, **blocking** the original, which moves to **Blocked**. When Koen sets the manual ticket to Done, the relay releases the original (see README, "Blocked tickets and Auto-start"). If the tickets can't be created, the original goes to Needs Human with the tasks as questions.
- **Reviewer:** `manual_tasks` in the verdict, same shape. When it escalates, the tickets block the original (Blocked instead of Needs Human); otherwise they are only related, so an approved PR is not held up.

## Rough notes from Koen

A ticket created in **Triage** with no Origin label, which means a person typed it, gets Origin › Human from the relay and is sent to the factory repo as `factory-issue-writer` (the relay needs `FACTORY_REPO` in `wrangler.jsonc`). The workflow runs `agents/issue-writer/run.sh`; Claude writes the text, the script checks the project and does the Linear calls.

- The note must name the app (`backpack: weight per item?`), or the ticket must already be in a project. The writer never guesses: it asks "Which app?".
- A clear note is rewritten in place (same ticket, so links stay): title, Goal, Acceptance criteria, Out of scope, Agent notes, the right project, Origin › Human. Koen's original title and text stay at the bottom under "Original note from Koen". The ticket stays in Triage; Koen moves it to Agent Ready.
- An unclear note gets its questions (at most 3) as a comment and stays in Triage, untouched. Edit the note or create a new ticket with the answers; a ticket is only picked up when it is created.
- A note about manual work (with exact steps) becomes a `factory:manual` ticket assigned to Koen.
- The note is treated as data: Claude never gets the Linear key, and a rewritten ticket is never moved to Agent Ready.
