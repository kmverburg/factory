# Factory health check

The factory tests itself every day, so Koen doesn't have to find out that something expired or lost access. `.github/workflows/health.yml` runs `agents/health/health.sh` at 06:30 UTC (after the log scout). It only reads; fixing what it finds is the tickets' job.

Each failed check becomes one Linear ticket in the **Factory** project: title `Factory health: …`, state **Todo**, labels `source:health` and **Origin › Agent**, with what's wrong and how to fix it. The ticket holds `Signature: healthsig-<check>`:
- A check that keeps failing **updates** its open ticket (no duplicates, no comment spam).
- When the check passes again, the ticket gets **one comment** and is marked `Health status: recovered`. Close it yourself. If it fails again, the ticket is updated and gets a "fails again" comment.
- Checks that can't be tested (marked *skip*) never create or touch tickets.

## Running it
GitHub → Actions → *Factory health check* → *Run workflow*. **Dry run** (ticked by default) prints every result and creates nothing; untick it to file tickets. Locally: `bash agents/health/health.sh --dry-run` with the environment of the workflow. Tests: `bash agents/health/test.sh` (fake `gh` and `curl`, no network).

## What is checked
| Area | Checks | Ticket key |
|---|---|---|
| Relay | `GET /` answers; `GET /health?deep=1` (needs `HEALTH_CHECK_SECRET`) says the relay's GitHub token and Linear key are valid and its three secrets are set. The route returns statuses only, never values, and is off (404) without the secret on the Worker. | `relay-*` |
| GitHub | For every repo in the relay's `PROJECT_REPOS`: the factory app is installed; `.github/workflows/factory.yml` exists and matches the template (the factory repo's own caller isn't compared); required status checks on the default branch (rulesets or branch protection); auto-merge is allowed. | `github-<repo>-*` |
| Claude app | Installed on the org (only with the optional `HEALTH_ORG_TOKEN`, an org-admin read token; GitHub doesn't show installations to the app token). Without it, or when the app is on selected repos only, this is skipped. | `claude-app` |
| Cloudflare | A required check on the default branch mentions Workers Builds, and it reported on the latest commit; each Worker still has a build trigger connected to its repo (`CLOUDFLARE_BUILDS_TOKEN`, needs Workers Scripts and Workers Builds Configuration read). | `cloudflare-<repo>-*` |
| Linear integration | The last merged `agent-built` PR of each repo (older than an hour) has a ticket whose attachments link that PR and whose state is Done. | `linear-<repo>-integration` |
| Secrets | `LINEAR_API_KEY` (a `viewer` query), `CLOUDFLARE_ACCOUNT_ID` (format), `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_BUILDS_TOKEN`, `CLOUDFLARE_OBSERVABILITY_TOKEN` (Cloudflare token verify), `FACTORY_APP_ID` + `FACTORY_APP_PRIVATE_KEY` (an installation token can be created), `CLAUDE_CODE_OAUTH_TOKEN` (format and one models request). Each is tested by format and one harmless call; values are never printed. | `secret-*` |
| Real API queries | Every read-only `query` the relay (`relay/src/*.ts`) and the agents (`linear_gql '…'` in `agents/**/*.sh`) send is found by `agents/health/queries.mjs` and run against the real Linear API with sample values from the Factory project. Any GraphQL error, such as a query that is too complex, is a failure. Mutations aren't run (they're not read-only). | `linear-query-*` |

A new query needs no change, but a new query **variable name** needs a sample value in `check_linear_queries` (`agents/health/checks.sh`); `bash agents/health/test.sh` fails until it has one.

## Setup
1. Choose a long random `HEALTH_CHECK_SECRET` and store it in Infisical in `/shared` (this repo) and in `/cloudflare/factory-relay` (the Worker). Without it on the Worker the deep relay check reports "off".
2. Set the repo variable (or secret) `RELAY_URL` to the Worker's URL.
3. The factory GitHub app needs, besides its current permissions, *Administration: read* (branch rules), *Checks: read* and *Pull requests: read* on every app repo.
4. This repo also needs `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_BUILDS_TOKEN` (the other secrets are already synced here); optional `HEALTH_ORG_TOKEN` for the Claude app check.

## Limits
- The Cloudflare Workers Builds lookups use `/builds/workers/<id>/triggers`; if Cloudflare changes the API the check fails with a ticket that says what it couldn't read.
- If Linear itself is unreachable the run fails (no tickets can be written) when something is failing.
