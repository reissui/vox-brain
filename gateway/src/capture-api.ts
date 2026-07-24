/**
 * Durable, paired-device capture ingress for the remote-first API.
 *
 * A client is acknowledged only after its operational row, optional binary
 * evidence, and JSON queue envelope are durable. Canonical Markdown remains a
 * Brain Agent concern; this module never calls GitHub.
 */

import {
  MAX_TRANSCRIPT_BYTES,
  parseCapture,
  type Capture,
  type CapturedImage,
} from "./capture";
import { enrichDesignCapture } from "./design-enrichment";
import { authorizeDevice, DeviceAuthError } from "./device-auth";
import type { CaptureObjectMetadata, CaptureSummary } from "./remote-contract";

export const MAX_CAPTURE_BODY_BYTES = 8 * 1024 * 1024;
export const MAX_CAPTURE_QUEUE_BYTES = 96 * 1024;
export const MAX_CAPTURE_STATUS_ERROR_BYTES = 2 * 1024;
export const MAX_BINARY_OBJECT_BYTES = 6 * 1024 * 1024;
export const STALE_DELIVERY_REPUBLISH_MS = 2 * 60 * 1_000;

const MAX_RESULT_DETAIL_BYTES = 2 * 1024;
const ERROR_CODE_PATTERN = /^[a-z][a-z0-9_]{0,63}$/;
const CONTENT_TYPE_PATTERN = /^[a-z0-9][a-z0-9!#$&^_.+-]{0,126}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,126}$/;

export interface CaptureApiEnv {
  DB: D1Database;
  CAPTURE_OBJECTS: R2Bucket;
  BRAIN_QUEUE: Queue;
  /** Fixed deployment instance. A client can never select this value. */
  INSTANCE_ID?: string;
  BRAIN_INSTANCE_ID?: string;
  /** Optional secret binding; otherwise the instance's D1 digest is used. */
  AGENT_TOKEN?: string;
  BRAIN_AGENT_TOKEN?: string;
}

export type RemoteCaptureType = Capture["type"] | "transcript";

export interface CaptureDeliveryEnvelope {
  kind: "capture";
  instance_id: string;
  device_id: string;
  idempotency_key: string;
  capture: {
    id: string;
    captured_at: string;
    type: RemoteCaptureType;
    source: string;
    url?: string;
    text?: string;
    note?: string;
    title?: string;
    entity?: string;
  };
  object?:
    | {
      path: string;
      sha256: string;
      content_type: string;
      byte_length: number;
      filename: string;
      retention: "permanent";
    }
    | {
      kind: "transcript";
      capture_id: string;
      path: string;
      sha256: string;
      content_type: "text/plain; charset=utf-8";
      byte_length: number;
      filename: string;
      retention: "permanent";
    };
}

interface BinaryCapture {
  bytes: Uint8Array;
  contentType: string;
  filename: string;
}

interface RemoteCapture extends Omit<Capture, "type"> {
  type: RemoteCaptureType;
  title?: string;
  entity?: string;
  filename?: string;
  binary?: BinaryCapture;
}

interface ExistingCaptureRow {
  id: string;
  device_id: string;
  payload_digest: string;
  capture_type: RemoteCaptureType;
  source: string;
  object_key: string | null;
  object_sha256: string | null;
  object_content_type: string | null;
  object_byte_length: number | null;
  object_filename: string | null;
  object_retention_state: string;
  state: string;
  last_error: string | null;
  captured_at: string;
  updated_at: string;
}

interface StagedObject {
  key: string;
  sha256: string;
  contentType: string;
  filename: string;
  kind: "binary" | "image" | "transcript";
  byteLength: number;
  bytes?: Uint8Array;
}

interface CaptureResultRow {
  state: string;
  last_error: string | null;
  object_key: string | null;
}

interface CaptureStatusRow {
  id: string;
  capture_type: RemoteCaptureType;
  source: string;
  state: string;
  last_error: string | null;
  created_at: string;
  updated_at: string;
  delivered_at: string | null;
  object_key: string | null;
  object_sha256: string | null;
  object_content_type: string | null;
  object_byte_length: number | null;
  object_filename: string | null;
  object_retention_state: string;
}

interface CaptureObjectRow {
  object_key: string | null;
  object_sha256: string | null;
  object_content_type: string | null;
  object_byte_length: number | null;
  object_filename: string | null;
  object_retention_state: string;
}

type CaptureResult =
  | { state: "delivered"; encodedError: null }
  | { state: "failed"; encodedError: string };

const IDEMPOTENCY_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CAPTURE_ID_PATTERN = IDEMPOTENCY_PATTERN;
const INSTANCE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/;
const GATEWAY_STAGING = "gateway_staging";
const GATEWAY_R2_FAILURE = "gateway_r2_write_failed";
const GATEWAY_QUEUE_FAILURE = "gateway_queue_publish_failed";
const retryableGatewayErrors = new Set([GATEWAY_R2_FAILURE, GATEWAY_QUEUE_FAILURE]);

/** Route the capture endpoints owned by this module. */
export async function handleCaptureApi(request: Request, env: CaptureApiEnv): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (pathname === "/v1/captures") {
    return request.method === "GET"
      ? handleCaptureListRequest(request, env)
      : handleCaptureRequest(request, env);
  }
  if (/^\/v1\/captures\/[^/]+\/object$/.test(pathname)) {
    return handlePairedCaptureObjectRequest(request, env);
  }
  if (/^\/v1\/captures\/[^/]+$/.test(pathname)) {
    return handleCaptureStatusRequest(request, env);
  }
  if (/^\/v1\/agent\/captures\/[^/]+\/result$/.test(pathname)) {
    return handleCaptureResultRequest(request, env);
  }
  if (/^\/v1\/agent\/captures\/[^/]+\/object$/.test(pathname)) {
    return handleCaptureObjectRequest(request, env);
  }
  return json(404, { error: "not found" });
}

/** Handle POST /v1/captures. */
export async function handleCaptureRequest(
  request: Request,
  env: CaptureApiEnv,
): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "method not allowed" });

  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "capture service is not configured" });

  let device;
  try {
    device = await authorizeDevice(
      env.DB,
      instanceId,
      request.headers.get("authorization"),
      ["capture"],
    );
  } catch (caught) {
    if (caught instanceof DeviceAuthError) return caught.toResponse();
    return json(503, { error: "capture authorization unavailable" });
  }

  const idempotencyKey = parseIdempotencyKey(request.headers.get("idempotency-key"));
  if (!idempotencyKey) {
    return json(422, { error: "Idempotency-Key must be an RFC 4122 UUID" });
  }

  const decoded = await readJsonBody(request);
  if (!decoded.ok) return json(decoded.status, { error: decoded.error });
  const parsed = parseRemoteCapture(decoded.value);
  if (!parsed.ok) return json(422, { error: parsed.error });
  const payloadDigest = await sha256(decoded.bytes);

  let existing: ExistingCaptureRow | null;
  try {
    existing = await findCapture(env.DB, instanceId, idempotencyKey);
  } catch {
    return json(503, { error: "capture state unavailable" });
  }

  let captureId: string;
  let capturedAt: string;
  let deliveryDeviceId: string;
  let retrying = false;
  if (existing) {
    if (existing.payload_digest !== payloadDigest) {
      return json(409, { error: "idempotency key already has a different payload" });
    }
    const staleDelivery = isStaleDelivery(existing, Date.now());
    if (!isRetryableCaptureFailure(existing.state, existing.last_error) && !staleDelivery) {
      if (existing.state === "delivering" && existing.last_error === GATEWAY_STAGING) {
        return json(503, { error: "capture delivery is still in progress" });
      }
      return accepted(existing.id);
    }

    try {
      const claimedAt = new Date().toISOString();
      let claimed;
      if (isRetryableCaptureFailure(existing.state, existing.last_error)) {
        claimed = await env.DB.prepare(
          `UPDATE captures
              SET state = 'delivering', last_error = ?, updated_at = ?
            WHERE id = ? AND instance_id = ? AND state = 'failed' AND last_error = ?`,
        )
          .bind(GATEWAY_STAGING, claimedAt, existing.id, instanceId, existing.last_error)
          .run();
      } else if (existing.state === "queued") {
        claimed = await env.DB.prepare(
          `UPDATE captures
              SET state = 'delivering', last_error = ?, updated_at = ?
            WHERE id = ? AND instance_id = ? AND state = 'queued'
              AND last_error IS NULL AND updated_at = ?`,
        )
          .bind(GATEWAY_STAGING, claimedAt, existing.id, instanceId, existing.updated_at)
          .run();
      } else {
        claimed = await env.DB.prepare(
          `UPDATE captures
              SET state = 'delivering', last_error = ?, updated_at = ?
            WHERE id = ? AND instance_id = ? AND state = 'delivering'
              AND last_error = ? AND updated_at = ?`,
        )
          .bind(
            GATEWAY_STAGING,
            claimedAt,
            existing.id,
            instanceId,
            GATEWAY_STAGING,
            existing.updated_at,
          )
          .run();
      }
      if (claimed.meta.changes !== 1) {
        return json(503, { error: "capture delivery is still in progress" });
      }
    } catch {
      return json(503, { error: "capture state unavailable" });
    }
    retrying = true;
    captureId = existing.id;
    capturedAt = existing.captured_at;
    deliveryDeviceId = existing.device_id;
  } else {
    captureId = crypto.randomUUID();
    capturedAt = new Date().toISOString();
    deliveryDeviceId = device.deviceId;
  }

  const enriched = await enrichRemoteCapture(parsed.capture);
  const source = enriched.capture.source ?? "remote";
  let stagedObject = await buildStagedObject(instanceId, captureId, enriched.capture);

  if (retrying && existing) {
    stagedObject = stagedObjectForRetry(existing, stagedObject);
  }

  const envelope = buildEnvelope(
    instanceId,
    deliveryDeviceId,
    idempotencyKey,
    captureId,
    capturedAt,
    enriched.capture,
    source,
    stagedObject,
  );
  if (new TextEncoder().encode(JSON.stringify(envelope)).byteLength >= MAX_CAPTURE_QUEUE_BYTES) {
    return json(422, { error: "capture metadata is too large for delivery" });
  }

  if (!retrying) {
    try {
      await env.DB.prepare(
        `INSERT INTO captures
          (id, instance_id, device_id, idempotency_key, payload_digest, capture_type, source,
           object_key, object_sha256, object_content_type, object_byte_length, object_filename,
           object_retention_state, state, last_error, captured_at, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'delivering', ?, ?, ?, ?)`,
      )
        .bind(
          captureId,
          instanceId,
          deliveryDeviceId,
          idempotencyKey,
          payloadDigest,
          enriched.capture.type,
          source,
          stagedObject?.key ?? null,
          stagedObject?.sha256 ?? null,
          stagedObject?.contentType ?? null,
          stagedObject?.byteLength ?? null,
          stagedObject?.filename ?? null,
          stagedObject ? "permanent" : "none",
          GATEWAY_STAGING,
          capturedAt,
          capturedAt,
          capturedAt,
        )
        .run();
    } catch {
      // A concurrent request can win the per-instance unique key. Re-read it
      // rather than creating another capture or touching R2/Queues.
      try {
        const winner = await findCapture(env.DB, instanceId, idempotencyKey);
        if (winner?.payload_digest !== payloadDigest) {
          return winner
            ? json(409, { error: "idempotency key already has a different payload" })
            : json(503, { error: "capture state unavailable" });
        }
        if (winner.state === "delivering" && winner.last_error === GATEWAY_STAGING) {
          return json(503, { error: "capture delivery is still in progress" });
        }
        return accepted(winner.id);
      } catch {
        return json(503, { error: "capture state unavailable" });
      }
    }
  }

  if (stagedObject) {
    try {
      await ensureObject(env.CAPTURE_OBJECTS, instanceId, captureId, stagedObject, retrying);
    } catch {
      await markGatewayFailure(env.DB, instanceId, captureId, GATEWAY_R2_FAILURE);
      return json(503, { error: "capture object storage unavailable" });
    }
  }

  try {
    await env.BRAIN_QUEUE.send(envelope, { contentType: "json" });
  } catch {
    await markGatewayFailure(env.DB, instanceId, captureId, GATEWAY_QUEUE_FAILURE);
    return json(503, { error: "capture queue unavailable" });
  }

  try {
    const completed = await env.DB.prepare(
      `UPDATE captures
          SET state = 'queued', last_error = NULL, updated_at = ?
        WHERE id = ? AND instance_id = ? AND state = 'delivering' AND last_error = ?`,
    )
      .bind(new Date().toISOString(), captureId, instanceId, GATEWAY_STAGING)
      .run();
    if (completed.meta.changes !== 1) {
      return json(503, { error: "capture state unavailable" });
    }
  } catch {
    return json(503, { error: "capture state unavailable" });
  }

  return accepted(captureId);
}

/** Handle GET /v1/captures/<id> for paired capture clients. */
export async function handleCaptureStatusRequest(
  request: Request,
  env: CaptureApiEnv,
  captureIdInput?: string,
): Promise<Response> {
  if (request.method !== "GET") return json(405, { error: "method not allowed" });
  const requestUrl = new URL(request.url);
  if (requestUrl.search !== "") return json(400, { error: "invalid query" });
  const pathMatch = /^\/v1\/captures\/([^/]+)$/.exec(requestUrl.pathname);
  const captureId = (captureIdInput ?? pathMatch?.[1] ?? "").toLowerCase();
  if (!CAPTURE_ID_PATTERN.test(captureId)) return json(404, { error: "not found" });

  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "capture service is not configured" });
  try {
    await authorizeDevice(
      env.DB,
      instanceId,
      request.headers.get("authorization"),
      ["capture"],
    );
  } catch (caught) {
    if (caught instanceof DeviceAuthError) return caught.toResponse();
    return json(503, { error: "capture authorization unavailable" });
  }

  let row: CaptureStatusRow | null;
  try {
    row = await env.DB.prepare(
      `SELECT id, capture_type, source, state, last_error, created_at, updated_at, delivered_at,
              object_key, object_sha256, object_content_type, object_byte_length,
              object_filename, object_retention_state
         FROM captures
        WHERE id = ? AND instance_id = ?`,
    )
      .bind(captureId, instanceId)
      .first<CaptureStatusRow>();
  } catch {
    return json(503, { error: "capture state unavailable" });
  }
  if (!row) return json(404, { error: "not found" });

  const state = publicCaptureState(row.state);
  if (!state) return json(503, { error: "capture state unavailable" });
  const failure = state === "failed"
    ? publicCaptureFailure(row.last_error)
    : { retryable: false, error: null };
  return json(200, publicCaptureSummary(row, state, failure));
}

/** Handle GET /v1/captures for paired read clients. */
export async function handleCaptureListRequest(
  request: Request,
  env: CaptureApiEnv,
): Promise<Response> {
  if (request.method !== "GET") return json(405, { error: "method not allowed" });
  if (new URL(request.url).search !== "") return json(400, { error: "invalid query" });
  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "capture service is not configured" });
  try {
    await authorizeDevice(env.DB, instanceId, request.headers.get("authorization"), ["read"]);
  } catch (caught) {
    if (caught instanceof DeviceAuthError) return caught.toResponse();
    return json(503, { error: "capture authorization unavailable" });
  }

  let rows: CaptureStatusRow[];
  try {
    const result = await env.DB.prepare(
      `SELECT id, capture_type, source, state, last_error, created_at, updated_at, delivered_at,
              object_key, object_sha256, object_content_type, object_byte_length,
              object_filename, object_retention_state
         FROM captures
        WHERE instance_id = ?
        ORDER BY created_at DESC, id DESC
        LIMIT 100`,
    ).bind(instanceId).all<CaptureStatusRow>();
    rows = result.results;
  } catch {
    return json(503, { error: "capture state unavailable" });
  }

  const captures: CaptureSummary[] = [];
  for (const row of rows) {
    const state = publicCaptureState(row.state);
    if (!state) return json(503, { error: "capture state unavailable" });
    const failure = state === "failed"
      ? publicCaptureFailure(row.last_error)
      : { retryable: false, error: null };
    captures.push(publicCaptureSummary(row, state, failure));
  }
  return json(200, { captures });
}

/** Handle GET /v1/captures/<id>/object for paired read clients. */
export async function handlePairedCaptureObjectRequest(
  request: Request,
  env: CaptureApiEnv,
  captureIdInput?: string,
): Promise<Response> {
  if (request.method !== "GET") return json(405, { error: "method not allowed" });
  const requestUrl = new URL(request.url);
  if (requestUrl.search !== "") return json(400, { error: "invalid query" });
  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "capture service is not configured" });
  try {
    await authorizeDevice(env.DB, instanceId, request.headers.get("authorization"), ["read"]);
  } catch (caught) {
    if (caught instanceof DeviceAuthError) return caught.toResponse();
    return json(503, { error: "capture authorization unavailable" });
  }
  const pathMatch = /^\/v1\/captures\/([^/]+)\/object$/.exec(requestUrl.pathname);
  const captureId = (captureIdInput ?? pathMatch?.[1] ?? "").toLowerCase();
  if (!CAPTURE_ID_PATTERN.test(captureId)) return json(404, { error: "not found" });
  return streamCaptureObject(request, env, instanceId, captureId);
}

/** Handle GET /v1/agent/captures/<id>/object. */
export async function handleCaptureObjectRequest(
  request: Request,
  env: CaptureApiEnv,
  captureIdInput?: string,
): Promise<Response> {
  if (request.method !== "GET") return json(405, { error: "method not allowed" });
  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "capture service is not configured" });
  if (!(await authorizeAgent(env, instanceId, request.headers.get("authorization")))) {
    return json(401, { error: "unauthorized" });
  }

  const pathMatch = /^\/v1\/agent\/captures\/([^/]+)\/object$/.exec(new URL(request.url).pathname);
  const captureId = captureIdInput ?? pathMatch?.[1] ?? "";
  if (!CAPTURE_ID_PATTERN.test(captureId)) return json(404, { error: "not found" });

  return streamCaptureObject(request, env, instanceId, captureId.toLowerCase());
}

/** Handle POST /v1/agent/captures/<id>/result. */
export async function handleCaptureResultRequest(
  request: Request,
  env: CaptureApiEnv,
  captureIdInput?: string,
): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "method not allowed" });
  const requestUrl = new URL(request.url);
  if (requestUrl.search !== "") return json(400, { error: "invalid query" });

  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "capture service is not configured" });
  if (!(await authorizeAgent(env, instanceId, request.headers.get("authorization")))) {
    return json(401, { error: "unauthorized" });
  }

  const pathMatch = /^\/v1\/agent\/captures\/([^/]+)\/result$/.exec(requestUrl.pathname);
  const captureId = (captureIdInput ?? pathMatch?.[1] ?? "").toLowerCase();
  if (!CAPTURE_ID_PATTERN.test(captureId)) return json(404, { error: "not found" });

  const decoded = await readJsonBody(request);
  if (!decoded.ok) return json(decoded.status, { error: decoded.error });
  const report = parseCaptureResult(decoded.value);
  if (!report.ok) return json(422, { error: report.error });

  let row: CaptureResultRow | null;
  try {
    row = await env.DB.prepare(
      `SELECT state, last_error, object_key
         FROM captures
        WHERE id = ? AND instance_id = ?`,
    )
      .bind(captureId, instanceId)
      .first<CaptureResultRow>();
  } catch {
    return json(503, { error: "capture state unavailable" });
  }
  if (!row) return json(404, { error: "not found" });

  const terminalReplay = row.state === report.value.state &&
    (row.state === "delivered" || row.last_error === report.value.encodedError);
  if (!terminalReplay) {
    if (row.state !== "queued" && row.state !== "processing") {
      return json(409, { error: "capture result conflicts with terminal state" });
    }

    const now = new Date().toISOString();
    try {
      const updated = await env.DB.prepare(
        `UPDATE captures
            SET state = ?, last_error = ?, delivered_at = ?, updated_at = ?
          WHERE id = ? AND instance_id = ? AND state = ?`,
      )
        .bind(
          report.value.state,
          report.value.encodedError,
          report.value.state === "delivered" ? now : null,
          now,
          captureId,
          instanceId,
          row.state,
        )
        .run();
      if (updated.meta.changes !== 1) {
        return json(409, { error: "capture state changed concurrently" });
      }
    } catch {
      return json(503, { error: "capture state unavailable" });
    }
  }

  return json(200, { id: captureId, state: report.value.state });
}

// Friendly aliases for the entrypoint that wires all independent /v1 modules.
export const handleCapture = handleCaptureRequest;
export const handleCaptureStatus = handleCaptureStatusRequest;
export const handleCaptureList = handleCaptureListRequest;
export const handleCaptureObject = handleCaptureObjectRequest;
export const handlePairedCaptureObject = handlePairedCaptureObjectRequest;
export const handleCaptureResult = handleCaptureResultRequest;

function configuredInstanceId(env: CaptureApiEnv): string | null {
  const value = env.INSTANCE_ID ?? env.BRAIN_INSTANCE_ID;
  return typeof value === "string" && INSTANCE_PATTERN.test(value) ? value : null;
}

function parseIdempotencyKey(value: string | null): string | null {
  return value && IDEMPOTENCY_PATTERN.test(value) ? value.toLowerCase() : null;
}

function isRetryableCaptureFailure(state: string, lastError: string | null): boolean {
  if (state !== "failed" || !lastError) return false;
  if (retryableGatewayErrors.has(lastError)) return true;
  const parsed = parsePersistedCaptureFailure(lastError);
  return parsed?.retryable === true;
}

function isStaleDelivery(existing: ExistingCaptureRow, now: number): boolean {
  const recoverableState = existing.state === "queued"
    ? existing.last_error === null
    : existing.state === "delivering" && existing.last_error === GATEWAY_STAGING;
  if (!recoverableState) return false;
  const updatedAt = Date.parse(existing.updated_at);
  return Number.isFinite(updatedAt) && now - updatedAt >= STALE_DELIVERY_REPUBLISH_MS;
}

function publicCaptureState(
  state: string,
): "queued" | "processing" | "delivered" | "failed" | null {
  switch (state) {
    case "queued":
    case "delivering":
      return "queued";
    case "processing":
      return "processing";
    case "delivered":
    case "completed":
      return "delivered";
    case "failed":
    case "needs_attention":
      return "failed";
    default:
      return null;
  }
}

function publicCaptureSummary(
  row: CaptureStatusRow,
  state: NonNullable<ReturnType<typeof publicCaptureState>>,
  failure: { retryable: boolean; error: string | null },
): CaptureSummary {
  return {
    id: row.id,
    type: row.capture_type,
    source: row.source,
    state,
    retryable: failure.retryable,
    error: failure.error,
    created_at: row.created_at,
    updated_at: row.updated_at,
    delivered_at: row.delivered_at,
    object: publicObjectMetadata(row),
  };
}

function publicObjectMetadata(row: CaptureObjectRow & { id?: string }): CaptureObjectMetadata | null {
  const contentType = safeResponseContentType(row.object_content_type);
  if (
    !row.object_key ||
    !row.object_sha256 ||
    !/^[0-9a-f]{64}$/.test(row.object_sha256) ||
    !contentType ||
    !Number.isSafeInteger(row.object_byte_length) ||
    (row.object_byte_length ?? -1) < 0 ||
    !row.object_filename ||
    row.object_retention_state !== "permanent" ||
    !row.id
  ) return null;
  return {
    sha256: row.object_sha256,
    content_type: contentType,
    byte_length: row.object_byte_length as number,
    filename: row.object_filename,
    retention: "permanent",
    href: `/v1/captures/${row.id}/object`,
  };
}

async function streamCaptureObject(
  request: Request,
  env: CaptureApiEnv,
  instanceId: string,
  captureId: string,
): Promise<Response> {
  let row: CaptureObjectRow | null;
  try {
    row = await env.DB.prepare(
      `SELECT object_key, object_sha256, object_content_type, object_byte_length,
              object_filename, object_retention_state
         FROM captures
        WHERE id = ? AND instance_id = ?`,
    ).bind(captureId, instanceId).first<CaptureObjectRow>();
  } catch {
    return json(503, { error: "capture state unavailable" });
  }
  const prefix = `instances/${instanceId}/captures/${captureId}/`;
  const contentType = safeResponseContentType(row?.object_content_type ?? null);
  if (
    !row?.object_key ||
    !row.object_key.startsWith(prefix) ||
    !row.object_sha256 ||
    !/^[0-9a-f]{64}$/.test(row.object_sha256) ||
    !contentType ||
    !Number.isSafeInteger(row.object_byte_length) ||
    (row.object_byte_length ?? -1) < 0 ||
    !row.object_filename ||
    row.object_retention_state !== "permanent"
  ) return json(404, { error: "not found" });

  const totalLength = row.object_byte_length as number;
  const parsedRange = parseByteRange(request.headers.get("range"), totalLength);
  if (parsedRange.kind === "malformed") return json(400, { error: "invalid range" });
  if (parsedRange.kind === "unsatisfiable") {
    return json(416, { error: "range not satisfiable" }, {
      "accept-ranges": "bytes",
      "content-range": `bytes */${totalLength}`,
    });
  }

  const range = parsedRange.kind === "range"
    ? { offset: parsedRange.start, length: parsedRange.end - parsedRange.start + 1 }
    : null;
  let object: R2ObjectBody | null;
  try {
    object = await env.CAPTURE_OBJECTS.get(
      row.object_key,
      range ? { range } : undefined,
    );
  } catch {
    return json(503, { error: "capture object unavailable" });
  }
  if (!object) return json(404, { error: "not found" });
  if (object.customMetadata?.sha256 && object.customMetadata.sha256 !== row.object_sha256) {
    return json(503, { error: "capture object unavailable" });
  }

  const responseLength = range?.length ?? totalLength;
  const headers = new Headers({
    "accept-ranges": "bytes",
    "content-disposition": contentDisposition(row.object_filename),
    "content-length": String(responseLength),
    "content-type": contentType,
    etag: `"${row.object_sha256}"`,
    "x-content-sha256": row.object_sha256,
  });
  if (range) {
    headers.set("content-range", `bytes ${range.offset}-${range.offset + range.length - 1}/${totalLength}`);
  }
  return new Response(object.body, { status: range ? 206 : 200, headers });
}

type ParsedByteRange =
  | { kind: "none" }
  | { kind: "range"; start: number; end: number }
  | { kind: "malformed" }
  | { kind: "unsatisfiable" };

function parseByteRange(value: string | null, size: number): ParsedByteRange {
  if (value === null) return { kind: "none" };
  if (value.includes(",")) return { kind: "malformed" };
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!match || (!match[1] && !match[2])) return { kind: "malformed" };
  if (size === 0) return { kind: "unsatisfiable" };
  const rawStart = match[1] ?? "";
  const rawEnd = match[2] ?? "";
  if (!rawStart) {
    const suffix = Number(rawEnd);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return { kind: "unsatisfiable" };
    return { kind: "range", start: Math.max(0, size - suffix), end: size - 1 };
  }
  const start = Number(rawStart);
  if (!Number.isSafeInteger(start) || start >= size) return { kind: "unsatisfiable" };
  const requestedEnd = rawEnd ? Number(rawEnd) : size - 1;
  if (!Number.isSafeInteger(requestedEnd) || requestedEnd < start) {
    return { kind: "unsatisfiable" };
  }
  return { kind: "range", start, end: Math.min(requestedEnd, size - 1) };
}

function safeResponseContentType(value: string | null): string | null {
  if (!value) return null;
  const normalized = value.toLowerCase();
  if (CONTENT_TYPE_PATTERN.test(normalized)) return normalized;
  if (normalized === "text/plain; charset=utf-8") return normalized;
  return null;
}

function contentDisposition(filename: string): string {
  const fallback = filename.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 180) || "capture.bin";
  return `attachment; filename="${fallback}"; filename*=UTF-8''${encodeURIComponent(filename)}`;
}

function publicCaptureFailure(lastError: string | null): {
  retryable: boolean;
  error: string;
} {
  if (lastError && retryableGatewayErrors.has(lastError)) {
    return {
      retryable: true,
      error: "Capture delivery is temporarily unavailable.",
    };
  }
  const parsed = lastError ? parsePersistedCaptureFailure(lastError) : null;
  if (parsed) {
    return {
      retryable: parsed.retryable,
      error: boundUtf8(
        parsed.detail ?? parsed.error,
        MAX_CAPTURE_STATUS_ERROR_BYTES,
      ),
    };
  }
  return { retryable: false, error: "Capture delivery needs attention." };
}

function parsePersistedCaptureFailure(value: string): {
  error: string;
  detail?: string;
  retryable: boolean;
} | null {
  try {
    const parsed: unknown = JSON.parse(value);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
    const record = parsed as Record<string, unknown>;
    if (typeof record.error !== "string" || !ERROR_CODE_PATTERN.test(record.error)) return null;
    if (typeof record.retryable !== "boolean") return null;
    if (record.detail !== undefined && typeof record.detail !== "string") return null;
    return {
      error: record.error,
      retryable: record.retryable,
      ...(typeof record.detail === "string" ? { detail: record.detail } : {}),
    };
  } catch {
    return null;
  }
}

async function readJsonBody(request: Request): Promise<
  | { ok: true; value: unknown; bytes: Uint8Array }
  | { ok: false; status: 413 | 422; error: string }
> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_CAPTURE_BODY_BYTES) {
    return { ok: false, status: 413, error: "capture body must be 8 MiB or smaller" };
  }
  if (!request.body) return { ok: false, status: 422, error: "body must be valid JSON" };

  const chunks: Uint8Array[] = [];
  const reader = request.body.getReader();
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_CAPTURE_BODY_BYTES) {
      await reader.cancel();
      return { ok: false, status: 413, error: "capture body must be 8 MiB or smaller" };
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
    return { ok: true, value: JSON.parse(text) as unknown, bytes };
  } catch {
    return { ok: false, status: 422, error: "body must be valid JSON" };
  }
}

function parseRemoteCapture(
  body: unknown,
): { ok: true; capture: RemoteCapture } | { ok: false; error: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "body must be a JSON object" };
  }
  const record = body as Record<string, unknown>;
  const explicitType = record.type;
  const transcript = record.transcript;
  if (transcript !== undefined && transcript !== null && typeof transcript !== "string") {
    return { ok: false, error: "transcript must be a string" };
  }
  if (transcript !== undefined && transcript !== null && record.text !== undefined) {
    return { ok: false, error: "use either transcript or text, not both" };
  }

  const isTranscript = explicitType === "transcript" || transcript !== undefined && transcript !== null;
  if (isTranscript && explicitType !== undefined && explicitType !== "transcript") {
    return { ok: false, error: "transcript requires type transcript" };
  }

  const legacyBody: Record<string, unknown> = { ...record };
  delete legacyBody.transcript;
  delete legacyBody.title;
  delete legacyBody.entity;
  delete legacyBody.filename;
  delete legacyBody.object;
  if (isTranscript) {
    legacyBody.type = "note";
    if (typeof transcript === "string") legacyBody.text = transcript;
  }
  const parsed = parseCapture(legacyBody);
  if (!parsed.ok) return parsed;
  if (isTranscript && !parsed.capture.text) {
    return { ok: false, error: "transcript must not be empty" };
  }
  if (
    isTranscript &&
    new TextEncoder().encode(parsed.capture.text ?? "").byteLength > MAX_TRANSCRIPT_BYTES
  ) {
    return { ok: false, error: "transcript must be 6 MiB or smaller" };
  }

  const title = optionalString(record.title, "title");
  if (typeof title === "object") return title;
  const entity = optionalString(record.entity, "entity");
  if (typeof entity === "object") return entity;
  const filenameValue = optionalString(record.filename, "filename");
  if (typeof filenameValue === "object") return filenameValue;
  const filename = filenameValue ? sanitizeFilename(filenameValue, "capture.bin") : undefined;
  const binaryResult = isTranscript ? { ok: true as const, binary: undefined } : parseBinaryObject(record.object);
  if (!binaryResult.ok) return { ok: false, error: binaryResult.error };
  if (binaryResult.binary && parsed.capture.image) {
    return { ok: false, error: "use either image or object, not both" };
  }
  return {
    ok: true,
    capture: {
      ...parsed.capture,
      type: isTranscript ? "transcript" : parsed.capture.type,
      title,
      entity,
      filename,
      binary: binaryResult.binary,
    },
  };
}

function parseBinaryObject(
  value: unknown,
): { ok: true; binary: BinaryCapture | undefined } | { ok: false; error: string } {
  if (value === undefined || value === null) return { ok: true, binary: undefined };
  if (typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, error: "object must be a JSON object" };
  }
  const record = value as Record<string, unknown>;
  const allowed = new Set(["base64", "content_type", "filename"]);
  if (Object.keys(record).some((key) => !allowed.has(key))) {
    return { ok: false, error: "object contains an unsupported field" };
  }
  if (typeof record.base64 !== "string" || !record.base64) {
    return { ok: false, error: "object base64 is required" };
  }
  if (typeof record.content_type !== "string") {
    return { ok: false, error: "object content_type is required" };
  }
  const contentType = record.content_type.trim().toLowerCase();
  if (!CONTENT_TYPE_PATTERN.test(contentType)) {
    return { ok: false, error: "object content_type is invalid" };
  }
  if (typeof record.filename !== "string" || !record.filename.trim()) {
    return { ok: false, error: "object filename is required" };
  }
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(record.base64) || record.base64.length % 4 !== 0) {
    return { ok: false, error: "object contains invalid base64 data" };
  }
  let bytes: Uint8Array;
  try {
    bytes = decodeBase64(record.base64);
  } catch {
    return { ok: false, error: "object contains invalid base64 data" };
  }
  if (bytes.byteLength > MAX_BINARY_OBJECT_BYTES) {
    return { ok: false, error: "object must be 6 MiB or smaller" };
  }
  return {
    ok: true,
    binary: {
      bytes,
      contentType,
      filename: sanitizeFilename(record.filename, "capture.bin"),
    },
  };
}

function sanitizeFilename(value: string, fallback: string): string {
  const basename = value.normalize("NFC").replace(/\\/g, "/").split("/").at(-1) ?? "";
  const safe = basename
    .replace(/[\u0000-\u001f\u007f]/g, "_")
    .replace(/^\.+$/, "")
    .trim()
    .slice(0, 180);
  return safe || fallback;
}

function optionalString(
  value: unknown,
  field: string,
): string | undefined | { ok: false; error: string } {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string") return { ok: false, error: `${field} must be a string` };
  return value;
}

function parseCaptureResult(
  value: unknown,
): { ok: true; value: CaptureResult } | { ok: false; error: string } {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return { ok: false, error: "body must be a JSON object" };
  }
  const record = value as Record<string, unknown>;
  if (record.state === "delivered") {
    if (Object.keys(record).some((key) => key !== "state")) {
      return { ok: false, error: "delivered result must contain only state" };
    }
    return { ok: true, value: { state: "delivered", encodedError: null } };
  }
  if (record.state !== "failed") {
    return { ok: false, error: "capture result state must be delivered or failed" };
  }
  const allowed = new Set(["state", "error", "detail", "retryable"]);
  if (Object.keys(record).some((key) => !allowed.has(key))) {
    return { ok: false, error: "failed result contains an unsupported field" };
  }
  if (typeof record.error !== "string" || !ERROR_CODE_PATTERN.test(record.error)) {
    return { ok: false, error: "invalid error code" };
  }
  if (typeof record.retryable !== "boolean") {
    return { ok: false, error: "failed result requires retryable" };
  }
  if (record.detail !== undefined && typeof record.detail !== "string") {
    return { ok: false, error: "detail must be a string" };
  }
  const persisted: Record<string, unknown> = {
    error: record.error,
    retryable: record.retryable,
  };
  if (typeof record.detail === "string") {
    persisted.detail = boundUtf8(record.detail, MAX_RESULT_DETAIL_BYTES);
  }
  return {
    ok: true,
    value: { state: "failed", encodedError: JSON.stringify(persisted) },
  };
}

function boundUtf8(value: string, limit: number): string {
  const encoded = new TextEncoder().encode(value);
  if (encoded.byteLength <= limit) return value;
  let end = limit;
  while (end > 0) {
    try {
      return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(
        encoded.subarray(0, end),
      );
    } catch {
      end -= 1;
    }
  }
  return "";
}

async function enrichRemoteCapture(capture: RemoteCapture): Promise<{
  capture: RemoteCapture;
}> {
  if (capture.type === "transcript") return { capture };
  const enriched = await enrichDesignCapture(capture as Capture);
  return { capture: { ...capture, ...enriched.capture } };
}

async function findCapture(
  db: D1Database,
  instanceId: string,
  idempotencyKey: string,
): Promise<ExistingCaptureRow | null> {
  return db.prepare(
    `SELECT id, device_id, payload_digest, capture_type, source, object_key, object_sha256,
            object_content_type, object_byte_length, object_filename, object_retention_state,
            state, last_error, captured_at, updated_at
       FROM captures
      WHERE instance_id = ? AND idempotency_key = ?`,
  )
    .bind(instanceId, idempotencyKey)
    .first<ExistingCaptureRow>();
}

async function buildStagedObject(
  instanceId: string,
  captureId: string,
  capture: RemoteCapture,
): Promise<StagedObject | undefined> {
  if (capture.type === "transcript") {
    const bytes = new TextEncoder().encode(capture.text ?? "");
    return {
      key: `instances/${instanceId}/captures/${captureId}/transcript.txt`,
      sha256: await sha256(bytes),
      contentType: "text/plain; charset=utf-8",
      filename: sanitizeFilename(capture.filename ?? "transcript.txt", "transcript.txt"),
      kind: "transcript",
      byteLength: bytes.byteLength,
      bytes,
    };
  }
  if (capture.binary) {
    const extension = safeFilenameExtension(capture.binary.filename);
    return {
      key: `instances/${instanceId}/captures/${captureId}/original${extension}`,
      sha256: await sha256(capture.binary.bytes),
      contentType: capture.binary.contentType,
      filename: capture.binary.filename,
      kind: "binary",
      byteLength: capture.binary.bytes.byteLength,
      bytes: capture.binary.bytes,
    };
  }
  const image = capture.image;
  if (!image) return undefined;
  const bytes = decodeBase64(image.base64);
  const extension = image.mimeType === "image/jpeg" ? "jpg" : image.mimeType.split("/")[1];
  return {
    key: `instances/${instanceId}/captures/${captureId}/image.${extension}`,
    sha256: await sha256(bytes),
    contentType: image.mimeType,
    filename: sanitizeFilename(capture.filename ?? `image.${extension}`, `image.${extension}`),
    kind: "image",
    byteLength: bytes.byteLength,
    bytes,
  };
}

function stagedObjectForRetry(
  existing: ExistingCaptureRow,
  candidate: StagedObject | undefined,
): StagedObject | undefined {
  if (!existing.object_key || !existing.object_sha256 || !candidate) return undefined;
  return {
    key: existing.object_key,
    sha256: existing.object_sha256,
    contentType: existing.object_content_type ?? candidate.contentType,
    filename: existing.object_filename ?? candidate.filename,
    kind: candidate.kind,
    byteLength: existing.object_byte_length ?? candidate.byteLength,
    bytes: candidate.bytes,
  };
}

async function ensureObject(
  bucket: R2Bucket,
  instanceId: string,
  captureId: string,
  object: StagedObject,
  retrying: boolean,
): Promise<void> {
  if (retrying) {
    const current = await bucket.head(object.key);
    if (current) {
      if (current.customMetadata?.sha256 && current.customMetadata.sha256 !== object.sha256) {
        throw new Error("stored capture object digest mismatch");
      }
      if (current.size !== object.byteLength) {
        throw new Error("stored capture object length mismatch");
      }
      return;
    }
  }
  if (!object.bytes) throw new Error("capture object bytes unavailable");
  const digest = await sha256(object.bytes);
  if (object.sha256 && object.sha256 !== digest) throw new Error("capture object digest mismatch");
  object.sha256 = digest;
  await bucket.put(object.key, object.bytes, {
    httpMetadata: { contentType: object.contentType },
    customMetadata: {
      sha256: object.sha256,
      instanceId,
      captureId,
      filename: object.filename,
      retention: "permanent",
    },
  });
}

function buildEnvelope(
  instanceId: string,
  deviceId: string,
  idempotencyKey: string,
  captureId: string,
  capturedAt: string,
  capture: RemoteCapture,
  source: string,
  object: StagedObject | undefined,
): CaptureDeliveryEnvelope {
  const normalized: CaptureDeliveryEnvelope["capture"] = {
    id: captureId,
    captured_at: capturedAt,
    type: capture.type,
    source,
  };
  if (capture.url) normalized.url = capture.url;
  if (capture.type !== "transcript" && capture.text) normalized.text = capture.text;
  if (capture.note) normalized.note = capture.note;
  if (capture.title) normalized.title = capture.title;
  if (capture.entity) normalized.entity = capture.entity;

  const envelope: CaptureDeliveryEnvelope = {
    kind: "capture",
    instance_id: instanceId,
    device_id: deviceId,
    idempotency_key: idempotencyKey,
    capture: normalized,
  };
  if (object) {
    envelope.object = object.kind === "transcript"
      ? {
        kind: "transcript",
        capture_id: captureId,
        path: `/v1/agent/captures/${captureId}/object`,
        sha256: object.sha256,
        content_type: "text/plain; charset=utf-8",
        byte_length: object.byteLength,
        filename: object.filename,
        retention: "permanent",
      }
      : {
        path: `/v1/agent/captures/${captureId}/object`,
        sha256: object.sha256,
        content_type: object.contentType,
        byte_length: object.byteLength,
        filename: object.filename,
        retention: "permanent",
      };
  }
  return envelope;
}

function safeFilenameExtension(filename: string): string {
  const match = /\.([A-Za-z0-9]{1,10})$/.exec(filename);
  return match?.[1] ? `.${match[1].toLowerCase()}` : ".bin";
}

async function markGatewayFailure(
  db: D1Database,
  instanceId: string,
  captureId: string,
  reason: string,
): Promise<void> {
  try {
    await db.prepare(
      `UPDATE captures
          SET state = 'failed', last_error = ?, updated_at = ?
        WHERE id = ? AND instance_id = ? AND state = 'delivering' AND last_error = ?`,
    )
      .bind(reason, new Date().toISOString(), captureId, instanceId, GATEWAY_STAGING)
      .run();
  } catch {
    // Preserve the original storage/queue failure response.
  }
}

async function authorizeAgent(
  env: CaptureApiEnv,
  instanceId: string,
  authorization: string | null,
): Promise<boolean> {
  const match = /^Bearer ([^\s]{1,1024})$/i.exec(authorization ?? "");
  const token = match?.[1];
  if (!token) return false;
  const presentedDigest = await sha256(new TextEncoder().encode(token));
  const configuredToken = env.AGENT_TOKEN ?? env.BRAIN_AGENT_TOKEN;
  if (configuredToken !== undefined) {
    return presentedDigest === await sha256(new TextEncoder().encode(configuredToken));
  }
  try {
    const row = await env.DB.prepare(
      "SELECT agent_token_digest FROM instances WHERE id = ?",
    )
      .bind(instanceId)
      .first<{ agent_token_digest: string | null }>();
    return Boolean(row?.agent_token_digest && row.agent_token_digest === presentedDigest);
  } catch {
    return false;
  }
}

function decodeBase64(value: string): Uint8Array {
  const decoded = atob(value);
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

function accepted(id: string): Response {
  return json(202, { id, state: "queued" });
}

function json(status: number, data: unknown, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...extraHeaders },
  });
}
