# Daily secret scan

A secret that leaks into a log or a commit should be noticed within a day. `.github/workflows/secret-scan.yml` runs `agents/secrets/scan.sh` every day at 04:45 UTC (after the health check). Start it by hand under Actions → *Factory secret scan* → *Run workflow*; **Dry run** (ticked by default) prints what it found and creates and changes nothing. Tests: `bash agents/secrets/test.sh` (fake `gh` and `curl`, no network).

## What is scanned

The last 24 hours, in every repo in the relay's `PROJECT_REPOS` (the factory and the app repos):

- **GitHub Actions logs**: the logs of every workflow run created in that time (at most 100 runs per repo).
- **Cloudflare Workers Builds logs**: the builds of each app's Worker from that time, read with the read-only `CLOUDFLARE_BUILDS_TOKEN`. Skipped (with a note in the run log) when the token can't look the Worker up.
- **Commits**: every new commit on **every branch**: the lines it adds and its message (at most 200 commits per repo).

## What it looks for

- **Formats** of the secrets the factory uses: GitHub tokens (`ghp_`, `ghs_`, `gho_`, `ghu_`, `ghr_`, `github_pat_`), Linear keys (`lin_api_`, `lin_oauth_`), Claude tokens (`sk-ant-`), Cloudflare tokens (`cfut_`, `cfat_`, `cfk_`) and private keys (`-----BEGIN … PRIVATE KEY-----`). Obvious placeholders (fewer than 10 different characters, like `xxxxxxxx`) and masked values (`***`) are ignored.
- **The current values** of the factory's secrets (`CLAUDE_CODE_OAUTH_TOKEN`, `LINEAR_API_KEY`, the three Cloudflare tokens, `HEALTH_CHECK_SECRET`, `FACTORY_APP_PRIVATE_KEY`). Old Cloudflare tokens have no recognisable format, so this is how they are found. The values only exist in the scanner's memory as SHA-256 hashes: every word of the scanned text is hashed and compared to those hashes (a multi-line key is compared line by line). Nothing is ever printed or written with a secret or a piece of one.

The scan is plain code (`agents/secrets/match.py` and `scan.sh`); no LLM reads the logs.

## What a hit does

A high-priority (**High**) ticket in the **Factory** project, **Todo**, Origin › Agent, label `factory:secret-leak`, titled `Secret leak: <type> in <place>`. It says where (run, commit or build link), which secret type, and whether it matched a format or the current value of a named secret, with the steps to rotate it in Infisical (new secret at the service, replace it in the folder from the README's *Secrets* table, delete the leak, check the audit log). **It never repeats the secret.**

**Not reported twice:** each ticket carries `Leak: \`secretleak-<fingerprint>\``, a hash of the place and the type (not of the secret). An open ticket with the same fingerprint gets a comment instead of a new ticket. Closing the ticket and scanning the same place again within 24 hours would report it again; the daily window makes that rare. At most 10 tickets are made per run; the rest are listed (places only) in the run log.

The ticket is made through the issue writer (`priority: 2`). Rotating is manual: it is out of scope for the scan.

## GitHub's own secret scanning

GitHub's secret scanning and push protection are free for public repos. The scan turns them on for each public repo where they are off, if the factory app has *Administration: Read and write*. If it can't, it files one manual ticket for Koen ("Turn on GitHub secret scanning and push protection"): in each repo, Settings → Advanced Security (Code security) → turn on *Secret protection* and *Push protection*. Private repos need GitHub Advanced Security and are skipped.

## Setup

The factory GitHub App needs, besides what it has: *Actions: Read* (for the logs) and, to switch scanning on, *Administration: Read and write*, on every repo. The workflow uses the repo secrets listed in the README's *Secrets* table (`LINEAR_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, the Cloudflare tokens, `HEALTH_CHECK_SECRET`, `FACTORY_APP_ID`, `FACTORY_APP_PRIVATE_KEY`); a missing one only means its value isn't compared (its format still is).
