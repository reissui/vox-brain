import { applyD1Migrations, env } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import migrationSql from "../migrations/0001_remote_first.sql?raw";
import captureResultMigrationSql from "../migrations/0002_capture_delivery_results.sql?raw";
import permanentObjectMigrationSql from "../migrations/0003_permanent_capture_objects.sql?raw";
import { claimPairingCode, mintPairingCode, type DeviceScope } from "../src/device-auth";
import {
  MAX_JOB_OUTPUT_BYTES,
  handleRemoteApi,
  type JobDeliveryEnvelope,
  type RemoteApiEnv,
} from "../src/remote-api";

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
const instanceId = "instance-remote-api";
const otherInstanceId = "instance-other";
const originToken = "origin-secret-never-from-a-client";
const agentToken = "agent-secret-independent-from-device-tokens";
const originUrl = "https://brain-origin.example.test";

let readToken: string;
let controlToken: string;
let captureToken: string;
let queue: FakeQueue;
let bucket: FakeBucket;
let apiEnv: RemoteApiEnv;
let originOffline: boolean;
let originRequests: OriginRequest[];

beforeAll(async () => {
  await applyD1Migrations(db, migrations);
  await insertInstance(instanceId, "Remote API", await sha256(agentToken));
  await insertInstance(otherInstanceId, "Other", await sha256("other-agent-token"));
});

beforeEach(async () => {
  await db.prepare("DELETE FROM captures").run();
  await db.prepare("DELETE FROM heartbeats").run();
  await db.prepare("DELETE FROM jobs").run();
  await db.prepare("DELETE FROM devices").run();
  readToken = await pair("Reader", ["read"]);
  controlToken = await pair("Controller", ["control"]);
  captureToken = await pair("Capture only", ["capture"]);
  await insertOtherDevice();
  queue = new FakeQueue();
  bucket = new FakeBucket();
  apiEnv = {
    DB: db,
    BRAIN_QUEUE: queue as unknown as Queue,
    CAPTURE_OBJECTS: bucket as unknown as R2Bucket,
    INSTANCE_ID: instanceId,
    BRAIN_ORIGIN_URL: originUrl,
    BRAIN_ORIGIN_TOKEN: originToken,
    AGENT_TOKEN: agentToken,
  };
  originOffline = false;
  originRequests = [];
  vi.stubGlobal("fetch", fakeOriginFetch);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("live status and stale snapshots", () => {
  it("requires read scope, sends only fixed origin authentication, and persists live status and health", async () => {
    expect((await get("/v1/status", null)).status).toBe(401);
    expect((await get("/v1/status", controlToken)).status).toBe(403);
    expect((await get("/v1/health", captureToken)).status).toBe(403);
    expect(await heartbeatCount()).toBe(0);

    const status = await get("/v1/status", readToken, {
      "x-brain-origin-token": "client-injection",
      "x-origin-url": "https://attacker.invalid",
    });
    expect(status.status).toBe(200);
    expect(status.headers.get("x-brain-snapshot")).toBe("fresh");
    expect(await status.json()).toEqual({
      schema_version: 1,
      inbox: 2,
      site_url: "https://private.example.test",
    });

    const health = await get("/v1/health", readToken);
    expect(health.status).toBe(200);
    expect(await health.json()).toEqual({ overall: "pass", checks: [] });
    expect(originRequests).toEqual([
      {
        url: `${originUrl}/v1/status`,
        method: "GET",
        accept: "application/json",
        originToken,
        authorization: null,
      },
      {
        url: `${originUrl}/v1/health`,
        method: "GET",
        accept: "application/json",
        originToken,
        authorization: null,
      },
    ]);
    expect(await heartbeatCount()).toBe(2);
  });

  it("returns a clearly aged stale route-specific snapshot only for status and health", async () => {
    expect((await get("/v1/status", readToken)).status).toBe(200);
    const old = new Date(Date.now() - 65_000).toISOString();
    await db.prepare("UPDATE heartbeats SET observed_at = ?").bind(old).run();
    originOffline = true;

    const stale = await get("/v1/status", readToken);
    expect(stale.status).toBe(200);
    expect(stale.headers.get("x-brain-snapshot")).toBe("stale");
    expect(Number(stale.headers.get("x-brain-snapshot-age-seconds"))).toBeGreaterThanOrEqual(65);
    expect(await stale.json()).toMatchObject({
      schema_version: 1,
      inbox: 2,
      stale: true,
      age_seconds: expect.any(Number),
      snapshot_at: old,
    });

    const noHealthSnapshot = await get("/v1/health", readToken);
    expect(noHealthSnapshot.status).toBe(503);
    expect(await noHealthSnapshot.json()).toEqual({ error: "remote Brain unavailable" });
  });

  it("accepts an agent heartbeat as the latest offline status and health snapshot", async () => {
    const generatedAt = new Date(Date.now() - 2_000).toISOString();
    const heartbeat = await agentPost("/v1/agent/heartbeat", {
      instance_id: instanceId,
      generated_at: generatedAt,
      agent_version: "1",
      status: { inbox: 7, site_url: "https://private.example.test" },
      health: { overall: "activity" },
      last_successful_queue_poll: generatedAt,
    });
    expect(heartbeat.status).toBe(202);
    originOffline = true;

    expect(await (await get("/v1/status", readToken)).json()).toMatchObject({
      inbox: 7,
      site_url: "https://private.example.test",
      stale: true,
    });
    expect(await (await get("/v1/health", readToken)).json()).toMatchObject({
      overall: "activity",
      stale: true,
    });

    const unavailableAt = new Date(Date.now() - 1_000).toISOString();
    expect((await agentPost("/v1/agent/heartbeat", {
      instance_id: instanceId,
      generated_at: unavailableAt,
      agent_version: "1",
      status: { available: false },
      health: { available: false },
      last_successful_queue_poll: unavailableAt,
    })).status).toBe(202);
    expect(await (await get("/v1/status", readToken)).json()).toMatchObject({
      inbox: 7,
      stale: true,
    });
  });

  it("preserves typed Agent operations and rejects malformed health diagnostics", async () => {
    const at = new Date().toISOString();
    const operations = {
      last_successful_poll: at,
      poll_age_seconds: 1,
      backlog_count: 2,
      oldest_backlog_age_seconds: 95,
      process: {
        state: "stuck",
        label: "capture:safe-id",
        started_at: at,
        progress_age_seconds: 95,
        declared_bound_seconds: 90,
      },
      automation: {
        last_progress_at: at,
        progress_age_seconds: 2,
      },
      launchd: { agent: "running", automation: "loaded" },
    };
    expect((await agentPost("/v1/agent/heartbeat", {
      instance_id: instanceId,
      generated_at: at,
      agent_version: "2",
      status: { inbox: 1 },
      health: { overall: "failure", operations },
      last_successful_queue_poll: at,
    })).status).toBe(202);
    originOffline = true;
    expect(await (await get("/v1/health", readToken)).json()).toMatchObject({
      overall: "failure",
      operations,
      stale: true,
    });

    expect((await agentPost("/v1/agent/heartbeat", {
      instance_id: instanceId,
      generated_at: at,
      agent_version: "2",
      status: { inbox: 1 },
      health: { overall: "pass", operations: { ...operations, backlog_count: -1 } },
      last_successful_queue_poll: at,
    })).status).toBe(422);
  });

  it("rejects unsafe site destinations and remains compatible with an older Agent", async () => {
    const older = await get("/v1/status", readToken);
    expect(older.status).toBe(200);
    expect(await older.json()).toMatchObject({ site_url: "https://private.example.test" });

    const at = new Date().toISOString();
    const unsafe = await agentPost("/v1/agent/heartbeat", {
      instance_id: instanceId,
      generated_at: at,
      agent_version: "1",
      status: { inbox: 7, site_url: "https://user:secret@attacker.invalid?token=secret" },
      health: { overall: "activity" },
      last_successful_queue_poll: at,
    });
    expect(unsafe.status).toBe(422);

    originOffline = true;
    await db.prepare("DELETE FROM heartbeats").run();
    const olderHeartbeat = await agentPost("/v1/agent/heartbeat", {
      instance_id: instanceId,
      generated_at: at,
      agent_version: "0",
      status: { inbox: 3 },
      health: { overall: "pass" },
      last_successful_queue_poll: at,
    });
    expect(olderHeartbeat.status).toBe(202);
    expect(await (await get("/v1/status", readToken)).json()).toMatchObject({ inbox: 3 });
    expect(await (await get("/v1/status", readToken)).json()).not.toHaveProperty("site_url");
  });
});

describe("live knowledge proxy", () => {
  it("requires read scope and forwards only fixed list/search/document parameters", async () => {
    expect((await get("/v1/knowledge/search?q=Agents", controlToken)).status).toBe(403);
    const documents = await get("/v1/knowledge/documents?limit=2", readToken);
    expect(documents.status).toBe(200);
    expect(await documents.json()).toEqual({
      documents: [{ title: "Agents", path: "notes/Agents.md" }],
    });
    const search = await get("/v1/knowledge/search?q=Agents%20SDK&limit=3", readToken, {
      authorization: `Bearer ${readToken}`,
      "x-brain-origin-token": "client-origin-token",
    });
    expect(search.status).toBe(200);
    expect(await search.json()).toEqual({
      query: "Agents SDK",
      results: [{ title: "Agents", path: "notes/Agents.md", snippet: "match" }],
    });

    const document = await get(
      "/v1/knowledge/document?path=notes%2FAgents.md",
      readToken,
    );
    expect(document.status).toBe(200);
    expect(await document.json()).toEqual({
      path: "notes/Agents.md",
      title: "Agents",
      content: "# Agents\n\nCanonical.",
    });
    expect(originRequests.map((request) => request.url)).toEqual([
      `${originUrl}/v1/knowledge/documents?limit=2`,
      `${originUrl}/v1/knowledge/search?q=Agents+SDK&limit=3`,
      `${originUrl}/v1/knowledge/document?path=notes%2FAgents.md`,
    ]);
    expect(originRequests.every((request) => request.originToken === originToken)).toBe(true);
    expect(originRequests.every((request) => request.authorization === null)).toBe(true);
  });

  it("fails live knowledge closed when offline and never uses a D1 snapshot", async () => {
    await db.prepare(
      `INSERT INTO heartbeats (id, instance_id, agent_version, status_json, observed_at)
       VALUES ('old-copy', ?, '1', ?, ?)`,
    )
      .bind(
        instanceId,
        JSON.stringify({ document: { path: "notes/Agents.md", content: "stale secret" } }),
        new Date().toISOString(),
      )
      .run();
    originOffline = true;

    const search = await get("/v1/knowledge/search?q=Agents", readToken);
    const document = await get("/v1/knowledge/document?path=notes%2FAgents.md", readToken);
    expect(search.status).toBe(503);
    expect(document.status).toBe(503);
    expect(JSON.stringify(await search.json())).not.toContain("stale secret");
    expect(JSON.stringify(await document.json())).not.toContain("stale secret");
  });

  it("rejects extra, repeated, unbounded, and unsafe path parameters before fetch", async () => {
    const invalid = [
      "/v1/knowledge/search?q=x&origin=https%3A%2F%2Fevil.invalid",
      "/v1/knowledge/search?q=x&q=y",
      "/v1/knowledge/search?q=&limit=2",
      "/v1/knowledge/search?q=x&limit=51",
      "/v1/knowledge/documents?limit=0",
      "/v1/knowledge/documents?path=notes%2FAgents.md",
      "/v1/knowledge/document?path=%2Fetc%2Fpasswd",
      "/v1/knowledge/document?path=notes%2F..%2Fme%2Fprofile.md",
      "/v1/knowledge/document?path=notes%2FAgents.md&argv=cat",
    ];
    for (const path of invalid) expect((await get(path, readToken)).status).toBe(400);
    expect(originRequests).toEqual([]);
  });
});

describe("durable allowlisted jobs", () => {
  it("requires control scope and writes exactly one D1 row plus one queue envelope for each job type", async () => {
    expect((await postJob({ kind: "process" }, null)).status).toBe(401);
    expect((await postJob({ kind: "process" }, readToken)).status).toBe(403);
    expect(await jobCount()).toBe(0);

    const cases = [
      { kind: "ask", question: "What links to [[Agents]]?" },
      { kind: "process" },
      { kind: "digest" },
    ];
    for (const body of cases) {
      const response = await postJob(body);
      expect(response.status).toBe(202);
      expect(await response.json()).toEqual({
        id: expect.stringMatching(/^[0-9a-f-]{36}$/),
        state: "queued",
      });
    }

    expect(await jobCount()).toBe(3);
    expect(queue.messages).toHaveLength(3);
    expect(queue.messages.map(({ body }) => body.action.kind)).toEqual(["ask", "process", "digest"]);
    expect(queue.messages[0]?.body.action.question).toBe("What links to [[Agents]]?");
    for (const message of queue.messages) {
      expect(message.body).toMatchObject({ kind: "action", instance_id: instanceId });
      expect(message.body.action).not.toHaveProperty("argv");
      expect(message.options).toEqual({ contentType: "json" });
    }
    const rows = await db.prepare(
      "SELECT kind, state, request_digest FROM jobs ORDER BY created_at, kind",
    ).all<{ kind: string; state: string; request_digest: string }>();
    expect(rows.results.map((row) => row.kind).sort()).toEqual(["ask", "digest", "process"]);
    expect(rows.results.every((row) => row.state === "queued")).toBe(true);
    expect(rows.results.every((row) => /^[0-9a-f]{64}$/.test(row.request_digest))).toBe(true);
  });

  it("accepts no shell, argv, origin URL, path, or unsupported job kind", async () => {
    const forbidden = [
      { kind: "shell", command: "rm -rf /" },
      { kind: "process", shell: "brain process" },
      { kind: "process", argv: ["brain", "process"] },
      { kind: "digest", origin_url: "https://evil.invalid" },
      { kind: "ask", question: "question", path: "/tmp/vox-brain-example" },
      { kind: "ask", question: "" },
    ];
    for (const body of forbidden) expect((await postJob(body)).status).toBe(422);
    expect(await jobCount()).toBe(0);
    expect(queue.messages).toEqual([]);
  });

  it("does not acknowledge a queue failure and records a terminal operational failure", async () => {
    queue.fail = true;
    const response = await postJob({ kind: "digest" });
    expect(response.status).toBe(503);
    const row = await db.prepare("SELECT state, last_error FROM jobs").first<{
      state: string;
      last_error: string;
    }>();
    expect(row).toEqual({ state: "failed", last_error: "gateway_queue_publish_failed" });
  });
});

describe("job reads and agent reports", () => {
  it("returns instance-scoped state, bounds output, and preserves Brain wikilink citations", async () => {
    const created = await postJob({ kind: "ask", question: "What do I know?" });
    const { id } = await created.json<{ id: string }>();
    const output = "Grounded in [[notes/Agents]] and [[projects/Brain]].\n" +
      "x".repeat(MAX_JOB_OUTPUT_BYTES + 100);
    const completed = await agentPost(`/v1/agent/jobs/${id}/result`, {
      state: "completed",
      output,
    });
    expect(completed.status).toBe(200);

    expect((await get(`/v1/jobs/${id}`, controlToken)).status).toBe(403);
    const result = await get(`/v1/jobs/${id}`, readToken);
    expect(result.status).toBe(200);
    const payload = await result.json<{ state: string; output: string; truncated: boolean }>();
    expect(payload.state).toBe("completed");
    expect(payload.output).toContain("[[notes/Agents]]");
    expect(payload.output).toContain("[[projects/Brain]]");
    expect(new TextEncoder().encode(payload.output)).toHaveLength(MAX_JOB_OUTPUT_BYTES);
    expect(payload.truncated).toBe(true);

    await insertOtherJob("other-instance-job");
    expect((await get("/v1/jobs/other-instance-job", readToken)).status).toBe(404);
  });

  it("requires the agent bearer and permits only forward transitions with idempotent terminal replay", async () => {
    const created = await postJob({ kind: "process" });
    const { id } = await created.json<{ id: string }>();
    const resultPath = `/v1/agent/jobs/${id}/result`;

    expect((await postJson(resultPath, { state: "running" }, readToken)).status).toBe(401);
    expect((await postJson(resultPath, { state: "running" }, captureToken)).status).toBe(401);
    expect((await agentPost(resultPath, { state: "queued" })).status).toBe(422);

    expect((await agentPost(resultPath, { state: "running" })).status).toBe(200);
    expect((await agentPost(resultPath, { state: "running" })).status).toBe(200);
    const terminal = { state: "completed", output: "processed 4 captures" };
    expect((await agentPost(resultPath, terminal)).status).toBe(200);
    expect((await agentPost(resultPath, terminal)).status).toBe(200);
    expect((await agentPost(resultPath, { state: "failed", error: "action_failed" })).status).toBe(409);
    expect((await agentPost(resultPath, { state: "running" })).status).toBe(409);

    const row = await db.prepare(
      "SELECT state, result_json, started_at, finished_at FROM jobs WHERE id = ?",
    )
      .bind(id)
      .first<{ state: string; result_json: string; started_at: string; finished_at: string }>();
    expect(row?.state).toBe("completed");
    expect(JSON.parse(row?.result_json ?? "null")).toEqual({ output: "processed 4 captures" });
    expect(row?.started_at).toBeTruthy();
    expect(row?.finished_at).toBeTruthy();
  });

  it("rejects client credentials and wrong-instance or secret-bearing heartbeat fields", async () => {
    const at = new Date().toISOString();
    const body = {
      instance_id: instanceId,
      generated_at: at,
      agent_version: "1",
      status: { inbox: 0 },
      health: { overall: "pass" },
      last_successful_queue_poll: at,
    };
    expect((await postJson("/v1/agent/heartbeat", body, readToken)).status).toBe(401);
    expect((await agentPost("/v1/agent/heartbeat", { ...body, instance_id: otherInstanceId })).status).toBe(422);
    expect((await agentPost("/v1/agent/heartbeat", { ...body, origin_url: originUrl })).status).toBe(422);
    expect((await agentPost("/v1/agent/heartbeat", body)).status).toBe(202);
    expect(await heartbeatCount()).toBe(1);
  });
});

describe("paired permanent-object contract", () => {
  it("routes object reads through read scope and never exposes storage coordinates", async () => {
    const id = "00000070-1111-4111-8111-000000000070";
    const key = `instances/${instanceId}/captures/${id}/original.pdf`;
    const bytes = Uint8Array.of(0x25, 0x50, 0x44, 0x46);
    const digest = await sha256Bytes(bytes);
    const reader = await db.prepare(
      "SELECT id FROM devices WHERE instance_id = ? AND name = 'Reader'",
    ).bind(instanceId).first<{ id: string }>();
    await db.prepare(
      `INSERT INTO captures
        (id, instance_id, device_id, idempotency_key, payload_digest, capture_type, source,
         object_key, object_sha256, object_content_type, object_byte_length, object_filename,
         object_retention_state, state, captured_at, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, 'note', 'test', ?, ?, 'application/pdf', ?, 'source.pdf',
               'permanent', 'delivered', ?, ?, ?)`,
    ).bind(
      id,
      instanceId,
      reader?.id,
      "00000071-1111-4111-8111-000000000071",
      "d".repeat(64),
      key,
      digest,
      bytes.byteLength,
      new Date().toISOString(),
      new Date().toISOString(),
      new Date().toISOString(),
    ).run();
    bucket.seed(key, bytes, digest);

    expect((await get(`/v1/captures/${id}/object`, captureToken)).status).toBe(403);
    const response = await get(`/v1/captures/${id}/object`, readToken);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/pdf");
    expect(response.headers.get("content-length")).toBe(String(bytes.byteLength));
    expect(response.headers.get("etag")).toBe(`"${digest}"`);
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(bytes);
    expect(response.headers.get("x-r2-key")).toBeNull();
    expect(JSON.stringify([...response.headers])).not.toContain(key);
  });
});

describe("closed routing", () => {
  it("returns closed method/route errors without writes or fetches", async () => {
    const cases = [
      new Request("https://gateway.test/v1/status", { method: "POST" }),
      new Request("https://gateway.test/v1/jobs/one/result", { method: "POST" }),
      new Request("https://gateway.test/v1/knowledge", { method: "GET" }),
      new Request("https://gateway.test/v1/agent/jobs/one", { method: "POST" }),
      new Request("https://gateway.test/v1/status?origin=https://evil.invalid", {
        headers: { authorization: `Bearer ${readToken}` },
      }),
    ];
    expect((await handleRemoteApi(cases[0]!, apiEnv)).status).toBe(405);
    expect((await handleRemoteApi(cases[1]!, apiEnv)).status).toBe(404);
    expect((await handleRemoteApi(cases[2]!, apiEnv)).status).toBe(404);
    expect((await handleRemoteApi(cases[3]!, apiEnv)).status).toBe(404);
    expect((await handleRemoteApi(cases[4]!, apiEnv)).status).toBe(400);
    expect(originRequests).toEqual([]);
    expect(queue.messages).toEqual([]);
    expect(await jobCount()).toBe(0);
  });
});

async function fakeOriginFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const request = input instanceof Request ? input : new Request(String(input), init);
  const headers = request.headers;
  originRequests.push({
    url: request.url,
    method: request.method,
    accept: headers.get("accept"),
    originToken: headers.get("x-brain-origin-token"),
    authorization: headers.get("authorization"),
  });
  if (originOffline) throw new Error("origin offline");

  const url = new URL(request.url);
  if (url.pathname === "/v1/status") {
    return originJson(200, {
      schema_version: 1,
      inbox: 2,
      site_url: "https://private.example.test",
    });
  }
  if (url.pathname === "/v1/health") return originJson(200, { overall: "pass", checks: [] });
  if (url.pathname === "/v1/knowledge/documents") {
    return originJson(200, {
      documents: [{ title: "Agents", path: "notes/Agents.md" }],
    });
  }
  if (url.pathname === "/v1/knowledge/search") {
    return originJson(200, {
      query: url.searchParams.get("q"),
      results: [{ title: "Agents", path: "notes/Agents.md", snippet: "match" }],
    });
  }
  if (url.pathname === "/v1/knowledge/document") {
    return originJson(200, {
      path: url.searchParams.get("path"),
      title: "Agents",
      content: "# Agents\n\nCanonical.",
    });
  }
  return originJson(404, { error: { code: "not_found" } });
}

function originJson(status: number, value: unknown): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function get(
  path: string,
  token: string | null = readToken,
  extraHeaders: Record<string, string> = {},
): Promise<Response> {
  const headers = new Headers(extraHeaders);
  if (token) headers.set("authorization", `Bearer ${token}`);
  return handleRemoteApi(new Request(`https://gateway.test${path}`, { headers }), apiEnv);
}

async function postJob(value: unknown, token: string | null = controlToken): Promise<Response> {
  return postJson("/v1/jobs", value, token);
}

async function agentPost(path: string, value: unknown): Promise<Response> {
  return postJson(path, value, agentToken);
}

async function postJson(path: string, value: unknown, token: string | null): Promise<Response> {
  const headers = new Headers({ "content-type": "application/json" });
  if (token) headers.set("authorization", `Bearer ${token}`);
  return handleRemoteApi(
    new Request(`https://gateway.test${path}`, {
      method: "POST",
      headers,
      body: JSON.stringify(value),
    }),
    apiEnv,
  );
}

async function pair(name: string, scopes: readonly DeviceScope[]): Promise<string> {
  const minted = await mintPairingCode(db, { instanceId, deviceName: name, scopes });
  return (await claimPairingCode(db, { instanceId, code: minted.code })).token;
}

async function insertInstance(id: string, name: string, digest: string): Promise<void> {
  const now = new Date().toISOString();
  await db.prepare(
    `INSERT INTO instances (id, name, agent_token_digest, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
    .bind(id, name, digest, now, now)
    .run();
}

async function insertOtherDevice(): Promise<void> {
  const now = new Date().toISOString();
  await db.prepare(
    `INSERT INTO devices
      (id, instance_id, name, token_digest, scopes, claimed_at, created_at, updated_at)
     VALUES ('other-device', ?, 'Other device', ?, '["read"]', ?, ?, ?)`,
  )
    .bind(otherInstanceId, await sha256("other-device-token"), now, now, now)
    .run();
}

async function insertOtherJob(id: string): Promise<void> {
  const now = new Date().toISOString();
  await db.prepare(
    `INSERT INTO jobs
      (id, instance_id, device_id, request_digest, kind, state, created_at, updated_at)
     VALUES (?, ?, 'other-device', ?, 'ask', 'queued', ?, ?)`,
  )
    .bind(id, otherInstanceId, "d".repeat(64), now, now)
    .run();
}

async function jobCount(): Promise<number> {
  return ((await db.prepare("SELECT COUNT(*) AS count FROM jobs").first<{ count: number }>())?.count ?? 0);
}

async function heartbeatCount(): Promise<number> {
  return ((await db.prepare("SELECT COUNT(*) AS count FROM heartbeats").first<{ count: number }>())?.count ?? 0);
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256Bytes(value: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", value);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function requireBinding<T>(binding: T | undefined, name: string): T {
  if (!binding) throw new Error(`missing test binding: ${name}`);
  return binding;
}

interface OriginRequest {
  url: string;
  method: string;
  accept: string | null;
  originToken: string | null;
  authorization: string | null;
}

class FakeQueue {
  messages: Array<{ body: JobDeliveryEnvelope; options: QueueSendOptions }> = [];
  fail = false;

  async send(body: JobDeliveryEnvelope, options: QueueSendOptions): Promise<void> {
    if (this.fail) throw new Error("queue unavailable");
    this.messages.push({ body, options });
  }
}

class FakeBucket {
  private readonly objects = new Map<string, { bytes: Uint8Array; sha256: string }>();

  seed(key: string, bytes: Uint8Array, sha256Value: string): void {
    this.objects.set(key, { bytes: bytes.slice(), sha256: sha256Value });
  }

  async get(key: string): Promise<R2ObjectBody | null> {
    const stored = this.objects.get(key);
    if (!stored) return null;
    return {
      key,
      version: "test",
      size: stored.bytes.byteLength,
      etag: stored.sha256,
      httpEtag: `"${stored.sha256}"`,
      uploaded: new Date(),
      checksums: {},
      httpMetadata: { contentType: "application/pdf" },
      customMetadata: { sha256: stored.sha256 },
      range: undefined,
      storageClass: "Standard",
      body: new Response(stored.bytes).body,
      bodyUsed: false,
      arrayBuffer: () => Promise.resolve(stored.bytes.buffer),
      bytes: () => Promise.resolve(stored.bytes),
      text: () => Promise.resolve(new TextDecoder().decode(stored.bytes)),
      json: () => Promise.reject(new Error("not json")),
      blob: () => Promise.resolve(new Blob([stored.bytes])),
      writeHttpMetadata() {},
    } as unknown as R2ObjectBody;
  }
}
