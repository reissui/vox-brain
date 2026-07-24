import { applyD1Migrations, env } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import migrationSql from "../migrations/0001_remote_first.sql?raw";
import deliveryMigrationSql from "../migrations/0002_capture_delivery_results.sql?raw";
import permanentObjectMigrationSql from "../migrations/0003_permanent_capture_objects.sql?raw";
import {
  handleCaptureObjectRequest,
  handleCaptureRequest,
  handleCaptureResultRequest,
  handleCaptureStatusRequest,
  type CaptureApiEnv,
  type CaptureDeliveryEnvelope,
} from "../src/capture-api";
import { MAX_TRANSCRIPT_BYTES } from "../src/capture";
import { claimPairingCode, mintPairingCode } from "../src/device-auth";

const migrations = [
  { name: "0001_remote_first.sql", sql: migrationSql },
  { name: "0002_capture_delivery_results.sql", sql: deliveryMigrationSql },
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
const instanceId = "voice-meeting-acceptance";
const agentToken = "agent-acceptance-secret";
const providerCredential = "provider-credential-must-never-cross-the-gateway";
const idempotencyKey = "93000000-0000-4000-8000-000000000093";
const base = "https://voice-meeting.example.test";

let token: string;
let bucket: AcceptanceBucket;
let queue: AcceptanceQueue;
let apiEnv: CaptureApiEnv;

beforeAll(async () => {
  await applyD1Migrations(db, migrations);
  await db.prepare(
    `INSERT OR REPLACE INTO instances
       (id, name, agent_token_digest, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).bind(
    instanceId,
    "Voice meeting acceptance",
    await sha256Text(agentToken),
    "2026-07-16T09:00:00.000Z",
    "2026-07-16T09:00:00.000Z",
  ).run();
});

beforeEach(async () => {
  await db.prepare("DELETE FROM captures WHERE instance_id = ?").bind(instanceId).run();
  await db.prepare("DELETE FROM devices WHERE instance_id = ?").bind(instanceId).run();
  const pairing = await mintPairingCode(db, {
    instanceId,
    deviceName: "Brain.app voice acceptance",
    scopes: ["capture"],
  });
  token = (await claimPairingCode(db, { instanceId, code: pairing.code })).token;
  bucket = new AcceptanceBucket();
  queue = new AcceptanceQueue();
  apiEnv = {
    DB: db,
    CAPTURE_OBJECTS: bucket as unknown as R2Bucket,
    BRAIN_QUEUE: queue as unknown as Queue,
    INSTANCE_ID: instanceId,
    AGENT_TOKEN: agentToken,
  };
});

describe("voice meeting gateway acceptance", () => {
  it("stages, retries, streams, and delivers one six-MiB transcript without audio or credentials", async () => {
    const line = "[00:00:00.000-00:00:01.000] You: canonical acceptance transcript\n";
    const transcript = (line.repeat(Math.ceil(MAX_TRANSCRIPT_BYTES / line.length)))
      .slice(0, MAX_TRANSCRIPT_BYTES);
    expect(new TextEncoder().encode(transcript)).toHaveLength(MAX_TRANSCRIPT_BYTES);
    const body = JSON.stringify({
      type: "transcript",
      source: "Brain.app meeting",
      title: "Voice meeting acceptance.md",
      transcript,
    });

    queue.failSend = true;
    const failed = await postCapture(body);
    expect(failed.status).toBe(503);
    const failedRow = await captureRow();
    expect(failedRow).toMatchObject({
      capture_type: "transcript",
      source: "Brain.app meeting",
      state: "failed",
      last_error: "gateway_queue_publish_failed",
    });
    expect(bucket.putCalls).toBe(1);
    expect(bucket.objects.get(failedRow!.object_key)).toEqual(new TextEncoder().encode(transcript));
    expect(queue.messages).toEqual([]);

    queue.failSend = false;
    const accepted = await postCapture(body);
    expect(accepted.status).toBe(202);
    expect(await accepted.json()).toEqual({ id: failedRow!.id, state: "queued" });
    expect(bucket.putCalls).toBe(1);
    expect(bucket.headCalls).toBe(1);
    expect(queue.messages).toHaveLength(1);

    const envelope = queue.messages[0]!;
    expect(envelope.capture).toEqual({
      id: failedRow!.id,
      captured_at: expect.stringMatching(/Z$/),
      type: "transcript",
      source: "Brain.app meeting",
      title: "Voice meeting acceptance.md",
    });
    expect(envelope.object).toEqual({
      kind: "transcript",
      capture_id: failedRow!.id,
      path: `/v1/agent/captures/${failedRow!.id}/object`,
      sha256: await sha256Text(transcript),
      content_type: "text/plain; charset=utf-8",
      byte_length: MAX_TRANSCRIPT_BYTES,
      filename: "transcript.txt",
      retention: "permanent",
    });
    const serializedEnvelope = JSON.stringify(envelope);
    expect(serializedEnvelope).not.toContain(transcript.slice(0, 128));
    expect(serializedEnvelope).not.toContain(providerCredential);
    expect(serializedEnvelope).not.toMatch(/audio|credential|authorization/i);

    const object = await handleCaptureObjectRequest(new Request(
      `${base}${envelope.object!.path}`,
      { headers: { authorization: `Bearer ${agentToken}` } },
    ), apiEnv);
    expect(object.status).toBe(200);
    expect(object.headers.get("content-type")).toBe("text/plain; charset=utf-8");
    expect(new Uint8Array(await object.arrayBuffer())).toEqual(new TextEncoder().encode(transcript));

    expect((await postResult(failedRow!.id, { state: "delivered" })).status).toBe(200);
    expect((await postResult(failedRow!.id, { state: "delivered" })).status).toBe(200);
    expect(bucket.deleteKeys).toEqual([]);
    expect(bucket.objects.size).toBe(1);
    expect(bucket.objects.has(failedRow!.object_key)).toBe(true);
    const status = await handleCaptureStatusRequest(new Request(
      `${base}/v1/captures/${failedRow!.id}`,
      { headers: { authorization: `Bearer ${token}` } },
    ), apiEnv);
    expect(status.status).toBe(200);
    expect(await status.json()).toMatchObject({
      id: failedRow!.id,
      state: "delivered",
      retryable: false,
      error: null,
      delivered_at: expect.stringMatching(/Z$/),
    });
  }, 60_000);
});

async function postCapture(body: string): Promise<Response> {
  return handleCaptureRequest(new Request(`${base}/v1/captures`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      "idempotency-key": idempotencyKey,
    },
    body,
  }), apiEnv);
}

async function postResult(id: string, body: unknown): Promise<Response> {
  return handleCaptureResultRequest(new Request(`${base}/v1/agent/captures/${id}/result`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${agentToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  }), apiEnv);
}

async function captureRow(): Promise<{
  id: string;
  capture_type: string;
  source: string;
  object_key: string;
  state: string;
  last_error: string | null;
} | null> {
  return db.prepare(
    `SELECT id, capture_type, source, object_key, state, last_error
       FROM captures WHERE instance_id = ? AND idempotency_key = ?`,
  ).bind(instanceId, idempotencyKey).first();
}

class AcceptanceQueue {
  messages: CaptureDeliveryEnvelope[] = [];
  failSend = false;

  async send(body: CaptureDeliveryEnvelope): Promise<void> {
    if (this.failSend) throw new Error("injected Queue outage");
    this.messages.push(structuredClone(body));
  }
}

class AcceptanceBucket {
  objects = new Map<string, Uint8Array>();
  deleteKeys: string[] = [];
  putCalls = 0;
  headCalls = 0;

  async put(
    key: string,
    value: Uint8Array,
    options: { httpMetadata?: { contentType?: string }; customMetadata?: Record<string, string> },
  ): Promise<R2Object> {
    this.putCalls += 1;
    this.objects.set(key, value.slice());
    return this.object(key, options.httpMetadata?.contentType, options.customMetadata?.sha256);
  }

  async head(key: string): Promise<R2Object | null> {
    this.headCalls += 1;
    return this.objects.has(key) ? this.object(key) : null;
  }

  async get(key: string): Promise<R2ObjectBody | null> {
    if (!this.objects.has(key)) return null;
    return this.object(key, "text/plain; charset=utf-8", undefined, true) as R2ObjectBody;
  }

  async delete(key: string): Promise<void> {
    if (this.objects.delete(key)) this.deleteKeys.push(key);
  }

  private object(
    key: string,
    contentType = "text/plain; charset=utf-8",
    sha256 = "",
    withBody = false,
  ): R2Object {
    const bytes = this.objects.get(key)!;
    const value: Record<string, unknown> = {
      key,
      version: "acceptance",
      size: bytes.byteLength,
      etag: "acceptance",
      httpEtag: '"acceptance"',
      uploaded: new Date("2026-07-16T09:00:00.000Z"),
      checksums: {},
      httpMetadata: { contentType },
      customMetadata: { sha256 },
      range: undefined,
      storageClass: "Standard",
      writeHttpMetadata(headers: Headers) { headers.set("content-type", contentType); },
    };
    if (withBody) value.body = new Response(bytes).body;
    return value as unknown as R2Object;
  }
}

async function sha256Text(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function requireBinding<T>(binding: T | undefined, name: string): T {
  if (!binding) throw new Error(`${name} test binding is not configured`);
  return binding;
}
