# Factory

Linear tickets in, reviewed pull requests out.

```
Linear issue → "Agent Ready"
   │  webhook
   ▼
relay/ (Cloudflare Worker) ── finds the repo for the issue's project
   │  repository_dispatch "factory-build"
   ▼
app repo: factory.yml → build.yml (builder agent) → opens PR, issue → "Agent Working"
                      → review.yml (reviewer agent) → label agent-approved
                                                     or needs-human + Linear "Needs Human"
```

## What's in here

| Path | What it is |
|---|---|
| `relay/` | Cloudflare Worker that turns Linear webhooks into GitHub builds |
| `.github/workflows/build.yml` | Reusable builder agent workflow |
| `.github/workflows/review.yml` | Reusable reviewer agent workflow |
| `.github/workflows/sync-caller.yml` | Sends caller workflow changes to the app repos |
| `.github/workflows/health.yml` | Daily self-check that files "Factory health: …" tickets, see [docs/health-check.md](docs/health-check.md) |
| `.github/workflows/stuck.yml` | Hourly check that retries tickets and PRs whose run died, see [docs/health-check.md](docs/health-check.md#stuck-tickets-and-prs-hourly) |
| `agents/lib/issue-writer.sh`, `agents/issue-writer/` | The issue writer: the one way tickets are created, and rough notes from Koen become proper tickets, see [docs/issue-writer.md](docs/issue-writer.md) |
| `.github/workflows/issue-writer.yml` | Rewrites rough notes in Triage into proper tickets |
| `templates/app-repo/` | The two files every app repo needs |
| `templates/linear-issue-template.md` | Paste into Linear as your issue template |

## Setup (in this order)

### 1. Push this repo to GitHub
Create a repo called `factory` under the same account that owns your app repos, and push this folder to it.

If it's **private**: Settings → Actions → General → Access → choose *Accessible from repositories owned by you*. Otherwise your app repos can't use its workflows.

### 2. Connect the Worker to this repo
In Cloudflare: Workers & Pages → `factory` → Settings → Build → Connect, and pick this repo.
- Root directory: `relay`
- Deploy command: `npx wrangler deploy`

The Worker's name in Cloudflare must match `name` in `relay/wrangler.jsonc` (`factory`).

PR branches get a Worker Preview (`npx wrangler preview`). Its settings come from the `previews` block in `relay/wrangler.jsonc`: the same state names, no repos and no secrets, so a preview can't start builds or accept webhooks. Never add production secrets to that block or to the Previews Base settings in Cloudflare.

Then edit `PROJECT_REPOS` in `relay/wrangler.jsonc`: one line per app, mapping the **exact Linear project name** to the repo name (`backpack`; `owner/repo` also works). The owner comes from `GITHUB_OWNER` in the same file (also set in the `previews` block). Every push to `main` redeploys the Worker.

### 3. Worker secrets
Don't add these by hand in Cloudflare. Set them in Infisical, folder `/cloudflare/factory-relay` (see [Secrets](#secrets)), and let the sync write them to the `factory` Worker:
- `LINEAR_API_KEY` (lives in `/shared` and is referenced from this folder)
- `FACTORY_APP_ID` and `FACTORY_APP_PRIVATE_KEY`: the factory GitHub App's credentials, referenced from `/shared` (for example `${prod.shared.FACTORY_APP_ID}`). The relay signs a JWT with the key and creates a short-lived installation token per owner (cached until 5 minutes before it expires). The app needs *Contents: Read and write* and *Pull requests: Read* on your app repos. The key may be GitHub's PKCS#1 PEM (`BEGIN RSA PRIVATE KEY`) or PKCS#8 as is.
- `GITHUB_TOKEN` (optional fallback): a fine-grained personal token with *Contents: Read and write*. Used only while `FACTORY_APP_ID` isn't set; delete it, and the token on GitHub, once the app works.
- `LINEAR_WEBHOOK_SECRET`: from step 4

### 4. Linear webhook
Linear → Settings → API → Webhooks → New webhook.
- URL: the relay's URL (`https://relay.kmverburg.nl`)
- Events: **Issues**

Store the signing secret in Infisical as `LINEAR_WEBHOOK_SECRET` (folder `/cloudflare/factory-relay`); don't paste it into Cloudflare. Opening the Worker URL in a browser should show "factory-relay is running".

### 5. Each app repo
1. Copy `templates/app-repo/.github/workflows/factory.yml` into the repo (it already points at `kmverburg/factory`; see [Changing the GitHub owner](#changing-the-github-owner)).
2. Copy `templates/app-repo/CLAUDE.md` to the repo root and fill it in. Good commands here make both agents much better.
3. Repo secrets: don't add them by hand. Add the repo as a sync destination for the `/shared` folder in Infisical, so it gets `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`), `LINEAR_API_KEY`, `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`. See [Secrets](#secrets).
4. Settings → Actions → General → Workflow permissions: tick **Allow GitHub Actions to create and approve pull requests**.
5. Make sure the Claude GitHub App is installed on the repo.

### 6. Linear ↔ GitHub
Install Linear's GitHub integration and turn on its pull request automations, so an opened PR moves the issue to In Review and a merged PR moves it to Done. Agent branches start with the issue ID (e.g. `fac-12-fix-login`), which is how Linear links them.

### 7. First test
Create a small, low-risk issue in a mapped project and move it to **Agent Ready**. Within a minute the issue should get a "Picked up by the factory" comment and move to **Agent Working**.

## Secrets

All secrets live in one Infisical project, `factory`, environment `prod`. There is one folder per destination, and each folder is synced to exactly one place. A secret used in several places is stored once in `/shared`. To change or rotate a secret, edit it in Infisical and the sync updates every destination. Never edit secrets directly in GitHub or Cloudflare, as the next sync overwrites them.

| Secret | What it's for | Infisical folder → destination |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Lets the agents run Claude | `/shared` → factory, backpack and feast repos |
| `LINEAR_API_KEY` | Lets the agents and the relay read and update Linear issues | `/shared` → all three repos; referenced by `/cloudflare/factory-relay` |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account for deploys and API calls | `/shared` → all three repos |
| `CLOUDFLARE_API_TOKEN` | Deploy token for the apps (one token shared by all apps for now) | `/shared` → all three repos |
| `FACTORY_APP_ID` | ID of the factory's GitHub App, so agents act under their own identity ([KOE-13](https://linear.app/koenv/issue/KOE-13/give-the-factory-its-own-github-app-identity)) | `/shared` → all three repos |
| `FACTORY_APP_PRIVATE_KEY` | Private key of that GitHub App | `/shared` → all three repos |
| `CLOUDFLARE_BUILDS_TOKEN` | Read-only token that lets the reviewer read Cloudflare build results ([KOE-15](https://linear.app/koenv/issue/KOE-15/treat-failing-ci-checks-on-agent-prs-as-something-to-fix)) | `/github/factory` → app repos |
| `CLOUDFLARE_OBSERVABILITY_TOKEN` | Read-only token that lets the log scout read Workers Logs ([KOE-17](https://linear.app/koenv/issue/KOE-17/log-scout-turn-app-errors-into-linear-tickets)) | `/github/factory` → factory repo |
| `LINEAR_WEBHOOK_SECRET` | Verifies that webhooks really come from Linear | `/cloudflare/factory-relay` → `factory` Worker |
| `HEALTH_CHECK_SECRET` | Lets the daily health check ask the relay whether its GitHub app credentials work ([docs/health-check.md](docs/health-check.md)) | `/cloudflare/factory-relay` → `factory` Worker, and the same value in the folder synced to the factory repo |
| `FACTORY_APP_ID`, `FACTORY_APP_PRIVATE_KEY` (relay) | Let the relay start builds in the app repos with short-lived installation tokens | `/cloudflare/factory-relay` → `factory` Worker, referenced from `/shared` |
| `GITHUB_TOKEN` (relay, fallback) | Personal token the relay uses only while `FACTORY_APP_ID` isn't set; delete once the app works | `/cloudflare/factory-relay` → `factory` Worker |

### Local development
Run the relay with dummy secrets from Infisical's `dev` environment instead of creating `relay/.dev.vars` by hand:

```
cd relay
infisical run --env=dev --path=/cloudflare/factory-relay -- npx wrangler dev
```

The `dev` environment holds dummy values only, never real secrets. `GET /` should answer "factory-relay is running".

## How decisions are made

- **Builder** won't guess: if a ticket is unclear it comments questions on the Linear issue and moves it to *Needs Human*. It can check UI changes in a headless browser (Python Playwright) before opening the PR.
- **Reviewer** runs the repo's checks, clicks through UI changes in the headless browser, and decides:
  - **approve**: label `agent-approved`, Linear issue to *In Review*.
  - **fix**: label `agent-fixing`; it sends concrete fix instructions back to the builder (`factory-fix` event), which pushes to the same PR, after which the reviewer checks again. At most 2 rounds, then it escalates. Only for PRs the factory opened.
  - **escalate**: label `needs-human`, Linear issue to *Needs Human*. For auth, payments, secrets, personal data, schema changes, dependency or CI changes, more than 400 changed lines, scope problems, "Factory review rules" in the repo's `CLAUDE.md`, or anything it can't verify.
- **Preview and screenshots**: the reviewer opens an app's per-PR preview when its `CLAUDE.md` describes one, and its Linear and PR comments carry the preview link and up to 3 screenshots. See [docs/previews.md](docs/previews.md).
- **Follow-ups**: gaps in the repo itself (no tests, linter, docs) never block a PR. The reviewer files them as Linear issues in *Todo*, labelled `factory:follow-up`, in the same project (max 3 per review, no duplicates of open follow-ups). PRs for follow-up tickets don't create new follow-ups.
- **Auto-merge**: when the final verdict is approve with risk `low` (also after fix rounds) on a PR the factory opened, the reviewer turns on squash auto-merge with the factory app's token (`FACTORY_APP_TOKEN`), and GitHub merges once the required checks pass. Medium or high risk, fix and escalate verdicts, and PRs not opened by the factory never auto-merge. The repo must allow auto-merge (Settings → General). To opt a repo out, put the line `Factory auto-merge: off` in its `CLAUDE.md`. If auto-merge can't be enabled, the PR keeps `agent-approved` and the Linear comment says why; merge it yourself.
- **Re-review after a failed check**: a check that fails after the review (for example a slow Cloudflare Workers Build) starts the reviewer again. The caller workflow listens for `check_run` events that complete with a failure, and `.github/workflows/recheck.yml` (logic in `agents/review/recheck.sh`) decides: only for an open, non-draft PR with the label `agent-built`, only for the check's latest commit, never for the factory's own `build` and `review` checks, and not while a fix round is running (`agent-fixing`). If auto-merge was already on, it is cancelled first (with a PR comment), so nothing merges with a red check; the reviewer turns it back on if it approves again. The check run counts as one extra review per failed check, and the round counter is read from the builder's fix comments, so the 2-round cap on fixes still applies. Limit: GitHub doesn't start workflows for events caused by the workflow token, so this covers checks from other apps (Cloudflare Workers Builds) but may not cover failures of GitHub Actions jobs; those are already waited for by the review that follows the build. An app's own check named exactly `build` or `review` is treated as a factory check and ignored.
- **Keeping PRs up to date**: tickets in a repo run at the same time, so `main` moves while agent PRs are open. The caller workflow has a `push` trigger for `main` and an `update` job (`.github/workflows/update.yml`, logic in `agents/update/update.sh`) that also runs after every review. For each open, non-draft PR labelled `agent-built` that is behind its base branch:
  - **No conflicts**: the factory merges the base branch into the PR branch and pushes with the app's token, so the checks run again. The PR gets a comment. This also covers PRs with auto-merge on: they are brought up to date before they could merge, so GitHub never merges an out-of-date PR.
  - **Conflicts**: auto-merge is cancelled, the PR gets `agent-fixing` and a `factory-fix` event with `conflict: true` goes to the builder. The builder starts the merge of the base branch in its checkout, gets the conflicting files, the commits that landed on the base branch and the ticket, resolves the conflicts, runs the tests and pushes the merge commit. The reviewer then reviews the result like any fix round. These rounds don't count towards the 2-round limit (the round number is passed on unchanged and the comment isn't a "review fixes" comment).
  - **Can't resolve with confidence**: the builder writes questions instead of guessing. The PR gets `needs-human` and the Linear ticket moves to *Needs Human* with the explanation. Conflict markers are never pushed. While a PR has `needs-human` or `agent-fixing`, later pushes to the base branch don't start another conflict fix.
  - Limit: pushing a base change that touches `.github/workflows/` needs the app's `workflows` permission; without it the push is refused and the run warns. PRs the factory didn't open are never touched.

The workflows are thin: their logic (prompts, bash scripts, Linear helpers) lives in `agents/` and is fetched from `main` at run time. See `CLAUDE.md` for the layout.

### How caller changes reach the app repos
Change the caller workflow once, in `templates/app-repo/.github/workflows/factory.yml` (and this repo's own `.github/workflows/factory.yml` in the same PR). When that template changes on `main`, `.github/workflows/sync-caller.yml` runs `agents/sync/sync-caller.sh` (you can also start it by hand under Actions → *Sync caller workflow*). For every repo in the relay's `PROJECT_REPOS` except this one, it compares the repo's `.github/workflows/factory.yml` with the template, ignoring the leading comment lines, which are repo-specific. If they differ it opens (or updates) one PR titled "<TICKET>: Update factory caller workflow", labelled `factory-sync`, using the factory app's token. **Every PR the factory opens has a Linear ticket.** Before opening the PR, the sync creates a ticket "Merge the factory caller update" in the app's Linear project (the `PROJECT_REPOS` key), in **Needs Human** with labels **Origin › Agent** and **Delivery › Human involved**. The PR's branch (`kv-41-factory-caller-update`) and title start with that ticket's identifier, so Linear links the PR and moves the ticket to Done when it's merged. An open sync PR is updated in place and keeps its ticket, so there are no duplicates. The sync also comments on the ticket named in the merge commit title (like `KV-35: …`) with links to the new tickets and PRs. It needs the `LINEAR_API_KEY` repository secret; if Linear is unreachable it logs a warning and still opens the PRs (with the branch `factory/sync-caller-workflow` and no ticket). Repos that are up to date are left alone, and a failure for one repo doesn't stop the others (the run fails at the end and names them). The PR touches `.github/`, so the reviewer always escalates it and Koen approves it. Test it with `bash agents/sync/test.sh`. The factory app must be installed on every app repo with *Workflows: Read and write* and *Pull requests: Read and write*. Adding an app to `PROJECT_REPOS` includes it in future syncs; the first sync happens on the next template change or manual run.

## Managing the factory with the factory

Issues in the Linear project **Factory** are built and reviewed in this repo, just like an app. Agents can change everything, including workflow files in `.github/`, but only when a ticket asks for it. A PR that touches `.github/` is always escalated (enforced in `agents/review/publish.sh`) and never auto-merges, so Koen approves every workflow change. This needs the factory GitHub App to have *Workflows: Read and write*. The reviewer also always escalates changes to the prompts, the verdict logic and the relay's security, since those change how the factory judges itself. Merged changes to `agents/` go live for every app right away.

One-time setup for this repo, the same as step 5 for an app:
1. Repo secrets `CLAUDE_CODE_OAUTH_TOKEN` and `LINEAR_API_KEY`, synced from Infisical's `/shared` folder (see [Secrets](#secrets)).
2. Settings → Actions → General → *Allow GitHub Actions to create and approve pull requests*.
3. The Claude GitHub App has access to this repo.
4. The factory GitHub App (or, until the relay has `FACTORY_APP_ID`, the relay's `GITHUB_TOKEN`) is installed on this repo with *Contents: Read and write*.

### Linear comment commands

Koen can also approve a PR, ask for changes or answer the builder's questions by commenting on the Linear ticket: see [Linear comment commands](docs/linear-commands.md).

### Blocked tickets and Auto-start

Tickets that wait on other tickets start by themselves. Put the ticket in the **Blocked** status (add it to the *Unstarted* category in the team's statuses) and mark the others as blocking it with Linear's *blocks* relation. When a blocking ticket reaches a Done (completed) or canceled status, the relay checks every ticket it blocks that is in Blocked. If none of that ticket's blockers is still open, it moves:
- to **Agent Ready** (which starts a build like a manual move) if it has the **Auto-start** label and not `factory:manual`;
- to **Todo** otherwise, including every `factory:manual` ticket;
- to **Todo** with a "plan changed" comment if any of its blockers was canceled, never to Agent Ready.

Each move gets a comment naming the ticket that unblocked it. Tickets with open blockers, or not in Blocked, are left alone. Problems (a status or label not found, Linear errors) are logged as warnings and never stop builds. The names are settings in `relay/wrangler.jsonc` (`BLOCKED_STATE`, `TODO_STATE`, `AUTO_START_LABEL`, `MANUAL_LABEL`). Setting a ticket to Blocked is up to whoever creates it.

### Linear labels

Two label groups in each Linear team tell you how a ticket came about and how it was delivered. Create them once in Linear (labels with a parent group); the scripts only add them to tickets and warn if one is missing.
- **Origin** (who had the idea): **Human** is set by the relay on new tickets that have no Origin label. **Agent** is set when the reviewer creates a follow-up ticket and when the log scout creates a ticket (in the same `issueCreate`, so the relay leaves it alone).
- **Delivery** (did agents do it on their own): **Human involved** is set as soon as a human is needed: the reviewer escalates, the builder asks questions or makes no changes, a build or fix run fails, or the reviewer approves without turning on auto-merge (medium/high risk, repo opted out, PR not opened by the factory, or enabling auto-merge failed). **Autonomous** is set when the reviewer approves and turns on auto-merge. Human involved always wins: it replaces Autonomous, and Autonomous never replaces it. Only one Delivery label is on a ticket, other labels are kept.

## Issue writer

Every ticket the factory creates goes through one shared part, `agents/lib/issue-writer.sh`, so they all look the same (Goal, Acceptance criteria, Out of scope, Agent notes) and follow the same rules for labels (Origin, `factory:manual`, Delivery), assignee (Koen for manual work, nobody for agent work), status (Triage, Todo or Blocked with *blocked by* relations) and deduplication (an open ticket gets a comment instead of a duplicate). The reviewer's follow-ups, the log scout, the caller sync and the health check use it. **Every new part that creates tickets must use it too: this includes deploy watching, which has to be added to the writer's users when it is built.**

- **Manual work** the builder or reviewer can't do or confirm themselves (after checking) becomes its own `factory:manual` ticket assigned to Koen with exact steps. It blocks the original ticket, which waits in Blocked until the relay releases it when the manual ticket is Done.
- **Rough notes:** a ticket Koen creates in Triage with just a note (`backpack: weight per item?`) is rewritten into a proper ticket in the right project with Origin › Human, with his words kept at the bottom, or gets questions as a comment. The note must name the app; it is never guessed. Needs `FACTORY_REPO` in the relay's `wrangler.jsonc` and the repo secrets `CLAUDE_CODE_OAUTH_TOKEN` and `LINEAR_API_KEY` in this repo.
- Details: [docs/issue-writer.md](docs/issue-writer.md). Tests: `bash agents/lib/test-issue-writer.sh`, `bash agents/issue-writer/test.sh`.

## Weekly dependency updates

`agents/deps/deps.sh` (`.github/workflows/deps.yml`, Mondays) checks `npm outdated` and `npm audit` in every app repo and this one, and files up to three tickets per repo per week: security fixes (High priority, Agent Ready), routine minor/patch updates (Agent Ready) and major updates (Todo). Versions must be at least 2 weeks old, except security fixes; an open ticket from an earlier week is updated instead of duplicated. See [docs/dependency-updates.md](docs/dependency-updates.md).

## Log scout

`agents/scout/scout.sh` looks for things to improve in each app's Cloudflare Workers Logs (read-only `CLOUDFLARE_OBSERVABILITY_TOKEN` plus `CLOUDFLARE_ACCOUNT_ID`), not just errors. Clear problems become tickets in the app's Linear project in **Triage** (Todo if the team has none), labelled `source:logs` and **Origin › Agent**, never *Agent Ready*; everything else goes into a **weekly health report**, posted on Mondays as a Linear project update. Counting, thresholds and comparisons are plain code; Claude only writes the ticket and report text, and log text is untrusted: masked (emails, tokens), normalised (numbers and ids) and only shown in code blocks.

- **Errors:** grouped by signature (message plus top stack frame) over the last 24 hours, one ticket per new group. An open `source:logs` ticket that carries the signature (`Signature: logsig-…`) gets a comment instead.
- **Signals:** a signal is a Workers Logs filter, what to measure and a threshold. Built in for every app (`agents/scout/signals.json`): slow requests (p95 `ms` per `route` from `event = request`), 4xx and 5xx rate per route, warnings per message, and the error count. Each app adds its own in `apps.json` (Feast: LLM job durations and waits, Gemini 429s and rejected keys, save conflicts, AI feedback outcomes, import failures per website, re-parses, bad LLM output, requests per app version; Backpack: save conflicts and usage per `action`). Events that aren't logged yet simply report zero, so nothing breaks before [KOE-29](https://linear.app/koenv/issue/KOE-29/log-the-outcome-of-ai-feedback-on-recipes) and [KOE-30](https://linear.app/koenv/issue/KOE-30/log-requests-save-conflicts-and-key-user-actions) land. The Feast and Backpack field names beyond the ones in the tickets (`decision`, `rounds`, `changed`, `ok`, `host`, `status`, `text`, `action`, `version`) are best guesses: check them against the app's `OBSERVABILITY.md`.
- **When a signal gets a ticket:** daily runs look at the last 24 hours and file a ticket when a signal is above its threshold. Weekly runs (Mondays, and every dry run) look at the last 7 days, do the same, and also file a ticket when a signal is clearly worse than last week (up by `worse_pct`, default 50%, and above its `floor`). A signal with `"ticket": false` only appears in the report. At most 3 new tickets per app per run, errors first, then signals by how far over they are, then themes.
- **Themes:** Feast's no-change AI feedback requests (`themes` in `apps.json`) are grouped by Claude into themes ("shopping list"); each theme with at least 2 requests becomes one feature-request ticket, deduplicated by theme name. The scout validates Claude's grouping; without Claude it files one "unsorted requests" ticket.
- **Shipped this week:** the weekly report starts with release notes: one line per ticket whose commit reached the default branch and was deployed (its Workers Builds check succeeded, the same rule as the deploy watch) in the last 7 days, linked to the ticket, split into New, Fixes (titles starting "Bug:" or "Fix") and Reverts (titles starting "Revert"). `agents/scout/shipped.sh` lists them from GitHub, `shipped.jq` builds the section, and Claude only rewrites titles into user-facing lines (the ticket title is used if it fails). No tickets: "Nothing shipped this week."; GitHub unreadable: the section says so. Needs `GH_TOKEN` with read access to the app repos in the scout workflow.
- **Weekly report:** the Monday run posts a project update with the main numbers, what changed since last week, what is over a threshold, signals that saw no events, and Claude's short "what changed" and "suggestions" sections. Health is `onTrack` (nothing to act on), `atRisk` (1–2 signals) or `offTrack` (3 or more).
- **Week over week:** Workers Logs keeps about 7 days, so the report ends with a collapsed *Scout data* block holding that week's numbers. The next Monday run reads it from the app's latest project update (only if it is 5 to 14 days old) and compares. If it is missing, the comparison is skipped. Each query returns at most 2000 events; the run warns when a window hit that limit (the numbers then cover part of it).
- **Add an app:** add `{"project": "<exact Linear project name>", "repo": "<repo name, no owner>", "worker": "<Worker name>"}` to `agents/scout/apps.json`. The app must log errors to Workers Logs.
- **Add a signal for an app:** add an object to that app's `"signals"` list:
  `{"name": "Gemini 429s", "filters": [{"key": "event", "operation": "eq", "value": "gemini_upstream"}], "where": [{"key": "status", "operation": "eq", "value": 429}], "measure": "count", "threshold": 5}`.
  `filters` select the events (also sent to Workers Logs; operations `eq`, `neq`, `gt`, `gte`, `lt`, `lte`); `where` (optional) narrows which of them are counted or, for `share`, form the numerator; `measure` is `count`, `sum`, `avg`, `p95`, `max` or `share` (the last four except `share` need `field`); `by` (optional) gives one number per value of a field (numbers and ids in the value are normalised, 25 groups at most); `unit` is `ms` or `rate` for display; `threshold` (a ticket when the value is above it, with at least `min_count` events, default 1), `worse_pct` and `floor` for the week-over-week rule; `"ticket": false` keeps it report-only; `expect` lists `by` values that should show up, so a never-used one is reported with zero. A `themes` entry takes `name`, `filters`, `where`, `text_field` and `min_count`.
- **Try it:** `bash agents/scout/scout.sh --dry-run` prints the numbers, the tickets and the weekly report it would create, and doesn't write to Linear (with `LINEAR_API_KEY` set it reads last week's numbers). `SCOUT_MODE=daily` makes a dry run behave like a daily run. `bash agents/scout/test.sh` runs the tests on recorded data.
- **When it runs:** `.github/workflows/scout.yml` runs it every day at 05:00 UTC (06:00 in winter, 07:00 in summer in Amsterdam), for every app in `apps.json` (Backpack and Feast); that run is the weekly one on Mondays. It needs the repo secrets `CLOUDFLARE_OBSERVABILITY_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `LINEAR_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`; a missing one fails the run with an error naming it. The run also fails if an app's logs can't be read or its Linear project isn't found. Claude's process doesn't get the Cloudflare or Linear values. A second run on the same Monday posts a second report.
- **Dry run:** GitHub → Actions → *Log scout* → *Run workflow*, keep **Dry run** ticked. It prints what it would create and doesn't touch Linear. Untick it to run for real.

## Deploy watch

An hour after an app deploys a merge to `main`, the factory compares production with the 24 hours before (error rate, 5xx rate, request time). If it clearly got worse, it opens a revert PR (never auto-merged) and a Needs Human ticket; otherwise it comments that all is normal. Details and settings: [docs/deploy-watch.md](docs/deploy-watch.md).

## Checks on this repo

Every pull request to this repo runs the **Agent scripts** workflow (`.github/workflows/agent-scripts.yml`, which runs `bash agents/ci/run.sh`; you can run that locally too). It runs `bash -n` and `shellcheck` on every script in `agents/`, compiles every `jq` filter (inline ones in the scripts and the `.jq` files; `agents/ci/check-jq.sh`), runs smoke tests of `agents/review/publish.sh` and `agents/build/publish.sh` with `gh`, `git push` and the Linear helpers stubbed (`agents/ci/smoke-test.sh`: approve, fix, escalate, follow-ups, manual tasks, questions, conflicts), and all existing tests (scout, deploy watch, health check, issue writer, reviewer, sync, update, approve). **Add `Agent scripts` as a required status check to the `main` ruleset** (Settings → Rules) so a broken script can't be merged. **A new script needs a smoke test or test** (add it to `agents/ci/smoke-test.sh`, or to a `test.sh` that is listed in `agents/ci/run.sh`; a `test*.sh` that isn't listed fails the check).

## Changing the GitHub owner
The factory and the app repos moved from the personal account `kverburg` to `kmverburg` (the owner of this repo). Old links redirect, but nothing here should name the old account any more.

The factory and the app repos share one owner. Only these places name it:
- `relay/wrangler.jsonc`: `GITHUB_OWNER`, in both `vars` and the `previews` block. `PROJECT_REPOS` holds bare repo names (an `owner/repo` value still works). If a repo has moved and GitHub answers a build request with a redirect, the relay sends the same request once to the new location and logs that the repo has moved, so builds keep working until you update the setting.
- `templates/app-repo/.github/workflows/factory.yml`: the three `uses: <owner>/factory/...` lines (GitHub needs a literal name there). The sync workflow opens PRs with the new template in every app repo.
- Documentation (this README, `CLAUDE.md` files).

Everything else derives it: `build.yml`, `review.yml` and `recheck.yml` use `github.repository_owner`, this repo's own `factory.yml` calls the local workflows (`./.github/workflows/...`), and the log scout gets `GITHUB_OWNER` from the workflow (`agents/scout/apps.json` names repos without an owner).

## Safety notes

- Agents never get push access: checkout runs without credentials, and only the workflow's own steps push and open PRs.
- Only move tickets to *Agent Ready* yourself. Anything generated from outside input (like logs) should land in Triage first, because ticket text becomes agent instructions.

## Troubleshooting

- **Nothing happens in Linear:** check the Worker's logs in Cloudflare (Observability tab) and the webhook's delivery log in Linear.
- **"No GitHub repo is mapped":** the Linear project name doesn't exactly match a key in `PROJECT_REPOS`.
- **Build fails at "Publish":** step 5.4 isn't enabled.
- **App repo can't find the workflow:** step 1's access setting.
