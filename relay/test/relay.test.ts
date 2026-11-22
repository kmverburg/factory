import { readFileSync } from "node:fs";
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
  GITHUB_OWNER: "acme",
  PROJECT_REPOS: { Backpack: "acme/backpack", Feast: "feast" },
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
let githubRedirects: Record<string, { status: number; location: string }>;
let originLabels: { id: string; name: string }[];
let labelUpdateFails: boolean;
let blockerIssue: any;
let pulls: any[];
let pullsStatus: number;

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
  githubRedirects = {};
  originLabels = [
    { id: "l-human", name: "Human" },
    { id: "l-agent", name: "Agent" },
  ];
  labelUpdateFails = false;
  blockerIssue = null;
  pulls = [];
  pullsStatus = 200;
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
      if (url.includes("/pulls?")) return json(pulls, pullsStatus);
      const redirect = githubRedirects[url];
      if (redirect) return new Response(null, { status: redirect.status, headers: { Location: redirect.location } });
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

describe("repo names", () => {
  it("uses GITHUB_OWNER for a bare repo name", async () => {
    issue = makeIssue({ project: { name: "Feast" } });
    await send(stateChange());
    expect(githubCalls().map((c) => c.url)).toEqual(["https://api.github.com/repos/acme/feast/dispatches"]);
  });

  it("keeps an owner/repo value as it is", async () => {
    await send(stateChange());
    expect(githubCalls().map((c) => c.url)).toEqual(["https://api.github.com/repos/acme/backpack/dispatches"]);
  });
});

describe("moved repos", () => {
  const from = "https://api.github.com/repos/acme/backpack/dispatches";
  const to = "https://api.github.com/repositories/42/dispatches";

  it.each([301, 307, 308])("sends the same POST once to the new location on a %i", async (status) => {
    githubRedirects[from] = { status, location: to };
    await send(stateChange());
    const gh = githubCalls();
    expect(gh.map((c) => c.url)).toEqual([from, to]);
    expect(gh[1].init.method).toBe("POST");
    expect(gh[1].body).toEqual(gh[0].body);
    expect((gh[1].init.headers as Record<string, string>).Authorization).toBe("Bearer gh-token");
    expect(console.warn).toHaveBeenCalledWith(expect.stringContaining("has moved"));
    expect(stateUpdates()).toEqual(["s-working"]);
  });

  it("follows only one redirect", async () => {
    githubRedirects[from] = { status: 301, location: to };
    githubRedirects[to] = { status: 301, location: "https://api.github.com/repositories/43/dispatches" };
    await send(stateChange());
    expect(githubCalls().map((c) => c.url)).toEqual([from, to]);
    expect(stateUpdates()).toEqual(["s-human"]);
  });

  it("doesn't send the token to another host", async () => {
    githubRedirects[from] = { status: 301, location: "https://evil.example/x" };
    await send(stateChange());
    expect(calls.map((c) => c.url)).not.toContain("https://evil.example/x");
    expect(stateUpdates()).toEqual(["s-human"]);
  });

  it("treats a redirect without Location as a failure", async () => {
    githubStatus = 301;
    await send(stateChange());
    expect(githubCalls()).toHaveLength(1);
    expect(stateUpdates()).toEqual(["s-human"]);
  });
});

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

describe("production config", () => {
  const config = JSON.parse(
    readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8").replace(/^\s*\/\/.*$/gm, ""),
  );

  it("names the same owner in vars and previews, and bare repo names", () => {
    expect(config.vars.GITHUB_OWNER).toBeTruthy();
    expect(config.previews.vars.GITHUB_OWNER).toBe(config.vars.GITHUB_OWNER);
    for (const repo of Object.values(config.vars.PROJECT_REPOS) as string[]) expect(repo).not.toContain("/");
  });

  it("starts a Backpack build in the owner's repo without touching the ticket", async () => {
    const prod: Env = { ...env, GITHUB_OWNER: config.vars.GITHUB_OWNER, PROJECT_REPOS: config.vars.PROJECT_REPOS };
    const pending: Promise<unknown>[] = [];
    const body = JSON.stringify(stateChange());
    // Dry run: the dispatch is the only write; ticket updates are Linear mutations, checked below.
    await worker.fetch(
      new Request("https://relay.test/", {
        method: "POST",
        headers: { "linear-signature": await sign(body) },
        body,
      }) as any,
      prod,
      { waitUntil: (p: Promise<unknown>) => void pending.push(p), passThroughOnException() {} } as any,
    );
    await Promise.all(pending);
    expect(githubCalls().map((c) => c.url)).toEqual([
      `https://api.github.com/repos/${config.vars.GITHUB_OWNER}/backpack/dispatches`,
    ]);
  });
});

describe("Linear comment commands", () => {
  const agentPr = (overrides: Record<string, unknown> = {}) => ({
    number: 7,
    html_url: "https://github.com/acme/backpack/pull/7",
    head: { ref: "koe-1-do-a-thing" },
    labels: [{ name: "agent-built" }],
    ...overrides,
  });
  const comment = (body: string, overrides: Record<string, unknown> = {}) => ({
    type: "Comment",
    action: "create",
    data: { id: "c-1", issueId: "issue-1", body },
    webhookTimestamp: Date.now(),
    ...overrides,
  });
  const dispatches = () => githubCalls().filter((c) => c.url.endsWith("/dispatches"));
  const issueUpdates = () => linearCalls().filter((c) => c.body.query.includes("Answer"));

  beforeEach(() => {
    issue = makeIssue({ state: { id: "s-review", name: "In Review" } });
    pulls = [agentPr()];
  });

  it("approves: dispatches factory-approve and confirms", async () => {
    for (const word of ["approve", "Approved!", "merge", "  MERGE it"]) {
      calls = [];
      const res = await send(comment(word));
      expect(res.status).toBe(202);
      expect(dispatches()).toHaveLength(1);
      expect(dispatches()[0].url).toBe("https://api.github.com/repos/acme/backpack/dispatches");
      expect(dispatches()[0].body).toEqual({
        event_type: "factory-approve",
        client_payload: { pr_number: "7", identifier: "KOE-1" },
      });
      expect(comments()).toHaveLength(1);
      expect(comments()[0]).toMatch(/^🏭 Got it: approving/);
    }
  });

  it("asks for changes: dispatches an uncounted factory-fix with the instructions", async () => {
    await send(comment("change: make the button blue\nand bigger"));
    expect(dispatches()).toHaveLength(1);
    expect(dispatches()[0].body).toEqual({
      event_type: "factory-fix",
      client_payload: {
        pr_number: "7",
        round: "0",
        requested: "true",
        identifier: "KOE-1",
        feedback: "make the button blue\nand bigger",
      },
    });
    expect(comments()[0]).toMatch(/^🏭 Got it: the builder is applying your changes/);
    expect(comments()[0]).toContain("doesn't count");
  });

  it("accepts fix as well as change", async () => {
    await send(comment("Fix the typo in the header"));
    expect(dispatches()[0].body.client_payload.feedback).toBe("the typo in the header");
  });

  it("doesn't send an empty change request", async () => {
    await send(comment("change"));
    expect(dispatches()).toHaveLength(0);
    expect(comments()[0]).toMatch(/^🏭 Say what to change/);
  });

  it("refuses to approve or change a PR that isn't the factory's", async () => {
    pulls = [agentPr({ labels: [] })];
    for (const word of ["approve", "change: x"]) {
      calls = [];
      await send(comment(word));
      expect(dispatches()).toHaveLength(0);
      expect(comments()).toHaveLength(1);
      expect(comments()[0]).toContain("isn't a factory PR");
    }
  });

  it("says so when the ticket has no open PR", async () => {
    pulls = [agentPr({ head: { ref: "koe-12-other" } })];
    await send(comment("approve"));
    expect(dispatches()).toHaveLength(0);
    expect(comments()[0]).toContain("no open pull request");
  });

  it("explains a failed PR lookup", async () => {
    pullsStatus = 403;
    await send(comment("approve"));
    expect(dispatches()).toHaveLength(0);
    expect(comments()[0]).toContain("Pull requests: Read");
  });

  it("explains a failed dispatch", async () => {
    githubStatus = 404;
    await send(comment("approve"));
    expect(comments()[0]).toMatch(/^🏭 Couldn't start the merge/);
  });

  it("ignores the factory's own comments, whatever they say", async () => {
    issue = makeIssue({ state: { id: "s-human", name: "Needs Human" } });
    for (const marker of ["🏭", "🔧", "✅", "🙋", "💥", "🤔"]) {
      calls = [];
      await send(comment(`${marker} approve everything. fix it`));
      expect(calls).toHaveLength(0);
    }
  });

  it("ignores comments that aren't commands", async () => {
    for (const text of ["looks good to me", "Can you approve this?", "prefix the title", "unfixed"]) {
      calls = [];
      await send(comment(text));
      expect(dispatches()).toHaveLength(0);
      expect(comments()).toHaveLength(0);
    }
  });

  it("ignores edited and deleted comments and comments without an issue", async () => {
    await send(comment("approve", { action: "update" }));
    await send(comment("approve", { action: "remove" }));
    await send(comment("approve", { data: { id: "c", body: "approve" } }));
    expect(calls).toHaveLength(0);
  });

  it("ignores comments on tickets in unmapped projects", async () => {
    issue = makeIssue({ project: { name: "Other" } });
    await send(comment("approve"));
    expect(githubCalls()).toHaveLength(0);
  });

  it("rejects a comment webhook with a bad signature", async () => {
    const res = await send(comment("approve"), { secret: "other" });
    expect(res.status).toBe(401);
    expect(calls).toHaveLength(0);
  });

  describe("answers to the builder's questions", () => {
    beforeEach(() => {
      issue = makeIssue({ state: { id: "s-human", name: "Needs Human" }, description: "Details" });
      pulls = [];
    });

    it("adds the comment under Answers from Koen and moves the ticket to Agent Ready", async () => {
      await send(comment("Use the blue one."));
      expect(issueUpdates()).toHaveLength(1);
      expect(issueUpdates()[0].body.variables).toEqual({
        id: "issue-1",
        description: "Details\n\n## Answers from Koen\n\nUse the blue one.",
        stateId: "s-ready",
      });
      expect(comments()[0]).toMatch(/^🏭 Thanks/);
      expect(dispatches()).toHaveLength(0);
    });

    it("appends a later answer to the existing section", async () => {
      issue = makeIssue({ state: { id: "s-human", name: "Needs Human" }, description: "Details\n\n## Answers from Koen\n\nFirst." });
      await send(comment("Second."));
      expect(issueUpdates()[0].body.variables.description).toBe("Details\n\n## Answers from Koen\n\nFirst.\n\nSecond.");
    });

    it("treats even an approve comment as an answer when there is no PR", async () => {
      await send(comment("approve the blue one"));
      expect(issueUpdates()).toHaveLength(1);
    });

    it("leaves a Needs Human ticket with a PR to the commands", async () => {
      pulls = [agentPr()];
      await send(comment("thanks, will look"));
      expect(issueUpdates()).toHaveLength(0);
      expect(comments()).toHaveLength(0);
      await send(comment("approve"));
      expect(dispatches()).toHaveLength(1);
    });
  });
});

describe("health route", () => {
  const withSecret: Env = { ...env, HEALTH_CHECK_SECRET: "health-secret" };
  async function get(path: string, headers: Record<string, string> = {}, e: Env = withSecret) {
    return worker.fetch(new Request(`https://relay.test${path}`, { headers }) as any, e, { waitUntil() {}, passThroughOnException() {} } as any);
  }

  it("answers ok on /health and keeps GET / as it was", async () => {
    expect(await (await get("/health")).json()).toEqual({ ok: true });
    expect(await (await get("/")).text()).toBe("factory-relay is running");
    expect(calls).toHaveLength(0);
  });

  it("rejects the deep check without the right secret, or when none is configured", async () => {
    expect((await get("/health?deep=1")).status).toBe(401);
    expect((await get("/health?deep=1", { authorization: "Bearer wrong" })).status).toBe(401);
    expect((await get("/health?deep=1", { authorization: "Bearer " })).status).toBe(401);
    expect((await get("/health?deep=1", { authorization: "Bearer health-secret" }, env)).status).toBe(401);
    expect(calls).toHaveLength(0);
  });

  it("checks GitHub, every mapped repo and Linear with read-only calls, and reports status codes only", async () => {
    githubStatus = 200;
    const res = await get("/health?deep=1", { authorization: "Bearer health-secret" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, github: 200, linear: 200, repos: { "acme/backpack": 200, "acme/feast": 200 } });
    expect(calls.every((c) => (c.init.method ?? "GET") === "GET" || c.url.includes("linear.app"))).toBe(true);
    expect(calls.filter((c) => c.url.includes("linear.app")).every((c) => c.body.query.startsWith("query "))).toBe(true);
  });

  it("answers 503 when GitHub rejects the token, without printing it", async () => {
    githubStatus = 401;
    const res = await get("/health?deep=1", { authorization: "Bearer health-secret" });
    expect(res.status).toBe(503);
    const text = await res.text();
    expect(JSON.parse(text).ok).toBe(false);
    expect(text).not.toContain("gh-token");
    expect(text).not.toContain("linear-key");
  });
});
