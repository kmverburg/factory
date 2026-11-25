# Daily factory health check

The factory checks itself every day and files a Linear ticket for each thing that is broken, so Koen doesn't find out first. Fixing is out of scope: the tickets do that.

`.github/workflows/health.yml` runs `agents/health/health.sh` every day at 04:30 UTC. Start it by hand under Actions → *Factory health check* → *Run workflow*. **Dry run** (ticked by default) prints the results and doesn't touch Linear. `bash agents/health/test.sh` tests it with a fake `gh` and `curl`.

## What it checks

Each check is a result with an id; a failed one becomes one ticket.

| Id | Check |
|---|---|
| `relay` | `GET /health` answers, and `GET /health?deep=1` (with `HEALTH_CHECK_SECRET`) says the relay's GitHub token is valid and can read every repo in `PROJECT_REPOS`, and that its Linear key works |
| `github-<repo>` | the factory app is installed on the repo; the repo has `.github/workflows/factory.yml` (and for app repos it equals the template); `main` has required status checks; auto-merge is allowed; the latest ticket-started *Factory* run didn't fail |
| `cloudflare-<repo>` | what the app's `cloudflare` setting in `agents/scout/apps.json` asks for. With `"cloudflare": {"required_check": "check"}` (Backpack, Feast: they deploy through GitHub Actions) the deploy workflow's `check` job is a required check on `main` and reported on its latest commit. Without it (the factory's relay) a required *Workers Builds: …* check exists and reported, and the Worker still has a Workers Builds trigger (its Git connection); if the token can't list the Workers, that last part is skipped with a note instead of a ticket |
| `linear-<repo>` | the last agent PR merged more than 2 hours ago has a Linear ticket that links it and is Done |
| `secret-<NAME>` | every secret the workflows use is set, has the right format (length, prefix) and passes one harmless API call: Linear `viewer`, Cloudflare token verify, GitHub app token creation |
| `linear-queries` | every GraphQL **query** in `agents/lib/linear.sh` and `relay/src/index.ts` runs against the real Linear API, with sample values from the *Factory* project, and succeeds. This catches problems the tests (which fake Linear) can't, like [KOE-32](https://linear.app/koenv/issue/KV-32/bug-relay-doesnt-release-blocked-tickets-when-their-blocker-is-done)'s oversized query |

Existing tickets are found by the `Health check: <id>` marker among all open tickets of the project, with or without the label; the label is added (and created if the team has none) when missing.

Repos come from the relay's `PROJECT_REPOS`; a repo's Worker name comes from `agents/scout/apps.json` (the factory's own from `relay/wrangler.jsonc`). A new query is found by itself, but a new *variable name* needs a sample value in `check_linear_queries` (`agents/health/checks.sh`); until then the check fails and says so. Mutations are never run. The test fails if another file starts calling the Linear API.

A check that can't run because its prerequisite is already reported (no GitHub token, no Linear key) is skipped, so one root cause makes one ticket.

## Tickets

- Title `Factory health: <what is wrong>`, in the **Factory** project, **Todo**, labels **Origin › Agent** and `factory:health`. Never Agent Ready. The text says what is wrong and how to fix it.
- A failure that has an open ticket (matched by the `Health check: \`<id>\`` line in its description) updates that ticket's description instead of creating a new one.
- When the check passes again, the ticket gets one comment ("this problem is gone") and its description says `Health status: resolved`. It stays open for a human to close. If it fails again before it is closed, the description goes back to `failing`.
- If Linear can't be reached the results are printed and the run fails.

## The relay's health route

- `GET /health` answers `{"ok": true}`.
- `GET /health?deep=1` needs `Authorization: Bearer <HEALTH_CHECK_SECRET>` (otherwise 401, and always 401 when the relay has no such secret). It makes read-only calls to GitHub (`/rate_limit` for the token, `/repos/<repo>` for each mapped repo) and Linear (`viewer`) and answers `{ok, github, linear, repos}` with HTTP status codes only, 503 when something fails. It never returns a token.

## Setup

Add `HEALTH_CHECK_SECRET` (a random string of 16+ characters) to Infisical, in `/cloudflare/factory-relay` (for the relay) and in the folder synced to this repo (for the workflow), with the same value. Until the relay has it, the `relay` check reports "refused `HEALTH_CHECK_SECRET`". The workflow also uses the secrets listed in the README's Secrets table: `CLAUDE_CODE_OAUTH_TOKEN`, `LINEAR_API_KEY`, `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_BUILDS_TOKEN` (needs *Workers Scripts: Read* and *Workers Builds Configuration: Read* for the connection check), `CLOUDFLARE_OBSERVABILITY_TOKEN`, `FACTORY_APP_ID` and `FACTORY_APP_PRIVATE_KEY`, all as secrets of **this** repo.

## Limits

- Secrets are checked in this repo only; the app repos' copies can't be read, only their effects (for example a failed *Factory* run).
- The Claude GitHub App's installation can't be read with the factory app's token. A missing installation shows up as a failed latest *Factory* run, not as its own check.
- The Cloudflare Workers Builds API calls (`builds/workers/<tag>/triggers`) are not documented as stable; if Cloudflare changes them the `cloudflare-<repo>` ticket says which call failed.
