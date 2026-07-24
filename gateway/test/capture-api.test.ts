import { applyD1Migrations, env } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import migrationSql from "../migrations/0001_remote_first.sql?raw";
import captureResultMigrationSql from "../migrations/0002_capture_delivery_results.sql?raw";
import permanentObjectMigrationSql from "../migrations/0003_permanent_capture_objects.sql?raw";
import {
  MAX_CAPTURE_BODY_BYTES,
  MAX_CAPTURE_QUEUE_BYTES,
  MAX_CAPTURE_STATUS_ERROR_BYTES,
  handleCaptureApi,
  handleCaptureObjectRequest,
  handleCaptureListRequest,
  handlePairedCaptureObjectRequest,
  handleCaptureRequest,
  handleCaptureResultRequest,
  handleCaptureStatusRequest,
  type CaptureApiEnv,
  type CaptureDeliveryEnvelope,
} from "../src/capture-api";
import { MAX_TRANSCRIPT_BYTES } from "../src/capture";
import { claimPairingCode, mintPairingCode, type DeviceScope } from "../src/device-auth";

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
const instanceId = "instance-capture";
const otherInstanceId = "instance-other";
const agentToken = "agent-secret-independent-from-device-credentials";
const baseTime = new Date("2026-07-15T12:00:00.000Z");
const imageBytes = Uint8Array.of(
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x72, 0x65, 0x6d, 0x6f, 0x74, 0x65,
);
const imageDataUrl = `data:image/png;base64,${base64(imageBytes)}`;

let bucket: FakeBucket;
let queue: FakeQueue;
let apiEnv: CaptureApiEnv;
let captureToken: string;
let readToken: string;
let outboundUrls: string[];

beforeAll(async () => {
  await applyD1Migrations(db, migrations);
  await insertInstance(instanceId, "Capture instance", await sha256Text(agentToken));
  await insertInstance(otherInstanceId, "Other instance", await sha256Text("other-agent-secret"));
});

beforeEach(async () => {
  await db.prepare("DELETE FROM captures").run();
  await db.prepare("DELETE FROM devices").run();
  captureToken = (await pair("Capture client", ["capture"])).token;
  readToken = (await pair("Read-only client", ["read"])).token;
  bucket = new FakeBucket();
  queue = new FakeQueue();
  apiEnv = {
    DB: db,
    CAPTURE_OBJECTS: bucket as unknown as R2Bucket,
    BRAIN_QUEUE: queue as unknown as Queue,
    INSTANCE_ID: instanceId,
  };
  outboundUrls = [];
  vi.stubGlobal("fetch", async (input: RequestInfo | URL): Promise<Response> => {
    const url = String(input);
    outboundUrls.push(url);
    return new Response("unavailable", { status: 503 });
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("POST /v1/captures authorization and validation", () => {
  it("requires a paired device with capture scope", async () => {
    const key = uuid(1);
    const body = JSON.stringify({ text: "authorization boundary" });

    expect((await post(body, key, null)).status).toBe(401);
    expect((await post(body, key, readToken)).status).toBe(403);
    expect(await captureCount()).toBe(0);
    expect(bucket.putCalls).toBe(0);
    expect(queue.messages).toHaveLength(0);
  });

  it("requires an RFC 4122 UUID idempotency key before writing", async () => {
    for (const key of [null, "", "not-a-uuid", "11111111-1111-0111-8111-111111111111"]) {
      const response = await post(JSON.stringify({ text: "note" }), key);
      expect(response.status).toBe(422);
      expect(await response.json()).toEqual({
        error: "Idempotency-Key must be an RFC 4122 UUID",
      });
    }
    expect(await captureCount()).toBe(0);
  });

  it("enforces the eight-MiB encoded body ceiling and existing capture validation", async () => {
    const tooLarge = new Request("https://gateway.test/v1/captures", {
      method: "POST",
      headers: {
        authorization: `Bearer ${captureToken}`,
        "idempotency-key": uuid(2),
        "content-type": "application/json",
        "content-length": String(MAX_CAPTURE_BODY_BYTES + 1),
      },
      body: JSON.stringify({ text: "small, but the declared request is too large" }),
    });
    const oversized = await handleCaptureRequest(tooLarge, apiEnv);
    expect(oversized.status).toBe(413);

    const invalidType = await post(JSON.stringify({ url: "example.com", type: "podcast" }), uuid(3));
    expect(invalidType.status).toBe(422);
    expect(await invalidType.json<{ error: string }>()).toEqual({
      error: "type must be one of: video, tweet, article, design, note",
    });

    const invalidEvidence = await post(
      JSON.stringify({ text: "not a design", image: imageDataUrl }),
      uuid(4),
    );
    expect(invalidEvidence.status).toBe(422);
    expect(await invalidEvidence.json()).toEqual({
      error: "image is only accepted for design captures",
    });

    const invalidSource = await post(
      JSON.stringify({ url: "example.com", source: "client\ninjected" }),
      uuid(5),
    );
    expect(invalidSource.status).toBe(422);
    expect(await captureCount()).toBe(0);
  });

  it("stages a six-MiB transcript while keeping D1 and Queue payloads bounded", async () => {
    const transcript = "x".repeat(MAX_TRANSCRIPT_BYTES);
    const raw = JSON.stringify({
      transcript,
      source: "mac-parakeet",
      title: "Planning: week 29",
      entity: "ExampleCo",
      note: "Completed meeting transcript",
      object: {
        kind: "transcript",
        path: "/attacker-selected",
        sha256: "0".repeat(64),
        content_type: "audio/mpeg",
        byte_length: 1,
      },
    });
    expect(new TextEncoder().encode(raw).byteLength).toBeGreaterThan(6 * 1024 * 1024);
    expect(new TextEncoder().encode(raw).byteLength).toBeLessThan(MAX_CAPTURE_BODY_BYTES);
    const response = await post(
      raw,
      uuid(6),
    );
    expect(response.status).toBe(202);
    const result = await response.json<{ id: string }>();
    const expectedKey = `instances/${instanceId}/captures/${result.id}/transcript.txt`;
    const digest = await sha256Text(transcript);

    const row = await captureByKey(uuid(6));
    expect(row).toMatchObject({
      id: result.id,
      capture_type: "transcript",
      source: "mac-parakeet",
      object_key: expectedKey,
      object_sha256: digest,
      object_content_type: "text/plain; charset=utf-8",
      object_byte_length: MAX_TRANSCRIPT_BYTES,
      object_filename: "transcript.txt",
      object_retention_state: "permanent",
      state: "queued",
      last_error: null,
    });
    expect(new TextEncoder().encode(JSON.stringify(row)).byteLength).toBeLessThan(2 * 1024);
    expect(JSON.stringify(row)).not.toContain(transcript.slice(0, 128));

    const stored = bucket.objects.get(expectedKey);
    expect(stored?.bytes).toEqual(new TextEncoder().encode(transcript));
    expect(stored?.contentType).toBe("text/plain; charset=utf-8");
    expect(queue.messages).toHaveLength(1);
    expect(queue.messages[0]?.body.capture).toEqual({
      id: result.id,
      captured_at: expect.stringMatching(/^20\d\d-/),
      type: "transcript",
      source: "mac-parakeet",
      title: "Planning: week 29",
      entity: "ExampleCo",
      note: "Completed meeting transcript",
    });
    expect(queue.messages[0]?.body.object).toEqual({
      kind: "transcript",
      capture_id: result.id,
      path: `/v1/agent/captures/${result.id}/object`,
      sha256: digest,
      content_type: "text/plain; charset=utf-8",
      byte_length: MAX_TRANSCRIPT_BYTES,
      filename: "transcript.txt",
      retention: "permanent",
    });
    expect(new TextEncoder().encode(JSON.stringify(queue.messages[0]?.body)).byteLength)
      .toBeLessThan(MAX_CAPTURE_QUEUE_BYTES);
    expect(bucket.putCalls).toBe(1);

    const ambiguous = await post(
      JSON.stringify({ transcript: "one", text: "two" }),
      uuid(7),
    );
    expect(ambiguous.status).toBe(422);

    const tooManyUtf8Bytes = await post(
      JSON.stringify({ transcript: `${"é".repeat(MAX_TRANSCRIPT_BYTES / 2)}x` }),
      uuid(8),
    );
    expect(tooManyUtf8Bytes.status).toBe(422);
    expect(await tooManyUtf8Bytes.json()).toEqual({
      error: "transcript must be 6 MiB or smaller",
    });
  }, 60_000);
});

describe("durable capture writes", () => {
  it("writes D1, R2, then one JSON queue envelope before returning exact 202", async () => {
    const key = uuid(10);
    const raw = JSON.stringify({
      type: "design",
      url: "example.com/design",
      text: "Searchable visual context",
      note: "Why this was saved",
      source: " brain-app ",
      image: imageDataUrl,
    });
    const response = await post(raw, key);
    expect(response.status).toBe(202);
    const result = await response.json<{ id: string; state: string }>();
    expect(result).toEqual({ id: expect.stringMatching(UUID_PATTERN), state: "queued" });

    const row = await db.prepare(
      `SELECT instance_id, device_id, idempotency_key, payload_digest, capture_type, source,
              object_key, object_sha256, object_content_type, object_byte_length,
              object_filename, object_retention_state, state, last_error
         FROM captures WHERE id = ?`,
    )
      .bind(result.id)
      .first<CaptureRow>();
    expect(row).toMatchObject({
      instance_id: instanceId,
      idempotency_key: key,
      payload_digest: expect.stringMatching(/^[0-9a-f]{64}$/),
      capture_type: "design",
      source: "brain-app",
      object_key: `instances/${instanceId}/captures/${result.id}/image.png`,
      object_sha256: await sha256Bytes(imageBytes),
      object_content_type: "image/png",
      object_byte_length: imageBytes.byteLength,
      object_filename: "image.png",
      object_retention_state: "permanent",
      state: "queued",
      last_error: null,
    });
    expect(row?.device_id).toBeTruthy();

    expect(bucket.putCalls).toBe(1);
    expect(bucket.objects.get(row?.object_key ?? "")?.bytes).toEqual(imageBytes);
    expect(queue.messages).toHaveLength(1);
    expect(queue.messages[0]?.options).toEqual({ contentType: "json" });
    expect(queue.messages[0]?.body).toEqual({
      kind: "capture",
      instance_id: instanceId,
      device_id: row?.device_id,
      idempotency_key: key,
      capture: {
        id: result.id,
        captured_at: expect.stringMatching(/^2026-|^20\d\d-/),
        type: "design",
        source: "brain-app",
        url: "https://example.com/design",
        text: "Searchable visual context",
        note: "Why this was saved",
      },
      object: {
        path: `/v1/agent/captures/${result.id}/object`,
        sha256: await sha256Bytes(imageBytes),
        content_type: "image/png",
        byte_length: imageBytes.byteLength,
        filename: "image.png",
        retention: "permanent",
      },
    });
    expect(outboundUrls).toEqual([]);
  });

  it("replays byte-identical input without another object or queue message and conflicts on other bytes", async () => {
    const key = uuid(11);
    const raw = JSON.stringify({
      type: "design",
      url: "https://example.com/replay",
      text: "context",
      image: imageDataUrl,
    });
    const first = await post(raw, key);
    const firstBody = await first.json<{ id: string; state: string }>();
    expect(first.status).toBe(202);
    expect(bucket.putCalls).toBe(1);
    expect(queue.messages).toHaveLength(1);

    const replay = await post(raw, key);
    expect(replay.status).toBe(202);
    expect(await replay.json()).toEqual(firstBody);
    expect(await captureCount()).toBe(1);
    expect(bucket.putCalls).toBe(1);
    expect(queue.messages).toHaveLength(1);

    const conflict = await post(`${raw} `, key);
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toEqual({
      error: "idempotency key already has a different payload",
    });
    expect(await captureCount()).toBe(1);
    expect(bucket.putCalls).toBe(1);
    expect(queue.messages).toHaveLength(1);
  });

  it("republishes a byte-identical capture whose queued delivery went stale", async () => {
    const key = uuid(111);
    const raw = JSON.stringify({
      type: "transcript",
      source: "Brain.app meeting",
      title: "Recovered meeting.md",
      transcript: "durable transcript",
    });
    const first = await post(raw, key);
    const receipt = await first.json<{ id: string; state: string }>();
    expect(first.status).toBe(202);
    expect(queue.messages).toHaveLength(1);
    expect(bucket.putCalls).toBe(1);

    await db.prepare(
      "UPDATE captures SET updated_at = ? WHERE instance_id = ? AND idempotency_key = ?",
    ).bind("2000-01-01T00:00:00.000Z", instanceId, key).run();

    const recovered = await post(raw, key);
    expect(recovered.status).toBe(202);
    expect(await recovered.json()).toEqual(receipt);
    expect(queue.messages).toHaveLength(2);
    expect(bucket.putCalls).toBe(1);
    expect(bucket.headCalls).toBe(1);
    expect(await captureByKey(key)).toMatchObject({ state: "queued", last_error: null });
  });

  it("does not acknowledge an R2 failure and safely resumes the same D1 row", async () => {
    const key = uuid(12);
    const raw = JSON.stringify({ type: "design", text: "context", image: imageDataUrl });
    bucket.failPut = true;
    const failed = await post(raw, key);
    expect(failed.status).toBe(503);
    expect(queue.messages).toHaveLength(0);
    const failedRow = await captureByKey(key);
    expect(failedRow).toMatchObject({ state: "failed", last_error: "gateway_r2_write_failed" });

    bucket.failPut = false;
    const resumed = await post(raw, key);
    expect(resumed.status).toBe(202);
    expect((await resumed.json<{ id: string }>()).id).toBe(failedRow?.id);
    expect(await captureCount()).toBe(1);
    expect(bucket.putCalls).toBe(1);
    expect(queue.messages).toHaveLength(1);
    expect(await captureByKey(key)).toMatchObject({ state: "queued", last_error: null });
  });

  it("does not acknowledge a Queue failure and reuses its already-staged R2 object", async () => {
    const key = uuid(13);
    const raw = JSON.stringify({ type: "design", text: "context", image: imageDataUrl });
    queue.failSend = true;
    const failed = await post(raw, key);
    expect(failed.status).toBe(503);
    const failedRow = await captureByKey(key);
    expect(failedRow).toMatchObject({ state: "failed", last_error: "gateway_queue_publish_failed" });
    expect(bucket.putCalls).toBe(1);
    expect(queue.messages).toHaveLength(0);

    queue.failSend = false;
    const resumed = await post(raw, key);
    expect(resumed.status).toBe(202);
    expect((await resumed.json<{ id: string }>()).id).toBe(failedRow?.id);
    expect(bucket.putCalls).toBe(1);
    expect(bucket.headCalls).toBe(1);
    expect(queue.messages).toHaveLength(1);
    expect(await captureCount()).toBe(1);
  });

  it("never calls the GitHub Contents API for a successful capture", async () => {
    const response = await post(
      JSON.stringify({ url: "https://example.com/article", note: "save this", source: "shortcut" }),
      uuid(14),
    );
    expect(response.status).toBe(202);
    expect(outboundUrls.filter((url) => url.includes("api.github.com"))).toEqual([]);
    expect(outboundUrls).toEqual([]);
  });

  it("persists permanent metadata for image, audio, video, PDF, and other originals", async () => {
    const cases = [
      { contentType: "image/png", filename: "shot.png" },
      { contentType: "audio/mpeg", filename: "voice.mp3" },
      { contentType: "video/mp4", filename: "meeting.mp4" },
      { contentType: "application/pdf", filename: "brief.pdf" },
      { contentType: "application/octet-stream", filename: "../archive.data" },
    ];
    for (const [index, value] of cases.entries()) {
      const bytes = Uint8Array.of(index, 1, 2, 3, 4);
      const idempotencyKey = uuid(40 + index);
      const response = await post(JSON.stringify({
        type: "note",
        text: `binary ${index}`,
        object: {
          base64: base64(bytes),
          content_type: value.contentType,
          filename: value.filename,
        },
      }), idempotencyKey);
      expect(response.status).toBe(202);
      const row = await captureByKey(idempotencyKey);
      expect(row).toMatchObject({
        object_sha256: await sha256Bytes(bytes),
        object_content_type: value.contentType,
        object_byte_length: bytes.byteLength,
        object_filename: value.filename.split("/").at(-1),
        object_retention_state: "permanent",
      });
      expect(row?.object_key).toMatch(
        new RegExp(`^instances/${instanceId}/captures/${row?.id}/original\\.`),
      );
      expect(bucket.objects.get(row?.object_key ?? "")?.bytes).toEqual(bytes);
    }
    expect(bucket.deleteKeys).toEqual([]);
  });
});

describe("GET /v1/captures/<id>", () => {
  it("requires capture scope and returns only instance-scoped public delivery state", async () => {
    const created = await post(JSON.stringify({ text: "status boundary" }), uuid(15));
    const { id } = await created.json<{ id: string }>();

    expect((await getStatus(id, null)).status).toBe(401);
    expect((await getStatus(id, readToken)).status).toBe(403);

    const queued = await getStatus(id, captureToken);
    expect(queued.status).toBe(200);
    const queuedBody = await queued.json<Record<string, unknown>>();
    expect(queuedBody).toEqual({
      id,
      type: "note",
      source: "remote",
      state: "queued",
      retryable: false,
      error: null,
      created_at: expect.stringMatching(/Z$/),
      updated_at: expect.stringMatching(/Z$/),
      delivered_at: null,
      object: null,
    });
    expect(Object.keys(queuedBody).sort()).toEqual([
      "created_at",
      "delivered_at",
      "error",
      "id",
      "object",
      "retryable",
      "source",
      "state",
      "type",
      "updated_at",
    ]);

    await db.prepare("UPDATE captures SET state = 'processing' WHERE id = ?").bind(id).run();
    expect(await (await getStatus(id)).json()).toMatchObject({ state: "processing" });

    const delivered = await postResult(id, { state: "delivered" });
    expect(delivered.status).toBe(200);
    const terminal = await getStatus(id);
    expect(await terminal.json()).toMatchObject({
      id,
      state: "delivered",
      retryable: false,
      error: null,
      delivered_at: expect.stringMatching(/Z$/),
    });
  });

  it("bounds agent failures, exposes retry only when marked, and republishes the same capture", async () => {
    const key = uuid(16);
    const raw = JSON.stringify({ text: "retry the original bytes" });
    const created = await post(raw, key);
    const { id } = await created.json<{ id: string }>();
    const detail = "é".repeat(MAX_CAPTURE_STATUS_ERROR_BYTES);

    expect((await postResult(id, {
      state: "failed",
      error: "ingest_failed",
      detail,
      retryable: true,
    })).status).toBe(200);
    const failed = await getStatus(id);
    const failedBody = await failed.json<{
      state: string;
      retryable: boolean;
      error: string;
    }>();
    expect(failedBody.state).toBe("failed");
    expect(failedBody.retryable).toBe(true);
    expect(new TextEncoder().encode(failedBody.error).byteLength)
      .toBeLessThanOrEqual(MAX_CAPTURE_STATUS_ERROR_BYTES);
    expect(JSON.stringify(failedBody)).not.toContain("last_error");

    const retried = await post(raw, key);
    expect(retried.status).toBe(202);
    expect(await retried.json()).toEqual({ id, state: "queued" });
    expect(queue.messages).toHaveLength(2);
    expect(queue.messages[0]?.body).toEqual(queue.messages[1]?.body);
    expect(await captureByKey(key)).toMatchObject({ state: "queued", last_error: null });

    expect((await postResult(id, {
      state: "failed",
      error: "permanent_failure",
      retryable: false,
    })).status).toBe(200);
    expect(await (await getStatus(id)).json()).toMatchObject({
      state: "failed",
      retryable: false,
      error: "permanent_failure",
    });
    const replay = await post(raw, key);
    expect(replay.status).toBe(202);
    expect(queue.messages).toHaveLength(2);
  });

  it("rejects queries and unsafe IDs and cannot read another configured instance", async () => {
    const id = uuid(17);
    await insertOtherCapture(id, `instances/${otherInstanceId}/captures/${id}/image.png`);

    expect((await getStatus(id, captureToken, "?instance=other")).status).toBe(400);
    expect((await getStatus("unsafe$id")).status).toBe(404);
    expect((await getStatus(uuid(18))).status).toBe(404);
    expect((await getStatus(id)).status).toBe(404);

    const wrongMethod = await handleCaptureApi(new Request(
      `https://gateway.test/v1/captures/${uuid(19)}`,
      { method: "POST" },
    ), apiEnv);
    expect(wrongMethod.status).toBe(405);
  });
});

describe("GET /v1/agent/captures/<id>/object", () => {
  it("requires the independent agent secret and streams only the configured instance object", async () => {
    const created = await post(
      JSON.stringify({ type: "design", text: "context", image: imageDataUrl }),
      uuid(20),
    );
    const { id } = await created.json<{ id: string }>();
    const url = `https://gateway.test/v1/agent/captures/${id}/object`;

    expect((await getObject(url, null)).status).toBe(401);
    expect((await getObject(url, captureToken)).status).toBe(401);
    const object = await getObject(url, agentToken);
    expect(object.status).toBe(200);
    expect(object.headers.get("content-type")).toBe("image/png");
    expect(object.headers.get("x-content-sha256")).toBe(await sha256Bytes(imageBytes));
    expect(new Uint8Array(await object.arrayBuffer())).toEqual(imageBytes);

    const otherId = uuid(21);
    const otherKey = `instances/${otherInstanceId}/captures/${otherId}/image.png`;
    await db.prepare(
      `INSERT INTO devices
        (id, instance_id, name, token_digest, scopes, claimed_at, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind("other-device", otherInstanceId, "Other", "other-digest", '["capture"]',
        baseTime.toISOString(), baseTime.toISOString(), baseTime.toISOString())
      .run();
    await db.prepare(
      `INSERT INTO captures
        (id, instance_id, device_id, idempotency_key, payload_digest, capture_type, source,
         object_key, object_sha256, object_content_type, object_byte_length, object_filename,
         object_retention_state, state, captured_at, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'image/png', ?, 'image.png', 'permanent', 'queued', ?, ?, ?)`,
    )
      .bind(otherId, otherInstanceId, "other-device", uuid(22), "d".repeat(64), "design", "test",
        otherKey, await sha256Bytes(imageBytes), imageBytes.byteLength,
        baseTime.toISOString(), baseTime.toISOString(), baseTime.toISOString())
      .run();
    bucket.seed(otherKey, imageBytes, "image/png", await sha256Bytes(imageBytes));

    const crossInstance = await getObject(
      `https://gateway.test/v1/agent/captures/${otherId}/object`,
      agentToken,
    );
    expect(crossInstance.status).toBe(404);
    expect(bucket.getKeys).not.toContain(otherKey);
  });

  it("enforces its fixed route and methods", async () => {
    const wrongMethod = await handleCaptureApi(
      new Request(`https://gateway.test/v1/agent/captures/${uuid(23)}/object`, {
        method: "POST",
      }),
      apiEnv,
    );
    expect(wrongMethod.status).toBe(405);
    const unknown = await handleCaptureApi(
      new Request("https://gateway.test/v1/agent/captures/object"),
      apiEnv,
    );
    expect(unknown.status).toBe(404);
  });
});

describe("paired capture object reads", () => {
  it("publishes safe metadata in status/list responses without exposing an R2 key", async () => {
    const created = await post(
      JSON.stringify({
        type: "design",
        text: "context",
        filename: "../../Owner's screenshot.png",
        image: imageDataUrl,
      }),
      uuid(24),
    );
    const { id } = await created.json<{ id: string }>();
    const status = await getStatus(id);
    const statusBody = await status.json<Record<string, unknown>>();
    expect(statusBody.object).toEqual({
      sha256: await sha256Bytes(imageBytes),
      content_type: "image/png",
      byte_length: imageBytes.byteLength,
      filename: "Owner's screenshot.png",
      retention: "permanent",
      href: `/v1/captures/${id}/object`,
    });
    expect(JSON.stringify(statusBody)).not.toContain("object_key");
    expect(JSON.stringify(statusBody)).not.toContain(`instances/${instanceId}`);

    expect((await getList(captureToken)).status).toBe(403);
    const list = await getList(readToken);
    expect(list.status).toBe(200);
    const listed = await list.json<{ captures: Array<Record<string, unknown>> }>();
    expect(listed.captures).toHaveLength(1);
    expect(listed.captures[0]).toMatchObject({ id, object: statusBody.object });
    expect(JSON.stringify(listed)).not.toContain("object_key");
    expect(JSON.stringify(listed)).not.toContain(`instances/${instanceId}`);
  });

  it("requires read scope, streams full and single-range bytes, and hides other instances", async () => {
    const created = await post(
      JSON.stringify({ type: "design", text: "context", image: imageDataUrl }),
      uuid(25),
    );
    const { id } = await created.json<{ id: string }>();
    expect((await getPairedObject(id, null)).status).toBe(401);
    expect((await getPairedObject(id, captureToken)).status).toBe(403);

    const full = await getPairedObject(id, readToken);
    expect(full.status).toBe(200);
    expect(full.headers.get("content-type")).toBe("image/png");
    expect(full.headers.get("content-length")).toBe(String(imageBytes.byteLength));
    expect(full.headers.get("accept-ranges")).toBe("bytes");
    expect(full.headers.get("etag")).toBe(`"${await sha256Bytes(imageBytes)}"`);
    expect(full.headers.get("content-disposition")).toContain('filename="image.png"');
    expect(new Uint8Array(await full.arrayBuffer())).toEqual(imageBytes);

    const ranged = await getPairedObject(id, readToken, "bytes=2-6");
    expect(ranged.status).toBe(206);
    expect(ranged.headers.get("content-range")).toBe(`bytes 2-6/${imageBytes.byteLength}`);
    expect(ranged.headers.get("content-length")).toBe("5");
    expect(new Uint8Array(await ranged.arrayBuffer())).toEqual(imageBytes.slice(2, 7));

    const suffix = await getPairedObject(id, readToken, "bytes=-3");
    expect(suffix.status).toBe(206);
    expect(new Uint8Array(await suffix.arrayBuffer())).toEqual(imageBytes.slice(-3));

    for (const range of ["bytes=1-2,4-5", "items=1-2", "bytes=-"]) {
      expect((await getPairedObject(id, readToken, range)).status).toBe(400);
    }
    for (const range of [`bytes=${imageBytes.byteLength}-`, "bytes=7-3", "bytes=-0"]) {
      const response = await getPairedObject(id, readToken, range);
      expect(response.status).toBe(416);
      expect(response.headers.get("content-range")).toBe(`bytes */${imageBytes.byteLength}`);
    }

    const otherId = uuid(26);
    await insertOtherCapture(otherId, `instances/${otherInstanceId}/captures/${otherId}/image.png`);
    expect((await getPairedObject(otherId, readToken)).status).toBe(404);
  });
});

describe("POST /v1/agent/captures/<id>/result", () => {
  it("persists delivered state while retaining the immutable R2 original", async () => {
    const created = await post(
      JSON.stringify({ type: "design", text: "context", image: imageDataUrl }),
      uuid(30),
    );
    const { id } = await created.json<{ id: string }>();
    await db.prepare("UPDATE captures SET state = 'processing' WHERE id = ?").bind(id).run();
    const delivered = await postResult(id, { state: "delivered" });
    expect(delivered.status).toBe(200);
    expect(await delivered.json()).toEqual({ id, state: "delivered" });
    const row = await db.prepare(
      "SELECT state, last_error, delivered_at, updated_at FROM captures WHERE id = ?",
    )
      .bind(id)
      .first<{
        state: string;
        last_error: string | null;
        delivered_at: string | null;
        updated_at: string;
      }>();
    expect(row).toMatchObject({ state: "delivered", last_error: null });
    expect(row?.delivered_at).toBe(row?.updated_at);
    expect(bucket.deleteKeys).toEqual([]);
    expect(bucket.objects.size).toBe(1);
    expect(bucket.objects.get(`instances/${instanceId}/captures/${id}/image.png`)?.bytes)
      .toEqual(imageBytes);

    expect((await postResult(id, { state: "delivered" })).status).toBe(200);
    expect(bucket.objects.size).toBe(1);
    expect(bucket.deleteKeys).toEqual([]);
  });

  it("persists only a bounded retryable failure and permits only its identical replay", async () => {
    const created = await post(
      JSON.stringify({ type: "design", text: "context", image: imageDataUrl }),
      uuid(31),
    );
    const { id } = await created.json<{ id: string }>();
    const detail = "é".repeat(2_000);
    const report = { state: "failed", error: "ingest_failed", detail, retryable: true };

    const unsupported = await postResult(id, { ...report, path: "/tmp/private" });
    expect(unsupported.status).toBe(422);
    expect((await db.prepare("SELECT state FROM captures WHERE id = ?").bind(id)
      .first<{ state: string }>())?.state).toBe("queued");

    expect((await postResult(id, report)).status).toBe(200);
    const row = await db.prepare(
      "SELECT state, last_error, delivered_at FROM captures WHERE id = ?",
    )
      .bind(id)
      .first<{ state: string; last_error: string | null; delivered_at: string | null }>();
    expect(row?.state).toBe("failed");
    expect(row?.delivered_at).toBeNull();
    const persisted = JSON.parse(row?.last_error ?? "null") as Record<string, unknown>;
    expect(persisted).toEqual({
      error: "ingest_failed",
      retryable: true,
      detail: expect.any(String),
    });
    expect(new TextEncoder().encode(String(persisted.detail)).byteLength).toBe(2 * 1024);
    expect(bucket.objects.size).toBe(1);
    expect(bucket.deleteKeys).toEqual([]);

    expect((await postResult(id, report)).status).toBe(200);
    expect((await postResult(id, { ...report, retryable: false })).status).toBe(409);
    expect((await postResult(id, { state: "delivered" })).status).toBe(409);
    expect(bucket.objects.size).toBe(1);
    expect(bucket.deleteKeys).toEqual([]);
  });

  it("rejects wrong methods, credentials, queries, unsafe IDs, and missing captures before writes", async () => {
    const id = uuid(32);
    const url = `https://gateway.test/v1/agent/captures/${id}/result`;
    expect((await handleCaptureApi(new Request(url), apiEnv)).status).toBe(405);
    expect((await postResult(id, { state: "delivered" }, null)).status).toBe(401);
    expect((await postResult(id, { state: "delivered" }, captureToken)).status).toBe(401);
    expect((await postResult(id, { state: "delivered" }, agentToken, "?instance=other")).status)
      .toBe(400);
    expect((await postResult("unsafe$id", { state: "delivered" })).status).toBe(404);
    expect((await postResult(id, { state: "delivered" })).status).toBe(404);
    expect(await captureCount()).toBe(0);
    expect(bucket.deleteKeys).toEqual([]);
  });

  it("does not expose or mutate another instance's capture", async () => {
    const id = uuid(33);
    const key = `instances/${otherInstanceId}/captures/${id}/image.png`;
    await insertOtherCapture(id, key);
    bucket.seed(key, imageBytes, "image/png", await sha256Bytes(imageBytes));

    expect((await postResult(id, { state: "delivered" })).status).toBe(404);
    const row = await db.prepare("SELECT state FROM captures WHERE id = ?").bind(id)
      .first<{ state: string }>();
    expect(row?.state).toBe("queued");
    expect(bucket.objects.has(key)).toBe(true);
    expect(bucket.deleteKeys).toEqual([]);
  });

  it("leaves D1 and R2 untouched when the terminal D1 update fails", async () => {
    const created = await post(
      JSON.stringify({ type: "design", text: "context", image: imageDataUrl }),
      uuid(34),
    );
    const { id } = await created.json<{ id: string }>();
    apiEnv = { ...apiEnv, DB: captureResultFailingDb(db) };

    const response = await postResult(id, { state: "delivered" });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "capture state unavailable" });
    const row = await db.prepare("SELECT state, delivered_at FROM captures WHERE id = ?")
      .bind(id)
      .first<{ state: string; delivered_at: string | null }>();
    expect(row).toEqual({ state: "queued", delivered_at: null });
    expect(bucket.objects.size).toBe(1);
    expect(bucket.deleteKeys).toEqual([]);
  });
});

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

interface CaptureRow {
  id?: string;
  instance_id: string;
  device_id: string;
  idempotency_key: string;
  payload_digest: string;
  capture_type: string;
  source: string;
  object_key: string | null;
  object_sha256: string | null;
  object_content_type: string | null;
  object_byte_length: number | null;
  object_filename: string | null;
  object_retention_state: string;
  state: string;
  last_error: string | null;
}

interface StoredObject {
  bytes: Uint8Array;
  contentType: string;
  customMetadata: Record<string, string>;
}

class FakeBucket {
  readonly objects = new Map<string, StoredObject>();
  readonly getKeys: string[] = [];
  readonly deleteKeys: string[] = [];
  putCalls = 0;
  headCalls = 0;
  failPut = false;

  async put(
    key: string,
    value: Uint8Array,
    options: { httpMetadata?: { contentType?: string }; customMetadata?: Record<string, string> } = {},
  ): Promise<R2Object> {
    if (this.failPut) throw new Error("injected R2 failure");
    this.putCalls += 1;
    this.seed(
      key,
      value,
      options.httpMetadata?.contentType ?? "application/octet-stream",
      options.customMetadata?.sha256 ?? "",
      options.customMetadata,
    );
    return this.object(key) as unknown as R2Object;
  }

  async head(key: string): Promise<R2Object | null> {
    this.headCalls += 1;
    return this.objects.has(key) ? this.object(key) as unknown as R2Object : null;
  }

  async get(
    key: string,
    options?: { range?: { offset: number; length: number } },
  ): Promise<R2ObjectBody | null> {
    this.getKeys.push(key);
    return this.objects.has(key)
      ? this.object(key, true, options?.range) as unknown as R2ObjectBody
      : null;
  }

  async delete(keys: string | string[]): Promise<void> {
    for (const key of typeof keys === "string" ? [keys] : keys) {
      this.deleteKeys.push(key);
      this.objects.delete(key);
    }
  }

  seed(
    key: string,
    bytes: Uint8Array,
    contentType: string,
    sha256: string,
    customMetadata: Record<string, string> = {},
  ): void {
    this.objects.set(key, {
      bytes: bytes.slice(),
      contentType,
      customMetadata: { ...customMetadata, sha256 },
    });
  }

  private object(
    key: string,
    withBody = false,
    range?: { offset: number; length: number },
  ): Record<string, unknown> {
    const stored = this.objects.get(key);
    if (!stored) throw new Error("missing fake object");
    const object: Record<string, unknown> = {
      key,
      version: "fake-version",
      size: stored.bytes.byteLength,
      etag: "fake-etag",
      httpEtag: '"fake-etag"',
      uploaded: baseTime,
      checksums: {},
      httpMetadata: { contentType: stored.contentType },
      customMetadata: stored.customMetadata,
      range: undefined,
      storageClass: "Standard",
      writeHttpMetadata(headers: Headers) {
        headers.set("content-type", stored.contentType);
      },
    };
    if (withBody) {
      const bytes = range
        ? stored.bytes.slice(range.offset, range.offset + range.length)
        : stored.bytes;
      object.body = new Response(bytes).body;
    }
    return object;
  }
}

class FakeQueue {
  readonly messages: Array<{
    body: CaptureDeliveryEnvelope;
    options: { contentType?: string } | undefined;
  }> = [];
  failSend = false;

  async send(
    body: CaptureDeliveryEnvelope,
    options?: { contentType?: string },
  ): Promise<void> {
    if (this.failSend) throw new Error("injected Queue failure");
    this.messages.push({ body: structuredClone(body), options: structuredClone(options) });
  }
}

async function post(
  rawBody: string,
  idempotencyKey: string | null,
  token: string | null = captureToken,
): Promise<Response> {
  const headers = new Headers({ "content-type": "application/json" });
  if (idempotencyKey !== null) headers.set("idempotency-key", idempotencyKey);
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return handleCaptureRequest(
    new Request("https://gateway.test/v1/captures", {
      method: "POST",
      headers,
      body: rawBody,
    }),
    apiEnv,
  );
}

async function getObject(url: string, token: string | null): Promise<Response> {
  const headers = new Headers();
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return handleCaptureObjectRequest(new Request(url, { headers }), apiEnv);
}

async function getPairedObject(
  id: string,
  token: string | null,
  range?: string,
): Promise<Response> {
  const headers = new Headers();
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  if (range) headers.set("range", range);
  return handlePairedCaptureObjectRequest(new Request(
    `https://gateway.test/v1/captures/${id}/object`,
    { headers },
  ), apiEnv);
}

async function getList(token: string | null): Promise<Response> {
  const headers = new Headers();
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return handleCaptureListRequest(
    new Request("https://gateway.test/v1/captures", { headers }),
    apiEnv,
  );
}

async function getStatus(
  id: string,
  token: string | null = captureToken,
  query = "",
): Promise<Response> {
  const headers = new Headers();
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return handleCaptureStatusRequest(new Request(
    `https://gateway.test/v1/captures/${id}${query}`,
    { headers },
  ), apiEnv);
}

async function postResult(
  id: string,
  body: unknown,
  token: string | null = agentToken,
  query = "",
): Promise<Response> {
  const headers = new Headers({ "content-type": "application/json" });
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return handleCaptureResultRequest(new Request(
    `https://gateway.test/v1/agent/captures/${id}/result${query}`,
    { method: "POST", headers, body: JSON.stringify(body) },
  ), apiEnv);
}

async function insertInstance(id: string, name: string, agentDigest: string): Promise<void> {
  const timestamp = baseTime.toISOString();
  await db.prepare(
    `INSERT INTO instances (id, name, agent_token_digest, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  )
    .bind(id, name, agentDigest, timestamp, timestamp)
    .run();
}

async function insertOtherCapture(id: string, objectKey: string): Promise<void> {
  await db.prepare(
    `INSERT INTO devices
      (id, instance_id, name, token_digest, scopes, claimed_at, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      "other-result-device",
      otherInstanceId,
      "Other result device",
      "other-result-digest",
      '["capture"]',
      baseTime.toISOString(),
      baseTime.toISOString(),
      baseTime.toISOString(),
    )
    .run();
  await db.prepare(
    `INSERT INTO captures
      (id, instance_id, device_id, idempotency_key, payload_digest, capture_type, source,
       object_key, object_sha256, object_content_type, object_byte_length, object_filename,
       object_retention_state, state, captured_at, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'image/png', ?, 'image.png', 'permanent', 'queued', ?, ?, ?)`,
  )
    .bind(
      id,
      otherInstanceId,
      "other-result-device",
      uuid(35),
      "e".repeat(64),
      "design",
      "test",
      objectKey,
      await sha256Bytes(imageBytes),
      imageBytes.byteLength,
      baseTime.toISOString(),
      baseTime.toISOString(),
      baseTime.toISOString(),
    )
    .run();
}

function captureResultFailingDb(delegate: D1Database): D1Database {
  return {
    prepare(query: string) {
      if (query.includes("SET state = ?, last_error = ?, delivered_at = ?, updated_at = ?")) {
        return {
          bind() {
            return {
              async run() {
                throw new Error("injected D1 result failure");
              },
            };
          },
        } as unknown as D1PreparedStatement;
      }
      return delegate.prepare(query);
    },
  } as unknown as D1Database;
}

async function pair(name: string, scopes: readonly DeviceScope[]) {
  const minted = await mintPairingCode(db, { instanceId, deviceName: name, scopes }, baseTime);
  return claimPairingCode(
    db,
    { instanceId, code: minted.code },
    new Date(baseTime.getTime() + 1_000),
  );
}

async function captureCount(): Promise<number> {
  const row = await db.prepare("SELECT COUNT(*) AS count FROM captures")
    .first<{ count: number }>();
  return row?.count ?? 0;
}

async function captureByKey(key: string): Promise<(CaptureRow & { id: string }) | null> {
  return db.prepare(
    `SELECT id, instance_id, device_id, idempotency_key, payload_digest, capture_type, source,
            object_key, object_sha256, object_content_type, object_byte_length,
            object_filename, object_retention_state, state, last_error
       FROM captures WHERE instance_id = ? AND idempotency_key = ?`,
  )
    .bind(instanceId, key)
    .first<CaptureRow & { id: string }>();
}

function uuid(value: number): string {
  return `${value.toString(16).padStart(8, "0")}-1111-4111-8111-${value.toString(16).padStart(12, "0")}`;
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function sha256Text(value: string): Promise<string> {
  return sha256Bytes(new TextEncoder().encode(value));
}

async function sha256Bytes(value: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", value);
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

function requireBinding<T>(binding: T | undefined, name: string): T {
  if (!binding) throw new Error(`${name} test binding is not configured`);
  return binding;
}
