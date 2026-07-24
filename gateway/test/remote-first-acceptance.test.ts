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
const bucket = requireBinding(env.CAPTURE_OBJECTS, "CAPTURE_OBJECTS");
const instanceId = "acceptance-instance";
const otherInstanceId = "acceptance-other";
const agentToken = "acceptance-agent-secret";
const originToken = "acceptance-origin-secret";
const originUrl = "https://acceptance-origin.example.test";
const callbackUrl = "https://acceptance-gateway.example.test/v1/gmail/callback";
const base = "https://acceptance-gateway.example.test";
const png = Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x42);

let apiEnv: Env;
let queue: AcceptanceQueue;
let deviceToken: string;
let otherDeviceToken: string;
let originOffline: boolean;
let originRequests: Request[];
let githubWrites: Request[];

beforeAll(async () => {
  await applyD1Migrations(db, migrations);
  await insertInstance(instanceId, "Acceptance", await sha256(agentToken));
  await insertInstance(otherInstanceId, "Other acceptance", await sha256("other-agent-token"));
});

beforeEach(async () => {
  await db.prepare("DELETE FROM captures").run();
  await db.prepare("DELETE FROM jobs").run();
  await db.prepare("DELETE FROM heartbeats").run();
  await db.prepare("DELETE FROM devices").run();
  queue = new AcceptanceQueue();
  originOffline = false;
  originRequests = [];
  githubWrites = [];
  apiEnv = {
    ...env,
    DB: db,
    CAPTURE_OBJECTS: bucket,
    BRAIN_QUEUE: queue as unknown as Queue,
    INSTANCE_ID: instanceId,
    AGENT_TOKEN: agentToken,
    BRAIN_ORIGIN_URL: originUrl,
    BRAIN_ORIGIN_TOKEN: originToken,
    GMAIL_CALLBACK_URL: callbackUrl,
    GMAIL_STATE_SECRET: "acceptance-state-secret",
  } as unknown as Env;
  vi.stubGlobal("fetch", acceptanceFetch);

  const pairing = await startAndClaimPairing();
  deviceToken = pairing.token;
  const other = await mintPairingCode(db, {
    instanceId: otherInstanceId,
    deviceName: "Other Brain.app",
    scopes: ["capture", "read", "control"],
  });
  otherDeviceToken = (await claimPairingCode(db, {
    instanceId: otherInstanceId,
    code: other.code,
  })).token;
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("remote-first Worker acceptance", () => {
  it("pairs and proves durable capture, live reads, Gmail, heartbeat, and job lifecycle", async () => {
    const dataUrl = `data:image/png;base64,${base64(png)}`;
    const capture = await jsonRequest(
      "/v1/captures",
      {
        type: "design",
        text: "Searchable acceptance image",
        source: "Brain.app acceptance",
        image: dataUrl,
      },
      deviceToken,
      { "idempotency-key": "64000000-0000-4000-8000-000000000001" },
    );
    expect(capture.status).toBe(202);
    const receipt = await capture.json<{ id: string; state: string }>();
    expect(receipt).toEqual({ id: expect.stringMatching(UUID_PATTERN), state: "queued" });

    const captureRow = await db.prepare(
      `SELECT instance_id, device_id, idempotency_key, capture_type, source, object_key,
              object_sha256, state
         FROM captures WHERE id = ?`,
    )
      .bind(receipt.id)
      .first<Record<string, string>>();
    expect(captureRow).toMatchObject({
      instance_id: instanceId,
      idempotency_key: "64000000-0000-4000-8000-000000000001",
      capture_type: "design",
      source: "Brain.app acceptance",
      state: "queued",
    });
    expect(captureRow?.object_sha256).toBe(await sha256Bytes(png));
    const object = await bucket.get(captureRow?.object_key ?? "");
    expect(object).not.toBeNull();
    expect(new Uint8Array(await object!.arrayBuffer())).toEqual(png);
    expect(queue.messages).toHaveLength(1);
    expect(queue.messages[0]?.body).toMatchObject({
      kind: "capture",
      instance_id: instanceId,
      capture: { id: receipt.id, type: "design", text: "Searchable acceptance image" },
      object: { path: `/v1/agent/captures/${receipt.id}/object` },
    });

    const clientObject = await authorized(`/v1/captures/${receipt.id}/object`);
    expect(clientObject.status).toBe(200);
    expect(clientObject.headers.get("x-content-sha256")).toBe(await sha256Bytes(png));
    expect(new Uint8Array(await clientObject.arrayBuffer())).toEqual(png);
    expect((await jsonRequest(
      `/v1/agent/captures/${receipt.id}/result`,
      { state: "delivered" },
      agentToken,
    )).status).toBe(200);
    expect(await (await authorized(`/v1/captures/${receipt.id}`)).json()).toMatchObject({
      id: receipt.id,
      state: "delivered",
      retryable: false,
    });
    const permanentObject = await bucket.get(captureRow?.object_key ?? "");
    expect(permanentObject).not.toBeNull();
    expect(new Uint8Array(await permanentObject!.arrayBuffer())).toEqual(png);

    const status = await authorized("/v1/status");
    expect(status.status).toBe(200);
    expect(status.headers.get("x-brain-snapshot")).toBe("fresh");
    expect(await status.json()).toEqual({
      schema_version: 1,
      inbox: 3,
      site_url: "https://brain-vault.example.pages.dev",
    });
    const health = await authorized("/v1/health");
    expect(health.status).toBe(200);
    expect(await health.json()).toMatchObject({ overall: "activity" });

    expect(await (await authorized("/v1/knowledge/search?q=remote&limit=2")).json()).toEqual({
      query: "remote",
      results: [{ title: "Remote", path: "notes/Remote.md", snippet: "Canonical remote result" }],
    });
    expect(await (await authorized(
      "/v1/knowledge/document?path=notes%2FRemote.md",
    )).json()).toEqual({
      path: "notes/Remote.md",
      title: "Remote",
      content: "# Remote\n\nCanonical content.",
    });
    expect(await (await authorized("/v1/gmail/status")).json()).toEqual({
      status: "connected",
      account: "owner@example.test",
    });

    const created = await jsonRequest("/v1/jobs", { kind: "process" }, deviceToken);
    expect(created.status).toBe(202);
    const job = await created.json<{ id: string; state: string }>();
    expect(job.state).toBe("queued");
    expect(queue.messages.at(-1)?.body).toMatchObject({
      kind: "action",
      instance_id: instanceId,
      action: { id: job.id, kind: "process" },
    });
    expect((await jsonRequest(
      `/v1/agent/jobs/${job.id}/result`,
      { state: "running" },
      agentToken,
    )).status).toBe(200);
    expect((await jsonRequest(
      `/v1/agent/jobs/${job.id}/result`,
      { state: "completed", output: "processed one capture" },
      agentToken,
    )).status).toBe(200);
    expect(await (await authorized(`/v1/jobs/${job.id}`)).json()).toMatchObject({
      id: job.id,
      kind: "process",
      state: "completed",
      output: "processed one capture",
    });

    const asked = await jsonRequest(
      "/v1/jobs",
      { kind: "ask", question: "Where is the remote note?" },
      deviceToken,
    );
    expect(asked.status).toBe(202);
    const askJob = await asked.json<{ id: string; state: string }>();
    expect(queue.messages.at(-1)?.body).toMatchObject({
      kind: "action",
      action: {
        id: askJob.id,
        kind: "ask",
        question: "Where is the remote note?",
      },
    });
    expect((await jsonRequest(
      `/v1/agent/jobs/${askJob.id}/result`,
      { state: "completed", output: "Canonical answer from [[Remote]]." },
      agentToken,
    )).status).toBe(200);
    expect(await (await authorized(`/v1/jobs/${askJob.id}`)).json()).toMatchObject({
      kind: "ask",
      state: "completed",
      output: "Canonical answer from [[Remote]].",
    });

    const generatedAt = new Date(Date.now() - 2_000).toISOString();
    expect((await jsonRequest("/v1/agent/heartbeat", {
      instance_id: instanceId,
      generated_at: generatedAt,
      agent_version: "1",
      status: { inbox: 3 },
      health: { overall: "activity" },
      last_successful_queue_poll: generatedAt,
    }, agentToken)).status).toBe(202);
    expect(originRequests.every((request) =>
      request.headers.get("x-brain-origin-token") === originToken
      && request.headers.get("authorization") === null
    )).toBe(true);
    expect(githubWrites).toEqual([]);
  });

  it("uses stale snapshots safely and preserves instance, legacy capture, and MCP boundaries", async () => {
    expect((await authorized("/v1/status", otherDeviceToken)).status).toBe(401);
    expect((await authorized(
      "/v1/captures/64000000-0000-4000-8000-000000000001/object",
      otherDeviceToken,
    )).status).toBe(401);
    expect((await authorized("/v1/gmail/status", otherDeviceToken)).status).toBe(401);
    expect((await jsonRequest("/v1/jobs", { kind: "digest" }, otherDeviceToken)).status).toBe(401);

    expect((await authorized("/v1/status")).status).toBe(200);
    const old = new Date(Date.now() - 70_000).toISOString();
    await db.prepare("UPDATE heartbeats SET observed_at = ? WHERE instance_id = ?")
      .bind(old, instanceId)
      .run();
    originOffline = true;
    const stale = await authorized("/v1/status");
    expect(stale.status).toBe(200);
    expect(stale.headers.get("x-brain-snapshot")).toBe("stale");
    expect(await stale.json()).toMatchObject({
      schema_version: 1,
      inbox: 3,
      stale: true,
      snapshot_at: old,
    });

    originOffline = false;
    const legacy = await jsonRequest(
      "/capture",
      { text: "legacy compatibility", source: "acceptance" },
      "test-capture-token",
    );
    expect(legacy.status).toBe(201);
    expect(legacy.headers.get("deprecation")).toBe("/v1/captures");
    expect(githubWrites).toHaveLength(1);

    const mcp = await dispatch(new Request(`${base}/mcp`, {
      method: "POST",
      headers: {
        authorization: "Bearer test-mcp-password",
        accept: "application/json, text/event-stream",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 64,
        method: "initialize",
        params: {
          protocolVersion: "2025-03-26",
          capabilities: {},
          clientInfo: { name: "remote-first-acceptance", version: "1" },
        },
      }),
    }), false);
    expect(mcp.status).toBe(200);
  });
});

async function startAndClaimPairing(): Promise<{ token: string }> {
  const started = await jsonRequest(
    "/v1/pair/start",
    { device_name: "Acceptance Brain.app", scopes: ["capture", "read", "control"] },
    agentToken,
  );
  expect(started.status).toBe(201);
  const { code } = await started.json<{ code: string }>();
  const claimed = await jsonRequest("/v1/pair/claim", { code });
  expect(claimed.status).toBe(200);
  const value = await claimed.json<{
    instance_id: string;
    scopes: string[];
    token: string;
  }>();
  expect(value).toMatchObject({
    instance_id: instanceId,
    scopes: ["capture", "read", "control"],
    token: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
  });
  return { token: value.token };
}

async function dispatch(request: Request, wait = true): Promise<Response> {
  const context = createExecutionContext();
  const response = await worker.fetch(request, apiEnv, context);
  if (wait) await waitOnExecutionContext(context);
  return response;
}

function authorized(path: string, token = deviceToken): Promise<Response> {
  return dispatch(new Request(`${base}${path}`, {
    headers: { authorization: `Bearer ${token}` },
  }));
}

function jsonRequest(
  path: string,
  body: unknown,
  token?: string,
  extraHeaders: Record<string, string> = {},
): Promise<Response> {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    ...extraHeaders,
  };
  if (token) headers.authorization = `Bearer ${token}`;
  return dispatch(new Request(`${base}${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  }));
}

async function acceptanceFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const request = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(request.url);
  if (url.hostname === "api.github.com") {
    githubWrites.push(request.clone());
    return Response.json({ content: { path: "unused" } }, { status: 201 });
  }
  if (url.origin !== originUrl) throw new Error(`unexpected acceptance origin: ${url.origin}`);
  originRequests.push(request.clone());
  if (originOffline) throw new Error("acceptance origin offline");
  if (url.pathname === "/v1/status") {
    return Response.json({
      schema_version: 1,
      inbox: 3,
      site_url: "https://brain-vault.example.pages.dev",
    });
  }
  if (url.pathname === "/v1/health") {
    return Response.json({
      schema_version: 1,
      overall: "activity",
      checks: [
        { id: "agent.heartbeat", scope: "mac_mini_agent", state: "pass" },
        { id: "capture.needs_attention", scope: "capture", state: "activity" },
      ],
    });
  }
  if (url.pathname === "/v1/knowledge/search") {
    return Response.json({
      query: url.searchParams.get("q"),
      results: [{ title: "Remote", path: "notes/Remote.md", snippet: "Canonical remote result" }],
    });
  }
  if (url.pathname === "/v1/knowledge/document") {
    return Response.json({
      path: url.searchParams.get("path"),
      title: "Remote",
      content: "# Remote\n\nCanonical content.",
    });
  }
  if (url.pathname === "/v1/agent/gmail/status") {
    return Response.json({ status: "connected", account: "owner@example.test" });
  }
  return Response.json({ error: "not found" }, { status: 404 });
}

async function insertInstance(id: string, name: string, digest: string): Promise<void> {
  const now = new Date().toISOString();
  await db.prepare(
    `INSERT INTO instances (id, name, agent_token_digest, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET agent_token_digest = excluded.agent_token_digest`,
  )
    .bind(id, name, digest, now, now)
    .run();
}

async function sha256(value: string): Promise<string> {
  return sha256Bytes(new TextEncoder().encode(value));
}

async function sha256Bytes(value: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", value);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function base64(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function requireBinding<T>(binding: T | undefined, name: string): T {
  if (!binding) throw new Error(`missing acceptance binding: ${name}`);
  return binding;
}

class AcceptanceQueue {
  readonly messages: Array<{ body: Record<string, any>; options: QueueSendOptions }> = [];

  async send(body: Record<string, any>, options: QueueSendOptions): Promise<void> {
    this.messages.push({ body, options });
  }
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
