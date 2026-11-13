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
In Cloudflare: Workers & Pages → `factory-relay` → Settings → Build → Connect, and pick this repo.
- Root directory: `relay`
- Deploy command: `npx wrangler deploy`

The Worker's name in Cloudflare must be `factory-relay` (or change `name` in `relay/wrangler.jsonc` to match).

Then edit `PROJECT_REPOS` in `relay/wrangler.jsonc`: one line per app, mapping the **exact Linear project name** to `owner/repo`. Every push to `main` redeploys the Worker.

### 3. Worker secrets
Worker → Settings → Variables and Secrets → Add, type **Secret**:
- `LINEAR_API_KEY`: your Linear personal API key
- `GITHUB_TOKEN`: a fine-grained GitHub token (github.com → Settings → Developer settings → Fine-grained tokens) with access to your app repos and the permission **Contents: Read and write**
- `LINEAR_WEBHOOK_SECRET`: from step 4

### 4. Linear webhook
Linear → Settings → API → Webhooks → New webhook.
- URL: your Worker URL (`https://factory-relay.<subdomain>.workers.dev`)
- Events: **Issues**

Copy the signing secret into the Worker as `LINEAR_WEBHOOK_SECRET`. Opening the Worker URL in a browser should show "factory-relay is running".

### 5. Each app repo
1. Copy `templates/app-repo/.github/workflows/factory.yml` into the repo (it already points at `kverburg/factory`).
2. Copy `templates/app-repo/CLAUDE.md` to the repo root and fill it in. Good commands here make both agents much better.
3. Repo secrets (Settings → Secrets and variables → Actions): `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) and `LINEAR_API_KEY`.
4. Settings → Actions → General → Workflow permissions: tick **Allow GitHub Actions to create and approve pull requests**.
5. Make sure the Claude GitHub App is installed on the repo.

### 6. Linear ↔ GitHub
Install Linear's GitHub integration and turn on its pull request automations, so an opened PR moves the issue to In Review and a merged PR moves it to Done. Agent branches start with the issue ID (e.g. `fac-12-fix-login`), which is how Linear links them.

### 7. First test
Create a small, low-risk issue in a mapped project and move it to **Agent Ready**. Within a minute the issue should get a "Picked up by the factory" comment and move to **Agent Working**.

## How decisions are made

- **Builder** won't guess: if a ticket is unclear it comments questions on the Linear issue and moves it to *Needs Human*.
- **Reviewer** escalates on auth, payments, secrets, personal data, schema or data changes, dependency or CI changes, more than 400 changed lines, failing checks, missing tests, scope creep, or low confidence. Add repo-specific rules under "Factory review rules" in that repo's `CLAUDE.md`.
- Nothing merges automatically. Merge `agent-approved` PRs yourself until you trust the reviewer, then consider enabling auto-merge for that label.

## Safety notes

- Agents never get push access: checkout runs without credentials, and only the workflow's own steps push and open PRs.
- Only move tickets to *Agent Ready* yourself. Anything generated from outside input (like logs) should land in Triage first, because ticket text becomes agent instructions.

## Troubleshooting

- **Nothing happens in Linear:** check the Worker's logs in Cloudflare (Observability tab) and the webhook's delivery log in Linear.
- **"No GitHub repo is mapped":** the Linear project name doesn't exactly match a key in `PROJECT_REPOS`.
- **Build fails at "Open pull request":** step 5.4 isn't enabled.
- **App repo can't find the workflow:** step 1's access setting.
