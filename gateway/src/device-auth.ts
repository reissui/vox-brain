/**
 * Single-user device pairing and bearer authorization.
 *
 * Pairing codes and device tokens are returned exactly once. D1 only ever sees
 * their SHA-256 digests; errors deliberately contain stable, credential-free
 * messages so failed credentials cannot be reflected into responses or logs.
 */

export const DEVICE_SCOPES = ["capture", "read", "control"] as const;

export type DeviceScope = (typeof DEVICE_SCOPES)[number];

export interface MintPairingCodeInput {
  /** The instance id established by the already-authenticated agent request. */
  instanceId: string;
  deviceName: string;
  scopes: readonly DeviceScope[];
}

export interface MintedPairingCode {
  code: string;
  deviceId: string;
  expiresAt: string;
}

export interface ClaimPairingCodeInput {
  instanceId: string;
  code: string;
}

export interface ClaimedDevice {
  deviceId: string;
  deviceName: string;
  instanceId: string;
  scopes: readonly DeviceScope[];
  token: string;
}

export interface AuthorizedDevice {
  deviceId: string;
  deviceName: string;
  instanceId: string;
  scopes: readonly DeviceScope[];
}

export type DeviceAuthErrorCode =
  | "invalid_pairing_code"
  | "unauthorized"
  | "forbidden";

/** A safe HTTP-shaped error for route handlers to return without reflection. */
export class DeviceAuthError extends Error {
  readonly status: 401 | 403;
  readonly code: DeviceAuthErrorCode;

  constructor(status: 401 | 403, code: DeviceAuthErrorCode) {
    super(code);
    this.name = "DeviceAuthError";
    this.status = status;
    this.code = code;
  }

  toResponse(): Response {
    return new Response(JSON.stringify({ error: this.code }), {
      status: this.status,
      headers: { "content-type": "application/json; charset=utf-8" },
    });
  }
}

const PAIRING_LIFETIME_MS = 10 * 60 * 1_000;
const OPAQUE_CREDENTIAL_BYTES = 32;
const OPAQUE_CREDENTIAL_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const knownScopes: ReadonlySet<unknown> = new Set(DEVICE_SCOPES);

/** Mint a one-time, ten-minute pairing code for an authenticated instance. */
export async function mintPairingCode(
  db: D1Database,
  input: MintPairingCodeInput,
  now = new Date(),
): Promise<MintedPairingCode> {
  const instanceId = requireIdentifier(input.instanceId, "instanceId");
  const deviceName = requireDeviceName(input.deviceName);
  const scopes = normalizeScopes(input.scopes);
  const code = randomCredential();
  const codeDigest = await sha256(code);
  const deviceId = crypto.randomUUID();
  const createdAt = now.toISOString();
  const expiresAt = new Date(now.getTime() + PAIRING_LIFETIME_MS).toISOString();

  await db.prepare(
    `INSERT INTO devices
      (id, instance_id, name, pairing_code_digest, scopes, pairing_expires_at,
       created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      deviceId,
      instanceId,
      deviceName,
      codeDigest,
      JSON.stringify(scopes),
      expiresAt,
      createdAt,
      createdAt,
    )
    .run();

  return { code, deviceId, expiresAt };
}

/**
 * Atomically consume a pairing code and return its device token once.
 *
 * The conditional UPDATE is the consume operation: concurrent claims cannot
 * both match, and an invalid claim never inserts or activates another device.
 */
export async function claimPairingCode(
  db: D1Database,
  input: ClaimPairingCodeInput,
  now = new Date(),
): Promise<ClaimedDevice> {
  const instanceId = requireIdentifier(input.instanceId, "instanceId");
  if (!isOpaqueCredential(input.code)) throw invalidPairingCode();

  const codeDigest = await sha256(input.code);
  const token = randomCredential();
  const tokenDigest = await sha256(token);
  const claimedAt = now.toISOString();
  const row = await db.prepare(
    `UPDATE devices
        SET pairing_code_digest = NULL,
            pairing_expires_at = NULL,
            token_digest = ?,
            claimed_at = ?,
            updated_at = ?
      WHERE instance_id = ?
        AND pairing_code_digest = ?
        AND claimed_at IS NULL
        AND revoked_at IS NULL
        AND pairing_expires_at > ?
      RETURNING id, instance_id, name, scopes`,
  )
    .bind(tokenDigest, claimedAt, claimedAt, instanceId, codeDigest, claimedAt)
    .first<DeviceRow>();

  if (!row) throw invalidPairingCode();
  const scopes = parseStoredScopes(row.scopes);
  if (!scopes) throw invalidPairingCode();

  return {
    token,
    deviceId: row.id,
    deviceName: row.name,
    instanceId: row.instance_id,
    scopes,
  };
}

/**
 * Authorize one bearer credential for an instance and all required scopes.
 * Unknown/malformed credentials are 401; known-but-forbidden devices are 403.
 */
export async function authorizeDevice(
  db: D1Database,
  instanceIdInput: string,
  authorization: string | null,
  requiredScopes: readonly DeviceScope[],
  now = new Date(),
): Promise<AuthorizedDevice> {
  const instanceId = requireIdentifier(instanceIdInput, "instanceId");
  const required = normalizeScopes(requiredScopes);
  const token = parseBearerToken(authorization);
  if (!token) throw unauthorized();

  const tokenDigest = await sha256(token);
  const row = await db.prepare(
    `SELECT id, instance_id, name, scopes, revoked_at
       FROM devices
      WHERE instance_id = ? AND token_digest = ? AND claimed_at IS NOT NULL`,
  )
    .bind(instanceId, tokenDigest)
    .first<DeviceRow>();

  if (!row) throw unauthorized();
  const scopes = parseStoredScopes(row.scopes);
  if (!scopes) throw unauthorized();
  if (row.revoked_at !== null || required.some((scope) => !scopes.includes(scope))) {
    throw forbidden();
  }

  const seenAt = now.toISOString();
  await db.prepare(
    `UPDATE devices
        SET last_seen_at = ?, updated_at = ?
      WHERE instance_id = ? AND id = ? AND revoked_at IS NULL`,
  )
    .bind(seenAt, seenAt, instanceId, row.id)
    .run();

  return {
    deviceId: row.id,
    deviceName: row.name,
    instanceId: row.instance_id,
    scopes,
  };
}

/** Revoke only the named device belonging to the authenticated instance. */
export async function revokeDevice(
  db: D1Database,
  instanceIdInput: string,
  deviceIdInput: string,
  now = new Date(),
): Promise<boolean> {
  const instanceId = requireIdentifier(instanceIdInput, "instanceId");
  const deviceId = requireIdentifier(deviceIdInput, "deviceId");
  const revokedAt = now.toISOString();
  const result = await db.prepare(
    `UPDATE devices
        SET revoked_at = ?, updated_at = ?
      WHERE instance_id = ? AND id = ? AND revoked_at IS NULL`,
  )
    .bind(revokedAt, revokedAt, instanceId, deviceId)
    .run();

  return result.meta.changes === 1;
}

interface DeviceRow {
  id: string;
  instance_id: string;
  name: string;
  scopes: string;
  revoked_at: string | null;
}

function requireIdentifier(value: string, field: string): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 255) {
    throw new TypeError(`${field} must be a non-empty string`);
  }
  return value;
}

function requireDeviceName(value: string): string {
  if (typeof value !== "string" || value.trim().length === 0 || value.length > 255) {
    throw new TypeError("deviceName must be a non-empty string");
  }
  return value.trim();
}

function normalizeScopes(scopes: readonly DeviceScope[]): DeviceScope[] {
  if (!Array.isArray(scopes) || scopes.some((scope) => !knownScopes.has(scope))) {
    throw new TypeError(`scopes must contain only: ${DEVICE_SCOPES.join(", ")}`);
  }
  return DEVICE_SCOPES.filter((scope) => scopes.includes(scope));
}

function parseStoredScopes(value: string): DeviceScope[] | null {
  try {
    const decoded: unknown = JSON.parse(value);
    if (!Array.isArray(decoded) || decoded.some((scope) => !knownScopes.has(scope))) return null;
    return DEVICE_SCOPES.filter((scope) => decoded.includes(scope));
  } catch {
    return null;
  }
}

function parseBearerToken(header: string | null): string | null {
  if (!header) return null;
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/i.exec(header);
  return match?.[1] && isOpaqueCredential(match[1]) ? match[1] : null;
}

function isOpaqueCredential(value: unknown): value is string {
  return typeof value === "string" && OPAQUE_CREDENTIAL_PATTERN.test(value);
}

function randomCredential(): string {
  const bytes = new Uint8Array(OPAQUE_CREDENTIAL_BYTES);
  crypto.getRandomValues(bytes);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

function invalidPairingCode(): DeviceAuthError {
  return new DeviceAuthError(401, "invalid_pairing_code");
}

function unauthorized(): DeviceAuthError {
  return new DeviceAuthError(401, "unauthorized");
}

function forbidden(): DeviceAuthError {
  return new DeviceAuthError(403, "forbidden");
}
