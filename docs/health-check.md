# Daily factory health check

The factory checks itself every day and files a Linear ticket for each thing that is broken, so Koen doesn't find out first. Fixing is out of scope: the tickets do that.

`.github/workflows/health.yml` runs `agents/health/health.sh` every day at 04:30 UTC. Start it by hand under Actions → *Factory health check* → *Run workflow*. **Dry run** (ticked by default) prints the results and doesn't touch Linear. `bash agents/health/test.sh` tests it with a fake `gh` and `curl`.

## What it checks

Each check is a result with an id; a failed one becomes one ticket.

| Id | Check |
|---|---|
| `relay` | `GET /health` answers, and `GET /health?deep=1` (with `HEALTH_CHECK_SECRET`) says the relay's GitHub app credentials (or, before `FACTORY_APP_ID` is set, its personal token) are valid and can read every repo in `PROJECT_REPOS`, and that its Linear key works |
| `github-<repo>` | the factory app is installed on the repo; the repo has `.github/workflows/factory.yml` (and for app repos it equals the template); `main` has required status checks; auto-merge is allowed; the latest ticket-started *Factory* run didn't fail |
| `cloudflare-<repo>` | what the app's `cloudflare` setting in `agents/scout/apps.json` asks for. With `"cloudflare": {"required_check": "check"}` (Backpack, Feast: they deploy through GitHub Actions) the deploy workflow's `check` job is a required check on `main` and reported on its latest commit. Without it (the factory's relay) a required *Workers Builds: …* check exists and reported, and the Worker still has a Workers Builds trigger (its Git connection); if the token can't list the Workers, that last part is skipped with a note instead of a ticket |
| `linear-<repo>` | the last agent PR merged more than 2 hours ago has a Linear ticket that links it and is Done |
| `secret-<NAME>` | every secret the workflows use is set, has the right format (length, prefix) and passes one harmless API call: Linear `viewer`, Cloudflare token verify, GitHub app token creation |
| `linear-queries` | every GraphQL **query** in `agents/lib/linear.sh` and `relay/src/index.ts` runs against the real Linear API, with sample values from the *Factory* project, and succeeds. This catches problems the tests (which fake Linear) can't, like [KOE-32](https://linear.app/koenv/issue/KV-32/bug-relay-doesnt-release-blocked-tickets-when-their-blocker-is-done)'s oversized query |

Existing tickets are found by the `Health check: <id>` marker among all open tickets of the project, with or without the label; the label is added (and created if the team has none) when missing.

Repos come from the relay's `PROJECT_REPOS`; a repo's Worker name comes from `agents/scout/apps.json` (the factory's own from `relay/wrangler.jsonc`). A new query is found by itself, but a new *variable name* needs a sample value in `check_linear_queries` (`agents/health/checks.sh`); until then the check fails and says so. Mutations are never run. The test fails if another file starts calling the Linear API.

A check that can't run because its prerequisite is already reported (no GitHub token, no Linear key) is skipped, so one root cause makes one ticket.

## Stuck tickets and PRs (hourly)

A factory run can die without reporting back (GitHub losing contact with its runner, as in KV-62). `agents/health/stuck.sh`, run every hour by `.github/workflows/stuck.yml`, makes sure nothing stays stuck silently. It uses the factory app token to read the runs of each app's `factory.yml` workflow, its open agent PRs and the Linear project of each repo in `PROJECT_REPOS`. Test: `bash agents/health/test-stuck.sh`.

**Tickets.** A ticket in **Agent Working** is stuck when no factory run for it is in progress and it hasn't changed for more than an hour. Runs that are queued, waiting or in progress never count as stuck. Runs belong to a ticket by its identifier in the run's name (the caller workflow names dispatch runs `Factory KV-1`) or in its branch name. Callers that don't name their runs yet are handled carefully: while a dispatch run without a ticket name is in progress, nothing in that repo counts as stuck. If a repo's runs can't be read, it is skipped.

- First time: comment "🏭 The last run stopped without reporting back (run link, conclusion); starting it again." With an open agent PR (label `agent-built`, branch starting with the identifier) the work continues as a **fix round** on that PR (a `factory-fix` event, the round count unchanged, the PR labelled `agent-fixing`), so finished work isn't thrown away. Without a PR the ticket goes back to **Agent Ready**, which starts a fresh build through the relay.
- Stuck again within 24 hours: **Needs Human** (and Delivery › Human involved) with a comment that links both runs and what is known about why they stopped (the failed job and step, and GitHub's own message). Never retried more than once in a row.

**PRs without a verdict.** An open agent PR with none of the labels `agent-approved`, `needs-human` or `agent-fixing` for more than an hour (not a draft, ticket not done or in Needs Human) with no run in progress gets its review started again once (a `factory-review` event, which the caller workflow turns into a call of the review workflow), with a comment on the ticket. If it is still without a verdict an hour after that, the ticket goes to **Needs Human** with a comment linking both review runs, and the PR gets `needs-human`.

Both remember their retry in a hidden marker in the comment on the ticket (`<!-- stuck-check:ticket|review prev=<run url> -->`); a marker older than 24 hours is ignored.

**Dry run:** start the workflow by hand (the default is a dry run) or run `bash agents/health/stuck.sh --dry-run` with `GH_TOKEN`, `FACTORY_REPO` and `LINEAR_API_KEY`: it only lists what it found.

**Rollout.** The check needs the `run-name` and the `factory-review` event in each app repo's caller workflow (`templates/app-repo/.github/workflows/factory.yml`); the caller sync opens "Update factory caller workflow" PRs for that. Until an app has merged it, its runs can't be matched to tickets (so nothing is retried while a dispatch run is active) and PRs can't be re-reviewed there (the dispatch is accepted but starts nothing).

## Tickets

- Title `Factory health: <what is wrong>`, in the **Factory** project, **Todo**, labels **Origin › Agent** and `factory:health`. Never Agent Ready. The text says what is wrong and how to fix it.
- A failure that has an open ticket (matched by the `Health check: \`<id>\`` line in its description) updates that ticket's description instead of creating a new one.
- When the check passes again, the ticket gets one comment ("this problem is gone") and its description says `Health status: resolved`. It stays open for a human to close. If it fails again before it is closed, the description goes back to `failing`.
- If Linear can't be reached the results are printed and the run fails.

## The relay's health route

- `GET /health` answers `{"ok": true}`.
- `GET /health?deep=1` needs `Authorization: Bearer <HEALTH_CHECK_SECRET>` (otherwise 401, and always 401 when the relay has no such secret). It makes read-only calls to GitHub (`GET /app` with a signed JWT for the app credentials, or `/rate_limit` for the fallback token; `/repos/<repo>` for each mapped repo) and Linear (`viewer`) and answers `{ok, auth, github, linear, repos}` (`auth` is `app` or `token`) with HTTP status codes only, 503 when something fails. It never returns a token.

## Setup

Add `HEALTH_CHECK_SECRET` (a random string of 16+ characters) to Infisical, in `/cloudflare/factory-relay` (for the relay) and in the folder synced to this repo (for the workflow), with the same value. Until the relay has it, the `relay` check reports "refused `HEALTH_CHECK_SECRET`". The workflow also uses the secrets listed in the README's Secrets table: `CLAUDE_CODE_OAUTH_TOKEN`, `LINEAR_API_KEY`, `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_BUILDS_TOKEN` (needs *Workers Scripts: Read* and *Workers Builds Configuration: Read* for the connection check), `CLOUDFLARE_OBSERVABILITY_TOKEN`, `FACTORY_APP_ID` and `FACTORY_APP_PRIVATE_KEY`, all as secrets of **this** repo.

## Limits

- Secrets are checked in this repo only; the app repos' copies can't be read, only their effects (for example a failed *Factory* run).
- The Claude GitHub App's installation can't be read with the factory app's token. A missing installation shows up as a failed latest *Factory* run, not as its own check.
- The Cloudflare Workers Builds API calls (`builds/workers/<tag>/triggers`) are not documented as stable; if Cloudflare changes them the `cloudflare-<repo>` ticket says which call failed.
