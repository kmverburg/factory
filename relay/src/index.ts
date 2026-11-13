/**
 * factory-relay
 *
 * Receives Linear webhooks. When an issue enters the "Agent Ready" state, it
 * looks up which GitHub repo belongs to the issue's Linear project, triggers
 * the factory build workflow in that repo, and moves the issue to
 * "Agent Working". Anything it can't handle goes to "Needs Human" with a
 * comment explaining why.
 */

export interface Env {
  // Secrets (set in the Cloudflare dashboard or with `wrangler secret put`)
  LINEAR_API_KEY: string;
  LINEAR_WEBHOOK_SECRET: string;
  GITHUB_TOKEN: string;

  // Plain vars (set in wrangler.jsonc)
  AGENT_READY_STATE: string;
  AGENT_WORKING_STATE: string;
  NEEDS_HUMAN_STATE: string;
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

    if (!isIssueStateEvent(payload)) {
      return new Response("Ignored");
    }

    // Answer Linear right away; do the work in the background.
    ctx.waitUntil(
      handleIssue(payload.data.id, env).catch((err) => console.error("handleIssue failed", err)),
    );
    return new Response("Accepted", { status: 202 });
  },
} satisfies ExportedHandler<Env>;

/** True for newly created issues and for updates that changed the state. */
function isIssueStateEvent(payload: any): boolean {
  if (payload?.type !== "Issue" || !payload?.data?.id) return false;
  if (payload.action === "create") return true;
  return payload.action === "update" && payload.updatedFrom != null && "stateId" in payload.updatedFrom;
}

async function handleIssue(issueId: string, env: Env): Promise<void> {
  const issue = await getIssue(issueId, env);
  if (!issue || issue.state.name !== env.AGENT_READY_STATE) return;

  const projectName = issue.project?.name;
  const repo = projectName ? env.PROJECT_REPOS[projectName] : undefined;

  if (!repo) {
    const reason = projectName
      ? `No GitHub repo is mapped to the Linear project **${projectName}**. Add it to \`PROJECT_REPOS\` in the relay's \`wrangler.jsonc\`.`
      : "This issue isn't in a Linear project, so the factory doesn't know which repo to build in. Add it to a project and move it back to Agent Ready.";
    await addComment(issue.id, `🏭 Factory couldn't pick this up. ${reason}`, env);
    await setState(issue, env.NEEDS_HUMAN_STATE, env);
    return;
  }

  const description = (issue.description ?? "").slice(0, MAX_DESCRIPTION_CHARS);
  const response = await fetch(`https://api.github.com/repos/${repo}/dispatches`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "factory-relay",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      event_type: "factory-build",
      client_payload: {
        issue_id: issue.id,
        identifier: issue.identifier,
        title: issue.title,
        description,
        url: issue.url,
      },
    }),
  });

  if (!response.ok) {
    const detail = await response.text();
    console.error(`GitHub dispatch to ${repo} failed`, response.status, detail);
    await addComment(
      issue.id,
      `🏭 Factory couldn't start a build in \`${repo}\` (GitHub answered ${response.status}). Check that the relay's GitHub token has *Contents: read and write* access to that repo.`,
      env,
    );
    await setState(issue, env.NEEDS_HUMAN_STATE, env);
    return;
  }

  await setState(issue, env.AGENT_WORKING_STATE, env);
  await addComment(
    issue.id,
    `🏭 Picked up by the factory. Building in \`${repo}\`; progress is in [GitHub Actions](https://github.com/${repo}/actions).`,
    env,
  );
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
    throw new Error(`Linear API error ${res.status}: ${JSON.stringify(json.errors ?? json)}`);
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
        team { states { nodes { id name } } }
      }
    }`,
    { id },
    env,
  );
  return data.issue;
}

async function setState(issue: LinearIssue, stateName: string, env: Env): Promise<void> {
  const state = issue.team.states.nodes.find((s) => s.name === stateName);
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
