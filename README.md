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

Then edit `PROJECT_REPOS` in `relay/wrangler.jsonc`: one line per app, mapping the **exact Linear project name** to `owner/repo`. Every push to `main` redeploys the Worker.

### 3. Worker secrets
Don't add these by hand in Cloudflare. Set them in Infisical, folder `/cloudflare/factory-relay` (see [Secrets](#secrets)), and let the sync write them to the `factory` Worker:
- `LINEAR_API_KEY` (lives in `/shared` and is referenced from this folder)
- `GITHUB_TOKEN`: a fine-grained GitHub token (github.com → Settings → Developer settings → Fine-grained tokens) with access to your app repos and the permission **Contents: Read and write**
- `LINEAR_WEBHOOK_SECRET`: from step 4

### 4. Linear webhook
Linear → Settings → API → Webhooks → New webhook.
- URL: the relay's URL (`https://relay.kmverburg.nl`)
- Events: **Issues**

Store the signing secret in Infisical as `LINEAR_WEBHOOK_SECRET` (folder `/cloudflare/factory-relay`); don't paste it into Cloudflare. Opening the Worker URL in a browser should show "factory-relay is running".

### 5. Each app repo
1. Copy `templates/app-repo/.github/workflows/factory.yml` into the repo (it already points at `kverburg/factory`).
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
| `GITHUB_TOKEN` (relay) | Lets the relay start builds in the app repos | `/cloudflare/factory-relay` → `factory` Worker |

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
- **Follow-ups**: gaps in the repo itself (no tests, linter, docs) never block a PR. The reviewer files them as Linear issues in *Todo*, labelled `factory:follow-up`, in the same project (max 3 per review, no duplicates of open follow-ups). PRs for follow-up tickets don't create new follow-ups.
- **Auto-merge**: when the final verdict is approve with risk `low` (also after fix rounds) on a PR the factory opened, the reviewer turns on squash auto-merge with the factory app's token (`FACTORY_APP_TOKEN`), and GitHub merges once the required checks pass. Medium or high risk, fix and escalate verdicts, and PRs not opened by the factory never auto-merge. The repo must allow auto-merge (Settings → General). To opt a repo out, put the line `Factory auto-merge: off` in its `CLAUDE.md`. If auto-merge can't be enabled, the PR keeps `agent-approved` and the Linear comment says why; merge it yourself.

The workflows are thin: their logic (prompts, bash scripts, Linear helpers) lives in `agents/` and is fetched from `main` at run time. See `CLAUDE.md` for the layout.

## Managing the factory with the factory

Issues in the Linear project **Factory** are built and reviewed in this repo, just like an app. Agents can change everything, including workflow files in `.github/`, but only when a ticket asks for it. A PR that touches `.github/` is always escalated (enforced in `agents/review/publish.sh`) and never auto-merges, so Koen approves every workflow change. This needs the factory GitHub App to have *Workflows: Read and write*. The reviewer also always escalates changes to the prompts, the verdict logic and the relay's security, since those change how the factory judges itself. Merged changes to `agents/` go live for every app right away.

One-time setup for this repo, the same as step 5 for an app:
1. Repo secrets `CLAUDE_CODE_OAUTH_TOKEN` and `LINEAR_API_KEY`, synced from Infisical's `/shared` folder (see [Secrets](#secrets)).
2. Settings → Actions → General → *Allow GitHub Actions to create and approve pull requests*.
3. The Claude GitHub App has access to this repo.
4. The relay's GitHub token (`GITHUB_TOKEN`, from Infisical's `/cloudflare/factory-relay` folder) includes this repo, with *Contents: Read and write*.

### Linear labels

Two label groups in each Linear team tell you how a ticket came about and how it was delivered. Create them once in Linear (labels with a parent group); the scripts only add them to tickets and warn if one is missing.
- **Origin** (who had the idea): **Human** is set by the relay on new tickets that have no Origin label. **Agent** is set when the reviewer creates a follow-up ticket and when the log scout creates a ticket (in the same `issueCreate`, so the relay leaves it alone).
- **Delivery** (did agents do it on their own): **Human involved** is set as soon as a human is needed: the reviewer escalates, the builder asks questions or makes no changes, a build or fix run fails, or the reviewer approves without turning on auto-merge (medium/high risk, repo opted out, PR not opened by the factory, or enabling auto-merge failed). **Autonomous** is set when the reviewer approves and turns on auto-merge. Human involved always wins: it replaces Autonomous, and Autonomous never replaces it. Only one Delivery label is on a ticket, other labels are kept.

## Log scout

`agents/scout/scout.sh` turns app errors into Linear tickets. For each app in `agents/scout/apps.json` it reads the last 24 hours of errors from Cloudflare Workers Logs (read-only `CLOUDFLARE_OBSERVABILITY_TOKEN` plus `CLOUDFLARE_ACCOUNT_ID`), groups them by signature (message plus top stack frame), and for each new group creates a ticket in the app's Linear project in **Triage** (Todo if the team has none), labelled `source:logs`, never *Agent Ready*. Koen decides what gets built. The ticket has what's happening, count, first/last seen, a sample and the probable code location; Claude writes only that text. If an open `source:logs` ticket already carries the signature, the scout comments with the new count. At most 3 new tickets per app per run. Emails and token-like strings are masked and log text is only shown in code blocks.

- **Add an app:** add `{"project": "<exact Linear project name>", "repo": "owner/repo", "worker": "<Worker name>"}` to `agents/scout/apps.json`.
- **Try it:** `bash agents/scout/scout.sh --dry-run` prints the tickets it would create and doesn't touch Linear. `bash agents/scout/test.sh` runs the tests on recorded data.
- **When it runs:** `.github/workflows/scout.yml` runs it every day at 05:00 UTC (06:00 in winter, 07:00 in summer in Amsterdam), for every app in `apps.json` (Backpack and Feast). It needs the repo secrets `CLOUDFLARE_OBSERVABILITY_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `LINEAR_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`; a missing one fails the run with an error naming it. The run also fails if an app's logs can't be read or its Linear project isn't found. Claude's process doesn't get the Cloudflare or Linear values.
- **Dry run:** GitHub → Actions → *Log scout* → *Run workflow*, keep **Dry run** ticked. It prints the tickets it would create and doesn't touch Linear. Untick it to run for real.

## Safety notes

- Agents never get push access: checkout runs without credentials, and only the workflow's own steps push and open PRs.
- Only move tickets to *Agent Ready* yourself. Anything generated from outside input (like logs) should land in Triage first, because ticket text becomes agent instructions.

## Troubleshooting

- **Nothing happens in Linear:** check the Worker's logs in Cloudflare (Observability tab) and the webhook's delivery log in Linear.
- **"No GitHub repo is mapped":** the Linear project name doesn't exactly match a key in `PROJECT_REPOS`.
- **Build fails at "Publish":** step 5.4 isn't enabled.
- **App repo can't find the workflow:** step 1's access setting.
