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
  BLOCKED_STATE: "Blocked",
  TODO_STATE: "Todo",
  AUTO_START_LABEL: "Auto-start",
  MANUAL_LABEL: "factory:manual",
  PROJECT_REPOS: { Backpack: "acme/backpack" },
};

const STATES = [
  { id: "s-ready", name: "Agent Ready" },
  { id: "s-working", name: "Agent Working" },
  { id: "s-human", name: "Needs Human" },
  { id: "s-todo", name: "Todo" },
  { id: "s-blocked", name: "Blocked" },
];

interface Call {
  url: string;
  init: RequestInit;
  body: any;
}

let calls: Call[];
let issue: any;
let githubStatus: number;
let originLabels: { id: string; name: string }[];
let labelUpdateFails: boolean;
let blockerIssue: any;

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
  originLabels = [
    { id: "l-human", name: "Human" },
    { id: "l-agent", name: "Agent" },
  ];
  labelUpdateFails = false;
  blockerIssue = null;
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.stubGlobal("fetch", async (input: any, init: RequestInit = {}) => {
    const url = String(input);
    const body = init.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ url, init, body });
    if (url === "https://api.linear.app/graphql") {
      if (body.query.includes("BlockedByThis")) return json({ data: { issue: blockerIssue } });
      if (body.query.includes("query Issue")) return json({ data: { issue } });
      if (body.query.includes("OriginLabels")) return json({ data: { issueLabels: { nodes: originLabels } } });
      if (body.query.includes("AddOrigin") && labelUpdateFails) return json({ errors: [{ message: "boom" }] }, 500);
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

const labelAdds = () =>
  linearCalls().filter((c) => c.body.query.includes("AddOrigin")).map((c) => c.body.variables);

describe("Origin label", () => {
  const created = (labelIds?: string[]) =>
    stateChange({ action: "create", updatedFrom: undefined, data: { id: "issue-1", labelIds } });

  it("adds Origin › Human when no Origin label is present", async () => {
    issue = makeIssue({ state: { id: "s-working", name: "Todo" } });
    await send(created(["l-bug"]));
    expect(labelAdds()).toEqual([{ id: "issue-1", labelId: "l-human" }]);
  });

  it("adds Origin › Human when the issue has no labels at all", async () => {
    await send(created(undefined));
    expect(labelAdds()).toEqual([{ id: "issue-1", labelId: "l-human" }]);
  });

  it("leaves an issue with Origin › Agent alone", async () => {
    await send(created(["l-bug", "l-agent"]));
    expect(labelAdds()).toHaveLength(0);
  });

  it("leaves an issue with Origin › Human alone", async () => {
    await send(created(["l-human"]));
    expect(labelAdds()).toHaveLength(0);
  });

  it("does not label on updates", async () => {
    await send(stateChange());
    expect(linearCalls().some((c) => c.body.query.includes("OriginLabels"))).toBe(false);
  });

  it("warns and still starts the build when the label update fails", async () => {
    labelUpdateFails = true;
    await send(created([]));
    expect(console.warn).toHaveBeenCalled();
    expect(githubCalls()).toHaveLength(1);
    expect(stateUpdates()).toEqual(["s-working"]);
  });

  it("warns and carries on when the Origin labels can't be found", async () => {
    originLabels = [];
    await send(created([]));
    expect(labelAdds()).toHaveLength(0);
    expect(console.warn).toHaveBeenCalled();
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

  it("says the token is invalid or expired when GitHub answers 401", async () => {
    githubStatus = 401;
    await send(stateChange());
    expect(stateUpdates()).toEqual(["s-human"]);
    expect(comments()).toHaveLength(1);
    expect(comments()[0]).toContain("invalid or expired");
    expect(comments()[0]).toContain("GITHUB_TOKEN");
    expect(comments()[0]).toContain("/cloudflare/factory-relay");
  });

  it.each([403, 404])("says the token can't reach the repo when GitHub answers %i", async (status) => {
    githubStatus = status;
    await send(stateChange());
    expect(stateUpdates()).toEqual(["s-human"]);
    expect(comments()).toHaveLength(1);
    expect(comments()[0]).toContain("can't reach that repo");
    expect(comments()[0]).toContain("Contents: Read and write");
    expect(comments()[0]).toContain("acme/backpack");
  });

  it("keeps a general message with the status code for other failures", async () => {
    githubStatus = 500;
    await send(stateChange());
    expect(stateUpdates()).toEqual(["s-human"]);
    expect(comments()).toHaveLength(1);
    expect(comments()[0]).toContain("500");
    expect(comments()[0]).not.toContain("token");
  });
});

describe("releasing blocked tickets", () => {
  const blocker = (identifier: string, type: string) => ({ type: "blocks", issue: { identifier, state: { type } } });
  const setup = (opts: { type?: string; labels?: string[]; state?: string; blockers?: any[] } = {}) => {
    blockerIssue = {
      identifier: "KOE-10",
      state: { type: opts.type ?? "completed" },
      relations: {
        nodes: [
          {
            type: "blocks",
            relatedIssue: {
              id: "blocked-1",
              identifier: "KOE-11",
              state: { name: opts.state ?? "Blocked" },
              labels: { nodes: (opts.labels ?? []).map((name) => ({ name })) },
              team: { states: { nodes: STATES } },
              inverseRelations: { nodes: opts.blockers ?? [blocker("KOE-10", opts.type ?? "completed")] },
            },
          },
        ],
      },
    };
    // The triggering issue itself is not in Agent Ready.
    issue = makeIssue({ state: { id: "s-working", name: "Done" } });
  };
  const moves = () =>
    linearCalls().filter((c) => c.body.query.includes("SetState")).map((c) => [c.body.variables.id, c.body.variables.stateId]);

  it("moves to Agent Ready with Auto-start and comments which ticket unblocked it", async () => {
    setup({ labels: ["Auto-start"] });
    await send(stateChange());
    expect(moves()).toEqual([["blocked-1", "s-ready"]]);
    expect(comments()[0]).toContain("KOE-10");
    expect(githubCalls()).toHaveLength(0); // the resulting webhook starts the build
  });

  it("moves to Todo without Auto-start", async () => {
    setup();
    await send(stateChange());
    expect(moves()).toEqual([["blocked-1", "s-todo"]]);
    expect(comments()[0]).toContain("KOE-10");
  });

  it("matches label names case-insensitively", async () => {
    setup({ labels: ["AUTO-START"] });
    await send(stateChange());
    expect(moves()).toEqual([["blocked-1", "s-ready"]]);
  });

  it("leaves the ticket in Blocked while another blocker is unfinished", async () => {
    setup({ labels: ["Auto-start"], blockers: [blocker("KOE-10", "completed"), blocker("KOE-12", "started")] });
    await send(stateChange());
    expect(moves()).toEqual([]);
    expect(comments()).toEqual([]);
  });

  it("moves to Todo when a blocker was canceled, even with Auto-start", async () => {
    setup({ type: "canceled", labels: ["Auto-start"] });
    await send(stateChange());
    expect(moves()).toEqual([["blocked-1", "s-todo"]]);
    expect(comments()[0]).toContain("plan changed");
  });

  it("sends factory:manual tickets to Todo even with Auto-start", async () => {
    setup({ labels: ["Auto-start", "factory:manual"] });
    await send(stateChange());
    expect(moves()).toEqual([["blocked-1", "s-todo"]]);
  });

  it("leaves tickets that aren't in Blocked alone", async () => {
    setup({ state: "In Progress", labels: ["Auto-start"] });
    await send(stateChange());
    expect(moves()).toEqual([]);
    expect(comments()).toEqual([]);
  });

  it("does nothing when the issue isn't completed or canceled", async () => {
    setup({ type: "started" });
    await send(stateChange());
    expect(moves()).toEqual([]);
  });

  it("warns and still starts builds when Linear fails", async () => {
    setup();
    blockerIssue = null;
    issue = makeIssue();
    await send(stateChange());
    expect(githubCalls()).toHaveLength(1);
  });

  it("warns with Linear's own error message when releasing fails", async () => {
    setup();
    const original = globalThis.fetch;
    vi.stubGlobal("fetch", async (input: any, init: RequestInit = {}) => {
      const body = init.body ? JSON.parse(String(init.body)) : undefined;
      if (body?.query?.includes("BlockedByThis")) {
        return json({ errors: [{ message: "Query too complex" }] }, 400);
      }
      return original(input, init);
    });
    await send(stateChange());
    const warned = (console.warn as any).mock.calls.map((c: any[]) => c.join(" ")).join("\n");
    expect(warned).toContain("Query too complex");
  });

  it("asks for explicit, small page sizes in every GraphQL query", async () => {
    // Linear rejects queries over a complexity limit; unpaged connections default to 50 items.
    setup();
    await send({ ...stateChange(), action: "create" });
    await send(stateChange());
    const queries = linearCalls().map((c) => c.body.query as string);
    expect(queries.length).toBeGreaterThan(3);
    for (const q of queries) {
      const connections = q.match(/\b\w+(\([^)]*\))?\s*\{\s*nodes\b/g) ?? [];
      for (const c of connections) expect(c, `${c} in ${q}`).toMatch(/\(first:\s*(\d+)\)|\(first:\s*\d+,/);
      for (const m of q.matchAll(/first:\s*(\d+)/g)) expect(Number(m[1])).toBeLessThanOrEqual(50);
    }
  });

  it("warns when the target state doesn't exist", async () => {
    setup();
    blockerIssue.relations.nodes[0].relatedIssue.team.states.nodes = [{ id: "s-blocked", name: "Blocked" }];
    await send(stateChange());
    expect(moves()).toEqual([]);
    expect(console.warn).toHaveBeenCalled();
  });
});
