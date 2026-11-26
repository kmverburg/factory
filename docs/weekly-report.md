# Weekly factory report

Every Monday `agents/report/report.sh` (`.github/workflows/weekly-report.yml`, 07:00 UTC, after the log scout and the dependency check) posts a **project update on the Factory project** in Linear. It shows the past 7 days next to the 7 days before, so you can see where the factory gets stuck. Nothing is posted outside Linear.

Run it by hand: `bash agents/report/report.sh --dry-run` (needs `LINEAR_API_KEY`; prints the update, posts nothing), or start the workflow with *dry run* ticked (the default for manual runs). Test: `bash agents/report/test.sh`.

## The numbers

All numbers are counted in code (`compute.jq`) from every ticket of the Factory team that changed in the last 14 days: its labels, state history and comments. Claude only words the suggestions.

| Number | How it is counted |
|---|---|
| Tickets finished | Tickets whose `completedAt` falls in the week. |
| Autonomous / Human involved | The **Delivery** label of those tickets. Tickets without a Delivery label (not built by the factory) are left out of the share. |
| Idea from Agent / Human | The **Origin** label of tickets *created* in the week. |
| Lead time (median, slowest) | From the last move to **Agent Ready** before completion to `completedAt` (the merge, when Linear's GitHub link closes the ticket). Tickets that were never in Agent Ready are left out. |
| Fix rounds per finished ticket | "Reviewer asked for fixes" comments on the finished tickets, divided by the number of finished tickets; plus how many tickets needed at least one. |
| 2-round limit hit | Comments in the week saying a PR still needed fixes after the automatic rounds (`MAX_FIX_ROUNDS`). |
| Escalations and reasons | "Reviewer agent wants you to look at …" comments in the week. The reasons are the bullet points; numbers and links are replaced (`N`, `<link>`) so the same reason groups together. Top 5. |
| Failed runs and causes | "The factory build/fix run failed" comments in the week. The cause is the first line of what Claude reported, normalised the same way, or "no cause reported". Top 5. |

## Health

- **On track**: failed runs did not go up and the autonomous share did not go down.
- **At risk**: failed runs went up, or the autonomous share went down (needs finished tickets in both weeks).
- **Off track**: both, and at least 3 failed runs this week.

## Suggestions

Two or three bullets from Claude (`agents/report/prompt.md`) based only on the escalation reasons, failure causes and round-limit count, aimed at raising the autonomous share. If Claude is unavailable the report lists the top escalation reasons instead.

## Limits

Counts depend on the comment texts of the reviewer and builder (`agents/review/publish.sh`, `agents/build/report-failure.sh`); if those change, update `compute.jq` and its test. Only the first 1000 tickets of two weeks are read.
