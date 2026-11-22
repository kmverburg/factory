/**
 * factory-relay
 *
 * Receives Linear webhooks. When an issue enters the "Agent Ready" state, it
 * looks up which GitHub repo belongs to the issue's Linear project, triggers
 * the factory build workflow in that repo, and moves the issue to
 * "Agent Working". Anything it can't handle goes to "Needs Human" with a
 * comment explaining why. It also reads Linear comments as commands (approve,
 * change, answers to the builder's questions); see docs/linear-commands.md.
 */

export interface Env {
  // Secrets (set in the Cloudflare dashboard or with `wrangler secret put`)
  LINEAR_API_KEY: string;
  LINEAR_WEBHOOK_SECRET: string;
  GITHUB_TOKEN: string;
  // Shared with the daily health check (docs/health-check.md). Optional: without it the deep health check is off.
  HEALTH_CHECK_SECRET?: string;

  // Plain vars (set in wrangler.jsonc)
  AGENT_READY_STATE: string;
  AGENT_WORKING_STATE: string;
  NEEDS_HUMAN_STATE: string;
  BLOCKED_STATE: string;
  TODO_STATE: string;
  AUTO_START_LABEL: string;
  MANUAL_LABEL: string;
  // GitHub user or organization that owns the repos. Used for PROJECT_REPOS values that are just a repo name.
  GITHUB_OWNER: string;
  // Linear project name -> repo name ("backpack") or "owner/repo".
  PROJECT_REPOS: Record<string, string>;
}

interface LinearIssue {
  id: string;
  identifier: string;
  title: string;
  description: string | null;
  url: string;
  state: { id: string; name: string };
  project: { name: string } | null;
  team: { states: { nodes: { id: string; name: string }[] } };
}

const LINEAR_API = "https://api.linear.app/graphql";
const MAX_DESCRIPTION_CHARS = 20_000;
const MAX_WEBHOOK_AGE_MS = 5 * 60 * 1000;

export default {
  async fetch(request, env, ctx): Promise<Response> {
    if (request.method === "GET") {
      const url = new URL(request.url);
      if (url.pathname === "/health") return healthCheck(request, url, env);
      return new Response("factory-relay is running");
    }
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const rawBody = await request.text();
    const signature = request.headers.get("linear-signature");
    if (!signature || !(await isValidSignature(rawBody, signature, env.LINEAR_WEBHOOK_SECRET))) {
      return new Response("Invalid signature", { status: 401 });
    }

    let payload: any;
    try {
      payload = JSON.parse(rawBody);
    } catch {
      return new Response("Invalid JSON", { status: 400 });
    }

    // Reject replayed webhooks.
    if (typeof payload.webhookTimestamp === "number" && Math.abs(Date.now() - payload.webhookTimestamp) > MAX_WEBHOOK_AGE_MS) {
      return new Response("Stale webhook", { status: 401 });
    }

    if (isNewCommentEvent(payload)) {
      ctx.waitUntil(
        handleComment(payload.data, env).catch((err) => console.error("handleComment failed", err)),
      );
      return new Response("Accepted", { status: 202 });
    }

    if (!isIssueStateEvent(payload)) {
      return new Response("Ignored");
    }

    // Answer Linear right away; do the work in the background.
    if (payload.action === "create") {
      ctx.waitUntil(
        labelOrigin(payload.data, env).catch((err) => console.warn("Origin labelling failed", String(err))),
      );
    }
    ctx.waitUntil(
      handleIssue(payload.data.id, env).catch((err) => console.error("handleIssue failed", err)),
    );
    if (payload.action === "update") {
      ctx.waitUntil(
        releaseBlocked(payload.data.id, env).catch((err) => console.warn("Releasing blocked tickets failed", String(err))),
      );
    }
    return new Response("Accepted", { status: 202 });
  },
} satisfies ExportedHandler<Env>;

/**
 * GET /health answers "ok" to anyone. GET /health?deep=1 needs `Authorization: Bearer <HEALTH_CHECK_SECRET>`
 * and makes one read-only call each to GitHub (the relay's token, and each repo in PROJECT_REPOS) and Linear.
 * It reports status codes only, never a token.
 */
async function healthCheck(request: Request, url: URL, env: Env): Promise<Response> {
  if (url.searchParams.get("deep") !== "1") return Response.json({ ok: true });

  const secret = env.HEALTH_CHECK_SECRET;
  const given = /^Bearer (.+)$/.exec(request.headers.get("authorization") ?? "")?.[1] ?? "";
  if (!secret || !(await sameSecret(given, secret))) return new Response("Unauthorized", { status: 401 });

  const status = async (call: () => Promise<Response>): Promise<number> => {
    try {
      return (await call()).status;
    } catch {
      return 0;
    }
  };
  const github = (path: string) => status(() => fetch(`https://api.github.com${path}`, { headers: githubHeaders(env) }));
  const repos: Record<string, number> = {};
  for (const mapped of new Set(Object.values(env.PROJECT_REPOS))) {
    const repo = fullRepoName(mapped, env.GITHUB_OWNER);
    repos[repo] = await github(`/repos/${repo}`);
  }
  const linearStatus = await status(() =>
    fetch(LINEAR_API, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: env.LINEAR_API_KEY },
      body: JSON.stringify({ query: `query Health { viewer { id } }` }),
    }),
  );
  const githubToken = await github("/rate_limit");
  const ok = githubToken === 200 && linearStatus === 200 && Object.values(repos).every((s) => s === 200);
  return Response.json({ ok, github: githubToken, linear: linearStatus, repos }, { status: ok ? 200 : 503 });
}

/** Compares two secrets without leaking where they differ (both are hashed first, so the lengths match). */
async function sameSecret(a: string, b: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [ha, hb] = await Promise.all(
    [a, b].map(async (v) => new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(v)))),
  );
  return crypto.subtle.timingSafeEqual(ha, hb);
}

/** True for newly created issues and for updates that changed the state. */
function isIssueStateEvent(payload: any): boolean {
  if (payload?.type !== "Issue" || !payload?.data?.id) return false;
  if (payload.action === "create") return true;
  return payload.action === "update" && payload.updatedFrom != null && "stateId" in payload.updatedFrom;
}

/** True for newly created comments on an issue. */
function isNewCommentEvent(payload: any): boolean {
  return payload?.type === "Comment" && payload.action === "create" && typeof payload.data?.issueId === "string" && typeof payload.data?.body === "string";
}

// ---------- Commands in Linear comments ----------

/** Every comment the factory writes starts with one of these, so the relay never reads them as commands. */
const FACTORY_MARKERS = ["🏭", "🔧", "✅", "🙋", "💥", "🤔"];
const ANSWERS_HEADING = "## Answers from Koen";

type Command = { kind: "approve" } | { kind: "change"; instructions: string };

/** "approve" or "merge" approves; "change" or "fix" asks for changes with the rest as instructions. Otherwise null. */
function parseCommand(body: string): Command | null {
  const match = /^\s*(approve[ds]?|merge[ds]?|changes?|fix(?:es)?)\b[\s:,.!-]*([\s\S]*)$/i.exec(body);
  if (!match) return null;
  const word = match[1].toLowerCase();
  if (word.startsWith("approve") || word.startsWith("merge")) return { kind: "approve" };
  return { kind: "change", instructions: match[2].trim() };
}

interface PullRequest {
  number: number;
  html_url: string;
  head: { ref: string };
  labels: { name: string }[];
}

/** The open PR for a ticket: its branch starts with the lowercased identifier (kv-45-…). */
async function findOpenPr(repo: string, identifier: string, env: Env): Promise<PullRequest | null> {
  const prefix = `${identifier.toLowerCase()}-`;
  for (let page = 1; page <= 5; page++) {
    const res = await fetch(`https://api.github.com/repos/${repo}/pulls?state=open&per_page=100&page=${page}`, {
      headers: githubHeaders(env),
    });
    if (!res.ok) throw new Error(`GitHub answered ${res.status} when listing pull requests in ${repo}. The relay's token needs *Pull requests: Read* on it.`);
    const prs = (await res.json()) as PullRequest[];
    const found = prs.find((pr) => pr.head.ref.toLowerCase().startsWith(prefix));
    if (found) return found;
    if (prs.length < 100) break;
  }
  return null;
}

async function handleComment(data: { id?: string; issueId: string; body: string }, env: Env): Promise<void> {
  const body = data.body.trim();
  if (FACTORY_MARKERS.some((m) => body.startsWith(m))) return;

  const command = parseCommand(body);
  const issue = await getIssue(data.issueId, env);
  if (!issue) return;
  const awaitingAnswer = sameName(issue.state.name, env.NEEDS_HUMAN_STATE);
  if (!command && !awaitingAnswer) return;

  const mapped = issue.project?.name ? findRepo(issue.project.name, env.PROJECT_REPOS) : undefined;
  if (!mapped) {
    console.log(`${issue.identifier}: comment ignored, no repo for project "${issue.project?.name ?? "(none)"}"`);
    return;
  }
  const repo = fullRepoName(mapped, env.GITHUB_OWNER);

  let pr: PullRequest | null;
  try {
    pr = await findOpenPr(repo, issue.identifier, env);
  } catch (err) {
    console.error(`${issue.identifier}: PR lookup failed`, String(err));
    if (command) await addComment(issue.id, `🏭 Couldn't look up the pull request for this ticket. ${String(err instanceof Error ? err.message : err)}`, env);
    return;
  }

  if (!pr) {
    if (awaitingAnswer) return answerQuestions(issue, body, env);
    if (command) {
      await addComment(issue.id, `🏭 Can't ${command.kind === "approve" ? "approve" : "change"} anything: there is no open pull request for ${issue.identifier} in \`${repo}\`.`, env);
    }
    return;
  }
  if (!command) return;

  const verb = command.kind === "approve" ? "approve" : "change";
  if (!pr.labels.some((l) => l.name === "agent-built")) {
    await addComment(issue.id, `🏭 Can't ${verb} ${pr.html_url}: it isn't a factory PR (no \`agent-built\` label), and the factory only merges or changes its own PRs.`, env);
    return;
  }

  if (command.kind === "approve") {
    const response = await dispatchBuild(repo, {
      event_type: "factory-approve",
      client_payload: { pr_number: String(pr.number), identifier: issue.identifier },
    }, env);
    if (!response.ok) {
      console.error(`GitHub dispatch to ${repo} failed`, response.status, await response.text());
      await addComment(issue.id, `🏭 Couldn't start the merge of ${pr.html_url}: ${dispatchFailureMessage(repo, response.status)}`, env);
      return;
    }
    await addComment(issue.id, `🏭 Got it: approving ${pr.html_url}. It merges (squash) once its required checks pass, and I'll say here when it has.`, env);
    return;
  }

  if (!command.instructions) {
    await addComment(issue.id, `🏭 Say what to change, for example \`change: make the button blue\`. Nothing was sent to the builder.`, env);
    return;
  }
  const response = await dispatchBuild(repo, {
    event_type: "factory-fix",
    client_payload: {
      pr_number: String(pr.number),
      round: "0",
      requested: "true",
      identifier: issue.identifier,
      feedback: command.instructions.slice(0, MAX_DESCRIPTION_CHARS),
    },
  }, env);
  if (!response.ok) {
    console.error(`GitHub dispatch to ${repo} failed`, response.status, await response.text());
    await addComment(issue.id, `🏭 Couldn't start a fix round on ${pr.html_url}: ${dispatchFailureMessage(repo, response.status)}`, env);
    return;
  }
  await addComment(issue.id, `🏭 Got it: the builder is applying your changes to ${pr.html_url}. This round doesn't count towards the automatic limit.`, env);
}

/** The builder asked questions and there is no PR yet: put the comment in the description and send the ticket back to the builder. */
async function answerQuestions(issue: LinearIssue, answer: string, env: Env): Promise<void> {
  const ready = issue.team.states.nodes.find((s) => sameName(s.name, env.AGENT_READY_STATE));
  if (!ready) {
    console.warn(`Linear state "${env.AGENT_READY_STATE}" not found on the issue's team`);
    return;
  }
  const current = issue.description ?? "";
  const description = current.includes(ANSWERS_HEADING)
    ? `${current}\n\n${answer}`
    : `${current}${current ? "\n\n" : ""}${ANSWERS_HEADING}\n\n${answer}`;
  await linear(
    `mutation Answer($id: String!, $description: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { description: $description, stateId: $stateId }) { success }
    }`,
    { id: issue.id, description, stateId: ready.id },
    env,
  );
  await addComment(issue.id, `🏭 Thanks, added your answer to the description under "Answers from Koen" and moved this to ${env.AGENT_READY_STATE}. The builder continues with it.`, env);
}

async function handleIssue(issueId: string, env: Env): Promise<void> {
  const issue = await getIssue(issueId, env);
  if (!issue) {
    console.log(`Skipped ${issueId}: issue not found`);
    return;
  }
  if (!sameName(issue.state.name, env.AGENT_READY_STATE)) {
    console.log(`Skipped ${issue.identifier}: state is "${issue.state.name}", not "${env.AGENT_READY_STATE}"`);
    return;
  }

  const projectName = issue.project?.name;
  const mapped = projectName ? findRepo(projectName, env.PROJECT_REPOS) : undefined;
  const repo = mapped ? fullRepoName(mapped, env.GITHUB_OWNER) : undefined;
  console.log(`${issue.identifier}: project "${projectName ?? "(none)"}" -> repo ${repo ?? "(none)"}`);

  if (!repo) {
    const reason = projectName
      ? `No GitHub repo is mapped to the Linear project **${projectName}**. Add it to \`PROJECT_REPOS\` in the relay's \`wrangler.jsonc\`.`
      : "This issue isn't in a Linear project, so the factory doesn't know which repo to build in. Add it to a project and move it back to Agent Ready.";
    await addComment(issue.id, `🏭 Factory couldn't pick this up. ${reason}`, env);
    await setState(issue, env.NEEDS_HUMAN_STATE, env);
    return;
  }

  const description = (issue.description ?? "").slice(0, MAX_DESCRIPTION_CHARS);
  const response = await dispatchBuild(repo, {
    event_type: "factory-build",
    client_payload: {
      issue_id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description,
      url: issue.url,
    },
  }, env);

  if (!response.ok) {
    const detail = await response.text();
    console.error(`GitHub dispatch to ${repo} failed`, response.status, detail);
    await addComment(
      issue.id,
      dispatchFailureMessage(repo, response.status),
      env,
    );
    await setState(issue, env.NEEDS_HUMAN_STATE, env);
    return;
  }

  console.log(`${issue.identifier}: build started in ${repo}`);
  await setState(issue, env.AGENT_WORKING_STATE, env);
  await addComment(
    issue.id,
    `🏭 Picked up by the factory. Building in \`${repo}\`; progress is in [GitHub Actions](https://github.com/${repo}/actions).`,
    env,
  );
}

function githubHeaders(env: Env): Record<string, string> {
  return {
    Authorization: `Bearer ${env.GITHUB_TOKEN}`,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "factory-relay",
  };
}

/**
 * Sends the repository_dispatch. GitHub answers 301/307/308 with a Location for a moved repo;
 * fetch would turn a redirected POST into a GET, so follow it by hand, once, with the same POST.
 */
async function dispatchBuild(repo: string, payload: unknown, env: Env): Promise<Response> {
  const init: RequestInit = {
    method: "POST",
    redirect: "manual",
    headers: { ...githubHeaders(env), "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  };
  const url = `https://api.github.com/repos/${repo}/dispatches`;
  const response = await fetch(url, init);
  const location = response.headers.get("Location");
  if (![301, 307, 308].includes(response.status) || !location) return response;

  let target: URL;
  try {
    target = new URL(location, url);
  } catch {
    return response;
  }
  // The token only goes to GitHub's API.
  if (target.protocol !== "https:" || target.hostname !== "api.github.com") {
    console.warn(`GitHub redirected ${repo} to an unexpected location; not following it`);
    return response;
  }
  console.warn(`Repo ${repo} has moved (GitHub answered ${response.status}); retrying at ${target.pathname}. Update PROJECT_REPOS / GITHUB_OWNER.`);
  return fetch(target.toString(), init);
}

/** Gives a new issue Origin › Human unless it already has a label from the Origin group. */
async function labelOrigin(data: any, env: Env): Promise<void> {
  const existing: string[] = Array.isArray(data.labelIds) ? data.labelIds : [];
  const found = await linear<{ issueLabels: { nodes: { id: string; name: string }[] } }>(
    `query OriginLabels {
      issueLabels(first: 50, filter: { parent: { name: { eq: "Origin" } } }) { nodes { id name } }
    }`,
    {},
    env,
  );
  const origins = found.issueLabels.nodes;
  if (origins.some((l) => existing.includes(l.id))) return;
  const human = origins.find((l) => sameName(l.name, "Human"));
  if (!human) {
    console.warn('Label "Origin › Human" not found; leaving the issue unlabelled');
    return;
  }
  await linear(
    `mutation AddOrigin($id: String!, $labelId: String!) {
      issueAddLabel(id: $id, labelId: $labelId) { success }
    }`,
    { id: data.id, labelId: human.id },
    env,
  );
  console.log(`${data.id}: labelled Origin › Human`);
}

interface BlockedCandidate {
  id: string;
  identifier: string;
  state: { name: string };
  labels: { nodes: { name: string }[] };
  team: { states: { nodes: { id: string; name: string }[] } };
  inverseRelations: { nodes: { type: string; issue: { identifier: string; state: { type: string } } }[] };
}

/**
 * When an issue becomes completed or canceled, looks at the issues it blocks. Those in the
 * Blocked state whose blockers are all finished move on: to Todo (a blocker was canceled, or
 * the ticket is `factory:manual` or lacks Auto-start) or to Agent Ready (Auto-start). Moving to
 * Agent Ready sends its own webhook, which starts the build. Never throws into the build path:
 * the caller only logs a warning.
 */
async function releaseBlocked(issueId: string, env: Env): Promise<void> {
  const data = await linear<{
    issue: { identifier: string; state: { type: string }; relations: { nodes: { type: string; relatedIssue: BlockedCandidate }[] } } | null;
  }>(
    `query BlockedByThis($id: String!) {
      issue(id: $id) {
        identifier
        state { type }
        relations(first: 50) {
          nodes {
            type
            relatedIssue {
              id identifier
              state { name }
              labels(first: 20) { nodes { name } }
              team { states(first: 30) { nodes { id name } } }
              inverseRelations(first: 30) { nodes { type issue { identifier state { type } } } }
            }
          }
        }
      }
    }`,
    { id: issueId },
    env,
  );
  const done = data.issue;
  if (!done || (done.state.type !== "completed" && done.state.type !== "canceled")) return;

  for (const rel of done.relations.nodes) {
    if (rel.type !== "blocks") continue;
    const blocked = rel.relatedIssue;
    try {
      if (!sameName(blocked.state.name, env.BLOCKED_STATE)) continue;
      const blockers = blocked.inverseRelations.nodes.filter((r) => r.type === "blocks").map((r) => r.issue);
      if (blockers.some((b) => b.state.type !== "completed" && b.state.type !== "canceled")) continue;

      const labels = blocked.labels.nodes.map((l) => l.name);
      const hasLabel = (name: string) => labels.some((l) => sameName(l, name));
      const canceled = blockers.some((b) => b.state.type === "canceled");
      const toReady = !canceled && hasLabel(env.AUTO_START_LABEL) && !hasLabel(env.MANUAL_LABEL);
      const target = toReady ? env.AGENT_READY_STATE : env.TODO_STATE;

      const state = blocked.team.states.nodes.find((s) => sameName(s.name, target));
      if (!state) {
        console.warn(`Linear state "${target}" not found on the team of ${blocked.identifier}; leaving it in Blocked`);
        continue;
      }
      await linear(
        `mutation SetState($id: String!, $stateId: String!) {
          issueUpdate(id: $id, input: { stateId: $stateId }) { success }
        }`,
        { id: blocked.id, stateId: state.id },
        env,
      );
      const message = canceled
        ? `🏭 The plan changed: a ticket blocking this one was canceled (${done.identifier} triggered this check). Moved to ${target} for a human to decide.`
        : toReady
          ? `🏭 Unblocked: ${done.identifier} was the last ticket blocking this one. It has **${env.AUTO_START_LABEL}**, so it moved to ${target}.`
          : `🏭 Unblocked: ${done.identifier} was the last ticket blocking this one. Moved to ${target}.`;
      await addComment(blocked.id, message, env);
      console.log(`${blocked.identifier}: unblocked by ${done.identifier}, moved to ${target}`);
    } catch (err) {
      console.warn(`Releasing ${blocked.identifier} failed`, String(err));
    }
  }
}

function dispatchFailureMessage(repo: string, status: number): string {
  const prefix = `🏭 Factory couldn't start a build in \`${repo}\`.`;
  if (status === 401) {
    return `${prefix} GitHub answered 401: the relay's GitHub token is invalid or expired. Replace \`GITHUB_TOKEN\` in Infisical (\`/cloudflare/factory-relay\`).`;
  }
  if (status === 403 || status === 404) {
    return `${prefix} GitHub answered ${status}: the token works but can't reach that repo. Give it *Contents: Read and write* on \`${repo}\`.`;
  }
  return `${prefix} GitHub answered ${status}.`;
}

// ---------- Name matching (case-insensitive, ignores extra spaces) ----------

function sameName(a: string, b: string): boolean {
  return a.trim().toLowerCase() === b.trim().toLowerCase();
}

/** "backpack" becomes "<owner>/backpack"; "owner/backpack" is left alone. */
function fullRepoName(repo: string, owner: string): string {
  const name = repo.trim();
  return name.includes("/") || !owner ? name : `${owner.trim()}/${name}`;
}

function findRepo(projectName: string, repos: Record<string, string>): string | undefined {
  const key = Object.keys(repos).find((k) => sameName(k, projectName));
  return key ? repos[key] : undefined;
}

// ---------- Linear API ----------

async function linear<T>(query: string, variables: Record<string, unknown>, env: Env): Promise<T> {
  const res = await fetch(LINEAR_API, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: env.LINEAR_API_KEY },
    body: JSON.stringify({ query, variables }),
  });
  const json: any = await res.json();
  if (!res.ok || json.errors) {
    const messages = Array.isArray(json.errors)
      ? json.errors.map((e: any) => e?.message ?? JSON.stringify(e)).join("; ")
      : JSON.stringify(json);
    throw new Error(`Linear API error ${res.status}: ${messages}`);
  }
  return json.data as T;
}

async function getIssue(id: string, env: Env): Promise<LinearIssue | null> {
  const data = await linear<{ issue: LinearIssue | null }>(
    `query Issue($id: String!) {
      issue(id: $id) {
        id identifier title description url
        state { id name }
        project { name }
        team { states(first: 30) { nodes { id name } } }
      }
    }`,
    { id },
    env,
  );
  return data.issue;
}

async function setState(issue: LinearIssue, stateName: string, env: Env): Promise<void> {
  const state = issue.team.states.nodes.find((s) => sameName(s.name, stateName));
  if (!state) {
    console.warn(`Linear state "${stateName}" not found on the issue's team`);
    return;
  }
  await linear(
    `mutation SetState($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) { success }
    }`,
    { id: issue.id, stateId: state.id },
    env,
  );
}

async function addComment(issueId: string, body: string, env: Env): Promise<void> {
  await linear(
    `mutation Comment($issueId: String!, $body: String!) {
      commentCreate(input: { issueId: $issueId, body: $body }) { success }
    }`,
    { issueId, body },
    env,
  );
}

// ---------- Webhook signature ----------

/** Linear signs the raw body with HMAC-SHA256 (hex) using the webhook's signing secret. */
async function isValidSignature(body: string, signature: string, secret: string): Promise<boolean> {
  if (!secret) return false;
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(body));
  const expected = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");

  const a = encoder.encode(expected);
  const b = encoder.encode(signature.trim().toLowerCase());
  if (a.byteLength !== b.byteLength) return false;
  return crypto.subtle.timingSafeEqual(a, b);
}
