/**
 * brain-gw — one closed, versioned remote-first API plus bounded legacy routes.
 *
 * OAuth still owns /mcp, /authorize, /token, and /register. The default
 * handler below owns only the explicitly enumerated /v1 routes, legacy
 * POST /capture, and the unauthenticated legacy health probe.
 */

import { OAuthProvider, type OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import { handleCaptureApi } from "./capture-api";
import { buildAttachmentPath, buildInboxPath, buildMarkdown, parseCapture } from "./capture";
import {
  DeviceAuthError,
  authorizeDevice,
  claimPairingCode,
  mintPairingCode,
  revokeDevice,
  type DeviceScope,
} from "./device-auth";
import { enrichDesignCapture } from "./design-enrichment";
import { handleGmailApi } from "./gmail-api";
import { putBase64Contents, putContents } from "./github";
import { BrainMcpAgent } from "./mcp";
import { handleAuthorize, resolveMcpPasswordToken, timingSafeEqualStr } from "./oauth";
import { handleRemoteApi } from "./remote-api";

const MAX_CAPTURE_BODY_BYTES = 6 * 1024 * 1024;
const MAX_PAIR_BODY_BYTES = 8 * 1024;
const INSTANCE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/;
const AGENT_BEARER_PATTERN = /^Bearer ([^\s]{1,1024})$/i;
const CORS_REQUEST_HEADERS = ["authorization", "content-type", "idempotency-key", "range"] as const;
const CORS_EXPOSE_HEADERS = [
  "deprecation",
  "link",
  "x-brain-snapshot",
  "x-brain-snapshot-age-seconds",
  "x-content-sha256",
  "accept-ranges",
  "content-disposition",
  "content-range",
  "etag",
  "x-request-id",
] as const;

export interface Env {
  /** Optional legacy route: bearer token clients present to POST /capture. */
  CAPTURE_TOKEN?: string;
  /** Optional legacy route: fine-grained PAT with Contents read/write. */
  GITHUB_TOKEN?: string;
  /** Optional legacy route: target in owner/repository form. */
  GITHUB_REPOSITORY?: string;
  /** Secret: accepted by /authorize and directly as a headless MCP bearer token. */
  MCP_PASSWORD: string;
  /** Token/client storage for the OAuth provider (binding name fixed by the library). */
  OAUTH_KV: KVNamespace;
  /** One Durable Object per MCP session (Agents SDK). */
  MCP_OBJECT: DurableObjectNamespace;
  /** Injected by OAuthProvider on every handler call — never configure it. */
  OAUTH_PROVIDER: OAuthHelpers;
  DB: D1Database;
  CAPTURE_OBJECTS: R2Bucket;
  BRAIN_QUEUE: Queue;
  /** Fixed single-user deployment configuration. None is client-selectable. */
  INSTANCE_ID?: string;
  BRAIN_INSTANCE_ID?: string;
  AGENT_TOKEN?: string;
  BRAIN_AGENT_TOKEN?: string;
  ORIGIN_URL?: string;
  BRAIN_ORIGIN_URL?: string;
  ORIGIN_TOKEN?: string;
  BRAIN_ORIGIN_TOKEN?: string;
  GMAIL_CALLBACK_URL?: string;
  BRAIN_GMAIL_CALLBACK_URL?: string;
  GMAIL_STATE_SECRET?: string;
  /** Comma-separated exact app/extension origins. CORS is off when absent. */
  CORS_ALLOWED_ORIGINS?: string;
  BRAIN_CORS_ALLOWED_ORIGINS?: string;
}

type V1Route =
  | "/v1/pair/start"
  | "/v1/pair/claim"
  | "/v1/pair/revoke"
  | "/v1/captures"
  | "/v1/captures/:id"
  | "/v1/captures/:id/object"
  | "/v1/status"
  | "/v1/health"
  | "/v1/knowledge/documents"
  | "/v1/knowledge/search"
  | "/v1/knowledge/document"
  | "/v1/jobs"
  | "/v1/jobs/:id"
  | "/v1/gmail/start"
  | "/v1/gmail/callback"
  | "/v1/gmail/status"
  | "/v1/gmail/disconnect"
  | "/v1/agent/heartbeat"
  | "/v1/agent/jobs/:id/result"
  | "/v1/agent/captures/:id/result"
  | "/v1/agent/captures/:id/object";

interface RouteDefinition {
  route: V1Route;
  method: "GET" | "POST";
}

/** The MCP session Durable Object — must be exported from the entry module. */
export { BrainMcpAgent };

/** Non-OAuth routes: the closed /v1 API, legacy capture, and /authorize. */
const app = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);

    if (pathname === "/health") {
      if (request.method !== "GET") return json(405, { error: "method not allowed" });
      return json(200, { ok: true });
    }

    if (pathname === "/capture") {
      const response = request.method === "POST"
        ? await handleLegacyCapture(request, env)
        : json(405, { error: "method not allowed" });
      return withHeaders(response, {
        deprecation: "/v1/captures",
        link: '</v1/captures>; rel="successor-version"',
      });
    }

    if (pathname === "/ask") {
      return json(410, {
        error: "gone",
        message: "GitHub-backed ask was retired. Pair a device and use POST /v1/jobs with kind ask.",
      }, {
        deprecation: "/v1/jobs",
        link: '</v1/jobs>; rel="successor-version"',
      });
    }

    if (pathname === "/authorize") {
      return handleAuthorize(request, env);
    }

    if (pathname.startsWith("/v1/")) {
      const definition = routeDefinition(pathname, request.method);
      if (!definition) return json(404, { error: "not found" });
      if (request.method !== definition.method) {
        return json(405, { error: "method not allowed" });
      }
      if (definition.route.startsWith("/v1/pair/")) {
        return handlePairing(
          request,
          env,
          definition.route as Extract<V1Route, `/v1/pair/${string}`>,
        );
      }
      if (
        definition.route === "/v1/captures" ||
        definition.route === "/v1/captures/:id" ||
        definition.route === "/v1/agent/captures/:id/result" ||
        definition.route === "/v1/agent/captures/:id/object"
      ) {
        return handleCaptureApi(request, env);
      }
      if (definition.route.startsWith("/v1/gmail/")) {
        return handleGmailApi(request, env);
      }
      return handleRemoteApi(request, env);
    }

    return json(404, { error: "not found" });
  },
} satisfies ExportedHandler<Env>;

const oauthProvider = new OAuthProvider<Env>({
  apiRoute: "/mcp",
  apiHandler: BrainMcpAgent.serve("/mcp"),
  defaultHandler: app,
  authorizeEndpoint: "/authorize",
  tokenEndpoint: "/token",
  clientRegistrationEndpoint: "/register",
  scopesSupported: ["brain"],
  // Codex can pass MCP_PASSWORD from an environment variable, avoiding the
  // interactive browser flow. Unknown bearer tokens still fail closed.
  resolveExternalToken: async ({ token, env }) =>
    resolveMcpPasswordToken(token, env.MCP_PASSWORD),
});

/**
 * Top-level policy wrapper: exact-origin CORS, a generated request id, and one
 * body/header-free structured completion event for every request.
 */
const worker = {
  async fetch(request: Request, env: Env, context: ExecutionContext): Promise<Response> {
    const startedAt = Date.now();
    const requestId = crypto.randomUUID();
    const url = new URL(request.url);
    const definition = routeDefinition(
      url.pathname,
      request.method === "OPTIONS"
        ? request.headers.get("access-control-request-method") ?? ""
        : request.method,
    );
    let status = 500;

    try {
      let response: Response;
      if (url.pathname.startsWith("/v1/") && request.headers.has("origin")) {
        const origin = request.headers.get("origin") ?? "";
        if (!allowedOrigins(env).has(origin)) {
          response = json(403, { error: "origin not allowed" });
        } else if (request.method === "OPTIONS") {
          response = corsPreflight(request, definition, origin);
        } else {
          response = await oauthProvider.fetch(request, env, context);
          response = withHeaders(response, corsHeaders(origin, definition));
        }
      } else if (request.method === "OPTIONS" && url.pathname.startsWith("/v1/")) {
        response = json(403, { error: "cors disabled" });
      } else {
        response = await oauthProvider.fetch(request, env, context);
      }

      status = response.status;
      return withHeaders(response, { "x-request-id": requestId });
    } catch {
      status = 500;
      return json(500, { error: "internal error" }, { "x-request-id": requestId });
    } finally {
      console.log(JSON.stringify({
        event: "gateway_request",
        request_id: requestId,
        method: safeMethodLabel(request.method),
        route: safeRouteLabel(url.pathname, definition),
        status,
        duration_ms: Math.max(0, Date.now() - startedAt),
      }));
    }
  },
} satisfies ExportedHandler<Env>;

export default worker;

async function handlePairing(
  request: Request,
  env: Env,
  route: Extract<V1Route, `/v1/pair/${string}`>,
): Promise<Response> {
  const requestUrl = new URL(request.url);
  if (requestUrl.search !== "") return json(400, { error: "invalid query" });
  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "pairing service is not configured" });

  if (route === "/v1/pair/start") {
    if (!(await authorizeAgent(env, instanceId, request.headers.get("authorization")))) {
      return json(401, { error: "unauthorized" });
    }
    const decoded = await readPairBody(request);
    if (!decoded.ok) return json(decoded.status, { error: decoded.error });
    const input = parsePairStart(decoded.value);
    if (!input.ok) return json(422, { error: input.error });
    try {
      const minted = await mintPairingCode(env.DB, {
        instanceId,
        deviceName: input.deviceName,
        scopes: input.scopes,
      });
      return json(201, {
        code: minted.code,
        device_id: minted.deviceId,
        expires_at: minted.expiresAt,
      });
    } catch {
      return json(503, { error: "pairing state unavailable" });
    }
  }

  if (route === "/v1/pair/claim") {
    const decoded = await readPairBody(request);
    if (!decoded.ok) return json(decoded.status, { error: decoded.error });
    const code = parsePairClaim(decoded.value);
    if (!code) return json(422, { error: "code is required" });
    try {
      const claimed = await claimPairingCode(env.DB, { instanceId, code });
      return json(200, {
        instance_id: claimed.instanceId,
        device_id: claimed.deviceId,
        device_name: claimed.deviceName,
        scopes: claimed.scopes,
        token: claimed.token,
      });
    } catch (caught) {
      if (caught instanceof DeviceAuthError) return caught.toResponse();
      return json(503, { error: "pairing state unavailable" });
    }
  }

  let device;
  try {
    device = await authorizeDevice(
      env.DB,
      instanceId,
      request.headers.get("authorization"),
      [],
    );
  } catch (caught) {
    if (caught instanceof DeviceAuthError) return caught.toResponse();
    return json(503, { error: "pairing authorization unavailable" });
  }
  try {
    const revoked = await revokeDevice(env.DB, instanceId, device.deviceId);
    return revoked
      ? json(200, { revoked: true, device_id: device.deviceId })
      : json(409, { error: "device could not be revoked" });
  } catch {
    return json(503, { error: "pairing state unavailable" });
  }
}

async function handleLegacyCapture(request: Request, env: Env): Promise<Response> {
  if (!env.CAPTURE_TOKEN || !env.GITHUB_TOKEN || !env.GITHUB_REPOSITORY) {
    return json(410, {
      error: "legacy GitHub capture is not configured; pair a device and use POST /v1/captures",
    });
  }
  if (!isAuthorized(request.headers.get("authorization"), env.CAPTURE_TOKEN)) {
    return json(401, { error: "unauthorized" });
  }

  const decoded = await readLegacyJsonBody(request);
  if (!decoded.ok) return json(decoded.status, { error: decoded.error });
  const body = decoded.value;

  const parsed = parseCapture(body);
  if (!parsed.ok) return json(422, { error: parsed.error });

  const enrichment = await enrichDesignCapture(parsed.capture);
  const capture = enrichment.capture;
  const now = new Date();
  const path = buildInboxPath(capture.type, now);
  const attachmentPath = capture.image
    ? buildAttachmentPath(path, capture.image.mimeType)
    : undefined;
  const markdown = buildMarkdown(capture, now, "gateway", attachmentPath);

  if (attachmentPath && capture.image) {
    const imageWritten = await putBase64Contents(
      env.GITHUB_TOKEN,
      env.GITHUB_REPOSITORY,
      attachmentPath,
      capture.image.base64,
      `gateway: capture ${attachmentPath}`,
    );
    if (!imageWritten.ok) return json(502, { error: imageWritten.error });
  }

  const written = await putContents(
    env.GITHUB_TOKEN,
    env.GITHUB_REPOSITORY,
    path,
    markdown,
    `gateway: capture ${path}`,
  );
  if (!written.ok) return json(502, { error: written.error });

  return json(201, {
    path,
    evidence: {
      visual: Boolean(capture.image),
      context: Boolean(capture.text),
      source: enrichment.source,
    },
  });
}

function routeDefinition(pathname: string, requestMethod = "GET"): RouteDefinition | null {
  const fixed: Readonly<Record<string, RouteDefinition>> = {
    "/v1/pair/start": { route: "/v1/pair/start", method: "POST" },
    "/v1/pair/claim": { route: "/v1/pair/claim", method: "POST" },
    "/v1/pair/revoke": { route: "/v1/pair/revoke", method: "POST" },
    "/v1/captures": {
      route: "/v1/captures",
      method: requestMethod === "GET" ? "GET" : "POST",
    },
    "/v1/status": { route: "/v1/status", method: "GET" },
    "/v1/health": { route: "/v1/health", method: "GET" },
    "/v1/knowledge/documents": { route: "/v1/knowledge/documents", method: "GET" },
    "/v1/knowledge/search": { route: "/v1/knowledge/search", method: "GET" },
    "/v1/knowledge/document": { route: "/v1/knowledge/document", method: "GET" },
    "/v1/jobs": { route: "/v1/jobs", method: "POST" },
    "/v1/gmail/start": { route: "/v1/gmail/start", method: "POST" },
    "/v1/gmail/callback": { route: "/v1/gmail/callback", method: "GET" },
    "/v1/gmail/status": { route: "/v1/gmail/status", method: "GET" },
    "/v1/gmail/disconnect": { route: "/v1/gmail/disconnect", method: "POST" },
    "/v1/agent/heartbeat": { route: "/v1/agent/heartbeat", method: "POST" },
  };
  const exact = fixed[pathname];
  if (exact) return exact;
  if (/^\/v1\/captures\/[^/]+\/object$/.test(pathname)) {
    return { route: "/v1/captures/:id/object", method: "GET" };
  }
  if (/^\/v1\/jobs\/[^/]+$/.test(pathname)) {
    return { route: "/v1/jobs/:id", method: "GET" };
  }
  if (/^\/v1\/captures\/[^/]+$/.test(pathname)) {
    return { route: "/v1/captures/:id", method: "GET" };
  }
  if (/^\/v1\/agent\/jobs\/[^/]+\/result$/.test(pathname)) {
    return { route: "/v1/agent/jobs/:id/result", method: "POST" };
  }
  if (/^\/v1\/agent\/captures\/[^/]+\/object$/.test(pathname)) {
    return { route: "/v1/agent/captures/:id/object", method: "GET" };
  }
  if (/^\/v1\/agent\/captures\/[^/]+\/result$/.test(pathname)) {
    return { route: "/v1/agent/captures/:id/result", method: "POST" };
  }
  return null;
}

function corsPreflight(
  request: Request,
  definition: RouteDefinition | null,
  origin: string,
): Response {
  if (!definition) return json(404, { error: "not found" });
  if (request.headers.get("access-control-request-method") !== definition.method) {
    return json(405, { error: "method not allowed" });
  }
  const requestedHeaders = (request.headers.get("access-control-request-headers") ?? "")
    .split(",")
    .map((header) => header.trim().toLowerCase())
    .filter(Boolean);
  if (requestedHeaders.some((header) => !CORS_REQUEST_HEADERS.includes(
    header as (typeof CORS_REQUEST_HEADERS)[number],
  ))) {
    return json(403, { error: "header not allowed" });
  }
  return new Response(null, { status: 204, headers: corsHeaders(origin, definition, true) });
}

function corsHeaders(
  origin: string,
  definition: RouteDefinition | null,
  preflight = false,
): Record<string, string> {
  const headers: Record<string, string> = {
    "access-control-allow-origin": origin,
    "access-control-expose-headers": CORS_EXPOSE_HEADERS.join(", "),
    vary: preflight
      ? "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"
      : "Origin",
  };
  if (preflight && definition) {
    headers["access-control-allow-methods"] = `${definition.method}, OPTIONS`;
    headers["access-control-allow-headers"] = CORS_REQUEST_HEADERS.join(", ");
    headers["access-control-max-age"] = "600";
  }
  return headers;
}

function allowedOrigins(env: Env): Set<string> {
  const configured = env.CORS_ALLOWED_ORIGINS ?? env.BRAIN_CORS_ALLOWED_ORIGINS ?? "";
  return new Set(
    configured
      .split(",")
      .map((origin) => origin.trim())
      .filter((origin) => origin.length > 0 && origin !== "*" && !/[\r\n]/.test(origin)),
  );
}

function safeRouteLabel(pathname: string, definition: RouteDefinition | null): string {
  if (definition) return definition.route;
  const known = new Set([
    "/health",
    "/capture",
    "/ask",
    "/mcp",
    "/authorize",
    "/token",
    "/register",
    "/.well-known/oauth-authorization-server",
    "/.well-known/oauth-protected-resource",
  ]);
  return known.has(pathname) ? pathname : "unknown";
}

function safeMethodLabel(method: string): string {
  return ["GET", "POST", "OPTIONS", "HEAD", "PUT", "PATCH", "DELETE"].includes(method)
    ? method
    : "OTHER";
}

function configuredInstanceId(env: Env): string | null {
  const value = env.INSTANCE_ID ?? env.BRAIN_INSTANCE_ID;
  return typeof value === "string" && INSTANCE_PATTERN.test(value) ? value : null;
}

async function authorizeAgent(
  env: Env,
  instanceId: string,
  authorization: string | null,
): Promise<boolean> {
  const token = AGENT_BEARER_PATTERN.exec(authorization ?? "")?.[1];
  if (!token) return false;
  const configuredToken = env.AGENT_TOKEN ?? env.BRAIN_AGENT_TOKEN;
  if (configuredToken !== undefined) return timingSafeEqualStr(token, configuredToken);
  try {
    const row = await env.DB.prepare("SELECT agent_token_digest FROM instances WHERE id = ?")
      .bind(instanceId)
      .first<{ agent_token_digest: string | null }>();
    return Boolean(row?.agent_token_digest && row.agent_token_digest === await sha256(token));
  } catch {
    return false;
  }
}

function parsePairStart(body: unknown):
  | { ok: true; deviceName: string; scopes: DeviceScope[] }
  | { ok: false; error: string } {
  if (!isRecord(body) || hasUnknownKeys(body, ["device_name", "scopes"])) {
    return { ok: false, error: "body must contain only device_name and scopes" };
  }
  if (
    typeof body.device_name !== "string" ||
    body.device_name.trim().length === 0 ||
    body.device_name.length > 255
  ) {
    return { ok: false, error: "device_name must be a non-empty string" };
  }
  if (!Array.isArray(body.scopes) || body.scopes.some((scope) =>
    scope !== "capture" && scope !== "read" && scope !== "control"
  )) {
    return { ok: false, error: "scopes must contain only capture, read, and control" };
  }
  const inputScopes = body.scopes;
  const scopes = ["capture", "read", "control"].filter((scope) =>
    inputScopes.includes(scope)
  ) as DeviceScope[];
  return { ok: true, deviceName: body.device_name.trim(), scopes };
}

function parsePairClaim(body: unknown): string | null {
  return isRecord(body) && !hasUnknownKeys(body, ["code"]) && typeof body.code === "string"
    ? body.code
    : null;
}

function hasUnknownKeys(record: Record<string, unknown>, allowed: readonly string[]): boolean {
  return Object.keys(record).some((key) => !allowed.includes(key));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function readPairBody(request: Request): Promise<
  | { ok: true; value: unknown }
  | { ok: false; status: 413 | 422; error: string }
> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_PAIR_BODY_BYTES) {
    return { ok: false, status: 413, error: "request body is too large" };
  }
  if (!request.body) return { ok: false, status: 422, error: "body must be valid JSON" };
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAX_PAIR_BODY_BYTES) {
    return { ok: false, status: 413, error: "request body is too large" };
  }
  try {
    const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
    return { ok: true, value: JSON.parse(text) as unknown };
  } catch {
    return { ok: false, status: 422, error: "body must be valid JSON" };
  }
}

async function readLegacyJsonBody(
  request: Request,
): Promise<
  | { ok: true; value: unknown }
  | { ok: false; status: 413 | 422; error: string }
> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_CAPTURE_BODY_BYTES) {
    return { ok: false, status: 413, error: "capture body must be 6 MiB or smaller" };
  }
  if (!request.body) return { ok: false, status: 422, error: "body must be valid JSON" };

  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let bytes = 0;
  let text = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    bytes += value.byteLength;
    if (bytes > MAX_CAPTURE_BODY_BYTES) {
      await reader.cancel();
      return { ok: false, status: 413, error: "capture body must be 6 MiB or smaller" };
    }
    text += decoder.decode(value, { stream: true });
  }
  text += decoder.decode();
  try {
    return { ok: true, value: JSON.parse(text) as unknown };
  } catch {
    return { ok: false, status: 422, error: "body must be valid JSON" };
  }
}

function isAuthorized(header: string | null, expected: string | undefined): boolean {
  if (!header || !expected || !header.startsWith("Bearer ")) return false;
  return timingSafeEqualStr(header.slice("Bearer ".length), expected);
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

function withHeaders(response: Response, additions: Record<string, string>): Response {
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(additions)) headers.set(name, value);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function json(status: number, data: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}
