import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { type Env } from "../src/index";

const SECRET = "test-secret";

const env: Env = {
  LINEAR_API_KEY: "linear-key",
  LINEAR_WEBHOOK_SECRET: SECRET,
  GITHUB_TOKEN: "gh-token",
  AGENT_READY_STATE: "Agent Ready",
  AGENT_WORKING_STATE: "Agent Working",
  NEEDS_HUMAN_STATE: "Needs Human",
  PROJECT_REPOS: { Backpack: "acme/backpack" },
};

const STATES = [
  { id: "s-ready", name: "Agent Ready" },
  { id: "s-working", name: "Agent Working" },
  { id: "s-human", name: "Needs Human" },
];

interface Call {
  url: string;
  init: RequestInit;
  body: any;
}

let calls: Call[];
let issue: any;
let githubStatus: number;

function makeIssue(overrides: Record<string, unknown> = {}) {
  return {
    id: "issue-1",
    identifier: "KOE-1",
    title: "Do a thing",
    description: "Details",
    url: "https://linear.app/koe/issue/KOE-1",
    state: { id: "s-ready", name: "Agent Ready" },
    project: { name: "Backpack" },
    team: { states: { nodes: STATES } },
    ...overrides,
  };
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
}

beforeEach(() => {
  calls = [];
  issue = makeIssue();
  githubStatus = 204;
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.stubGlobal("fetch", async (input: any, init: RequestInit = {}) => {
    const url = String(input);
    const body = init.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ url, init, body });
    if (url === "https://api.linear.app/graphql") {
      if (body.query.includes("query Issue")) return json({ data: { issue } });
      return json({ data: { ok: { success: true } } });
    }
    if (url.startsWith("https://api.github.com/")) {
      return new Response(githubStatus === 204 ? null : "nope", { status: githubStatus });
    }
    throw new Error(`Unexpected network call to ${url}`);
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

async function sign(body: string, secret = SECRET): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(body));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function stateChange(overrides: Record<string, unknown> = {}) {
  return {
    type: "Issue",
    action: "update",
    data: { id: "issue-1" },
    updatedFrom: { stateId: "old" },
    webhookTimestamp: Date.now(),
    ...overrides,
  };
}

async function send(payload: unknown, opts: { signature?: string | null; secret?: string } = {}) {
  const body = JSON.stringify(payload);
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  const signature = opts.signature === undefined ? await sign(body, opts.secret) : opts.signature;
  if (signature !== null) headers["linear-signature"] = signature;

  const pending: Promise<unknown>[] = [];
  const ctx = { waitUntil: (p: Promise<unknown>) => void pending.push(p), passThroughOnException() {} };
  const response = await worker.fetch(
    new Request("https://relay.test/", { method: "POST", headers, body }) as any,
    env,
    ctx as any,
  );
  await Promise.all(pending);
  return response;
}

const linearCalls = () => calls.filter((c) => c.url === "https://api.linear.app/graphql");
const githubCalls = () => calls.filter((c) => c.url.startsWith("https://api.github.com/"));
const stateUpdates = () =>
  linearCalls().filter((c) => c.body.query.includes("SetState")).map((c) => c.body.variables.stateId);
const comments = () =>
  linearCalls().filter((c) => c.body.query.includes("Comment")).map((c) => c.body.variables.body as string);

describe("webhook security", () => {
  it("accepts a valid signature", async () => {
    const res = await send(stateChange());
    expect(res.status).toBe(202);
  });

  it("rejects a missing signature", async () => {
    const res = await send(stateChange(), { signature: null });
    expect(res.status).toBe(401);
    expect(calls).toHaveLength(0);
  });

  it("rejects a wrong signature", async () => {
    const res = await send(stateChange(), { secret: "other-secret" });
    expect(res.status).toBe(401);
    expect(calls).toHaveLength(0);
  });

  it("rejects a malformed signature", async () => {
    const res = await send(stateChange(), { signature: "abc" });
    expect(res.status).toBe(401);
  });

  it("rejects a stale timestamp", async () => {
    const res = await send(stateChange({ webhookTimestamp: Date.now() - 10 * 60 * 1000 }));
    expect(res.status).toBe(401);
    expect(calls).toHaveLength(0);
  });
});

describe("event filtering", () => {
  it("ignores non-issue events", async () => {
    const res = await send(stateChange({ type: "Comment" }));
    expect(await res.text()).toBe("Ignored");
    expect(calls).toHaveLength(0);
  });

  it("ignores issue updates that didn't change the state", async () => {
    const res = await send(stateChange({ updatedFrom: { title: "old" } }));
    expect(await res.text()).toBe("Ignored");
    expect(calls).toHaveLength(0);
  });

  it("ignores issue removals", async () => {
    const res = await send(stateChange({ action: "remove" }));
    expect(await res.text()).toBe("Ignored");
    expect(calls).toHaveLength(0);
  });

  it("does nothing when the issue isn't in Agent Ready", async () => {
    issue = makeIssue({ state: { id: "s-working", name: "Agent Working" } });
    await send(stateChange());
    expect(githubCalls()).toHaveLength(0);
    expect(stateUpdates()).toHaveLength(0);
    expect(comments()).toHaveLength(0);
  });
});

describe("Agent Ready", () => {
  it.each(["Agent Ready", "agent ready", "AGENT READY"])("starts a build for state %j", async (name) => {
    issue = makeIssue({ state: { id: "s-ready", name } });
    await send(stateChange());

    expect(githubCalls()).toHaveLength(1);
    const gh = githubCalls()[0];
    expect(gh.url).toBe("https://api.github.com/repos/acme/backpack/dispatches");
    expect((gh.init.headers as Record<string, string>).Authorization).toBe("Bearer gh-token");
    expect(gh.body.event_type).toBe("factory-build");
    expect(gh.body.client_payload).toMatchObject({
      issue_id: "issue-1",
      identifier: "KOE-1",
      title: "Do a thing",
      description: "Details",
    });

    expect(stateUpdates()).toEqual(["s-working"]);
    expect(comments()).toHaveLength(1);
    expect(comments()[0]).toContain("acme/backpack");
  });

  it("matches the project name case-insensitively", async () => {
    issue = makeIssue({ project: { name: "backpack" } });
    await send(stateChange());
    expect(githubCalls()[0].url).toContain("acme/backpack");
  });

  it("handles newly created issues", async () => {
    await send(stateChange({ action: "create", updatedFrom: undefined }));
    expect(githubCalls()).toHaveLength(1);
  });
});

describe("problems", () => {
  it("sends an issue in an unmapped project to Needs Human with a comment", async () => {
    issue = makeIssue({ project: { name: "Mystery" } });
    await send(stateChange());
    expect(githubCalls()).toHaveLength(0);
    expect(stateUpdates()).toEqual(["s-human"]);
    expect(comments()).toHaveLength(1);
    expect(comments()[0]).toContain("Mystery");
  });

  it("sends an issue with no project to Needs Human with a comment", async () => {
    issue = makeIssue({ project: null });
    await send(stateChange());
    expect(githubCalls()).toHaveLength(0);
    expect(stateUpdates()).toEqual(["s-human"]);
    expect(comments()[0]).toContain("isn't in a Linear project");
  });

  it("sends the issue to Needs Human with a comment when GitHub rejects the build", async () => {
    githubStatus = 404;
    await send(stateChange());
    expect(githubCalls()).toHaveLength(1);
    expect(stateUpdates()).toEqual(["s-human"]);
    expect(comments()).toHaveLength(1);
    expect(comments()[0]).toContain("404");
  });
});
