/** Closed operational states shared by the gateway and the remote Brain Agent. */
export const CAPTURE_STATES = [
  "queued",
  "delivering",
  "delivered",
  "processing",
  "needs_attention",
  "completed",
  "failed",
] as const;

export type CaptureState = (typeof CAPTURE_STATES)[number];

export const CAPTURE_OBJECT_RETENTION_STATES = ["permanent"] as const;

export type CaptureObjectRetentionState =
  (typeof CAPTURE_OBJECT_RETENTION_STATES)[number];

/** Public metadata for an immutable capture original. R2 keys stay private. */
export interface CaptureObjectMetadata {
  sha256: string;
  content_type: string;
  byte_length: number;
  filename: string;
  retention: CaptureObjectRetentionState;
  href: string;
}

export interface CaptureSummary {
  id: string;
  type: "video" | "tweet" | "article" | "design" | "note" | "transcript";
  source: string;
  state: "queued" | "processing" | "delivered" | "failed";
  retryable: boolean;
  error: string | null;
  created_at: string;
  updated_at: string;
  delivered_at: string | null;
  object: CaptureObjectMetadata | null;
}

export interface AgentHealthOperations {
  last_successful_poll: string | null;
  poll_age_seconds: number | null;
  backlog_count: number;
  oldest_backlog_age_seconds: number | null;
  process: {
    state: "idle" | "running" | "stuck";
    label: string | null;
    started_at: string | null;
    progress_age_seconds: number | null;
    declared_bound_seconds: number;
  };
  automation: {
    last_progress_at: string | null;
    progress_age_seconds: number | null;
  };
  launchd: {
    agent: "running";
    automation: "running" | "loaded" | "not_loaded" | "unknown";
  };
}

export const JOB_STATES = [
  "queued",
  "running",
  "completed",
  "failed",
  "cancelled",
] as const;

export type JobState = (typeof JOB_STATES)[number];

export const MAX_SITE_URL_BYTES = 2_048;

const captureStates: ReadonlySet<unknown> = new Set(CAPTURE_STATES);
const jobStates: ReadonlySet<unknown> = new Set(JOB_STATES);

export function parseCaptureState(value: unknown): CaptureState {
  if (!captureStates.has(value)) throw new TypeError("invalid capture state");
  return value as CaptureState;
}

export function parseJobState(value: unknown): JobState {
  if (!jobStates.has(value)) throw new TypeError("invalid job state");
  return value as JobState;
}

/**
 * Accept only a bounded HTTPS private-site destination. The original string is
 * returned so clients open exactly the owner-configured destination.
 */
export function parseSiteUrl(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value !== value.trim() ||
    value.includes("\\") ||
    /[^\u0020-\u007e]/.test(value) ||
    new TextEncoder().encode(value).byteLength > MAX_SITE_URL_BYTES
  ) {
    throw new TypeError("invalid site URL");
  }
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new TypeError("invalid site URL");
  }
  if (
    parsed.protocol !== "https:" ||
    parsed.hostname.length === 0 ||
    parsed.username.length !== 0 ||
    parsed.password.length !== 0 ||
    parsed.search.length !== 0 ||
    parsed.hash.length !== 0
  ) {
    throw new TypeError("invalid site URL");
  }
  return value;
}

/** Missing is backward-compatible; a present unsafe value rejects the snapshot. */
export function validateStatusSiteUrl(
  payload: Record<string, unknown>,
): Record<string, unknown> | null {
  if (!("site_url" in payload)) return payload;
  try {
    return { ...payload, site_url: parseSiteUrl(payload.site_url) };
  } catch {
    return null;
  }
}

/** Older Agents may omit operations; a present report must be bounded and typed. */
export function validateHealthOperations(
  payload: Record<string, unknown>,
): Record<string, unknown> | null {
  if (!("operations" in payload)) return payload;
  const value = payload.operations;
  if (!isRecord(value) || !isNullableTimestamp(value.last_successful_poll) ||
      !isNullableCount(value.poll_age_seconds) || !isCount(value.backlog_count) ||
      !isNullableCount(value.oldest_backlog_age_seconds) || !isRecord(value.process) ||
      !isRecord(value.automation) || !isRecord(value.launchd)) {
    return null;
  }
  const process = value.process;
  const automation = value.automation;
  const launchd = value.launchd;
  if (!new Set(["idle", "running", "stuck"]).has(process.state as string) ||
      !(process.label === null || (typeof process.label === "string" && process.label.length <= 160)) ||
      !isNullableTimestamp(process.started_at) ||
      !isNullableCount(process.progress_age_seconds) ||
      !isCount(process.declared_bound_seconds) ||
      !isNullableTimestamp(automation.last_progress_at) ||
      !isNullableCount(automation.progress_age_seconds) ||
      launchd.agent !== "running" ||
      !new Set(["running", "loaded", "not_loaded", "unknown"]).has(launchd.automation as string)) {
    return null;
  }
  return payload;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isCount(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function isNullableCount(value: unknown): boolean {
  return value === null || isCount(value);
}

function isNullableTimestamp(value: unknown): boolean {
  if (value === null) return true;
  return typeof value === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value) &&
    !Number.isNaN(Date.parse(value));
}
