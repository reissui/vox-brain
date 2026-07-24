import { applyD1Migrations, env } from "cloudflare:test";
import { beforeAll, describe, expect, it, vi } from "vitest";
import migrationSql from "../migrations/0001_remote_first.sql?raw";
import {
  DEVICE_SCOPES,
  DeviceAuthError,
  authorizeDevice,
  claimPairingCode,
  mintPairingCode,
  revokeDevice,
  type DeviceScope,
} from "../src/device-auth";

const migration = {
  name: "0001_remote_first.sql",
  queries: migrationSql
    .replace(/^\s*--.*$/gm, "")
    .split(";")
    .map((query) => query.trim())
    .filter(Boolean),
};

const db = requireBinding(env.DB, "DB");
const baseTime = new Date("2026-07-15T12:00:00.000Z");

beforeAll(async () => {
  await applyD1Migrations(db, [migration]);
  await insertInstance("instance-a", "A");
  await insertInstance("instance-b", "B");
});

describe("device pairing", () => {
  it("mints a 32-byte URL-safe code, persists only its digest, and expires it in ten minutes", async () => {
    const minted = await mintPairingCode(
      db,
      {
        instanceId: "instance-a",
        deviceName: "MacBook",
        scopes: ["control", "capture", "capture"],
      },
      baseTime,
    );

    expect(minted.code).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(decodeCredential(minted.code)).toHaveLength(32);
    expect(minted.expiresAt).toBe("2026-07-15T12:10:00.000Z");

    const row = await db.prepare(
      `SELECT instance_id, name, pairing_code_digest, token_digest, scopes,
              pairing_expires_at, claimed_at
         FROM devices WHERE id = ?`,
    )
      .bind(minted.deviceId)
      .first<PairingRow>();

    expect(row).toEqual({
      instance_id: "instance-a",
      name: "MacBook",
      pairing_code_digest: await sha256(minted.code),
      token_digest: null,
      scopes: '["capture","control"]',
      pairing_expires_at: minted.expiresAt,
      claimed_at: null,
    });
    expect(JSON.stringify(row)).not.toContain(minted.code);
    expect(row?.pairing_code_digest).toMatch(/^[a-f0-9]{64}$/);
  });

  it("claims exactly once and persists only the device-token digest", async () => {
    const minted = await mintPairingCode(
      db,
      { instanceId: "instance-a", deviceName: "iPhone", scopes: ["capture", "read"] },
      baseTime,
    );
    const claimed = await claimPairingCode(
      db,
      { instanceId: "instance-a", code: minted.code },
      after(1),
    );

    expect(claimed).toMatchObject({
      deviceId: minted.deviceId,
      deviceName: "iPhone",
      instanceId: "instance-a",
      scopes: ["capture", "read"],
    });
    expect(claimed.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(decodeCredential(claimed.token)).toHaveLength(32);

    const row = await db.prepare(
      `SELECT pairing_code_digest, pairing_expires_at, token_digest, claimed_at
         FROM devices WHERE id = ?`,
    )
      .bind(minted.deviceId)
      .first<ClaimedRow>();
    expect(row).toEqual({
      pairing_code_digest: null,
      pairing_expires_at: null,
      token_digest: await sha256(claimed.token),
      claimed_at: after(1).toISOString(),
    });
    expect(JSON.stringify(row)).not.toContain(minted.code);
    expect(JSON.stringify(row)).not.toContain(claimed.token);

    const replay = await rejected(
      claimPairingCode(db, { instanceId: "instance-a", code: minted.code }, after(2)),
    );
    expect(replay).toEqual({ status: 401, body: { error: "invalid_pairing_code" } });

    const stored = await db.prepare("SELECT COUNT(*) AS count FROM devices WHERE claimed_at IS NOT NULL")
      .first<{ count: number }>();
    expect(stored?.count).toBe(1);
  });

  it("gives replay, expiry, wrong-instance, and malformed claims one constant safe response", async () => {
    const wrongInstance = await mintPairingCode(
      db,
      { instanceId: "instance-a", deviceName: "Wrong instance", scopes: ["read"] },
      baseTime,
    );
    const expired = await mintPairingCode(
      db,
      { instanceId: "instance-a", deviceName: "Expired", scopes: ["read"] },
      baseTime,
    );
    const replay = await mintPairingCode(
      db,
      { instanceId: "instance-b", deviceName: "Replay", scopes: ["capture"] },
      baseTime,
    );
    await claimPairingCode(db, { instanceId: "instance-b", code: replay.code }, after(1));
    const claimedBefore = await claimedDeviceCount();

    const failures = await Promise.all([
      rejected(claimPairingCode(db, { instanceId: "instance-b", code: wrongInstance.code }, after(1))),
      rejected(claimPairingCode(db, { instanceId: "instance-a", code: expired.code }, after(10))),
      rejected(claimPairingCode(db, { instanceId: "instance-b", code: replay.code }, after(2))),
      rejected(claimPairingCode(db, { instanceId: "instance-a", code: "not-a-code" }, after(1))),
    ]);

    expect(failures).toEqual(
      Array.from({ length: 4 }, () => ({
        status: 401,
        body: { error: "invalid_pairing_code" },
      })),
    );
    expect(JSON.stringify(failures)).not.toContain(wrongInstance.code);
    expect(JSON.stringify(failures)).not.toContain(expired.code);
    expect(JSON.stringify(failures)).not.toContain(replay.code);
    expect(await claimedDeviceCount()).toBe(claimedBefore);
  });

  it("rejects scopes outside the closed set before persisting a pairing row", async () => {
    expect(DEVICE_SCOPES).toEqual(["capture", "read", "control"]);
    const before = await allDeviceCount();

    await expect(
      mintPairingCode(db, {
        instanceId: "instance-a",
        deviceName: "Over-scoped",
        scopes: ["admin" as DeviceScope],
      }),
    ).rejects.toThrow(TypeError);
    expect(await allDeviceCount()).toBe(before);
  });
});

describe("device bearer authorization", () => {
  it("returns 401 for malformed or unknown credentials and 403 for missing scopes", async () => {
    const device = await pair("instance-a", "Reader", ["read"]);

    for (const header of [null, "", "Basic abc", "Bearer short", `Bearer ${"x".repeat(42)}`]) {
      await expectAuthError(
        authorizeDevice(db, "instance-a", header, ["read"], after(3)),
        401,
        "unauthorized",
      );
    }
    await expectAuthError(
      authorizeDevice(db, "instance-a", `Bearer ${"A".repeat(43)}`, ["read"], after(3)),
      401,
      "unauthorized",
    );
    await expectAuthError(
      authorizeDevice(db, "instance-a", `Bearer ${device.token}`, ["control"], after(3)),
      403,
      "forbidden",
    );

    await expect(
      authorizeDevice(
        db,
        "instance-a",
        `Bearer ${device.token}`,
        ["admin" as DeviceScope],
        after(3),
      ),
    ).rejects.toThrow(TypeError);
  });

  it("isolates credentials by instance and records successful authorization", async () => {
    const device = await pair("instance-a", "Controller", ["capture", "control"]);

    await expectAuthError(
      authorizeDevice(db, "instance-b", `Bearer ${device.token}`, ["capture"], after(4)),
      401,
      "unauthorized",
    );
    await expect(
      authorizeDevice(
        db,
        "instance-a",
        `Bearer ${device.token}`,
        ["capture", "control"],
        after(4),
      ),
    ).resolves.toEqual({
      deviceId: device.deviceId,
      deviceName: "Controller",
      instanceId: "instance-a",
      scopes: ["capture", "control"],
    });

    const row = await db.prepare("SELECT last_seen_at FROM devices WHERE id = ?")
      .bind(device.deviceId)
      .first<{ last_seen_at: string | null }>();
    expect(row?.last_seen_at).toBe(after(4).toISOString());
  });

  it("applies revocation on the next request without affecting another instance or device", async () => {
    const target = await pair("instance-a", "Target", ["read"]);
    const sameInstance = await pair("instance-a", "Sibling", ["read"]);
    const otherInstance = await pair("instance-b", "Other", ["read"]);

    expect(await revokeDevice(db, "instance-b", target.deviceId, after(5))).toBe(false);
    await expect(
      authorizeDevice(db, "instance-a", `Bearer ${target.token}`, ["read"], after(5)),
    ).resolves.toMatchObject({ deviceId: target.deviceId });

    expect(await revokeDevice(db, "instance-a", target.deviceId, after(6))).toBe(true);
    await expectAuthError(
      authorizeDevice(db, "instance-a", `Bearer ${target.token}`, ["read"], after(6)),
      403,
      "forbidden",
    );
    await expect(
      authorizeDevice(db, "instance-a", `Bearer ${sameInstance.token}`, ["read"], after(6)),
    ).resolves.toMatchObject({ deviceId: sameInstance.deviceId });
    await expect(
      authorizeDevice(db, "instance-b", `Bearer ${otherInstance.token}`, ["read"], after(6)),
    ).resolves.toMatchObject({ deviceId: otherInstance.deviceId });
  });

  it("never writes credentials to console output or safe error responses", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const device = await pair("instance-b", "Quiet", ["capture"]);
      const failure = await rejected(
        authorizeDevice(db, "instance-a", `Bearer ${device.token}`, ["capture"], after(7)),
      );

      expect(log).not.toHaveBeenCalled();
      expect(warn).not.toHaveBeenCalled();
      expect(error).not.toHaveBeenCalled();
      expect(JSON.stringify(failure)).not.toContain(device.token);
    } finally {
      log.mockRestore();
      warn.mockRestore();
      error.mockRestore();
    }
  });
});

interface PairingRow {
  instance_id: string;
  name: string;
  pairing_code_digest: string | null;
  token_digest: string | null;
  scopes: string;
  pairing_expires_at: string | null;
  claimed_at: string | null;
}

interface ClaimedRow {
  pairing_code_digest: string | null;
  pairing_expires_at: string | null;
  token_digest: string | null;
  claimed_at: string | null;
}

async function insertInstance(id: string, name: string): Promise<void> {
  const timestamp = baseTime.toISOString();
  await db.prepare(
    "INSERT INTO instances (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
  )
    .bind(id, name, timestamp, timestamp)
    .run();
}

async function pair(instanceId: string, name: string, scopes: readonly DeviceScope[]) {
  const minted = await mintPairingCode(
    db,
    { instanceId, deviceName: name, scopes },
    baseTime,
  );
  return claimPairingCode(db, { instanceId, code: minted.code }, after(1));
}

function after(minutes: number): Date {
  return new Date(baseTime.getTime() + minutes * 60_000);
}

async function rejected(promise: Promise<unknown>): Promise<{
  status: number;
  body: unknown;
}> {
  try {
    await promise;
  } catch (caught) {
    expect(caught).toBeInstanceOf(DeviceAuthError);
    const authError = caught as DeviceAuthError;
    const response = authError.toResponse();
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    return { status: response.status, body: await response.json() };
  }
  throw new Error("expected device-auth operation to reject");
}

async function expectAuthError(
  promise: Promise<unknown>,
  status: 401 | 403,
  code: "unauthorized" | "forbidden",
): Promise<void> {
  await expect(rejected(promise)).resolves.toEqual({ status, body: { error: code } });
}

async function allDeviceCount(): Promise<number> {
  const row = await db.prepare("SELECT COUNT(*) AS count FROM devices").first<{ count: number }>();
  return row?.count ?? 0;
}

async function claimedDeviceCount(): Promise<number> {
  const row = await db.prepare("SELECT COUNT(*) AS count FROM devices WHERE claimed_at IS NOT NULL")
    .first<{ count: number }>();
  return row?.count ?? 0;
}

function decodeCredential(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=";
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

function requireBinding<T>(binding: T | undefined, name: string): T {
  if (!binding) throw new Error(`${name} test binding is not configured`);
  return binding;
}
