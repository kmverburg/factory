# Deploy watch

After an app deploys, the factory watches production for an hour. If things got clearly worse it opens a **revert PR** and a ticket for Koen; if not, it says so on the ticket. It never reverts on its own: the revert PR is never auto-merged.

Code: `agents/deploywatch/` (`watch.sh`, `compare.jq`, `defaults.json`, `test.sh`). Schedule: `.github/workflows/deploy-watch.yml`, every 15 minutes. Comparing and thresholds are plain code, there is no LLM in it.

## How it works
1. For every app in `agents/scout/apps.json` it lists the app repo's successful runs of the deploy workflow on `main` (push events). A deploy counts for 4 hours after it finished (`WATCH_LOOKBACK_HOURS`), so a missed tick is caught up.
2. Once the hour after a deploy is over it reads Workers Logs (same query code and `CLOUDFLARE_OBSERVABILITY_TOKEN` as the log scout, `agents/scout/fetch.sh`) for the **24 hours before** the deploy and the **hour after** it: `event = request` lines (`status`, `ms`) and error-level lines. A newer deploy within the hour ends the watch early: the older one is skipped and the newer one is judged on its own.
3. It compares error rate (errors per request), 5xx rate (share of requests) and request time (p95 of `ms`).
4. The ticket named in the merge commit title (`KV-12: …`) gets one comment with the outcome. A hidden marker in it (`<!-- deploy-watch:<sha> -->`) makes later runs skip that deploy.

## Outcomes
- **All normal:** a comment "✅ Watched for an hour after deploy, all normal" on the original ticket.
- **Not enough traffic:** fewer than `min_requests` requests in the hour (or in the 24 hours before): no comparison, the comment says "not enough traffic to judge". No false alarms on quiet apps.
- **Worse:** the factory
  - creates a ticket "Revert: <original ticket>" in the app's Linear project, state **Needs Human**, labels **Origin › Agent** and **Delivery › Human involved**, with the numbers that triggered it;
  - opens a revert PR (`git revert` of the merge, with the factory app's token) from a branch that starts with the new ticket's identifier, so Linear links it; the PR is labelled `factory-revert` and `needs-human`, not `agent-built`, so the reviewer never auto-merges it (a revert that touches `.github/` is escalated too);
  - comments on the original ticket with the ticket and PR links.
  If the revert does not apply cleanly (later changes touch the same code) there is no PR: the ticket says so and Koen reverts by hand. Koen merges the PR, or approves it from Linear once KV-45 is in.

## Thresholds
Defaults in `agents/deploywatch/defaults.json`, overridden per app by a `watch` object in the app's `apps.json` entry:

| Setting | Default | Meaning |
|---|---|---|
| `workflow` | `deploy.yml` | The app's deploy workflow (file name or name) |
| `min_requests` | 50 | Fewer requests than this in the hour or the 24 h before: "not enough traffic" |
| `error_ratio` / `min_errors` | 2 / 5 | Error rate more than 2x the baseline **and** at least 5 errors in the hour |
| `error_5xx_ratio` / `min_5xx` | 2 / 5 | Same for the share of 5xx responses |
| `p95_slower_pct` / `p95_min_increase_ms` | 50 / 100 | p95 more than 50% slower **and** at least 100 ms slower |
| `enabled` | true | `false` turns the watch off for the app |

Example: `{"project": "Feast", "repo": "feast", "worker": "feast", "watch": {"workflow": "deploy.yml", "min_requests": 200}}`. The factory's own relay is not watched (the daily health check covers it).

## Dry run
`bash agents/deploywatch/watch.sh --dry-run` (needs `GH_TOKEN` or a logged-in `gh`, `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_OBSERVABILITY_TOKEN`, `GITHUB_OWNER`) prints the comparison for each recent deploy, including one whose hour isn't over yet ("so far"), and what it would open. It opens and comments nothing. In Actions: *Deploy watch* → Run workflow (dry run is the default). `bash agents/deploywatch/test.sh` runs the tests on recorded data.

## Notes
- Needs the repo secrets `FACTORY_APP_ID`, `FACTORY_APP_PRIVATE_KEY`, `CLOUDFLARE_OBSERVABILITY_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `LINEAR_API_KEY`. The factory app needs **Actions: Read** on the app repos (to list deploy runs), besides the contents and pull-request access it already has.
- A query returns at most 2000 events. On a busy app the 24-hour baseline then covers only part of the day; the run warns when that happens.
- Apps must log `event: "request"` lines with `status` and `ms` (Backpack since KV-30, Feast already); without them the app always reads as "not enough traffic".
