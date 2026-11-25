import { generateKeyPairSync, createVerify } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { type Env } from "../src/index";
import { GithubAuthError, appCredentialsStatus, githubToken, resetGithubAuthCache } from "../src/githubAuth";

// A throwaway key made for these tests only.
const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const PKCS8 = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
const PKCS1 = privateKey.export({ type: "pkcs1", format: "pem" }).toString();

const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });

let calls: { url: string; method: string; auth: string }[];
let installationStatus: number;
let tokenStatus: number;
let appStatus: number;
let expiresAt: string;
let issued: number;

beforeEach(() => {
  resetGithubAuthCache();
  calls = [];
  installationStatus = 200;
  tokenStatus = 201;
  appStatus = 200;
  issued = 0;
  expiresAt = new Date(Date.now() + 3600_000).toISOString();
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.stubGlobal("fetch", async (input: any, init: RequestInit = {}) => {
    const url = String(input);
    const auth = String((init.headers as Record<string, string>)?.Authorization ?? "");
    calls.push({ url, method: init.method ?? "GET", auth });
    if (url.startsWith("https://api.linear.app/")) return json({ data: { viewer: { id: "u" } } });
    if (url.endsWith("/installation")) return installationStatus === 200 ? json({ id: 77 }) : new Response("no", { status: installationStatus });
    if (url.endsWith("/access_tokens")) return tokenStatus === 201 ? json({ token: `inst-${++issued}`, expires_at: expiresAt }, 201) : new Response("no", { status: tokenStatus });
    if (url === "https://api.github.com/app") return new Response("{}", { status: appStatus });
    return new Response("{}", { status: 200 });
  });
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  vi.useRealTimers();
});

const appEnv = (key = PKCS8) => ({ FACTORY_APP_ID: "123", FACTORY_APP_PRIVATE_KEY: key });

describe("signing", () => {
  it.each([["PKCS#8", PKCS8], ["PKCS#1 (GitHub's format)", PKCS1], ["PEM with literal \\n", PKCS1.replace(/\n/g, "\\n")]])(
    "signs a valid RS256 JWT with a %s key",
    async (_name, key) => {
      await githubToken(appEnv(key), "acme/backpack");
      const jwt = calls[0].auth.replace("Bearer ", "");
      const [h, p, s] = jwt.split(".");
      expect(JSON.parse(atob(h))).toEqual({ alg: "RS256", typ: "JWT" });
      const claims = JSON.parse(atob(p));
      expect(claims.iss).toBe("123");
      expect(claims.exp - claims.iat).toBeLessThanOrEqual(600);
      const ok = createVerify("RSA-SHA256").update(`${h}.${p}`).verify(publicKey, Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64"));
      expect(ok).toBe(true);
    },
  );

  it("uses the JWT to find the installation and the installation token afterwards", async () => {
    expect(await githubToken(appEnv(), "acme/backpack")).toBe("inst-1");
    expect(calls.map((c) => `${c.method} ${c.url}`)).toEqual([
      "GET https://api.github.com/repos/acme/backpack/installation",
      "POST https://api.github.com/app/installations/77/access_tokens",
    ]);
  });
});

describe("caching", () => {
  it("reuses the token until shortly before it expires", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-01-01T00:00:00Z"));
    expiresAt = "2026-01-01T01:00:00Z";
    expect(await githubToken(appEnv(), "acme/a")).toBe("inst-1");
    expect(await githubToken(appEnv(), "acme/b")).toBe("inst-1");
    vi.setSystemTime(new Date("2026-01-01T00:54:00Z"));
    expect(await githubToken(appEnv(), "acme/a")).toBe("inst-1");
    expect(issued).toBe(1);
    vi.setSystemTime(new Date("2026-01-01T00:56:00Z"));
    expect(await githubToken(appEnv(), "acme/a")).toBe("inst-2");
  });
});

describe("fallback", () => {
  it("uses GITHUB_TOKEN while FACTORY_APP_ID isn't set, without calling GitHub", async () => {
    expect(await githubToken({ GITHUB_TOKEN: "personal" }, "acme/a")).toBe("personal");
    expect(calls).toHaveLength(0);
  });
});

describe("errors", () => {
  it("reports an unusable private key as wrong credentials, without echoing the key", async () => {
    const err = await githubToken(appEnv("-----BEGIN PRIVATE KEY-----\nbm9wZQ==\n-----END PRIVATE KEY-----"), "acme/a").catch((e) => e);
    expect(err).toBeInstanceOf(GithubAuthError);
    expect(err.kind).toBe("credentials");
    expect(err.message).not.toContain("bm9wZQ");
  });

  it("reports a rejected JWT as wrong credentials", async () => {
    installationStatus = 401;
    const err = await githubToken(appEnv(), "acme/a").catch((e) => e);
    expect(err.kind).toBe("credentials");
  });

  it("reports a missing installation as no access", async () => {
    installationStatus = 404;
    const err = await githubToken(appEnv(), "acme/a").catch((e) => e);
    expect(err.kind).toBe("access");
  });

  it("reports a refused installation token as no access", async () => {
    tokenStatus = 403;
    const err = await githubToken(appEnv(), "acme/a").catch((e) => e);
    expect(err.kind).toBe("access");
  });

  it("checks the app credentials with GET /app", async () => {
    expect(await appCredentialsStatus(appEnv())).toBe(200);
    appStatus = 401;
    expect(await appCredentialsStatus(appEnv())).toBe(401);
    expect(await appCredentialsStatus(appEnv("garbage"))).toBe(0);
  });
});

describe("in the relay", () => {
  const relayEnv = (extra: Partial<Env>): Env => ({
    LINEAR_API_KEY: "k", LINEAR_WEBHOOK_SECRET: "s", AGENT_READY_STATE: "Agent Ready", AGENT_WORKING_STATE: "Agent Working",
    NEEDS_HUMAN_STATE: "Needs Human", BLOCKED_STATE: "Blocked", TODO_STATE: "Todo", AUTO_START_LABEL: "Auto-start",
    MANUAL_LABEL: "factory:manual", GITHUB_OWNER: "acme", PROJECT_REPOS: { Backpack: "acme/backpack" },
    HEALTH_CHECK_SECRET: "health-secret-123456", ...extra,
  });
  const deep = (env: Env) =>
    worker.fetch(new Request("https://relay.test/health?deep=1", { headers: { authorization: "Bearer health-secret-123456" } }) as any, env, {} as any);

  it("health: app credentials are checked instead of the personal token", async () => {
    const res = await deep(relayEnv({ ...appEnv(), GITHUB_TOKEN: "personal" }));
    expect(await res.json()).toMatchObject({ ok: true, auth: "app", github: 200 });
    expect(calls.some((c) => c.url.endsWith("/rate_limit"))).toBe(false);
    expect(calls.every((c) => c.auth !== "Bearer personal")).toBe(true);
  });

  it("health: wrong app credentials give 503 with github 401", async () => {
    appStatus = 401;
    const res = await deep(relayEnv(appEnv()));
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ auth: "app", github: 401 });
  });

  it("health: falls back to the personal token and says so", async () => {
    const res = await deep(relayEnv({ GITHUB_TOKEN: "personal" }));
    expect(await res.json()).toMatchObject({ ok: true, auth: "token" });
    expect(calls.some((c) => c.url.endsWith("/rate_limit"))).toBe(true);
  });
});
