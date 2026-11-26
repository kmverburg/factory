# <App name>

Both factory agents read this file first. Keep it short and accurate.

## What this app is
One or two sentences: what it does and who uses it.

## Stack
e.g. Next.js 15, TypeScript, Postgres via Prisma, deployed on Cloudflare.

## Commands
- Install: `npm ci`
- Test: `npm test`
- Lint: `npm run lint`
- Build: `npm run build`
- Run locally: how to start the app so agents can open it in the headless browser (URL, port, test login if any).

## Conventions
- Where things live (e.g. "API routes in src/app/api, shared UI in src/components").
- Style rules the linter doesn't catch.

## Off-limits
- Files or folders agents must never change (e.g. migrations/, billing/).
- `.github/`: change workflow files only when the ticket asks for it. If a ticket can't work without a small workflow change it didn't mention (for example passing an existing secret to a job), the builder makes it in the same PR and lists it under "Workflow changes" in the PR description; bigger changes (new workflows, new triggers, new permissions or secrets) are asked about on the ticket first, never filed as manual work. The reviewer always escalates such a PR and it never auto-merges, so a human approves every workflow change.

## Factory review rules
Extra reasons for the reviewer to escalate in this repo, e.g.:
- Any change to the booking calendar logic.
