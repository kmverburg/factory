# Linear comment commands

Koen can handle everything the factory asks from the Linear ticket (on a phone, no GitHub): approve a PR, ask for changes, or answer the builder's questions, by writing a comment.

## Setup (once)

Linear → Settings → API → the factory webhook → *Data change events*: tick **Comments** as well as Issues.

The relay's GitHub token needs *Pull requests: Read* (to find the ticket's PR) next to *Contents: Read and write* on every app repo. The merge itself runs in GitHub Actions with the factory app's token.

## Commands

A comment made up **only** of approving words approves. Case, punctuation and surrounding spaces don't matter. The list lives in one place, `APPROVING_WORDS` in `relay/src/index.ts`: `approve`, `approved`, `allow`, `allowed`, `yes`, `yep`, `yeah`, `y`, `ok`, `okay`, `lgtm`, `go ahead`, `ja` (so `yes, approve`, `Go ahead.` and `/approve` all count). Anything with more content is a change request, whatever word it starts with:

- `yes but rename the button`
- `approve after fixing the typo`
- `Merge conflict, solve that`
- `approve it`, `merge`, `yes please`

A reply of only `no` or `nee` on an escalated PR (ticket in Needs Human, or the PR has the `needs-human` label) starts no fix round: the factory answers asking what should change and leaves the PR and ticket as they are.

| Comment | When | What happens |
| --- | --- | --- |
| Only approving words (`approve`, `yes`, `yes, approve`, `ok`, `lgtm`, `go ahead`, `ja`, …) | The ticket's agent PR is open | A `factory-approve` event starts the *Factory approve* workflow. It waits for the PR's required checks, then squash-merges and deletes the branch with the factory app's token. The ticket gets a comment when it's merged, or why it wasn't (a failing check, checks still running after 30 minutes, a merge GitHub refused). Confirmation: "🏭 👍 Approving … once checks pass". |
| Any other comment | The ticket's agent PR is open | The whole comment goes to the builder as instructions (a `factory-fix` event with `requested: true`), e.g. `approve but rename the button`. The reviewer checks the result as usual. These rounds don't count towards the automatic 2-round limit, and the next automatic count starts from 0. Confirmation: "🏭 🔧 Sending your comment to the builder as a fix round …". |
| Any comment | The ticket is in **Needs Human** and has no open PR (the builder asked questions) | The comment is added to the ticket description under `## Answers from Koen` (later answers are appended) and the ticket moves to **Agent Ready**, so the builder continues with it. |

Every approval and change request gets a short confirmation comment from the relay within seconds. Ignored: factory comments, empty comments, edits and deletions of comments, comments on tickets in projects the relay doesn't know, and comments on a ticket with no open PR that aren't approving words (a plain `approve` there gets a reply saying there is no PR). A change request on a PR without the `agent-built` label is ignored silently; `approve` on it is refused with an explanation.

## Rules

- **Factory comments are never commands.** Every comment the factory writes starts with one of 🏭 🔧 ✅ 🙋 💥 🤔 ⏳ 🔁 ℹ️ ⚠️, and the relay ignores comments that start with one. `linear_comment` and `linear_comment_on_id` (`agents/lib/linear.sh`) put 🏭 in front when a comment has no marker, the relay does the same for its own replies, and the Agent scripts check fails when a script calls `commentCreate` itself. As a second guard the relay also ignores a comment that repeats a factory comment from the last 10 minutes (marker or not) and starts at most one comment-requested fix round per ticket in 2 minutes. Keep this in mind when adding a new kind of comment: start it with a marker.
- **Only the factory's own PRs.** The PR must have the `agent-built` label, and is found by its branch name starting with the ticket identifier (`kv-45-…`, which is how the builder names it). Approving or changing any other PR is refused with an explanation.
- Anyone who can comment on a ticket in a mapped project can give commands, so keep the workspace to people who may merge.

## Where it lives

- `relay/src/index.ts`: `handleComment`, `parseCommand`, `answerQuestions`. Tests in `relay/test/relay.test.ts` ("Linear comment commands").
- `.github/workflows/approve.yml` and `agents/approve/approve.sh` (test: `bash agents/approve/test.sh`).
- The caller workflow (`templates/app-repo/.github/workflows/factory.yml`, synced to the app repos) handles `factory-approve` and passes `requested` to the builder.
