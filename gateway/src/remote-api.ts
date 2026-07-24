/**
 * Paired-device reads and durable, allowlisted Brain jobs.
 *
 * The origin URL and both credentials are deployment bindings. Client input can
 * select only the fixed routes and query fields below; it is never copied into
 * an origin, executable, argv array, or arbitrary local path.
 */

import { authorizeDevice, DeviceAuthError } from "./device-auth";
import { handlePairedCaptureObjectRequest } from "./capture-api";
import {
  validateHealthOperations,
  validateStatusSiteUrl,
  type CaptureObjectMetadata,
  type CaptureSummary,
  type JobState,
} from "./remote-contract";

export type { CaptureObjectMetadata, CaptureSummary };

export const MAX_JOB_OUTPUT_BYTES = 48 * 1024;
export const MAX_JOB_QUESTION_BYTES = 8 * 1024;

const MAX_JSON_BODY_BYTES = 64 * 1024;
const MAX_ORIGIN_RESPONSE_BYTES = 128 * 1024;
const MAX_RESULT_DETAIL_BYTES = 2 * 1024;
const MAX_ERROR_CODE_CHARS = 64;
const ORIGIN_TIMEOUT_MS = 10_000;
const MAX_SEARCH_QUERY_CHARS = 256;
const MAX_SEARCH_LIMIT = 50;
const MAX_DOCUMENT_PATH_CHARS = 1_024;

const INSTANCE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/;
const SAFE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const ERROR_CODE_PATTERN = /^[a-z][a-z0-9_]{0,63}$/;
const JOB_KINDS = ["ask", "process", "digest"] as const;
const TERMINAL_JOB_STATES: ReadonlySet<JobState> = new Set([
  "completed",
  "failed",
  "cancelled",
]);
const ALLOWED_KNOWLEDGE_ROOTS: ReadonlySet<string> = new Set([
  "maps",
  "notes",
  "sources",
  "projects",
  "people",
  "me",
  "daily",
  "inbox",
]);

export interface AgentKnowledgeSearchResult {
  title: string;
  path: string;
  snippet: string;
}

type JobKind = (typeof JOB_KINDS)[number];

export interface RemoteApiEnv {
  DB: D1Database;
  BRAIN_QUEUE: Queue;
  CAPTURE_OBJECTS: R2Bucket;
  /** Fixed deployment instance. Clients can never select it. */
  INSTANCE_ID?: string;
  BRAIN_INSTANCE_ID?: string;
  /** Fixed authenticated Cloudflare Tunnel origin. */
  BRAIN_ORIGIN_URL?: string;
  ORIGIN_URL?: string;
  /** Secret accepted by the loopback Brain read API. */
  BRAIN_ORIGIN_TOKEN?: string;
  ORIGIN_TOKEN?: string;
  /** Secret used only by the remote Brain Agent's gateway callbacks. */
  AGENT_TOKEN?: string;
  BRAIN_AGENT_TOKEN?: string;
}

export interface JobDeliveryEnvelope {
  kind: "action";
  instance_id: string;
  action: {
    id: string;
    kind: JobKind;
    question?: string;
  };
}

interface JobRow {
  id: string;
  kind: JobKind;
  state: JobState;
  result_json: string | null;
  last_error: string | null;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
  updated_at: string;
}

interface SnapshotRow {
  status_json: string;
  observed_at: string;
}

interface OriginResult {
  status: number;
  payload: Record<string, unknown>;
}

interface BoundedString {
  value: string;
  truncated: boolean;
}

interface SanitizedResult {
  value: Record<string, unknown>;
  encoded: string;
}

/** Route only the endpoints owned by the remote read/job module. */
export async function handleRemoteApi(request: Request, env: RemoteApiEnv): Promise<Response> {
  const { pathname } = new URL(request.url);

  if (/^\/v1\/captures\/[^/]+\/object$/.test(pathname)) {
    return handlePairedCaptureObjectRequest(request, env);
  }

  if (pathname === "/v1/status") return handleSnapshotRequest(request, env, "status");
  if (pathname === "/v1/health") return handleSnapshotRequest(request, env, "health");
  if (pathname === "/v1/knowledge/documents") {
    return handleKnowledgeRequest(request, env, "documents");
  }
  if (pathname === "/v1/knowledge/search") {
    return handleKnowledgeRequest(request, env, "search");
  }
  if (pathname === "/v1/knowledge/document") {
    return handleKnowledgeRequest(request, env, "document");
  }
  if (pathname === "/v1/jobs") return handleJobsRequest(request, env);

  const jobMatch = /^\/v1\/jobs\/([^/]+)$/.exec(pathname);
  if (jobMatch) return handleJobRequest(request, env, jobMatch[1] ?? "");

  if (pathname === "/v1/agent/heartbeat") return handleHeartbeatRequest(request, env);
  const resultMatch = /^\/v1\/agent\/jobs\/([^/]+)\/result$/.exec(pathname);
  if (resultMatch) return handleJobResultRequest(request, env, resultMatch[1] ?? "");

  return json(404, { error: "not found" });
}

/** GET /v1/status or GET /v1/health. */
export async function handleSnapshotRequest(
  request: Request,
  env: RemoteApiEnv,
  kind: "status" | "health",
): Promise<Response> {
  if (request.method !== "GET") return json(405, { error: "method not allowed" });
  const requestUrl = new URL(request.url);
  if (requestUrl.search !== "") return json(400, { error: "invalid query" });

  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "remote Brain is not configured" });
  const authorization = await authorizeClient(env, instanceId, request, "read");
  if (authorization) return authorization;

  const live = await fetchOriginJson(env, `/v1/${kind}`, new URLSearchParams());
  const livePayload = live
    ? kind === "status"
      ? validateStatusSiteUrl(live.payload)
      : validateHealthOperations(live.payload)
    : null;
  if (live && livePayload && live.status >= 200 && live.status < 300) {
    await persistSnapshot(env.DB, instanceId, kind, livePayload);
    return json(live.status, livePayload, {
      "x-brain-snapshot": "fresh",
      "x-brain-snapshot-age-seconds": "0",
    });
  }

  let snapshot: SnapshotRow | null;
  try {
    snapshot = await env.DB.prepare(
      `SELECT status_json, observed_at
         FROM heartbeats
        WHERE instance_id = ?
          AND json_type(status_json, ?) = 'object'
          AND COALESCE(json_extract(status_json, ?), 1) != 0
        ORDER BY observed_at DESC, received_at DESC
        LIMIT 1`,
    )
      .bind(instanceId, `$.${kind}`, `$.${kind}.available`)
      .first<SnapshotRow>();
  } catch {
    return json(503, { error: "remote Brain unavailable" });
  }
  if (!snapshot) return json(503, { error: "remote Brain unavailable" });

  const decoded = parseObject(snapshot.status_json);
  const storedValue = decoded?.[kind];
  if (!isObject(storedValue)) return json(503, { error: "remote Brain unavailable" });
  const value = kind === "status"
    ? validateStatusSiteUrl(storedValue)
    : validateHealthOperations(storedValue);
  if (!value) return json(503, { error: "remote Brain unavailable" });
  const observedAt = new Date(snapshot.observed_at);
  if (Number.isNaN(observedAt.getTime())) {
    return json(503, { error: "remote Brain unavailable" });
  }
  const ageSeconds = Math.max(0, Math.floor((Date.now() - observedAt.getTime()) / 1_000));
  return json(
    200,
    {
      ...value,
      stale: true,
      age_seconds: ageSeconds,
      snapshot_at: snapshot.observed_at,
    },
    {
      "x-brain-snapshot": "stale",
      "x-brain-snapshot-age-seconds": String(ageSeconds),
    },
  );
}

/** GET the fixed live knowledge search or document route. */
export async function handleKnowledgeRequest(
  request: Request,
  env: RemoteApiEnv,
  kind?: "documents" | "search" | "document",
): Promise<Response> {
  if (request.method !== "GET") return json(405, { error: "method not allowed" });
  const requestUrl = new URL(request.url);
  const selectedKind = kind ?? (
    requestUrl.pathname.endsWith("/documents")
      ? "documents"
      : requestUrl.pathname.endsWith("/search") ? "search" : "document"
  );
  const parameters = validateKnowledgeQuery(requestUrl.searchParams, selectedKind);
  if (!parameters.ok) return json(400, { error: parameters.error });

  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "remote Brain is not configured" });
  const authorization = await authorizeClient(env, instanceId, request, "read");
  if (authorization) return authorization;

  const live = await fetchOriginJson(
    env,
    `/v1/knowledge/${selectedKind}`,
    parameters.value,
    true,
  );
  if (!live || live.status >= 500) {
    return json(503, { error: "live knowledge unavailable" });
  }
  return json(live.status, live.payload);
}

/**
 * MCP retrieval uses the same fixed authenticated Agent origin as paired
 * Knowledge reads. It deliberately exposes no caller-selectable origin,
 * filesystem path, repository, or GitHub credential.
 */
export async function searchAgentKnowledge(
  env: RemoteApiEnv,
  query: string,
  limit: number,
): Promise<
  | { ok: true; results: AgentKnowledgeSearchResult[] }
  | { ok: false; error: string }
> {
  const parameters = validateKnowledgeQuery(
    new URLSearchParams({ q: query, limit: String(limit) }),
    "search",
  );
  if (!parameters.ok) return { ok: false, error: parameters.error };
  const live = await fetchOriginJson(env, "/v1/knowledge/search", parameters.value, true);
  if (!live || live.status < 200 || live.status >= 300) {
    return { ok: false, error: "paired Brain knowledge is unavailable" };
  }
  const results = live.payload.results;
  if (live.payload.query !== query || !Array.isArray(results)) {
    return { ok: false, error: "paired Brain returned an invalid knowledge response" };
  }
  const sanitized: AgentKnowledgeSearchResult[] = [];
  for (const value of results.slice(0, limit)) {
    if (!isObject(value) || typeof value.title !== "string" ||
        typeof value.path !== "string" || typeof value.snippet !== "string" ||
        !validDocumentPath(value.path)) {
      return { ok: false, error: "paired Brain returned an invalid knowledge response" };
    }
    sanitized.push({ title: value.title, path: value.path, snippet: value.snippet });
  }
  return { ok: true, results: sanitized };
}

/** POST /v1/jobs. */
export async function handleJobsRequest(request: Request, env: RemoteApiEnv): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "method not allowed" });
  const requestUrl = new URL(request.url);
  if (requestUrl.search !== "") return json(400, { error: "invalid query" });

  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "remote Brain is not configured" });
  const device = await authorizedDevice(env, instanceId, request, "control");
  if (device instanceof Response) return device;

  const decoded = await readJsonBody(request);
  if (!decoded.ok) return json(decoded.status, { error: decoded.error });
  const parsed = parseJobInput(decoded.value);
  if (!parsed.ok) return json(422, { error: parsed.error });

  const jobId = crypto.randomUUID();
  const now = new Date().toISOString();
  const requestDigest = await sha256(JSON.stringify(parsed.value));
  try {
    await env.DB.prepare(
      `INSERT INTO jobs
        (id, instance_id, device_id, request_digest, kind, state, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, 'queued', ?, ?)`,
    )
      .bind(jobId, instanceId, device.deviceId, requestDigest, parsed.value.kind, now, now)
      .run();
  } catch {
    return json(503, { error: "job state unavailable" });
  }

  const action: JobDeliveryEnvelope["action"] = {
    id: jobId,
    kind: parsed.value.kind,
  };
  if (parsed.value.question !== undefined) action.question = parsed.value.question;
  const envelope: JobDeliveryEnvelope = {
    kind: "action",
    instance_id: instanceId,
    action,
  };
  try {
    await env.BRAIN_QUEUE.send(envelope, { contentType: "json" });
  } catch {
    const failure = JSON.stringify({ error: "gateway_queue_publish_failed" });
    try {
      await env.DB.prepare(
        `UPDATE jobs
            SET state = 'failed', result_json = ?, last_error = ?, finished_at = ?, updated_at = ?
          WHERE id = ? AND instance_id = ? AND state = 'queued'`,
      )
        .bind(failure, "gateway_queue_publish_failed", now, now, jobId, instanceId)
        .run();
    } catch {
      // Preserve the original Queue failure response.
    }
    return json(503, { error: "job queue unavailable" });
  }

  return json(202, { id: jobId, state: "queued" });
}

/** GET /v1/jobs/<id>. */
export async function handleJobRequest(
  request: Request,
  env: RemoteApiEnv,
  jobIdInput?: string,
): Promise<Response> {
  if (request.method !== "GET") return json(405, { error: "method not allowed" });
  const requestUrl = new URL(request.url);
  if (requestUrl.search !== "") return json(400, { error: "invalid query" });

  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "remote Brain is not configured" });
  const authorization = await authorizeClient(env, instanceId, request, "read");
  if (authorization) return authorization;

  const match = /^\/v1\/jobs\/([^/]+)$/.exec(requestUrl.pathname);
  const jobId = jobIdInput ?? match?.[1] ?? "";
  if (!SAFE_ID_PATTERN.test(jobId)) return json(404, { error: "not found" });

  let row: JobRow | null;
  try {
    row = await findJob(env.DB, instanceId, jobId);
  } catch {
    return json(503, { error: "job state unavailable" });
  }
  if (!row) return json(404, { error: "not found" });

  const result = sanitizeStoredResult(row.result_json);
  return json(200, {
    id: row.id,
    kind: row.kind,
    state: row.state,
    ...result,
    created_at: row.created_at,
    started_at: row.started_at,
    finished_at: row.finished_at,
    updated_at: row.updated_at,
  });
}

/** POST /v1/agent/heartbeat. */
export async function handleHeartbeatRequest(
  request: Request,
  env: RemoteApiEnv,
): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "method not allowed" });
  const requestUrl = new URL(request.url);
  if (requestUrl.search !== "") return json(400, { error: "invalid query" });

  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "remote Brain is not configured" });
  if (!(await authorizeAgent(env, instanceId, request.headers.get("authorization")))) {
    return json(401, { error: "unauthorized" });
  }

  const decoded = await readJsonBody(request);
  if (!decoded.ok) return json(decoded.status, { error: decoded.error });
  const heartbeat = parseHeartbeat(decoded.value, instanceId);
  if (!heartbeat.ok) return json(422, { error: heartbeat.error });

  try {
    await env.DB.prepare(
      `INSERT INTO heartbeats
        (id, instance_id, agent_version, status_json, observed_at, received_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    )
      .bind(
        crypto.randomUUID(),
        instanceId,
        heartbeat.value.agentVersion,
        JSON.stringify(heartbeat.value.snapshot),
        heartbeat.value.generatedAt,
        new Date().toISOString(),
      )
      .run();
  } catch {
    return json(503, { error: "heartbeat state unavailable" });
  }
  return json(202, { accepted: true });
}

/** POST /v1/agent/jobs/<id>/result. */
export async function handleJobResultRequest(
  request: Request,
  env: RemoteApiEnv,
  jobIdInput?: string,
): Promise<Response> {
  if (request.method !== "POST") return json(405, { error: "method not allowed" });
  const requestUrl = new URL(request.url);
  if (requestUrl.search !== "") return json(400, { error: "invalid query" });

  const instanceId = configuredInstanceId(env);
  if (!instanceId) return json(503, { error: "remote Brain is not configured" });
  if (!(await authorizeAgent(env, instanceId, request.headers.get("authorization")))) {
    return json(401, { error: "unauthorized" });
  }

  const match = /^\/v1\/agent\/jobs\/([^/]+)\/result$/.exec(requestUrl.pathname);
  const jobId = jobIdInput ?? match?.[1] ?? "";
  if (!SAFE_ID_PATTERN.test(jobId)) return json(404, { error: "not found" });

  const decoded = await readJsonBody(request);
  if (!decoded.ok) return json(decoded.status, { error: decoded.error });
  const report = parseJobResult(decoded.value);
  if (!report.ok) return json(422, { error: report.error });

  let row: JobRow | null;
  try {
    row = await findJob(env.DB, instanceId, jobId);
  } catch {
    return json(503, { error: "job state unavailable" });
  }
  if (!row) return json(404, { error: "not found" });

  if (row.state === report.state) {
    if (row.state === "running") return json(200, { id: jobId, state: row.state });
    if (TERMINAL_JOB_STATES.has(row.state) && row.result_json === report.result.encoded) {
      return json(200, { id: jobId, state: row.state });
    }
    return json(409, { error: "job result conflicts with terminal state" });
  }
  if (!isForwardTransition(row.state, report.state)) {
    return json(409, { error: "invalid job state transition" });
  }

  const now = new Date().toISOString();
  const terminal = TERMINAL_JOB_STATES.has(report.state);
  const startedAt = report.state === "running" && row.started_at === null ? now : row.started_at;
  const lastError = report.state === "failed"
    ? typeof report.result.value.error === "string" ? report.result.value.error : "job_failed"
    : null;
  try {
    const updated = await env.DB.prepare(
      `UPDATE jobs
          SET state = ?, result_json = ?, last_error = ?, started_at = ?, finished_at = ?, updated_at = ?
        WHERE id = ? AND instance_id = ? AND state = ?`,
    )
      .bind(
        report.state,
        report.state === "running" ? null : report.result.encoded,
        lastError,
        startedAt,
        terminal ? now : null,
        now,
        jobId,
        instanceId,
        row.state,
      )
      .run();
    if (updated.meta.changes !== 1) {
      return json(409, { error: "job state changed concurrently" });
    }
  } catch {
    return json(503, { error: "job state unavailable" });
  }

  return json(200, { id: jobId, state: report.state });
}

// Friendly alias for the entrypoint that composes the independent /v1 modules.
export const handleRemoteRequest = handleRemoteApi;

async function authorizeClient(
  env: RemoteApiEnv,
  instanceId: string,
  request: Request,
  scope: "read" | "control",
): Promise<Response | null> {
  const device = await authorizedDevice(env, instanceId, request, scope);
  return device instanceof Response ? device : null;
}

async function authorizedDevice(
  env: RemoteApiEnv,
  instanceId: string,
  request: Request,
  scope: "read" | "control",
): Promise<{ deviceId: string } | Response> {
  try {
    return await authorizeDevice(
      env.DB,
      instanceId,
      request.headers.get("authorization"),
      [scope],
    );
  } catch (caught) {
    if (caught instanceof DeviceAuthError) return caught.toResponse();
    return json(503, { error: "device authorization unavailable" });
  }
}

function configuredInstanceId(env: RemoteApiEnv): string | null {
  const value = env.INSTANCE_ID ?? env.BRAIN_INSTANCE_ID;
  return typeof value === "string" && INSTANCE_PATTERN.test(value) ? value : null;
}

function configuredOrigin(env: RemoteApiEnv): { url: URL; token: string } | null {
  const rawUrl = env.BRAIN_ORIGIN_URL ?? env.ORIGIN_URL;
  const token = env.BRAIN_ORIGIN_TOKEN ?? env.ORIGIN_TOKEN;
  if (typeof rawUrl !== "string" || typeof token !== "string" || token.length === 0) return null;
  try {
    const url = new URL(rawUrl);
    if (
      url.protocol !== "https:" ||
      url.username ||
      url.password ||
      url.search ||
      url.hash ||
      (url.pathname !== "/" && url.pathname !== "")
    ) {
      return null;
    }
    return { url, token };
  } catch {
    return null;
  }
}

async function fetchOriginJson(
  env: RemoteApiEnv,
  path: string,
  query: URLSearchParams,
  includeClientErrors = false,
): Promise<OriginResult | null> {
  const origin = configuredOrigin(env);
  if (!origin) return null;
  const target = new URL(path, origin.url);
  target.search = query.toString();
  try {
    const response = await fetch(target.toString(), {
      method: "GET",
      headers: {
        accept: "application/json",
        "x-brain-origin-token": origin.token,
      },
      redirect: "manual",
      signal: AbortSignal.timeout(ORIGIN_TIMEOUT_MS),
    });
    if (
      response.status >= 500 ||
      (response.status >= 300 && response.status < 400) ||
      (!includeClientErrors && !response.ok)
    ) return null;
    const declared = Number(response.headers.get("content-length") ?? "0");
    if (Number.isFinite(declared) && declared > MAX_ORIGIN_RESPONSE_BYTES) return null;
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength > MAX_ORIGIN_RESPONSE_BYTES) return null;
    const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
    const payload: unknown = JSON.parse(text);
    if (!isObject(payload)) return null;
    return { status: response.status, payload };
  } catch {
    return null;
  }
}

async function persistSnapshot(
  db: D1Database,
  instanceId: string,
  kind: "status" | "health",
  payload: Record<string, unknown>,
): Promise<void> {
  const now = new Date().toISOString();
  try {
    await db.prepare(
      `INSERT INTO heartbeats
        (id, instance_id, agent_version, status_json, observed_at, received_at)
       VALUES (?, ?, 'gateway-proxy', ?, ?, ?)`,
    )
      .bind(crypto.randomUUID(), instanceId, JSON.stringify({ [kind]: payload }), now, now)
      .run();
  } catch {
    // A live read remains useful if only snapshot persistence is unavailable.
  }
}

function validateKnowledgeQuery(
  input: URLSearchParams,
  kind: "documents" | "search" | "document",
): { ok: true; value: URLSearchParams } | { ok: false; error: string } {
  const keys = Array.from(input.keys());
  if (keys.some((key) => input.getAll(key).length !== 1)) {
    return { ok: false, error: "invalid query" };
  }
  if (kind === "documents") {
    if (keys.some((key) => key !== "limit")) return { ok: false, error: "invalid query" };
    const output = new URLSearchParams();
    if (input.has("limit")) {
      const raw = input.get("limit") ?? "";
      if (!/^[0-9]+$/.test(raw)) return { ok: false, error: "invalid list limit" };
      const limit = Number(raw);
      if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_SEARCH_LIMIT) {
        return { ok: false, error: "invalid list limit" };
      }
      output.set("limit", String(limit));
    }
    return { ok: true, value: output };
  }
  if (kind === "search") {
    if (keys.some((key) => key !== "q" && key !== "limit") || !input.has("q")) {
      return { ok: false, error: "invalid query" };
    }
    const q = input.get("q") ?? "";
    if (!q.trim() || q.length > MAX_SEARCH_QUERY_CHARS || q.includes("\0")) {
      return { ok: false, error: "invalid search query" };
    }
    const output = new URLSearchParams({ q });
    if (input.has("limit")) {
      const raw = input.get("limit") ?? "";
      if (!/^[0-9]+$/.test(raw)) return { ok: false, error: "invalid search limit" };
      const limit = Number(raw);
      if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_SEARCH_LIMIT) {
        return { ok: false, error: "invalid search limit" };
      }
      output.set("limit", String(limit));
    }
    return { ok: true, value: output };
  }

  if (keys.length !== 1 || keys[0] !== "path") return { ok: false, error: "invalid query" };
  const path = input.get("path") ?? "";
  if (!validDocumentPath(path)) return { ok: false, error: "invalid document path" };
  return { ok: true, value: new URLSearchParams({ path }) };
}

function validDocumentPath(value: string): boolean {
  if (
    !value ||
    value.length > MAX_DOCUMENT_PATH_CHARS ||
    value.startsWith("/") ||
    value.includes("\\") ||
    value.includes("\0")
  ) {
    return false;
  }
  const parts = value.split("/");
  return Boolean(
    parts.length >= 2 &&
    ALLOWED_KNOWLEDGE_ROOTS.has(parts[0] ?? "") &&
    parts.every((part) => Boolean(part) && part !== "." && part !== ".." && !part.startsWith(".")) &&
    parts.at(-1)?.toLowerCase().endsWith(".md")
  );
}

function parseJobInput(
  value: unknown,
):
  | { ok: true; value: { kind: JobKind; question?: string } }
  | { ok: false; error: string } {
  if (!isObject(value)) return { ok: false, error: "body must be a JSON object" };
  const kind = value.kind;
  if (kind !== "ask" && kind !== "process" && kind !== "digest") {
    return { ok: false, error: "kind must be ask, process, or digest" };
  }
  const allowed = kind === "ask" ? new Set(["kind", "question"]) : new Set(["kind"]);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    return { ok: false, error: "body contains an unsupported field" };
  }
  if (kind === "ask") {
    if (typeof value.question !== "string" || !value.question.trim() || value.question.includes("\0")) {
      return { ok: false, error: "ask requires a question" };
    }
    if (new TextEncoder().encode(value.question).byteLength > MAX_JOB_QUESTION_BYTES) {
      return { ok: false, error: "question is too large" };
    }
    return { ok: true, value: { kind, question: value.question } };
  }
  return { ok: true, value: { kind } };
}

function parseHeartbeat(
  value: unknown,
  instanceId: string,
):
  | {
      ok: true;
      value: {
        agentVersion: string;
        generatedAt: string;
        snapshot: Record<string, unknown>;
      };
    }
  | { ok: false; error: string } {
  if (!isObject(value)) return { ok: false, error: "body must be a JSON object" };
  const allowed = new Set([
    "instance_id",
    "generated_at",
    "agent_version",
    "status",
    "health",
    "last_successful_queue_poll",
  ]);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    return { ok: false, error: "heartbeat contains an unsupported field" };
  }
  if (value.instance_id !== instanceId) return { ok: false, error: "wrong instance" };
  if (
    typeof value.agent_version !== "string" ||
    value.agent_version.length === 0 ||
    value.agent_version.length > 64
  ) {
    return { ok: false, error: "invalid agent version" };
  }
  if (typeof value.generated_at !== "string" || !isCanonicalTimestamp(value.generated_at)) {
    return { ok: false, error: "invalid generated timestamp" };
  }
  if (!isObject(value.status) || !isObject(value.health)) {
    return { ok: false, error: "heartbeat summaries must be objects" };
  }
  const status = validateStatusSiteUrl(value.status);
  if (!status) return { ok: false, error: "heartbeat status contains an invalid site URL" };
  const health = validateHealthOperations(value.health);
  if (!health) return { ok: false, error: "heartbeat health contains invalid operations" };
  const lastPoll = value.last_successful_queue_poll;
  if (lastPoll !== null && lastPoll !== undefined && (
    typeof lastPoll !== "string" || !isCanonicalTimestamp(lastPoll)
  )) {
    return { ok: false, error: "invalid queue poll timestamp" };
  }
  const snapshot: Record<string, unknown> = { status, health };
  if (typeof lastPoll === "string") snapshot.last_successful_queue_poll = lastPoll;
  return {
    ok: true,
    value: {
      agentVersion: value.agent_version,
      generatedAt: value.generated_at,
      snapshot,
    },
  };
}

function parseJobResult(
  value: unknown,
):
  | { ok: true; state: Exclude<JobState, "queued">; result: SanitizedResult }
  | { ok: false; error: string } {
  if (!isObject(value)) return { ok: false, error: "body must be a JSON object" };
  const allowed = new Set(["state", "output", "error", "detail"]);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    return { ok: false, error: "job result contains an unsupported field" };
  }
  if (value.state !== "running" && !TERMINAL_JOB_STATES.has(value.state as JobState)) {
    return { ok: false, error: "invalid job result state" };
  }
  const state = value.state as Exclude<JobState, "queued">;
  if (state === "running" && Object.keys(value).some((key) => key !== "state")) {
    return { ok: false, error: "running result cannot contain terminal output" };
  }
  if (value.output !== undefined && typeof value.output !== "string") {
    return { ok: false, error: "output must be a string" };
  }
  if (value.error !== undefined && (
    typeof value.error !== "string" ||
    value.error.length > MAX_ERROR_CODE_CHARS ||
    !ERROR_CODE_PATTERN.test(value.error)
  )) {
    return { ok: false, error: "invalid error code" };
  }
  if (state === "failed" && typeof value.error !== "string") {
    return { ok: false, error: "failed result requires an error code" };
  }
  if (value.detail !== undefined && typeof value.detail !== "string") {
    return { ok: false, error: "detail must be a string" };
  }
  if (state !== "failed" && (value.error !== undefined || value.detail !== undefined)) {
    return { ok: false, error: "only failed results can contain error details" };
  }

  const result: Record<string, unknown> = {};
  let truncated = false;
  if (typeof value.output === "string") {
    const bounded = boundUtf8(value.output, MAX_JOB_OUTPUT_BYTES);
    result.output = bounded.value;
    truncated ||= bounded.truncated;
  }
  if (typeof value.error === "string") result.error = value.error;
  if (typeof value.detail === "string") {
    const bounded = boundUtf8(value.detail, MAX_RESULT_DETAIL_BYTES);
    result.detail = bounded.value;
    truncated ||= bounded.truncated;
  }
  if (truncated) result.truncated = true;
  return { ok: true, state, result: { value: result, encoded: JSON.stringify(result) } };
}

function isForwardTransition(current: JobState, next: Exclude<JobState, "queued">): boolean {
  if (current === "queued") return next === "running" || TERMINAL_JOB_STATES.has(next);
  if (current === "running") return TERMINAL_JOB_STATES.has(next);
  return false;
}

async function findJob(db: D1Database, instanceId: string, jobId: string): Promise<JobRow | null> {
  return db.prepare(
    `SELECT id, kind, state, result_json, last_error, created_at, started_at, finished_at, updated_at
       FROM jobs
      WHERE id = ? AND instance_id = ?`,
  )
    .bind(jobId, instanceId)
    .first<JobRow>();
}

function sanitizeStoredResult(encoded: string | null): Record<string, unknown> {
  if (encoded === null) return {};
  const value = parseObject(encoded);
  if (!value) return {};
  const output: Record<string, unknown> = {};
  let truncated = value.truncated === true;
  if (typeof value.output === "string") {
    const bounded = boundUtf8(value.output, MAX_JOB_OUTPUT_BYTES);
    output.output = bounded.value;
    truncated ||= bounded.truncated;
  }
  if (typeof value.error === "string" && ERROR_CODE_PATTERN.test(value.error)) {
    output.error = value.error;
  }
  if (typeof value.detail === "string") {
    const bounded = boundUtf8(value.detail, MAX_RESULT_DETAIL_BYTES);
    output.detail = bounded.value;
    truncated ||= bounded.truncated;
  }
  if (truncated) output.truncated = true;
  return output;
}

async function authorizeAgent(
  env: RemoteApiEnv,
  instanceId: string,
  authorization: string | null,
): Promise<boolean> {
  const match = /^Bearer ([^\s]{1,1024})$/i.exec(authorization ?? "");
  const token = match?.[1];
  if (!token) return false;
  const presentedDigest = await sha256(token);
  const configuredToken = env.AGENT_TOKEN ?? env.BRAIN_AGENT_TOKEN;
  if (configuredToken !== undefined) return presentedDigest === await sha256(configuredToken);
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

async function readJsonBody(request: Request): Promise<
  | { ok: true; value: unknown }
  | { ok: false; status: 413 | 422; error: string }
> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_JSON_BODY_BYTES) {
    return { ok: false, status: 413, error: "request body is too large" };
  }
  if (!request.body) return { ok: false, status: 422, error: "body must be valid JSON" };
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAX_JSON_BODY_BYTES) {
    return { ok: false, status: 413, error: "request body is too large" };
  }
  try {
    const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
    return { ok: true, value: JSON.parse(text) as unknown };
  } catch {
    return { ok: false, status: 422, error: "body must be valid JSON" };
  }
}

function boundUtf8(value: string, limit: number): BoundedString {
  const encoded = new TextEncoder().encode(value);
  if (encoded.byteLength <= limit) return { value, truncated: false };
  let end = limit;
  while (end > 0) {
    try {
      return {
        value: new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(
          encoded.subarray(0, end),
        ),
        truncated: true,
      };
    } catch {
      end -= 1;
    }
  }
  return { value: "", truncated: true };
}

function isCanonicalTimestamp(value: string): boolean {
  const date = new Date(value);
  return !Number.isNaN(date.getTime()) && date.toISOString() === value;
}

function parseObject(value: string): Record<string, unknown> | null {
  try {
    const decoded: unknown = JSON.parse(value);
    return isObject(decoded) ? decoded : null;
  } catch {
    return null;
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

function json(status: number, data: unknown, extraHeaders: HeadersInit = {}): Response {
  const headers = new Headers(extraHeaders);
  headers.set("content-type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(data), { status, headers });
}
