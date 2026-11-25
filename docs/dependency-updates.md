# Weekly dependency updates

Every Monday the factory checks the npm dependencies of each app repo (everything in `agents/scout/apps.json`) and of this repo, and turns what it finds into ordinary Linear tickets that it builds and reviews itself.

Code: `agents/deps/` (`deps.sh`, `target.jq`, `ticket.jq`), workflow `.github/workflows/deps.yml` (Mondays 06:00 UTC, or by hand; "dry run" only prints), tests `bash agents/deps/test.sh`. No Claude is involved: it is all plain code.

## How it works

1. Shallow-clones each repo and finds every `package.json` (not in `node_modules`) that has a `package-lock.json`. A directory without a lockfile, or where `npm ci` fails, is skipped and named in the ticket ("Could not check"). Only npm is supported (no pnpm or yarn).
2. Per directory: `npm ci --ignore-scripts` (nothing from the packages runs), `npm outdated --json` and `npm audit --json`.
3. **2-week rule:** for each outdated package it reads the publish times (`npm view <package> time`) and proposes the highest stable version that is at least 14 days old: one within the current major (minor or patch) and, if there is one, one in a higher major. Pre-releases are never proposed. Security fixes ignore the rule.
4. Files up to three tickets per repo per week, in the repo's Linear project, through the issue writer (Origin › Agent, label `factory:dependencies`). Each says which packages, from which version to which, and why:

| Ticket | Contents | State |
|---|---|---|
| **Security fixes for dependencies** | advisories from `npm audit` that have a fix, with the advisory links | **Agent Ready**, priority **High**; **Todo** when a fix needs a new major version |
| **Dependency updates (week)** | minor and patch updates ("routine update", "bug fix release") | **Agent Ready** |
| **Major dependency updates (week)** | new major versions | **Todo**: Koen decides, since they can need code changes |

(A repo needs more than one ticket because the states differ.) Advisories without a fix yet are not filed; they show up as soon as a fix exists.

## No ticket, no duplicates

- Nothing to propose: no ticket.
- Each ticket carries `Signature: \`depsig-<repo>-<security|routine|major>\``. If an earlier ticket with that signature is still open, it is **updated** (title, list, and a comment) instead of creating a new one; unchanged lists are left alone. A closed or canceled ticket is not reopened, so a major update Koen canceled comes back next week if it is still outdated: update the ticket instead of canceling it if you want to keep it quiet.

## Reviewing the PRs

The reviewer's rule stays: dependency changes are escalated, except where Koen has made an exception (see [KV-47](https://linear.app/koenv/issue/KV-47/shorter-escalations-and-learn-from-what-koen-always-approves)). Nothing here changes the reviewer.

## Setup

Repo secrets `LINEAR_API_KEY`, `FACTORY_APP_ID` and `FACTORY_APP_PRIVATE_KEY` (already used by other workflows); the app must be able to read each repo. The Linear project of this repo is named by `FACTORY_PROJECT` (default `Factory`). Not covered: GitHub Actions versions.
