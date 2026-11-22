# Deploy watch

After an app deploys a merge to `main`, the factory watches production for an hour. If things clearly got worse it opens a **revert PR** and a **Needs Human** ticket right away; if all is normal it says so on the ticket.

Code: `agents/watch/` (`watch.sh`, `compare.jq`, `defaults.json`), workflow `.github/workflows/deploy-watch.yml`, tests `bash agents/watch/test.sh`.

## How it works

1. The workflow runs every 15 minutes. For each app in `agents/scout/apps.json` it lists the commits on the default branch of the last hours and finds the ones whose **Workers Builds** check run succeeded (`deploy_check` in the settings). The check's completion time is the deploy time. A commit counts only if its title starts with a ticket id (`KV-46: …`, as squash merges of factory PRs do), because that ticket is where the result goes.
2. When the hour after a deploy is over (up to 8 hours later, in case runs were missed), it compares **that hour** with the **24 hours before the deploy**, from the same Workers Logs data as the log scout (same Cloudflare token, `agents/scout/fetch.sh`):
   - **error rate**: error log lines per request,
   - **5xx rate**: share of `event: "request"` lines with status 500–599,
   - **request time**: p95 of `ms` on those lines.
3. If another deploy follows inside the hour, the window ends there; under 20 minutes it isn't judged on its own (the newer deploy is compared with the 24 hours before it).
4. The result is a comment on the ticket, which also marks the deploy as judged (`Deploy watch (\`abc1234\`)`), so nothing is reported twice:
   - **Normal:** `✅ … watched for 60 minutes after the deploy, all normal` with the numbers.
   - **Too little traffic:** `not enough traffic to judge`, no comparison. This also applies when the 24 hours before have too few requests.
   - **Clearly worse:** a ticket "Revert: <original ticket>" in the app's project (Needs Human, Origin › Agent, Delivery › Human involved, related to the original) with the numbers that triggered it; a **revert PR** (`git revert` of the merge, branch `<revert ticket>-revert-<ticket>`, title `<revert ticket>: Revert "…"`) opened with the factory app's token; and a comment on the original ticket linking both. If the revert doesn't apply cleanly (later commits touch the same lines) there is no PR: the ticket says to revert by hand.

## Revert PRs are never merged automatically

The PR has the labels `agent-built` and `deploy-revert`. The reviewer doesn't treat it as a factory PR (never auto-merge, no fix rounds), a failed check doesn't start a re-review, and the update job doesn't send its merge conflicts to the builder. Koen decides: merge it, or comment `approve` on the revert ticket ([Linear comment commands](linear-commands.md)), or close it if the numbers are fine.

## Settings

Defaults are in `agents/watch/defaults.json`. An app overrides them with a `"watch"` object next to its entry in `agents/scout/apps.json` (`"watch": false` turns watching off for that app):

| Setting | Default | Meaning |
|---|---|---|
| `window_minutes` | 60 | how long after the deploy to watch |
| `baseline_hours` | 24 | how far back the comparison starts |
| `min_requests` | 30 | requests needed after the deploy **and** before it; fewer → "not enough traffic to judge" |
| `factor` | 2 | error and 5xx rate must exceed this many times the old rate |
| `min_errors` | 5 | errors needed after the deploy before the error rate counts |
| `min_5xx` | 5 | 5xx responses needed before the 5xx rate counts |
| `p95_pct` | 50 | p95 must be this many percent slower |
| `p95_min_ms` | 100 | …and at least this many ms slower, so tiny numbers don't alarm |
| `deploy_check` | `Workers Builds` | regular expression (case-insensitive) matching the name of the deploy's check run |

Example: `{"project": "Feast", "repo": "feast", "worker": "feast", "watch": {"min_requests": 100, "p95_pct": 80}}`.

## Try it

- `bash agents/watch/watch.sh --dry-run` (needs `gh` logged in, `GITHUB_OWNER`, `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_OBSERVABILITY_TOKEN`) prints the comparison for the deploys of the last 24 hours, with the window so far, and touches nothing (no Linear key needed).
- GitHub → Actions → *Deploy watch* → *Run workflow*, keep **Dry run** ticked. Untick it to run for real.

## Limits

- Workers Logs returns at most 2000 events per query. When a query hits that limit it only covers the newest events, so the comparison starts where both queries have data (a warning says so); if the data doesn't reach back to the deploy, the ticket gets "too many log lines to compare".
- Merges without a ticket id in the commit title aren't watched. The factory's own relay isn't watched here (see the health check).
- It needs the log lines `event: "request"` with `status` and `ms`; without them an app reads as "not enough traffic".
- Secrets: `CLOUDFLARE_OBSERVABILITY_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `LINEAR_API_KEY`, and the factory app (`FACTORY_APP_ID`, `FACTORY_APP_PRIVATE_KEY`), which needs write access to the app repos' contents and pull requests (it already has it).
