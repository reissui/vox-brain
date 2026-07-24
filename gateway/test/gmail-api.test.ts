import { applyD1Migrations, env } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import migrationSql from "../migrations/0001_remote_first.sql?raw";
import { claimPairingCode, mintPairingCode, type DeviceScope } from "../src/device-auth";
import {
  handleGmailApi,
  handleGmailCallback,
  handleGmailDisconnect,
  handleGmailStart,
  handleGmailStatus,
  type GmailApiDependencies,
  type GmailApiEnv,
} from "../src/gmail-api";

const migration = {
  name: "0001_remote_first.sql",
  queries: migrationSql
    .replace(/^\s*--.*$/gm, "")
    .split(";")
    .map((query) => query.trim())
    .filter(Boolean),
};

const db = requireBinding(env.DB, "DB");
const instanceId = "gmail-instance";
const callbackUrl = "https://brain.example.test/v1/gmail/callback";
const originUrl = "https://origin.example.test";
const originToken = "origin-token-never-sent-to-a-device";
const stateSecret = "independent-gateway-state-signing-secret";
const baseTime = new Date("2026-07-15T12:00:00.000Z");

let origin: FakeGmailOrigin;
let apiEnv: GmailApiEnv;
let dependencies: GmailApiDependencies;
let controlToken: string;
let secondControlToken: string;
let readToken: string;

beforeAll(async () => {
  await applyD1Migrations(db, [migration]);
  const timestamp = baseTime.toISOString();
  await db.prepare(
    "INSERT INTO instances (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
  )
    .bind(instanceId, "Gmail instance", timestamp, timestamp)
    .run();
});

beforeEach(async () => {
  await db.prepare("DELETE FROM devices").run();
  controlToken = (await pair("Controller", ["control"])).token;
  secondControlToken = (await pair("Second controller", ["control"])).token;
  readToken = (await pair("Reader", ["read"])).token;
  origin = new FakeGmailOrigin();
  apiEnv = {
    DB: db,
    INSTANCE_ID: instanceId,
    ORIGIN_URL: originUrl,
    ORIGIN_TOKEN: originToken,
    GMAIL_CALLBACK_URL: callbackUrl,
    GMAIL_STATE_SECRET: stateSecret,
  };
  dependencies = {
    fetch: origin.fetch,
    now: () => baseTime,
  };
});

describe("POST /v1/gmail/start", () => {
  it("requires control scope, uses the fixed callback, and returns only Google's URL", async () => {
    expect((await start(null)).status).toBe(401);
    expect((await start(readToken)).status).toBe(403);
    expect(origin.calls).toHaveLength(0);

    const response = await start(controlToken);
    expect(response.status).toBe(200);
    const body = await response.json<Record<string, unknown>>();
    expect(Object.keys(body)).toEqual(["authorization_url"]);

    const authorizationUrl = new URL(String(body.authorization_url));
    expect(authorizationUrl.origin + authorizationUrl.pathname).toBe(
      "https://accounts.google.com/o/oauth2/v2/auth",
    );
    expect(authorizationUrl.searchParams.get("redirect_uri")).toBe(callbackUrl);
    expect(authorizationUrl.searchParams.get("state")).not.toBe(origin.lastStartedState);
    expect(authorizationUrl.searchParams.get("state")).toMatch(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    expect(JSON.stringify(body)).not.toContain("client-secret");
    expect(JSON.stringify(body)).not.toContain("access-token");

    expect(origin.calls).toHaveLength(1);
    expect(origin.calls[0]).toEqual({
      url: `${originUrl}/v1/agent/gmail/start`,
      method: "POST",
      token: originToken,
      body: { redirect_uri: callbackUrl },
      redirect: "manual",
    });
  });

  it("binds different device starts into signed state and rejects tampering", async () => {
    const first = await authorizationState(await start(controlToken));
    const second = await authorizationState(await start(secondControlToken));
    expect(first).not.toBe(second);

    const firstPayload = decodeStatePayload(first);
    const secondPayload = decodeStatePayload(second);
    expect(firstPayload).toMatchObject({ v: 1, i: instanceId, s: "origin-state-1" });
    expect(secondPayload).toMatchObject({ v: 1, i: instanceId, s: "origin-state-2" });
    expect(firstPayload.d).not.toBe(secondPayload.d);

    const separator = first.indexOf(".");
    const payload = first.slice(0, separator);
    const signature = first.slice(separator + 1);
    const nonCanonicalSignature = nonCanonicalBase64Url(signature);
    expect(decodeBase64Url(nonCanonicalSignature)).toBe(decodeBase64Url(signature));
    const tamperedStates = [
      `${mutateBase64Url(payload)}.${signature}`,
      `${payload}.${mutateBase64Url(signature)}`,
      `${payload}.${nonCanonicalSignature}`,
    ];
    const before = origin.calls.length;
    for (const tampered of tamperedStates) {
      const response = await callback({ state: tampered, code: "authorization-code" });
      expect(response.status).toBe(400);
      expect(await response.text()).not.toContain(tampered);
    }
    expect(origin.calls).toHaveLength(before);
  });

  it("fails closed when the origin is unavailable or returns an invalid ceremony", async () => {
    origin.connected = true;
    origin.outage = true;
    const unavailable = await start(controlToken);
    expect(unavailable.status).toBe(503);
    expect(await unavailable.json()).toEqual({ error: "gmail origin unavailable" });
    expect(origin.connected).toBe(true);

    origin.outage = false;
    origin.invalidStart = true;
    const invalid = await start(controlToken);
    expect(invalid.status).toBe(503);
    expect(origin.connected).toBe(true);
  });
});

describe("GET /v1/gmail/callback", () => {
  it("relays one successful code to the same origin and renders a bounded page", async () => {
    const state = await authorizationState(await start(controlToken));
    const response = await callback({ state, code: "authorization-code" });
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/html; charset=utf-8");
    expect(response.headers.get("cache-control")).toBe("no-store");
    const page = await response.text();
    expect(page).toContain("Brain Gmail connected");
    expect(page.length).toBeLessThan(1_024);
    expect(page).not.toContain("authorization-code");
    expect(page).not.toContain(state);
    expect(page).not.toContain("refresh-token");

    expect(origin.calls.at(-1)).toEqual({
      url: `${originUrl}/v1/agent/gmail/complete`,
      method: "POST",
      token: originToken,
      body: {
        redirect_uri: callbackUrl,
        state: "origin-state-1",
        code: "authorization-code",
      },
      redirect: "manual",
    });
    expect(origin.connected).toBe(true);

    const replay = await callback({ state, code: "authorization-code" });
    expect(replay.status).toBe(400);
    expect(await replay.text()).toContain("Brain Gmail connection failed");
    expect(origin.completeCalls).toBe(2);
  });

  it("relays Google denial, consumes it once, and rejects every other query shape", async () => {
    const state = await authorizationState(await start(controlToken));
    const denied = await callback({ state, error: "access_denied" });
    expect(denied.status).toBe(400);
    const deniedPage = await denied.text();
    expect(deniedPage).toContain("Brain Gmail connection failed");
    expect(deniedPage).not.toContain("access_denied");
    expect(origin.calls.at(-1)?.body).toEqual({
      redirect_uri: callbackUrl,
      state: "origin-state-1",
      error: "access_denied",
    });

    const replay = await callback({ state, error: "access_denied" });
    expect(replay.status).toBe(400);

    const invalidQueries: Array<Record<string, string>> = [
      { state },
      { code: "code" },
      { state, code: "code", error: "access_denied" },
      { state, code: "code", scope: "gmail" },
    ];
    for (const query of invalidQueries) {
      const before = origin.completeCalls;
      const response = await rawCallback(query);
      expect(response.status).toBe(400);
      expect(origin.completeCalls).toBe(before);
    }
  });

  it("rejects expired state before the origin and lets an outage retry safely", async () => {
    const expiredState = await authorizationState(await start(controlToken));
    dependencies.now = () => new Date(baseTime.getTime() + 11 * 60_000);
    const beforeExpired = origin.completeCalls;
    expect((await callback({ state: expiredState, code: "authorization-code" })).status).toBe(400);
    expect(origin.completeCalls).toBe(beforeExpired);

    dependencies.now = () => baseTime;
    const retryState = await authorizationState(await start(secondControlToken));
    origin.connected = true;
    origin.outage = true;
    const unavailable = await callback({ state: retryState, code: "authorization-code" });
    expect(unavailable.status).toBe(503);
    expect(origin.connected).toBe(true);
    expect(origin.pending.has("origin-state-2")).toBe(true);

    origin.outage = false;
    const retried = await callback({ state: retryState, code: "authorization-code" });
    expect(retried.status).toBe(200);
    expect(origin.pending.has("origin-state-2")).toBe(false);
  });
});

describe("GET /v1/gmail/status", () => {
  it("requires read scope and returns only the closed public status shapes", async () => {
    expect((await status(null)).status).toBe(401);
    expect((await status(controlToken)).status).toBe(403);
    expect(origin.calls).toHaveLength(0);

    origin.status = "disconnected";
    expect(await jsonBody(await status(readToken))).toEqual({ status: "disconnected" });

    origin.status = "connected";
    origin.account = "owner@example.test";
    const connected = await status(readToken);
    expect(connected.status).toBe(200);
    expect(await jsonBody(connected)).toEqual({
      status: "connected",
      account: "owner@example.test",
    });

    origin.status = "reconnect_required";
    expect(await jsonBody(await status(readToken))).toEqual({ status: "reconnect_required" });

    origin.status = "denied";
    expect(await jsonBody(await status(readToken))).toEqual({ status: "denied" });

    origin.status = "expired";
    expect(await jsonBody(await status(readToken))).toEqual({ status: "expired" });

    origin.outage = true;
    const unavailable = await status(readToken);
    expect(unavailable.status).toBe(503);
    expect(await jsonBody(unavailable)).toEqual({ status: "origin_unavailable" });
  });

  it("whitelists origin status and never reflects token or message fields", async () => {
    origin.status = "connected";
    const response = await status(readToken);
    const rendered = JSON.stringify(await response.json());
    for (const secret of [
      "client-secret",
      "authorization-code",
      "access-token",
      "refresh-token",
      "mailbox-message-body",
      "mailbox-thread-body",
    ]) {
      expect(rendered).not.toContain(secret);
    }
  });
});

describe("POST /v1/gmail/disconnect", () => {
  it("requires control scope and one exact explicit confirmation", async () => {
    expect((await disconnect(null, { confirm: true })).status).toBe(401);
    expect((await disconnect(readToken, { confirm: true })).status).toBe(403);

    for (const body of [{}, { confirm: false }, { confirm: true, operation: "other" }, null]) {
      const response = await disconnect(controlToken, body);
      expect(response.status).toBe(422);
    }
    expect(origin.calls).toHaveLength(0);

    origin.connected = true;
    const response = await disconnect(controlToken, { confirm: true });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "disconnected" });
    expect(origin.connected).toBe(false);
    expect(origin.calls).toEqual([{
      url: `${originUrl}/v1/agent/gmail/disconnect`,
      method: "POST",
      token: originToken,
      body: {},
      redirect: "manual",
    }]);
  });
});

describe("closed routing and secret-free boundaries", () => {
  it("routes only the fixed methods and never writes Gmail material to storage or logs", async () => {
    expect((await handleGmailApi(new Request("https://brain.example.test/v1/gmail/other"), apiEnv)).status)
      .toBe(404);
    expect((await handleGmailApi(new Request("https://brain.example.test/v1/gmail/start"), apiEnv)).status)
      .toBe(405);
    expect((await handleGmailApi(new Request(callbackUrl, { method: "POST" }), apiEnv)).status)
      .toBe(405);

    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const state = await authorizationState(await start(controlToken));
      await callback({ state, code: "authorization-code" });
      expect(log).not.toHaveBeenCalled();
      expect(warn).not.toHaveBeenCalled();
      expect(error).not.toHaveBeenCalled();
    } finally {
      log.mockRestore();
      warn.mockRestore();
      error.mockRestore();
    }

    const schema = await db.prepare(
      "SELECT sql FROM sqlite_master WHERE type IN ('table', 'index') ORDER BY name",
    ).all<{ sql: string | null }>();
    const stored = JSON.stringify(schema.results).toLowerCase();
    for (const forbidden of [
      "client_secret",
      "authorization_code",
      "access_token",
      "refresh_token",
      "message_body",
      "thread_body",
    ]) {
      expect(stored).not.toContain(forbidden);
    }
  });
});

interface OriginCall {
  url: string;
  method: string;
  token: string | null;
  body: Record<string, unknown> | null;
  redirect: RequestInit["redirect"];
}

class FakeGmailOrigin {
  readonly calls: OriginCall[] = [];
  readonly pending = new Set<string>();
  connected = false;
  outage = false;
  invalidStart = false;
  completeCalls = 0;
  status: "disconnected" | "connected" | "reconnect_required" | "denied" | "expired" = "disconnected";
  account = "owner@example.test";
  lastStartedState = "";

  fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    if (this.outage) throw new Error("injected origin outage");
    const headers = new Headers(init?.headers);
    const method = init?.method ?? "GET";
    const body = typeof init?.body === "string"
      ? JSON.parse(init.body) as Record<string, unknown>
      : null;
    const call: OriginCall = {
      url: String(input),
      method,
      token: headers.get("x-brain-origin-token"),
      body,
      redirect: init?.redirect,
    };
    this.calls.push(call);
    expect(call.token).toBe(originToken);

    const operation = new URL(call.url).pathname.split("/").at(-1);
    if (operation === "start") {
      const state = `origin-state-${this.pending.size + 1}`;
      this.lastStartedState = state;
      this.pending.add(state);
      if (this.invalidStart) {
        return originResponse(200, {
          authorization_url: "https://evil.example/authorize",
          state,
          expires_at: epoch(baseTime) + 600,
        });
      }
      const authorization = new URL("https://accounts.google.com/o/oauth2/v2/auth");
      authorization.searchParams.set("client_id", "public-client-id");
      authorization.searchParams.set("redirect_uri", String(body?.redirect_uri));
      authorization.searchParams.set("scope", "https://www.googleapis.com/auth/gmail.readonly");
      authorization.searchParams.set("state", state);
      return originResponse(200, {
        authorization_url: authorization.toString(),
        state,
        expires_at: epoch(baseTime) + 600,
        client_secret: "client-secret",
        access_token: "access-token",
      });
    }
    if (operation === "complete") {
      this.completeCalls += 1;
      const state = String(body?.state ?? "");
      if (body?.redirect_uri !== callbackUrl || !this.pending.has(state)) {
        return originResponse(400, {
          error: { code: "invalid_authorization", detail: "authorization-code refresh-token" },
        });
      }
      this.pending.delete(state);
      if (body?.error) {
        return originResponse(400, { error: { code: "authorization_denied" } });
      }
      this.connected = true;
      this.status = "connected";
      return originResponse(200, {
        status: "connected",
        access_token: "access-token",
        refresh_token: "refresh-token",
      });
    }
    if (operation === "status") {
      return originResponse(200, {
        status: this.status,
        account: this.account,
        client_secret: "client-secret",
        access_token: "access-token",
        refresh_token: "refresh-token",
        message_body: "mailbox-message-body",
        thread_body: "mailbox-thread-body",
      });
    }
    if (operation === "disconnect") {
      this.connected = false;
      this.status = "disconnected";
      return originResponse(200, { status: "disconnected", refresh_token: "refresh-token" });
    }
    return originResponse(404, { error: "not found" });
  };
}

async function start(token: string | null): Promise<Response> {
  const headers = new Headers();
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return handleGmailStart(
    new Request("https://untrusted-host.test/v1/gmail/start", { method: "POST", headers }),
    apiEnv,
    dependencies,
  );
}

async function callback(result: { state: string; code: string } | { state: string; error: string }) {
  return rawCallback(result);
}

async function rawCallback(query: Record<string, string>): Promise<Response> {
  const url = new URL(callbackUrl);
  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
  return handleGmailCallback(new Request(url), apiEnv, dependencies);
}

async function status(token: string | null): Promise<Response> {
  const headers = new Headers();
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return handleGmailStatus(
    new Request("https://brain.example.test/v1/gmail/status", { headers }),
    apiEnv,
    dependencies,
  );
}

async function disconnect(token: string | null, body: unknown): Promise<Response> {
  const headers = new Headers({ "content-type": "application/json" });
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return handleGmailDisconnect(
    new Request("https://brain.example.test/v1/gmail/disconnect", {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    }),
    apiEnv,
    dependencies,
  );
}

async function authorizationState(response: Response): Promise<string> {
  expect(response.status).toBe(200);
  const body = await response.json<{ authorization_url: string }>();
  const state = new URL(body.authorization_url).searchParams.get("state");
  expect(state).toBeTruthy();
  return state ?? "";
}

function decodeStatePayload(value: string): Record<string, unknown> {
  const encoded = value.split(".")[0] ?? "";
  return JSON.parse(decodeBase64Url(encoded)) as Record<string, unknown>;
}

function decodeBase64Url(value: string): string {
  const padding = "=".repeat((4 - value.length % 4) % 4);
  return atob(value.replace(/-/g, "+").replace(/_/g, "/") + padding);
}

function mutateBase64Url(value: string): string {
  return `${value.startsWith("A") ? "B" : "A"}${value.slice(1)}`;
}

function nonCanonicalBase64Url(value: string): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  const lastIndex = alphabet.indexOf(value.at(-1) ?? "");
  if (value.length % 4 !== 3 || lastIndex < 0 || lastIndex % 4 !== 0) {
    throw new Error("expected a canonical unpadded base64url value with two unused bits");
  }
  return `${value.slice(0, -1)}${alphabet[lastIndex + 1]}`;
}

function originResponse(status: number, value: unknown): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function pair(name: string, scopes: readonly DeviceScope[]) {
  const minted = await mintPairingCode(db, { instanceId, deviceName: name, scopes }, baseTime);
  return claimPairingCode(
    db,
    { instanceId, code: minted.code },
    new Date(baseTime.getTime() + 1_000),
  );
}

async function jsonBody(response: Response): Promise<unknown> {
  const rendered = await response.text();
  for (const forbidden of [
    "client-secret",
    "authorization-code",
    "access-token",
    "refresh-token",
    "mailbox-message-body",
    "mailbox-thread-body",
  ]) {
    expect(rendered).not.toContain(forbidden);
  }
  return JSON.parse(rendered) as unknown;
}

function epoch(value: Date): number {
  return Math.floor(value.getTime() / 1_000);
}

function requireBinding<T>(binding: T | undefined, name: string): T {
  if (!binding) throw new Error(`${name} test binding is not configured`);
  return binding;
}
