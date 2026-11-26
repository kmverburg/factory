# Claude usage limits

When Claude's usage or rate limit stops a factory run, the run waits and tries again instead of sending the ticket to
Needs Human.

## What counts

The failure reporters read Claude's own error text (`agents/lib/claude-error.sh`) and `usage_limit_hit` in
`agents/lib/usage-limit.sh` matches it: "usage limit", "rate limit", "limit reached", "limit will reset", "too many
requests", "429" and a few similar messages. Everything else fails exactly as before.

## What happens

- **Builder** (`factory-build` and `factory-fix`, `agents/build/report-failure.sh`) and **reviewer**
  (`factory-review`, `agents/review/report-failure.sh`): the ticket gets a comment
  "⏳ Claude's usage limit was reached; trying again at <time> (retry n of 3)". The ticket stays where it is (no Needs
  Human, no failure comment). The comment holds a hidden marker with the original event type and payload.
- **Retry job** (`agents/retry/retry.sh`, `.github/workflows/retry.yml`, every 10 minutes): once the time has come it
  sends the same `repository_dispatch` event with the same payload and comments "🔁 Trying again after the usage
  limit". Requests more than 3 hours past due are left to the stuck check.
- **When it tries again:** the reset time Claude gives (`…limit reached|<epoch>` or "resets 3pm (Europe/Amsterdam)"),
  or one hour later when there is none or it is more than 8 hours away.
- **After 3 retries** (of the same step, counted over 24 hours) the builder moves the ticket to Needs Human and says the
  limit was still reached; the reviewer does the same and labels the PR `needs-human`.
- **Log scout** (`agents/scout/run.sh`, called by `scout.yml`): before it writes anything the scout checks whether Claude
  answers. At the limit it exits 75, and `run.sh` waits for the reset (an hour when unknown) inside the job and starts
  it again, up to 3 times, then fails. A limit reached halfway through still falls back to the plain ticket text.
- The **stuck check** leaves tickets and PRs alone while a retry is waiting.

The workflow run that hit the limit still ends red in GitHub; only Linear is told it is a wait, not a failure.

Out of scope: switching to a paid API key at the limit.

Tests: `bash agents/retry/test.sh`.
