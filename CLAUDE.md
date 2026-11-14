# Factory

The software factory itself. Linear issues in "Agent Ready" go through the relay to GitHub, where a builder agent opens a PR and a reviewer agent approves it, sends fixes back, or escalates to Koen. It serves several app repos (Backpack, Feast) and this repo.

## Layout
- `relay/`: Cloudflare Worker (TypeScript) that receives Linear webhooks and starts builds via GitHub `repository_dispatch`. Deploys automatically on push to `main`.
- `agents/`: the agents' logic. `build/` and `review/` hold the prompts (`prompt.md`, with `{{NAME}}` placeholders filled from environment variables) and the bash scripts each workflow step runs; `lib/linear.sh` has the Linear helpers; `lib/render.sh` fills in prompts.
- `.github/workflows/build.yml` and `review.yml`: thin reusable workflows that every app repo calls. They fetch `agents/` from `main` at run time.
- `.github/workflows/factory.yml`: this repo's own caller, so the factory can build itself.
- `templates/`: files to copy into a new app repo.

Everything in `agents/` goes live for **all** app repos as soon as it's merged to `main`. A PR's own changes are never used to review that PR.

## Commands
- Relay typecheck: `cd relay && npm ci && npx tsc`
- Relay build check: `cd relay && npx wrangler deploy --dry-run --outdir /tmp/relay-out`
- Script checks: `bash -n` on every changed script, then `shellcheck -x agents/*.sh agents/*/*.sh`
- Relay locally: `cd relay && npx wrangler dev`. Put `LINEAR_WEBHOOK_SECRET=test` (and dummy `LINEAR_API_KEY`, `GITHUB_TOKEN`) in `relay/.dev.vars`, then POST a JSON body with header `linear-signature` set to its HMAC-SHA256 hex digest using that secret (`openssl dgst -sha256 -hmac test`). A `GET /` answers "factory-relay is running".
- There is no test suite yet.

## Conventions
- Scripts start with `set -eo pipefail`, read their inputs from environment variables set in the workflow, and write step outputs to `$GITHUB_OUTPUT`.
- Linear calls must never fail a run: helpers in `lib/linear.sh` warn and carry on.
- Never print or log tokens, API keys or webhook secrets.
- Linear status names are matched case-insensitively ("Agent Ready", "Agent Working", "Needs Human", "In Review", "Todo").
- Keep prompts short and concrete; every rule in a prompt should be checkable.

## Off-limits
- `.github/`: agents can't push workflow files, so changes there are done by Koen. If a ticket needs one, write the exact change you need into `.factory/QUESTIONS.md` instead.
- Weakening the relay's webhook signature or timestamp checks.
- `relay/wrangler.jsonc` `name`, and anything that would expose secrets.

## Factory review rules
- Escalate any change to `agents/build/prompt.md`, `agents/review/prompt.md`, or the decision logic in `agents/review/publish.sh` (verdicts, fix-round cap, follow-up limits). These change how the factory judges itself.
- Escalate any change to the relay's signature check, its GitHub dispatch, or `PROJECT_REPOS`.
- In the summary, say which app repos a change affects and how.
