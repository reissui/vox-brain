import { applyD1Migrations, env } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import migrationSql from "../migrations/0001_remote_first.sql?raw";
import {
  CAPTURE_STATES,
  JOB_STATES,
  MAX_SITE_URL_BYTES,
  parseCaptureState,
  parseJobState,
  parseSiteUrl,
  validateStatusSiteUrl,
} from "../src/remote-contract";

const migration = {
  name: "0001_remote_first.sql",
  queries: migrationSql
    .replace(/^\s*--.*$/gm, "")
    .split(";")
    .map((query) => query.trim())
    .filter(Boolean),
};

const now = "2026-07-15T12:34:56.789Z";
const db = requireBinding(env.DB, "DB");

beforeAll(async () => {
  await applyD1Migrations(db, [migration]);
  // Only the migration ledger makes a second application a safe no-op.
  await applyD1Migrations(db, [migration]);
});

describe("remote-first D1 migration", () => {
  it("creates only the five operational tables", async () => {
    const result = await db.prepare(
      "SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE ? AND name != ? ORDER BY name",
    )
      .bind("table", "sqlite_%", "_cf_METADATA")
      .all<{ name: string }>();

    expect(result.results.map(({ name }) => name)).toEqual([
      "captures",
      "d1_migrations",
      "devices",
      "heartbeats",
      "instances",
      "jobs",
    ]);
  });

  it("enforces foreign keys and per-instance idempotency", async () => {
    await db.prepare(
      "INSERT INTO instances (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
    )
      .bind("instance-a", "A", now, now)
      .run();
    await db.prepare(
      "INSERT INTO instances (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
    )
      .bind("instance-b", "B", now, now)
      .run();
    await db.prepare(
      `INSERT INTO devices
        (id, instance_id, name, token_digest, scopes, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind("device-a", "instance-a", "Mac", "digest-a", '["capture"]', now, now)
      .run();
    await db.prepare(
      `INSERT INTO devices
        (id, instance_id, name, token_digest, scopes, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind("device-b", "instance-b", "Mac", "digest-b", '["capture"]', now, now)
      .run();

    await insertCapture("capture-a", "instance-a", "device-a", "same-key");
    await insertCapture("capture-b", "instance-b", "device-b", "same-key");

    await expect(
      insertCapture("capture-duplicate", "instance-a", "device-a", "same-key"),
    ).rejects.toThrow(/UNIQUE constraint failed/);
    await expect(
      insertCapture("capture-orphan", "missing", "device-a", "another-key"),
    ).rejects.toThrow(/FOREIGN KEY constraint failed/);
  });

  it("creates the pending-work and latest-heartbeat indexes", async () => {
    const result = await db.prepare(
      "SELECT name FROM sqlite_master WHERE type = ? AND name IN (?, ?, ?) ORDER BY name",
    )
      .bind("index", "idx_captures_pending", "idx_jobs_pending", "idx_heartbeats_latest")
      .all<{ name: string }>();

    expect(result.results.map(({ name }) => name)).toEqual([
      "idx_captures_pending",
      "idx_heartbeats_latest",
      "idx_jobs_pending",
    ]);
  });

  it("rejects invalid states and non-UTC timestamps at the database boundary", async () => {
    await expect(
      insertCapture("capture-invalid", "instance-a", "device-a", "invalid-state", "unknown"),
    ).rejects.toThrow(/CHECK constraint failed/);

    await expect(
      db.prepare(
        "INSERT INTO heartbeats (id, instance_id, agent_version, status_json, observed_at) VALUES (?, ?, ?, ?, ?)",
      )
        .bind("heartbeat-local", "instance-a", "1", "{}", "2026-07-15T12:34:56+01:00")
        .run(),
    ).rejects.toThrow(/CHECK constraint failed/);
  });

  it("contains no canonical knowledge or Gmail secret columns", async () => {
    const forbidden = new Set([
      "body",
      "markdown",
      "markdown_body",
      "note_body",
      "message_body",
      "gmail_message_body",
      "refresh_token",
      "gmail_refresh_token",
    ]);

    for (const table of ["instances", "devices", "captures", "jobs", "heartbeats"]) {
      const columns = await db.prepare(`PRAGMA table_info(${table})`).all<{ name: string }>();
      expect(columns.results.map(({ name }) => name).filter((name) => forbidden.has(name))).toEqual([]);
    }
  });

  it("is forward-only outside Wrangler's migration ledger", async () => {
    await expect(db.prepare(migration.queries[0]!).run()).rejects.toThrow(/already exists/);
    expect(migration.queries.every((query) => /^CREATE\b/i.test(query))).toBe(true);
  });
});

describe("remote state parsers", () => {
  it("accepts every capture and job state in the exact closed sets", () => {
    expect(CAPTURE_STATES).toEqual([
      "queued",
      "delivering",
      "delivered",
      "processing",
      "needs_attention",
      "completed",
      "failed",
    ]);
    expect(JOB_STATES).toEqual(["queued", "running", "completed", "failed", "cancelled"]);

    for (const state of CAPTURE_STATES) expect(parseCaptureState(state)).toBe(state);
    for (const state of JOB_STATES) expect(parseJobState(state)).toBe(state);
  });

  it("rejects every value outside the closed sets", () => {
    for (const invalid of [undefined, null, "", "pending", "done", "QUEUED", 0, {}, []]) {
      expect(() => parseCaptureState(invalid)).toThrow(TypeError);
      expect(() => parseJobState(invalid)).toThrow(TypeError);
    }
    for (const jobOnly of ["running", "cancelled"]) {
      expect(() => parseCaptureState(jobOnly)).toThrow(TypeError);
    }
    for (const captureOnly of ["delivering", "delivered", "processing", "needs_attention"]) {
      expect(() => parseJobState(captureOnly)).toThrow(TypeError);
    }
  });

  it("accepts only the bounded HTTPS private-site contract and preserves the exact URL", () => {
    const exact = "https://private.example.test/brain";
    expect(parseSiteUrl(exact)).toBe(exact);
    expect(validateStatusSiteUrl({ schema_version: 1 })).toEqual({ schema_version: 1 });
    expect(validateStatusSiteUrl({ site_url: exact })).toEqual({ site_url: exact });

    for (const invalid of [
      undefined,
      null,
      "",
      "http://private.example.test",
      "https://user:secret@private.example.test",
      "https://private.example.test?token=secret",
      "https://private.example.test#fragment",
      "https://private.example.test\\@attacker.test",
      "https://private.example.test:99999",
      "x".repeat(MAX_SITE_URL_BYTES + 1),
    ]) {
      expect(() => parseSiteUrl(invalid)).toThrow(TypeError);
      expect(validateStatusSiteUrl({ site_url: invalid })).toBeNull();
    }
  });
});

function insertCapture(
  id: string,
  instanceId: string,
  deviceId: string,
  idempotencyKey: string,
  state = "queued",
): Promise<D1Result> {
  return db.prepare(
    `INSERT INTO captures
      (id, instance_id, device_id, idempotency_key, payload_digest, capture_type, source, state,
       captured_at, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      id,
      instanceId,
      deviceId,
      idempotencyKey,
      `digest-${id}`,
      "note",
      "test",
      state,
      now,
      now,
      now,
    )
    .run();
}

function requireBinding<T>(binding: T | undefined, name: string): T {
  if (!binding) throw new Error(`${name} test binding is not configured`);
  return binding;
}
