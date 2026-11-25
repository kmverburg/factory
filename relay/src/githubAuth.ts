/**
 * GitHub authentication for the relay. With FACTORY_APP_ID and FACTORY_APP_PRIVATE_KEY set it signs an RS256 JWT,
 * exchanges it for a short-lived installation token and caches that token until shortly before it expires.
 * Without them it falls back to the personal GITHUB_TOKEN. Nothing here ever logs the key, the JWT or a token.
 */

export interface GithubAuthEnv {
  GITHUB_TOKEN?: string;
  FACTORY_APP_ID?: string;
  FACTORY_APP_PRIVATE_KEY?: string;
}

/** "credentials": the app id/key are wrong (or the token is invalid). "access": the app is not installed on / can't reach the repo. */
export class GithubAuthError extends Error {
  constructor(
    readonly kind: "credentials" | "access",
    message: string,
  ) {
    super(message);
  }
  /** The HTTP status the relay's failure messages key on. */
  get status(): number {
    return this.kind === "credentials" ? 401 : 404;
  }
}

const API = "https://api.github.com";
const HEADERS = { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "factory-relay" };
/** Tokens are renewed this long before GitHub says they expire. */
const REFRESH_MARGIN_MS = 5 * 60 * 1000;

const tokenCache = new Map<string, { token: string; expiresAt: number }>();
const keyCache = new Map<string, Promise<CryptoKey>>();

export const usesApp = (env: GithubAuthEnv): boolean => Boolean(env.FACTORY_APP_ID);

/** Forgets cached tokens and keys (for tests). */
export function resetGithubAuthCache(): void {
  tokenCache.clear();
  keyCache.clear();
}

/** A token for calls about `repo` ("owner/name"): an installation token, or the personal token while the app isn't configured. */
export async function githubToken(env: GithubAuthEnv, repo?: string): Promise<string> {
  if (!usesApp(env)) {
    if (!env.GITHUB_TOKEN) throw new GithubAuthError("credentials", "Neither FACTORY_APP_ID nor GITHUB_TOKEN is set.");
    return env.GITHUB_TOKEN;
  }
  const owner = repo ? repo.split("/")[0] : "";
  const cached = tokenCache.get(owner);
  if (cached && cached.expiresAt - REFRESH_MARGIN_MS > Date.now()) return cached.token;

  const jwt = await appJwt(env);
  const asApp = { ...HEADERS, Authorization: `Bearer ${jwt}` };

  // The installation for the repo's owner (an app installed on the account that owns the repo).
  const lookup = await fetch(`${API}/repos/${repo}/installation`, { headers: asApp });
  if (lookup.status === 401) throw new GithubAuthError("credentials", "GitHub rejected the factory app's JWT.");
  if (!lookup.ok) throw new GithubAuthError("access", `The factory app is not installed on ${repo} (GitHub answered ${lookup.status}).`);
  const installationId = ((await lookup.json()) as { id?: number }).id;
  if (!installationId) throw new GithubAuthError("access", `GitHub returned no installation for ${repo}.`);

  const res = await fetch(`${API}/app/installations/${installationId}/access_tokens`, { method: "POST", headers: asApp });
  if (res.status === 401) throw new GithubAuthError("credentials", "GitHub rejected the factory app's JWT.");
  if (!res.ok) throw new GithubAuthError("access", `GitHub would not create an installation token (answered ${res.status}).`);
  const body = (await res.json()) as { token?: string; expires_at?: string };
  if (!body.token) throw new GithubAuthError("access", "GitHub's installation token answer had no token.");
  const expiresAt = body.expires_at ? Date.parse(body.expires_at) : Date.now() + 55 * 60 * 1000;
  tokenCache.set(owner, { token: body.token, expiresAt });
  return body.token;
}

/** Status of GET /app with a fresh JWT: 200 means the app id and private key are right. 0 when they can't be used at all. */
export async function appCredentialsStatus(env: GithubAuthEnv): Promise<number> {
  try {
    const res = await fetch(`${API}/app`, { headers: { ...HEADERS, Authorization: `Bearer ${await appJwt(env)}` } });
    return res.status;
  } catch {
    return 0;
  }
}

/** Authorization headers for GitHub's REST API. */
export async function githubHeaders(env: GithubAuthEnv, repo?: string): Promise<Record<string, string>> {
  return { ...HEADERS, Authorization: `Bearer ${await githubToken(env, repo)}` };
}

// ---------- JWT ----------

const b64url = (bytes: ArrayBuffer | Uint8Array): string => {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const text = (s: string) => new TextEncoder().encode(s);

async function appJwt(env: GithubAuthEnv): Promise<string> {
  let key: CryptoKey;
  try {
    key = await importKey(env.FACTORY_APP_PRIVATE_KEY ?? "");
  } catch {
    throw new GithubAuthError("credentials", "FACTORY_APP_PRIVATE_KEY is missing or not a valid RSA private key (PEM).");
  }
  const now = Math.floor(Date.now() / 1000);
  // iat 60 s in the past allows for clock drift; GitHub allows at most 10 minutes of lifetime.
  const unsigned = `${b64url(text(JSON.stringify({ alg: "RS256", typ: "JWT" })))}.${b64url(
    text(JSON.stringify({ iat: now - 60, exp: now + 9 * 60, iss: String(env.FACTORY_APP_ID) })),
  )}`;
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, text(unsigned));
  return `${unsigned}.${b64url(signature)}`;
}

function importKey(pem: string): Promise<CryptoKey> {
  let cached = keyCache.get(pem);
  if (!cached) {
    cached = parseKey(pem);
    keyCache.set(pem, cached);
    cached.catch(() => keyCache.delete(pem));
  }
  return cached;
}

/** Accepts PKCS#8 ("BEGIN PRIVATE KEY") and GitHub's PKCS#1 ("BEGIN RSA PRIVATE KEY"); "\n" written as two characters is fine too. */
function parseKey(pem: string): Promise<CryptoKey> {
  const normalized = pem.replace(/\\n/g, "\n");
  const pkcs1 = /-----BEGIN RSA PRIVATE KEY-----/.test(normalized);
  const body = normalized.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", pkcs1 ? pkcs1ToPkcs8(der) : der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}

function derLength(n: number): number[] {
  if (n < 128) return [n];
  const bytes: number[] = [];
  for (let v = n; v > 0; v = Math.floor(v / 256)) bytes.unshift(v % 256);
  return [0x80 | bytes.length, ...bytes];
}

/** Wraps an RSAPrivateKey (PKCS#1) in the PKCS#8 PrivateKeyInfo structure Web Crypto imports. */
function pkcs1ToPkcs8(pkcs1: Uint8Array): Uint8Array {
  // INTEGER 0, then SEQUENCE { OID rsaEncryption, NULL }
  const header = [0x02, 0x01, 0x00, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00];
  const octets = [0x04, ...derLength(pkcs1.length)];
  const inner = header.length + octets.length + pkcs1.length;
  return Uint8Array.from([0x30, ...derLength(inner), ...header, ...octets, ...pkcs1]);
}
