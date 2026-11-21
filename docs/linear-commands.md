# Linear comment commands

Koen can handle everything the factory asks from the Linear ticket (on a phone, no GitHub): approve a PR, ask for changes, or answer the builder's questions, by writing a comment.

## Setup (once)

Linear → Settings → API → the factory webhook → *Data change events*: tick **Comments** as well as Issues.

The relay's GitHub token needs *Pull requests: Read* (to find the ticket's PR) next to *Contents: Read and write* on every app repo. The merge itself runs in GitHub Actions with the factory app's token.

## Commands

The first word of the comment decides. Case doesn't matter.

| Comment | When | What happens |
| --- | --- | --- |
| `approve` or `merge` (anything after it is ignored) | The ticket's agent PR is open | A `factory-approve` event starts the *Factory approve* workflow. It waits for the PR's required checks, then squash-merges and deletes the branch with the factory app's token. The ticket gets a comment when it's merged, or why it wasn't (a failing check, checks still running after 30 minutes, a merge GitHub refused). |
| `change …` or `fix …` | The ticket's agent PR is open | The rest of the comment goes to the builder as instructions (a `factory-fix` event with `requested: true`). The reviewer checks the result as usual. These rounds don't count towards the automatic 2-round limit, and the next automatic count starts from 0. |
| Any comment | The ticket is in **Needs Human** and has no open PR (the builder asked questions) | The comment is added to the ticket description under `## Answers from Koen` (later answers are appended) and the ticket moves to **Agent Ready**, so the builder continues with it. |

Every command gets a short confirmation comment from the relay within seconds. Anything else is ignored: a comment that doesn't start with a command word on a ticket that isn't waiting for an answer, edits and deletions of comments, and comments on tickets in projects the relay doesn't know.

## Rules

- **Factory comments are never commands.** Every comment the factory writes starts with one of 🏭 🔧 ✅ 🙋 💥 🤔, and the relay ignores comments that start with one. Keep this in mind when adding a new kind of comment: start it with a marker.
- **Only the factory's own PRs.** The PR must have the `agent-built` label, and is found by its branch name starting with the ticket identifier (`kv-45-…`, which is how the builder names it). Approving or changing any other PR is refused with an explanation.
- A command on a ticket without an open PR gets a reply saying so.
- Anyone who can comment on a ticket in a mapped project can give commands, so keep the workspace to people who may merge.

## Where it lives

- `relay/src/index.ts`: `handleComment`, `parseCommand`, `answerQuestions`. Tests in `relay/test/relay.test.ts` ("Linear comment commands").
- `.github/workflows/approve.yml` and `agents/approve/approve.sh` (test: `bash agents/approve/test.sh`).
- The caller workflow (`templates/app-repo/.github/workflows/factory.yml`, synced to the app repos) handles `factory-approve` and passes `requested` to the builder.
