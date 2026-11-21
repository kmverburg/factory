# Factory

The software factory itself. Linear issues in "Agent Ready" go through the relay to GitHub, where a builder agent opens a PR and a reviewer agent approves it, sends fixes back, or escalates to Koen. It serves several app repos (Backpack, Feast) and this repo.

## Layout
- `relay/`: Cloudflare Worker (TypeScript) that receives Linear webhooks and starts builds via GitHub `repository_dispatch`. Deploys automatically on push to `main`.
- `agents/`: the agents' logic. `build/` and `review/` hold the prompts (`prompt.md`, with `{{NAME}}` placeholders filled from environment variables) and the bash scripts each workflow step runs; `lib/linear.sh` has the Linear helpers; `lib/render.sh` fills in prompts.
- `agents/scout/`: the log scout. `apps.json` lists the apps and their extra signals/themes; `signals.json` the built-in signals; `fetch.sh` reads Workers Logs, `group.sh`/`group.jq` mask and group errors, `metrics.jq`/`evaluate.jq`/`report.jq` count signals, apply thresholds and week-over-week rules and build the weekly report, `dedup.jq` matches open tickets, `scout.sh` creates the Linear tickets and the weekly project update (`--dry-run` touches nothing). Claude only writes the ticket and report text (`prompt*.md`) and groups themes.
- `.github/workflows/build.yml` and `review.yml`: thin reusable workflows that every app repo calls. They fetch `agents/` from `main` at run time.
- `.github/workflows/factory.yml`: this repo's own caller, so the factory can build itself.
- `agents/sync/`: `sync-caller.sh` (run by `.github/workflows/sync-caller.yml`) opens "Update factory caller workflow" PRs in every app repo in `PROJECT_REPOS` when the template caller changes. Test: `bash agents/sync/test.sh`.
- `agents/deploywatch/`: the deploy watch (`watch.sh`, run every 15 minutes by `.github/workflows/deploy-watch.yml`; docs in `docs/deploy-watch.md`). Test: `bash agents/deploywatch/test.sh`.
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
- There are no other tests for `agents/` yet.

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
