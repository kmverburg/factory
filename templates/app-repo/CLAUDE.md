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

## Factory review rules
Extra reasons for the reviewer to escalate in this repo, e.g.:
- Any change to the booking calendar logic.
