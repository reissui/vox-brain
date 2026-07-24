import {
  applyD1Migrations,
  createExecutionContext,
  env,
  waitOnExecutionContext,
} from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import migrationSql from "../migrations/0001_remote_first.sql?raw";
import captureResultMigrationSql from "../migrations/0002_capture_delivery_results.sql?raw";
import permanentObjectMigrationSql from "../migrations/0003_permanent_capture_objects.sql?raw";
import { claimPairingCode, mintPairingCode } from "../src/device-auth";
import worker, { type Env } from "../src/index";

const migrations = [
  { name: "0001_remote_first.sql", sql: migrationSql },
  { name: "0002_capture_delivery_results.sql", sql: captureResultMigrationSql },
  { name: "0003_permanent_capture_objects.sql", sql: permanentObjectMigrationSql },
].map(({ name, sql }) => ({
  name,
  queries: sql
    .replace(/^\s*--.*$/gm, "")
    .split(";")
    .map((query) => query.trim())
    .filter(Boolean),
}));

const db = requireBinding(env.DB, "DB");
const instanceId = "entrypoint-instance";
const agentToken = "entrypoint-agent-secret";
const originToken = "entrypoint-origin-secret";
const originUrl = "https://brain-origin.example.test";
const callbackUrl = "https://brain-gw.example.test/v1/gmail/callback";
const base = "https://brain-gw.example.test";
const allowedAppOrigin = "https://app.example.test";
const allowedExtensionOrigin = "chrome-extension://abcdefghijklmnop";

let apiEnv: Env;
let deviceToken: string;
let originRequests: Request[];

beforeAll(async () => {
  await applyD1Migrations(db, migrations);
  const now = new Date().toISOString();
  await db.prepare(
    `INSERT INTO instances
      (id, name, agent_token_digest, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
    .bind(instanceId, "Entrypoint", await sha256(agentToken), now, now)
    .run();
});

beforeEach(async () => {
  await db.prepare("DELETE FROM captures").run();
  await db.prepare("DELETE FROM jobs").run();
  await db.prepare("DELETE FROM heartbeats").run();
  await db.prepare("DELETE FROM devices").run();
  deviceToken = (await pair()).token;
  originRequests = [];
  apiEnv = {
    ...env,
    DB: db,
    INSTANCE_ID: instanceId,
    AGENT_TOKEN: agentToken,
    BRAIN_ORIGIN_URL: originUrl,
    BRAIN_ORIGIN_TOKEN: originToken,
    GMAIL_CALLBACK_URL: callbackUrl,
    GMAIL_STATE_SECRET: "entrypoint-gmail-state-secret",
  } as unknown as Env;
  vi.stubGlobal("fetch", fakeOutboundFetch);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("real Worker route and method matrix", () => {
  it("routes every fixed endpoint and rejects the opposite method before its handler", async () => {
    const routes: Array<[string, "GET" | "POST"]> = [
      ["/v1/pair/start", "POST"],
      ["/v1/pair/claim", "POST"],
      ["/v1/pair/revoke", "POST"],
      ["/v1/captures/00000000-0000-4000-8000-000000000052", "GET"],
      ["/v1/captures/00000000-0000-4000-8000-000000000052/object", "GET"],
      ["/v1/status", "GET"],
      ["/v1/health", "GET"],
      ["/v1/knowledge/documents", "GET"],
      ["/v1/knowledge/search", "GET"],
      ["/v1/knowledge/document", "GET"],
      ["/v1/jobs", "POST"],
      ["/v1/jobs/job-id", "GET"],
      ["/v1/gmail/start", "POST"],
      ["/v1/gmail/callback", "GET"],
      ["/v1/gmail/status", "GET"],
      ["/v1/gmail/disconnect", "POST"],
      ["/v1/agent/heartbeat", "POST"],
      ["/v1/agent/jobs/job-id/result", "POST"],
      ["/v1/agent/captures/00000000-0000-4000-8000-000000000001/result", "POST"],
      ["/v1/agent/captures/00000000-0000-4000-8000-000000000001/object", "GET"],
    ];

    for (const [path, method] of routes) {
      const wrongMethod = method === "GET" ? "POST" : "GET";
      const response = await dispatch(new Request(`${base}${path}`, { method: wrongMethod }));
      expect(response.status, `${wrongMethod} ${path}`).toBe(405);
      expect(response.headers.get("content-type")).toContain("application/json");
      expect(await response.json()).toEqual({ error: "method not allowed" });
    }
    const unsupportedCaptureMethod = await dispatch(new Request(`${base}/v1/captures`, {
      method: "PUT",
    }));
    expect(unsupportedCaptureMethod.status).toBe(405);
    expect(await unsupportedCaptureMethod.json()).toEqual({ error: "method not allowed" });
  });

  it("drives pairing, capture, reads, jobs, Gmail, heartbeat, and results through the entrypoint", async () => {
    const started = await jsonRequest("/v1/pair/start", "POST", {
      device_name: "Brain.app",
      scopes: ["read", "capture", "control"],
    }, agentToken);
    expect(started.status).toBe(201);
    const pairing = await started.json<{ code: string }>();
    expect(pairing.code).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const claimed = await jsonRequest("/v1/pair/claim", "POST", { code: pairing.code });
    expect(claimed.status).toBe(200);
    expect(await claimed.json()).toMatchObject({
      instance_id: instanceId,
      device_name: "Brain.app",
      scopes: ["capture", "read", "control"],
      token: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
    });

    const capture = await dispatch(new Request(`${base}/v1/captures`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${deviceToken}`,
        "content-type": "application/json",
        "idempotency-key": "00000000-0000-4000-8000-000000000052",
      },
      body: JSON.stringify({ text: "entrypoint capture", source: "api-test" }),
    }));
    expect(capture.status).toBe(202);
    const captureID = (await capture.clone().json<{ id: string }>()).id;
    expect((await authorized(`/v1/captures/${captureID}`)).status).toBe(200);

    for (const path of [
      "/v1/status",
      "/v1/health",
      "/v1/knowledge/documents?limit=2",
      "/v1/knowledge/search?q=Brain&limit=2",
      "/v1/knowledge/document?path=notes%2FBrain.md",
      "/v1/gmail/status",
    ]) {
      expect((await authorized(path)).status, path).toBe(200);
    }

    expect((await jsonRequest("/v1/gmail/start", "POST", {}, deviceToken)).status).toBe(200);
    expect((await jsonRequest(
      "/v1/gmail/disconnect",
      "POST",
      { confirm: true },
      deviceToken,
    )).status).toBe(200);

    const created = await jsonRequest(
      "/v1/jobs",
      "POST",
      { kind: "ask", question: "What links to [[Brain]]?" },
      deviceToken,
    );
    expect(created.status).toBe(202);
    const { id } = await created.json<{ id: string }>();
    expect((await authorized(`/v1/jobs/${id}`)).status).toBe(200);
    expect((await jsonRequest(
      `/v1/agent/jobs/${id}/result`,
      "POST",
      { state: "completed", output: "Grounded in [[notes/Brain]]" },
      agentToken,
    )).status).toBe(200);

    const at = new Date().toISOString();
    expect((await jsonRequest("/v1/agent/heartbeat", "POST", {
      instance_id: instanceId,
      generated_at: at,
      agent_version: "1",
      status: { inbox: 0 },
      health: { overall: "pass" },
      last_successful_queue_poll: at,
    }, agentToken)).status).toBe(202);

    const absentObject = await dispatch(new Request(
      `${base}/v1/agent/captures/00000000-0000-4000-8000-000000000001/object`,
      { headers: { authorization: `Bearer ${agentToken}` } },
    ));
    expect(absentObject.status).toBe(404);
    expect((await dispatch(new Request(`${base}/v1/gmail/callback?state=invalid&code=secret`))).status)
      .toBe(400);

    const revoked = await jsonRequest("/v1/pair/revoke", "POST", {}, deviceToken);
    expect(revoked.status).toBe(200);
    expect(await revoked.json()).toMatchObject({ revoked: true });
    expect((await authorized("/v1/status")).status).toBe(403);
  });
});

describe("credential boundaries", () => {
  it("requires device credentials on client routes and never accepts the agent secret", async () => {
    const cases: Array<[string, "GET" | "POST", unknown?]> = [
      ["/v1/captures", "POST", { text: "capture" }],
      ["/v1/captures/00000000-0000-4000-8000-000000000099", "GET"],
      ["/v1/status", "GET"],
      ["/v1/health", "GET"],
      ["/v1/knowledge/documents?limit=2", "GET"],
      ["/v1/knowledge/search?q=Brain", "GET"],
      ["/v1/knowledge/document?path=notes%2FBrain.md", "GET"],
      ["/v1/jobs", "POST", { kind: "process" }],
      ["/v1/jobs/missing", "GET"],
      ["/v1/gmail/start", "POST", {}],
      ["/v1/gmail/status", "GET"],
      ["/v1/gmail/disconnect", "POST", { confirm: true }],
      ["/v1/pair/revoke", "POST", {}],
    ];
    for (const [path, method, body] of cases) {
      const headers: Record<string, string> = {};
      if (path === "/v1/captures") {
        headers["idempotency-key"] = "00000000-0000-4000-8000-000000000099";
      }
      const init: RequestInit = { method, headers };
      if (body !== undefined) {
        headers["content-type"] = "application/json";
        init.body = JSON.stringify(body);
      }
      expect(
        (await dispatch(new Request(`${base}${path}`, init))).status,
        `missing device bearer on ${path}`,
      ).toBe(401);
      headers.authorization = `Bearer ${agentToken}`;
      expect(
        (await dispatch(new Request(`${base}${path}`, init))).status,
        `agent bearer on ${path}`,
      ).toBe(401);
    }
  });

  it("requires the independent agent secret and rejects a valid device credential", async () => {
    const at = new Date().toISOString();
    const cases: Array<[string, "GET" | "POST", unknown?]> = [
      ["/v1/pair/start", "POST", { device_name: "Other", scopes: ["read"] }],
      ["/v1/agent/heartbeat", "POST", {
        instance_id: instanceId,
        generated_at: at,
        agent_version: "1",
        status: {},
        health: {},
        last_successful_queue_poll: at,
      }],
      ["/v1/agent/jobs/missing/result", "POST", { state: "running" }],
      ["/v1/agent/captures/00000000-0000-4000-8000-000000000001/result", "POST", {
        state: "delivered",
      }],
      ["/v1/agent/captures/00000000-0000-4000-8000-000000000001/object", "GET"],
    ];
    for (const [path, method, body] of cases) {
      const headers: Record<string, string> = { authorization: `Bearer ${deviceToken}` };
      const init: RequestInit = { method, headers };
      if (body !== undefined) {
        headers["content-type"] = "application/json";
        init.body = JSON.stringify(body);
      }
      expect((await dispatch(new Request(`${base}${path}`, init))).status, path).toBe(401);
    }
  });
});

describe("legacy compatibility and closed inputs", () => {
  it("keeps /health and legacy capture working with an explicit successor header", async () => {
    const health = await dispatch(new Request(`${base}/health`));
    expect(health.status).toBe(200);
    expect(await health.json()).toEqual({ ok: true });

    const capture = await jsonRequest(
      "/capture",
      "POST",
      { text: "legacy capture" },
      "test-capture-token",
    );
    expect(capture.status).toBe(201);
    expect(capture.headers.get("deprecation")).toBe("/v1/captures");
    expect(capture.headers.get("link")).toBe('</v1/captures>; rel="successor-version"');
    expect((await capture.json<{ path: string }>()).path).toMatch(/^inbox\//);
  });

  it("retires legacy GitHub-backed ask with migration guidance and no outbound request", async () => {
    const before = originRequests.length;
    const response = await dispatch(new Request(`${base}/ask`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ question: "private question" }),
    }));

    expect(response.status).toBe(410);
    expect(response.headers.get("deprecation")).toBe("/v1/jobs");
    expect(response.headers.get("link")).toBe('</v1/jobs>; rel="successor-version"');
    expect(await response.json()).toEqual({
      error: "gone",
      message: "GitHub-backed ask was retired. Pair a device and use POST /v1/jobs with kind ask.",
    });
    expect(originRequests).toHaveLength(before);
  });

  it("keeps OAuth-backed /mcp active and its bearer independent", async () => {
    const unauthorized = await dispatch(new Request(`${base}/mcp`, { method: "POST" }));
    expect(unauthorized.status).toBe(401);

    const initialized = await dispatch(new Request(`${base}/mcp`, {
      method: "POST",
      headers: {
        authorization: "Bearer test-mcp-password",
        accept: "application/json, text/event-stream",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2025-03-26",
          capabilities: {},
          clientInfo: { name: "api-test", version: "1" },
        },
      }),
    }), false);
    expect(initialized.status).toBe(200);
  });

  it("returns JSON 404 for near misses and rejects selector-shaped inputs before side effects", async () => {
    for (const path of [
      "/v1",
      "/v1/captures/extra",
      "/v1/captures/unsafe$id",
      "/v1/knowledge",
      "/v1/agent/jobs/id",
      "/v1/repos/vox-brain/other",
      "/tmp/vox-brain-example",
    ]) {
      const response = await dispatch(new Request(`${base}${path}`));
      expect(response.status, path).toBe(404);
      expect(response.headers.get("content-type")).toContain("application/json");
      expect(await response.json()).toEqual({ error: "not found" });
    }

    const beforeOriginRequests = originRequests.length;
    expect((await authorized("/v1/status?origin=https%3A%2F%2Fevil.invalid")).status).toBe(400);
    expect((await jsonRequest(
      "/v1/pair/start",
      "POST",
      { device_name: "Injected", scopes: ["read"], instance_id: "other" },
      agentToken,
    )).status).toBe(422);
    expect((await jsonRequest(
      "/v1/jobs",
      "POST",
      { kind: "process", command: "brain process", path: "/tmp/vault" },
      deviceToken,
    )).status).toBe(422);
    expect(originRequests).toHaveLength(beforeOriginRequests);
    expect((await db.prepare("SELECT COUNT(*) AS count FROM jobs").first<{ count: number }>())?.count)
      .toBe(0);
  });
});

describe("strict opt-in CORS", () => {
  it("is disabled by default and permits only exact configured app/extension origins", async () => {
    const disabled = await dispatch(new Request(`${base}/v1/status`, {
      headers: {
        origin: allowedAppOrigin,
        authorization: `Bearer ${deviceToken}`,
      },
    }));
    expect(disabled.status).toBe(403);
    expect(disabled.headers.get("access-control-allow-origin")).toBeNull();

    apiEnv = {
      ...apiEnv,
      CORS_ALLOWED_ORIGINS: `${allowedAppOrigin}, ${allowedExtensionOrigin}`,
    };
    const allowed = await dispatch(new Request(`${base}/v1/status`, {
      headers: {
        origin: allowedAppOrigin,
        authorization: `Bearer ${deviceToken}`,
      },
    }));
    expect(allowed.status).toBe(200);
    expect(allowed.headers.get("access-control-allow-origin")).toBe(allowedAppOrigin);

    const extension = await dispatch(new Request(`${base}/v1/status`, {
      headers: {
        origin: allowedExtensionOrigin,
        authorization: `Bearer ${deviceToken}`,
      },
    }));
    expect(extension.status).toBe(200);
    expect(extension.headers.get("access-control-allow-origin")).toBe(allowedExtensionOrigin);

    const denied = await dispatch(new Request(`${base}/v1/status`, {
      headers: {
        origin: "https://evil.example.test",
        authorization: `Bearer ${deviceToken}`,
      },
    }));
    expect(denied.status).toBe(403);
    expect(denied.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("answers only valid preflights with the fixed route method and required headers", async () => {
    apiEnv = { ...apiEnv, CORS_ALLOWED_ORIGINS: allowedAppOrigin };
    const preflight = await dispatch(new Request(`${base}/v1/captures`, {
      method: "OPTIONS",
      headers: {
        origin: allowedAppOrigin,
        "access-control-request-method": "POST",
        "access-control-request-headers": "Authorization, Content-Type, Idempotency-Key",
      },
    }));
    expect(preflight.status).toBe(204);
    expect(preflight.headers.get("access-control-allow-origin")).toBe(allowedAppOrigin);
    expect(preflight.headers.get("access-control-allow-methods")).toBe("POST, OPTIONS");
    expect(preflight.headers.get("access-control-allow-headers")).toBe(
      "authorization, content-type, idempotency-key, range",
    );

    const extraHeader = await dispatch(new Request(`${base}/v1/status`, {
      method: "OPTIONS",
      headers: {
        origin: allowedAppOrigin,
        "access-control-request-method": "GET",
        "access-control-request-headers": "X-Origin-URL",
      },
    }));
    expect(extraHeader.status).toBe(403);
    const unknown = await dispatch(new Request(`${base}/v1/repository`, {
      method: "OPTIONS",
      headers: {
        origin: allowedAppOrigin,
        "access-control-request-method": "GET",
      },
    }));
    expect(unknown.status).toBe(404);
  });
});

describe("redacted structured request logs", () => {
  it("emits request id, canonical route, method, and status without sensitive inputs", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const bearer = "bearer-must-never-be-logged";
    const vault = "private vault contents must never be logged";
    const oauthCode = "google-oauth-code-must-never-be-logged";

    const response = await dispatch(new Request(`${base}/v1/jobs`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${bearer}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ kind: "ask", question: vault }),
    }));
    expect(response.status).toBe(401);
    expect(response.headers.get("x-request-id")).toMatch(/^[0-9a-f-]{36}$/);
    await dispatch(new Request(
      `${base}/v1/gmail/callback?state=invalid&code=${oauthCode}`,
    ));

    const rendered = log.mock.calls.map((call) => String(call[0])).join("\n");
    expect(rendered).not.toContain(bearer);
    expect(rendered).not.toContain(vault);
    expect(rendered).not.toContain(oauthCode);
    const records = log.mock.calls.map((call) => JSON.parse(String(call[0])) as Record<string, unknown>);
    expect(records).toHaveLength(2);
    expect(records[0]).toMatchObject({
      event: "gateway_request",
      method: "POST",
      route: "/v1/jobs",
      status: 401,
      request_id: expect.stringMatching(/^[0-9a-f-]{36}$/),
      duration_ms: expect.any(Number),
    });
    expect(records[1]?.route).toBe("/v1/gmail/callback");
  });
});

async function dispatch(request: Request, wait = true): Promise<Response> {
  const context = createExecutionContext();
  const response = await worker.fetch(request, apiEnv, context);
  if (wait) await waitOnExecutionContext(context);
  return response;
}

function authorized(path: string): Promise<Response> {
  return dispatch(new Request(`${base}${path}`, {
    headers: { authorization: `Bearer ${deviceToken}` },
  }));
}

function jsonRequest(
  path: string,
  method: "POST",
  body: unknown,
  token?: string,
): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (token) headers.authorization = `Bearer ${token}`;
  return dispatch(new Request(`${base}${path}`, {
    method,
    headers,
    body: JSON.stringify(body),
  }));
}

async function pair() {
  const minted = await mintPairingCode(db, {
    instanceId,
    deviceName: "Entrypoint test device",
    scopes: ["capture", "read", "control"],
  });
  return claimPairingCode(db, { instanceId, code: minted.code });
}

async function fakeOutboundFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const request = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(request.url);
  if (url.hostname === "api.github.com") {
    return Response.json({ content: { path: "unused" } }, { status: 201 });
  }
  if (url.origin !== originUrl) throw new Error("unexpected outbound origin");
  originRequests.push(request.clone());
  if (request.headers.get("x-brain-origin-token") !== originToken) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  if (url.pathname === "/v1/status") return Response.json({ schema_version: 1, inbox: 0 });
  if (url.pathname === "/v1/health") return Response.json({ overall: "pass", checks: [] });
  if (url.pathname === "/v1/knowledge/documents") {
    return Response.json({ documents: [{ title: "Brain", path: "notes/Brain.md" }] });
  }
  if (url.pathname === "/v1/knowledge/search") {
    return Response.json({ query: url.searchParams.get("q"), results: [] });
  }
  if (url.pathname === "/v1/knowledge/document") {
    return Response.json({
      path: url.searchParams.get("path"),
      title: "Brain",
      content: "# Brain",
    });
  }
  if (url.pathname === "/v1/agent/gmail/start") {
    const authorization = new URL("https://accounts.google.com/o/oauth2/v2/auth");
    authorization.searchParams.set("redirect_uri", callbackUrl);
    authorization.searchParams.set("state", "origin-state");
    return Response.json({
      authorization_url: authorization.toString(),
      state: "origin-state",
      expires_at: Math.floor(Date.now() / 1_000) + 600,
    });
  }
  if (url.pathname === "/v1/agent/gmail/status") {
    return Response.json({ status: "connected", account: "owner@example.test" });
  }
  if (url.pathname === "/v1/agent/gmail/disconnect") {
    return Response.json({ status: "disconnected" });
  }
  return Response.json({ error: "not found" }, { status: 404 });
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

function requireBinding<T>(binding: T | undefined, name: string): T {
  if (!binding) throw new Error(`${name} test binding is not configured`);
  return binding;
}
