/**
 * Paired-device Gmail consent relay.
 *
 * Google client configuration, the PKCE verifier, and mailbox credentials stay
 * at the authenticated Brain Agent origin. The gateway wraps the origin's
 * one-time state in a signed, expiring envelope so the browser callback is
 * bound to the device and instance that started it without persisting OAuth
 * material in Cloudflare storage.
 */

import { authorizeDevice, DeviceAuthError, type AuthorizedDevice } from "./device-auth";

export interface GmailApiEnv {
  DB: D1Database;
  /** Fixed deployment instance. Clients cannot select an instance or origin. */
  INSTANCE_ID?: string;
  BRAIN_INSTANCE_ID?: string;
  /** Authenticated Cloudflare Tunnel origin for the configured instance. */
  ORIGIN_URL?: string;
  BRAIN_ORIGIN_URL?: string;
  ORIGIN_TOKEN?: string;
  BRAIN_ORIGIN_TOKEN?: string;
  /** Public Worker URL registered as the Google OAuth redirect URI. */
  GMAIL_CALLBACK_URL?: string;
  BRAIN_GMAIL_CALLBACK_URL?: string;
  /** Optional independent HMAC key; the origin token is the safe fallback. */
  GMAIL_STATE_SECRET?: string;
}

export interface GmailApiDependencies {
  fetch?: typeof fetch;
  now?: () => Date;
}

interface GmailConfiguration {
  instanceId: string;
  originUrl: string;
  originToken: string;
  callbackUrl: string;
  stateSecret: string;
}

interface OriginStartResponse {
  authorization_url: string;
  state: string;
  expires_at: number;
}

interface CallbackState {
  v: 1;
  i: string;
  d: string;
  s: string;
  e: number;
}

const INSTANCE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/;
const DEVICE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/;
const STATE_PART_PATTERN = /^[A-Za-z0-9_-]+$/;
const MAX_ORIGIN_RESPONSE_BYTES = 16 * 1024;
const MAX_REQUEST_BODY_BYTES = 1_024;
const MAX_AUTHORIZATION_URL_CHARS = 4_096;
const MAX_ORIGIN_STATE_CHARS = 256;
const MAX_CALLBACK_STATE_CHARS = 1_024;
const MAX_AUTHORIZATION_CODE_CHARS = 4_096;
const MAX_GOOGLE_ERROR_CHARS = 256;
const MAX_ACCOUNT_CHARS = 320;
const MAX_STATE_LIFETIME_SECONDS = 15 * 60;
const ORIGIN_GMAIL_PATH = "/v1/agent/gmail/";

/** Route the four public Gmail endpoints owned by this module. */
export async function handleGmailApi(
  request: Request,
  env: GmailApiEnv,
  dependencies: GmailApiDependencies = {},
): Promise<Response> {
  const pathname = new URL(request.url).pathname;
  if (pathname === "/v1/gmail/start") return handleGmailStart(request, env, dependencies);
  if (pathname === "/v1/gmail/callback") return handleGmailCallback(request, env, dependencies);
  if (pathname === "/v1/gmail/status") return handleGmailStatus(request, env, dependencies);
  if (pathname === "/v1/gmail/disconnect") {
    return handleGmailDisconnect(request, env, dependencies);
  }
  return json(404, { error: "not found" });
}

/** Handle POST /v1/gmail/start. */
export async function handleGmailStart(
  request: Request,
  env: GmailApiEnv,
  dependencies: GmailApiDependencies = {},
): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "method not allowed" });
  const configuration = configured(env);
  if (!configuration) return json(503, { error: "gmail service is not configured" });

  const device = await authorize(request, env.DB, configuration.instanceId, "control");
  if (device instanceof Response) return device;

  const origin = await originJson(
    configuration,
    "start",
    "POST",
    { redirect_uri: configuration.callbackUrl },
    dependencies.fetch,
  );
  if (!origin.ok) return json(503, { error: "gmail origin unavailable" });

  const started = parseOriginStart(origin.value, configuration.callbackUrl, now(dependencies));
  if (!started) return json(503, { error: "gmail origin unavailable" });

  const callbackState = await signState(
    {
      v: 1,
      i: configuration.instanceId,
      d: device.deviceId,
      s: started.state,
      e: started.expires_at,
    },
    configuration.stateSecret,
  );
  const authorizationUrl = new URL(started.authorization_url);
  authorizationUrl.searchParams.set("state", callbackState);

  // This is intentionally the only field returned to Brain.app.
  return json(200, { authorization_url: authorizationUrl.toString() });
}

/** Handle GET /v1/gmail/callback. */
export async function handleGmailCallback(
  request: Request,
  env: GmailApiEnv,
  dependencies: GmailApiDependencies = {},
): Promise<Response> {
  if (request.method !== "GET") return callbackPage(false, 405);
  const configuration = configured(env);
  if (!configuration) return callbackPage(false, 503);

  const result = parseCallback(new URL(request.url));
  if (!result) return callbackPage(false, 400);
  const state = await verifyState(
    result.state,
    configuration.stateSecret,
    now(dependencies),
  );
  if (
    !state ||
    state.i !== configuration.instanceId ||
    !DEVICE_ID_PATTERN.test(state.d)
  ) {
    return callbackPage(false, 400);
  }

  const payload: Record<string, string> = {
    redirect_uri: configuration.callbackUrl,
    state: state.s,
  };
  if (result.code !== undefined) payload.code = result.code;
  else payload.error = result.error;

  // The origin owns and consumes the pending transaction. A network outage
  // never reaches it, leaving both its existing grant and pending state intact.
  const completed = await originJson(
    configuration,
    "complete",
    "POST",
    payload,
    dependencies.fetch,
  );
  if (!completed.reached) return callbackPage(false, 503);
  return callbackPage(completed.ok, completed.ok ? 200 : 400);
}

/** Handle GET /v1/gmail/status. */
export async function handleGmailStatus(
  request: Request,
  env: GmailApiEnv,
  dependencies: GmailApiDependencies = {},
): Promise<Response> {
  if (request.method !== "GET") return json(405, { error: "method not allowed" });
  const configuration = configured(env);
  if (!configuration) return json(503, { status: "origin_unavailable" });

  const device = await authorize(request, env.DB, configuration.instanceId, "read");
  if (device instanceof Response) return device;

  const origin = await originJson(
    configuration,
    "status",
    "GET",
    undefined,
    dependencies.fetch,
  );
  if (!origin.ok || !isRecord(origin.value)) {
    return json(503, { status: "origin_unavailable" });
  }

  if (origin.value.status === "disconnected") return json(200, { status: "disconnected" });
  if (origin.value.status === "reconnect_required") {
    return json(200, { status: "reconnect_required" });
  }
  if (origin.value.status === "denied") return json(200, { status: "denied" });
  if (origin.value.status === "expired") return json(200, { status: "expired" });
  if (origin.value.status === "connected") {
    const account = origin.value.account;
    if (account === undefined) return json(200, { status: "connected" });
    if (typeof account !== "string" || account.length === 0 || account.length > MAX_ACCOUNT_CHARS) {
      return json(503, { status: "origin_unavailable" });
    }
    return json(200, { status: "connected", account });
  }
  return json(503, { status: "origin_unavailable" });
}

/** Handle POST /v1/gmail/disconnect. */
export async function handleGmailDisconnect(
  request: Request,
  env: GmailApiEnv,
  dependencies: GmailApiDependencies = {},
): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "method not allowed" });
  const configuration = configured(env);
  if (!configuration) return json(503, { error: "gmail service is not configured" });

  const device = await authorize(request, env.DB, configuration.instanceId, "control");
  if (device instanceof Response) return device;
  const confirmation = await readConfirmation(request);
  if (!confirmation) {
    return json(422, { error: "disconnect requires explicit confirmation" });
  }

  const origin = await originJson(
    configuration,
    "disconnect",
    "POST",
    {},
    dependencies.fetch,
  );
  if (!origin.ok || !isRecord(origin.value) || origin.value.status !== "disconnected") {
    return json(503, { error: "gmail origin unavailable" });
  }
  return json(200, { status: "disconnected" });
}

async function authorize(
  request: Request,
  db: D1Database,
  instanceId: string,
  scope: "read" | "control",
): Promise<AuthorizedDevice | Response> {
  try {
    return await authorizeDevice(
      db,
      instanceId,
      request.headers.get("authorization"),
      [scope],
    );
  } catch (caught) {
    if (caught instanceof DeviceAuthError) return caught.toResponse();
    return json(503, { error: "gmail authorization unavailable" });
  }
}

function configured(env: GmailApiEnv): GmailConfiguration | null {
  const instanceId = env.INSTANCE_ID ?? env.BRAIN_INSTANCE_ID;
  const originUrlInput = env.ORIGIN_URL ?? env.BRAIN_ORIGIN_URL;
  const originToken = env.ORIGIN_TOKEN ?? env.BRAIN_ORIGIN_TOKEN;
  const callbackUrlInput = env.GMAIL_CALLBACK_URL ?? env.BRAIN_GMAIL_CALLBACK_URL;
  const stateSecret = env.GMAIL_STATE_SECRET ?? originToken;
  if (
    typeof instanceId !== "string" ||
    !INSTANCE_PATTERN.test(instanceId) ||
    typeof originToken !== "string" ||
    originToken.length === 0 ||
    typeof stateSecret !== "string" ||
    stateSecret.length === 0
  ) {
    return null;
  }
  const originUrl = fixedHttpsUrl(originUrlInput, false);
  const callbackUrl = fixedHttpsUrl(callbackUrlInput, true);
  if (!originUrl || !callbackUrl) return null;
  return { instanceId, originUrl, originToken, callbackUrl, stateSecret };
}

function fixedHttpsUrl(value: unknown, callback: boolean): string | null {
  if (typeof value !== "string" || value.length === 0 || value.length > 2_048) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.hash || url.search) {
      return null;
    }
    if (callback && url.pathname !== "/v1/gmail/callback") return null;
    if (!callback && url.pathname !== "/" && url.pathname !== "") return null;
    return callback ? url.toString() : url.origin;
  } catch {
    return null;
  }
}

async function originJson(
  configuration: GmailConfiguration,
  operation: "start" | "complete" | "status" | "disconnect",
  method: "GET" | "POST",
  body: Record<string, string> | undefined,
  fetcher: typeof fetch = fetch,
): Promise<{ reached: boolean; ok: boolean; value?: unknown }> {
  const headers = new Headers({
    accept: "application/json",
    "x-brain-origin-token": configuration.originToken,
  });
  let encoded: string | undefined;
  if (method === "POST") {
    headers.set("content-type", "application/json");
    encoded = JSON.stringify(body ?? {});
  }
  let response: Response;
  try {
    response = await fetcher(`${configuration.originUrl}${ORIGIN_GMAIL_PATH}${operation}`, {
      method,
      headers,
      body: encoded,
      redirect: "manual",
    });
  } catch {
    return { reached: false, ok: false };
  }

  let value: unknown;
  try {
    value = await readBoundedJson(response);
  } catch {
    return { reached: true, ok: false };
  }
  return { reached: true, ok: response.ok, value };
}

async function readBoundedJson(response: Response): Promise<unknown> {
  const declared = Number(response.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_ORIGIN_RESPONSE_BYTES) {
    throw new Error("origin response too large");
  }
  if (!response.body) throw new Error("origin response missing");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_ORIGIN_RESPONSE_BYTES) {
      await reader.cancel();
      throw new Error("origin response too large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
  return JSON.parse(text) as unknown;
}

function parseOriginStart(
  value: unknown,
  callbackUrl: string,
  current: Date,
): OriginStartResponse | null {
  if (!isRecord(value)) return null;
  const authorizationUrl = value.authorization_url;
  const state = value.state;
  const expiresAt = value.expires_at;
  if (
    typeof authorizationUrl !== "string" ||
    authorizationUrl.length === 0 ||
    authorizationUrl.length > MAX_AUTHORIZATION_URL_CHARS ||
    typeof state !== "string" ||
    state.length === 0 ||
    state.length > MAX_ORIGIN_STATE_CHARS ||
    typeof expiresAt !== "number" ||
    !Number.isSafeInteger(expiresAt)
  ) {
    return null;
  }
  const nowSeconds = Math.floor(current.getTime() / 1_000);
  if (expiresAt <= nowSeconds || expiresAt > nowSeconds + MAX_STATE_LIFETIME_SECONDS) return null;
  try {
    const parsed = new URL(authorizationUrl);
    if (
      parsed.protocol !== "https:" ||
      parsed.origin !== "https://accounts.google.com" ||
      parsed.searchParams.get("state") !== state ||
      parsed.searchParams.get("redirect_uri") !== callbackUrl
    ) {
      return null;
    }
  } catch {
    return null;
  }
  return {
    authorization_url: authorizationUrl,
    state,
    expires_at: expiresAt,
  };
}

function parseCallback(url: URL):
  | { state: string; code: string; error?: never }
  | { state: string; error: string; code?: never }
  | null {
  if (url.search.length > MAX_CALLBACK_STATE_CHARS + MAX_AUTHORIZATION_CODE_CHARS + 128) {
    return null;
  }
  const keys = Array.from(url.searchParams.keys());
  if (new Set(keys).size !== keys.length) return null;
  const state = url.searchParams.get("state");
  const code = url.searchParams.get("code");
  const error = url.searchParams.get("error");
  if (!state || state.length > MAX_CALLBACK_STATE_CHARS) return null;
  if (
    code !== null &&
    error === null &&
    keys.length === 2 &&
    keys.every((key) => key === "state" || key === "code") &&
    code.length > 0 &&
    code.length <= MAX_AUTHORIZATION_CODE_CHARS
  ) {
    return { state, code };
  }
  if (
    error !== null &&
    code === null &&
    keys.length === 2 &&
    keys.every((key) => key === "state" || key === "error") &&
    error.length > 0 &&
    error.length <= MAX_GOOGLE_ERROR_CHARS
  ) {
    return { state, error };
  }
  return null;
}

async function signState(state: CallbackState, secret: string): Promise<string> {
  const payload = base64UrlEncode(new TextEncoder().encode(JSON.stringify(state)));
  const signature = await hmac(payload, secret);
  return `${payload}.${base64UrlEncode(signature)}`;
}

async function verifyState(
  value: string,
  secret: string,
  current: Date,
): Promise<CallbackState | null> {
  const [payload, signature, extra] = value.split(".");
  if (
    !payload ||
    !signature ||
    extra !== undefined ||
    !STATE_PART_PATTERN.test(payload) ||
    !STATE_PART_PATTERN.test(signature)
  ) {
    return null;
  }
  try {
    const decodedPayload = base64UrlDecode(payload);
    const decodedSignature = base64UrlDecode(signature);
    if (
      base64UrlEncode(decodedPayload) !== payload ||
      base64UrlEncode(decodedSignature) !== signature
    ) {
      return null;
    }
    const key = await hmacKey(secret, ["verify"]);
    const valid = await crypto.subtle.verify(
      "HMAC",
      key,
      decodedSignature,
      new TextEncoder().encode(payload),
    );
    if (!valid) return null;
    const decoded: unknown = JSON.parse(new TextDecoder("utf-8", {
      fatal: true,
      ignoreBOM: false,
    }).decode(
      decodedPayload,
    ));
    if (!isCallbackState(decoded)) return null;
    if (decoded.e <= Math.floor(current.getTime() / 1_000)) return null;
    return decoded;
  } catch {
    return null;
  }
}

function isCallbackState(value: unknown): value is CallbackState {
  if (!isRecord(value) || Object.keys(value).sort().join(",") !== "d,e,i,s,v") return false;
  return value.v === 1 &&
    typeof value.i === "string" && INSTANCE_PATTERN.test(value.i) &&
    typeof value.d === "string" && DEVICE_ID_PATTERN.test(value.d) &&
    typeof value.s === "string" && value.s.length > 0 && value.s.length <= MAX_ORIGIN_STATE_CHARS &&
    Number.isSafeInteger(value.e);
}

async function hmac(value: string, secret: string): Promise<Uint8Array> {
  const key = await hmacKey(secret, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value)));
}

function hmacKey(secret: string, usages: Array<"sign" | "verify">): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    usages,
  );
}

function base64UrlEncode(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlDecode(value: string): Uint8Array {
  const padding = "=".repeat((4 - value.length % 4) % 4);
  const decoded = atob(value.replace(/-/g, "+").replace(/_/g, "/") + padding);
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

async function readConfirmation(request: Request): Promise<boolean> {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0];
  if (contentType?.trim().toLowerCase() !== "application/json") {
    return false;
  }
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_REQUEST_BODY_BYTES) return false;
  try {
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (bytes.byteLength === 0 || bytes.byteLength > MAX_REQUEST_BODY_BYTES) return false;
    const value: unknown = JSON.parse(new TextDecoder("utf-8", {
      fatal: true,
      ignoreBOM: false,
    }).decode(bytes));
    return isRecord(value) && Object.keys(value).length === 1 && value.confirm === true;
  } catch {
    return false;
  }
}

function now(dependencies: GmailApiDependencies): Date {
  return dependencies.now?.() ?? new Date();
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function callbackPage(success: boolean, status: number): Response {
  const title = success ? "Brain Gmail connected" : "Brain Gmail connection failed";
  const message = success
    ? "Gmail is connected. You can close this window."
    : "Return to Brain and start Gmail connection again.";
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${title}</title></head><body><main><h1>${title}</h1><p>${message}</p></main></body></html>`;
  return new Response(html, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

function json(status: number, data: unknown): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}
