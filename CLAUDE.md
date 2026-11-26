# Factory

The software factory itself. Linear issues in "Agent Ready" go through the relay to GitHub, where a builder agent opens a PR and a reviewer agent approves it, sends fixes back, or escalates to Koen. It serves several app repos (Backpack, Feast) and this repo.

## Layout
- `relay/`: Cloudflare Worker (TypeScript) that receives Linear webhooks and starts builds via GitHub `repository_dispatch`. Deploys automatically on push to `main`.
- `agents/`: the agents' logic. `build/` and `review/` hold the prompts (`prompt.md`, with `{{NAME}}` placeholders filled from environment variables) and the bash scripts each workflow step runs; `lib/linear.sh` has the Linear helpers; `lib/render.sh` fills in prompts.
- `agents/scout/`: the log scout. `apps.json` lists the apps and their extra signals/themes; `signals.json` the built-in signals; `fetch.sh` reads Workers Logs, `group.sh`/`group.jq` mask and group errors, `metrics.jq`/`evaluate.jq`/`report.jq` count signals, apply thresholds and week-over-week rules and build the weekly report, `shipped.sh`/`shipped.jq` build the report's "Shipped this week" section from deployed commits, `dedup.jq` matches open tickets, `scout.sh` creates the Linear tickets and the weekly project update (`--dry-run` touches nothing). Claude only writes the ticket and report text (`prompt*.md`) and groups themes.
- `.github/workflows/build.yml` and `review.yml`: thin reusable workflows that every app repo calls. They fetch `agents/` from `main` at run time.
- `.github/workflows/factory.yml`: this repo's own caller, so the factory can build itself.
- `agents/sync/`: `sync-caller.sh` (run by `.github/workflows/sync-caller.yml`) opens "Update factory caller workflow" PRs in every app repo in `PROJECT_REPOS` when the template caller changes. Test: `bash agents/sync/test.sh`.
- `agents/update/`: `update.sh` (run by `.github/workflows/update.yml`, called from the caller's `push` to `main` and after each review) merges the base branch into open agent PRs, or sends conflicts to the builder as a `factory-fix` event with `conflict: true` (not counted as a round). Test: `bash agents/update/test.sh`.
- `agents/approve/`: `approve.sh` merges an agent PR on a Linear "approve" comment (`.github/workflows/approve.yml`). Test: `bash agents/approve/test.sh`. The relay's comment commands are described in `docs/linear-commands.md`.
- `agents/review/learn.sh` + `learn.jq` + `categories.json`: escalation categories and rule proposals after 3 unchanged approvals. Test: `bash agents/review/test-learn.sh`. See `docs/escalation-learning.md`.
- `agents/health/`: the daily factory health check (`health.sh`, `checks.sh`; run by `.github/workflows/health.yml`). Files "Factory health: …" tickets. Test: `bash agents/health/test.sh`. See `docs/health-check.md`. New Linear queries are picked up by themselves; a new query variable needs a sample value in `check_linear_queries`.
- `agents/secrets/`: the daily secret scan (`scan.sh`, `match.py`; run by `.github/workflows/secret-scan.yml`): looks for leaked secrets (formats and current values, compared as hashes) in the last day's Actions logs, Workers Builds logs and new commits on every branch, and files high-priority "Secret leak: …" tickets without repeating the secret. Test: `bash agents/secrets/test.sh`. See `docs/secret-scan.md`.
- `agents/health/stuck.sh` (run hourly by `.github/workflows/stuck.yml`): retries tickets in Agent Working whose run died (fix round when there is an open PR, else Agent Ready), re-reviews agent PRs without a verdict, and hands anything stuck twice to Needs Human. Test: `bash agents/health/test-stuck.sh`. See `docs/health-check.md`.
- `agents/lib/issue-writer.sh` + `agents/issue-writer/`: the issue writer, the one way to create Linear tickets (formatting, labels, assignee, status, relations, dedup), plus rough notes from Koen (`.github/workflows/issue-writer.yml`, started by the relay as `factory-issue-writer`). **Anything that creates a ticket must call `issue_write`**, never `issueCreate` directly. Tests: `bash agents/lib/test-issue-writer.sh`, `bash agents/issue-writer/test.sh`. See `docs/issue-writer.md`.
- `agents/watch/`: the deploy watch (`watch.sh`, `compare.jq`, `defaults.json`; run every 15 minutes by `.github/workflows/deploy-watch.yml`). An hour after an app's deploy it compares production with the 24 hours before; if worse it opens a revert PR (label `deploy-revert`, never auto-merged) and a Needs Human ticket. Per-app settings are a `watch` object in `scout/apps.json`. Test: `bash agents/watch/test.sh`. See `docs/deploy-watch.md`.
- `agents/ci/`: the **Agent scripts** check (`.github/workflows/agent-scripts.yml`, runs `bash agents/ci/run.sh` on every PR): `bash -n`, `shellcheck -S warning`, `check-jq.sh` (compiles every jq filter) and `smoke-test.sh` (runs `review/publish.sh` and `build/publish.sh` with `gh`, `git push` and the Linear helpers stubbed), plus every `test.sh` (listed in `run.sh`; an unlisted `test*.sh` fails the check). **A new script needs a smoke test or test** (and a new `test.sh` must be added to `run.sh`). `Agent scripts` should be a required check on the `main` ruleset.
- `agents/report/`: the weekly factory report (`report.sh`, `compute.jq`, `render.jq`; run Mondays by `.github/workflows/weekly-report.yml`). Counts last week's autonomy, origin, lead time, fix rounds, escalations and failed runs from Linear and posts a project update on the Factory project. Test: `bash agents/report/test.sh`. See `docs/weekly-report.md`.
- `agents/deps/`: the weekly dependency check (`deps.sh`, `target.jq`, `ticket.jq`; run Mondays by `.github/workflows/deps.yml`). Files security, routine (Agent Ready) and major (Todo) update tickets per repo through `issue_write`, only versions at least 2 weeks old except security fixes. Test: `bash agents/deps/test.sh`. See `docs/dependency-updates.md`.
- `agents/lib/usage-limit.sh` + `agents/retry/` (`retry.sh`, run every 10 minutes by `.github/workflows/retry.yml`) + `agents/scout/run.sh`: when Claude's usage limit stops a builder, reviewer or scout run, the ticket gets a "⏳" comment holding the original event payload and `retry.sh` sends the same event again after the reset (an hour if unknown), 3 times, then Needs Human. Test: `bash agents/retry/test.sh`. See `docs/usage-limits.md`.
- `templates/`: files to copy into a new app repo.

Everything in `agents/` goes live for **all** app repos as soon as it's merged to `main`. A PR's own changes are never used to review that PR.

## Commands
- Relay typecheck: `cd relay && npm ci && npx tsc`
- Relay build check: `cd relay && npx wrangler deploy --dry-run --outdir /tmp/relay-out`
- Script checks: `bash -n` on every changed script, then `shellcheck -x agents/*.sh agents/*/*.sh`
- Relay locally: `cd relay && npx wrangler dev`. Put `LINEAR_WEBHOOK_SECRET=test` (and dummy `LINEAR_API_KEY`, `GITHUB_TOKEN`) in `relay/.dev.vars`, then POST a JSON body with header `linear-signature` set to its HMAC-SHA256 hex digest using that secret (`openssl dgst -sha256 -hmac test`). A `GET /` answers "factory-relay is running".
- Relay tests: `cd relay && npm ci && npm test` (Vitest, in `relay/test/`). They call the Worker's `fetch` directly and fake Linear and GitHub, so they need no network or Cloudflare login. Run them after any change to `relay/src/`.
- Scout tests: `bash agents/scout/test.sh` (fixtures in `agents/scout/fixtures/`, no network). Run after any change to `agents/scout/`. Try it on recorded data: `SCOUT_NO_LLM=1 SAMPLE_FILE=agents/scout/fixtures/response.json bash agents/scout/scout.sh --dry-run`.
- Reviewer tests: `bash agents/review/test.sh` (fake `gh`, no network). Proves a diff touching `.github/` escalates and never auto-merges. Run after any change to `agents/review/`.
- Everything above, plus syntax, shellcheck, jq filters and the publish smoke tests: `bash agents/ci/run.sh`.

## Log scout
Once a day (the schedule workflow is added by Koen) `agents/scout/scout.sh` reads each app's last 24 hours of errors from Cloudflare Workers Logs, groups them by signature (message + top stack frame, numbers and ids normalised), and files tickets in the app's Linear project in Triage (Todo if the team has no triage), labelled `source:logs`, never Agent Ready. The signature is in the ticket as `Signature: \`logsig-…\``; an open `source:logs` ticket with the same signature gets a comment instead. Max 3 new tickets per app per run. Log text is untrusted: masked (emails, tokens) and shown only in code blocks.
- **Add an app:** add `{"project": "<exact Linear project name>", "repo": "<repo name, no owner>", "worker": "<Worker name>"}` to `agents/scout/apps.json`. The app must log errors to Workers Logs.
- Env: `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_OBSERVABILITY_TOKEN` (read-only), `LINEAR_API_KEY`; optional `SCOUT_CHECKOUT_DIR` (a checkout per repo, so Claude can find the code).
- The grouping, masking, counting, thresholds, comparisons, dedup and limits are plain code; don't move them into the prompt. Signals, how to add one and the weekly report are described in the README's Log scout section.

## Conventions
- Scripts start with `set -eo pipefail`, read their inputs from environment variables set in the workflow, and write step outputs to `$GITHUB_OUTPUT`.
- Linear calls must never fail a run: helpers in `lib/linear.sh` warn and carry on.
- Never print or log tokens, API keys or webhook secrets.
- Linear status names are matched case-insensitively ("Agent Ready", "Agent Working", "Needs Human", "In Review", "Todo").
- Keep prompts short and concrete; every rule in a prompt should be checkable.

## Off-limits
- `.github/`: change workflow files only when the ticket explicitly asks for it, never otherwise. The reviewer always escalates such a PR and it never auto-merges, so Koen approves every workflow change.
- Weakening the relay's webhook signature or timestamp checks.
- `relay/wrangler.jsonc` `name`, and anything that would expose secrets.

## Factory review rules
- Escalate any change to `agents/build/prompt.md`, `agents/review/prompt.md`, or the decision logic in `agents/review/publish.sh` (verdicts, fix-round cap, follow-up limits). These change how the factory judges itself.
- Escalate any change to the relay's signature check, its GitHub dispatch, or `PROJECT_REPOS`.
- In the summary, say which app repos a change affects and how.
