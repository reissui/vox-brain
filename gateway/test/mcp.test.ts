/**
 * Regression suite for issue #5 — the remote MCP server at /mcp.
 *
 * Integration-style, like capture.test.ts: everything goes through the real
 * entrypoint via `exports.default.fetch()` — dynamic client registration,
 * the /authorize password screen, the /token exchange (PKCE), direct password
 * bearer auth, and MCP over streamable HTTP (hand-rolled JSON-RPC + SSE
 * parsing, no client SDK). Outbound capture PUTs and fixed authenticated Brain
 * Agent knowledge reads are recorded through one global fetch stub.
 */

import { applyD1Migrations, env } from "cloudflare:test";
import { exports as worker } from "cloudflare:workers";
import { afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { vi } from "vitest";
import migrationSql from "../migrations/0001_remote_first.sql?raw";
import captureResultMigrationSql from "../migrations/0002_capture_delivery_results.sql?raw";
import permanentObjectMigrationSql from "../migrations/0003_permanent_capture_objects.sql?raw";
import { RETRIEVAL_DISCLAIMER } from "../src/mcp";

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

/** Must stay in sync with the miniflare bindings in vitest.config.ts. */
const MCP_PASSWORD = "test-mcp-password";
const INSTANCE_ID = "example-instance";

const BASE = "https://brain-gw.test";
const REDIRECT_URI = "https://client.test/callback";

// ---------------------------------------------------------------------------
// Outbound GitHub mock (global fetch stub — the worker runs in this isolate).
// ---------------------------------------------------------------------------

interface RecordedPut {
  url: string;
  method: string;
  authorization: string | null;
  body: { message: string; content: string };
}

interface RecordedSearch {
  url: string;
  accept: string | null;
  authorization: string | null;
  originToken?: string | null;
}

let githubPuts: RecordedPut[];
let githubSearches: RecordedSearch[];
let githubSearchStatus: number;
let githubSearchBody: unknown;
let agentSearches: RecordedSearch[];
let agentSearchStatus: number;
let agentSearchBody: unknown;

beforeAll(async () => {
  await applyD1Migrations(requireBinding(env.DB, "DB"), migrations);
  const now = new Date().toISOString();
  await requireBinding(env.DB, "DB").prepare(
    `INSERT OR IGNORE INTO instances (id, name, created_at, updated_at)
     VALUES (?, ?, ?, ?)`,
  ).bind(INSTANCE_ID, "MCP test instance", now, now).run();
});

beforeEach(async () => {
  await requireBinding(env.DB, "DB").prepare("DELETE FROM captures").run();
  await requireBinding(env.DB, "DB").prepare("DELETE FROM devices").run();
  githubPuts = [];
  githubSearches = [];
  githubSearchStatus = 200;
  githubSearchBody = { total_count: 0, items: [] };
  agentSearches = [];
  agentSearchStatus = 200;
  agentSearchBody = { results: [] };

  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request = new Request(input, init);
    const url = new URL(request.url);

    if (url.hostname === "api.github.com" && url.pathname === "/search/code") {
      githubSearches.push({
        url: request.url,
        accept: request.headers.get("accept"),
        authorization: request.headers.get("authorization"),
      });
      return new Response(JSON.stringify(githubSearchBody), {
        status: githubSearchStatus,
        headers: { "content-type": "application/json" },
      });
    }

    if (url.hostname === "brain-origin.example.com" && url.pathname === "/v1/knowledge/search") {
      agentSearches.push({
        url: request.url,
        accept: request.headers.get("accept"),
        authorization: request.headers.get("authorization"),
        originToken: request.headers.get("x-brain-origin-token"),
      });
      const body = agentSearchBody as { results?: unknown };
      return new Response(JSON.stringify({
        query: url.searchParams.get("q"),
        results: body.results ?? [],
      }), {
        status: agentSearchStatus,
        headers: { "content-type": "application/json" },
      });
    }

    if (url.hostname !== "api.github.com") throw new Error("unexpected outbound request");
    githubPuts.push({
      url: request.url,
      method: request.method,
      authorization: request.headers.get("authorization"),
      body: JSON.parse(await request.text()) as RecordedPut["body"],
    });
    return new Response(JSON.stringify({ content: { path: "unused" } }), {
      status: 201,
      headers: { "content-type": "application/json" },
    });
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function requireBinding<T>(value: T | undefined, name: string): T {
  if (!value) throw new Error(`${name} test binding is unavailable`);
  return value;
}

async function captureCount(): Promise<number> {
  const row = await requireBinding(env.DB, "DB").prepare(
    "SELECT COUNT(*) AS count FROM captures",
  ).first<{ count: number }>();
  return row?.count ?? 0;
}

async function onlyCapture(): Promise<Record<string, unknown>> {
  const result = await requireBinding(env.DB, "DB").prepare(
    `SELECT id, instance_id, device_id, capture_type, source, state,
            object_key, object_sha256, object_content_type, object_byte_length,
            object_filename, object_retention_state
       FROM captures`,
  ).all<Record<string, unknown>>();
  expect(result.results).toHaveLength(1);
  return result.results[0]!;
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

// ---------------------------------------------------------------------------
// OAuth flow helpers (dynamic registration → /authorize password → /token).
// ---------------------------------------------------------------------------

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function pkcePair(): Promise<{ verifier: string; challenge: string }> {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const verifier = base64url(bytes);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: base64url(new Uint8Array(digest)) };
}

async function registerClient(): Promise<string> {
  const response = await worker.default.fetch(
    new Request(`${BASE}/register`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        client_name: "vitest",
        redirect_uris: [REDIRECT_URI],
        token_endpoint_auth_method: "none",
      }),
    }),
  );
  expect(response.status).toBe(201);
  const body = (await response.json()) as { client_id: string };
  return body.client_id;
}

/** GET /authorize (password form) then POST it back with `password`. */
async function submitAuthorize(clientId: string, challenge: string, password: string): Promise<Response> {
  const query = new URLSearchParams({
    response_type: "code",
    client_id: clientId,
    redirect_uri: REDIRECT_URI,
    state: "test-state",
    code_challenge: challenge,
    code_challenge_method: "S256",
    scope: "brain",
  });
  const page = await worker.default.fetch(new Request(`${BASE}/authorize?${query}`));
  expect(page.status).toBe(200);
  const html = await page.text();
  const hidden = html.match(/name="oauth" value="([^"]+)"/);
  expect(hidden).not.toBeNull();

  return worker.default.fetch(
    new Request(`${BASE}/authorize`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ oauth: hidden![1]!, password }).toString(),
      // Don't follow the 302 to the client's redirect_uri — the test wants it.
      redirect: "manual",
    }),
  );
}

/** The whole flow: register → authorize with the right password → token. */
async function getAccessToken(): Promise<string> {
  const clientId = await registerClient();
  const { verifier, challenge } = await pkcePair();

  const redirect = await submitAuthorize(clientId, challenge, MCP_PASSWORD);
  expect(redirect.status).toBe(302);
  const location = new URL(redirect.headers.get("location")!);
  expect(location.origin + location.pathname).toBe(REDIRECT_URI);
  expect(location.searchParams.get("state")).toBe("test-state");
  const code = location.searchParams.get("code");
  expect(code).toBeTruthy();

  const tokenResponse = await worker.default.fetch(
    new Request(`${BASE}/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        code: code!,
        redirect_uri: REDIRECT_URI,
        client_id: clientId,
        code_verifier: verifier,
      }).toString(),
    }),
  );
  expect(tokenResponse.status).toBe(200);
  const tokenBody = (await tokenResponse.json()) as { access_token: string };
  expect(tokenBody.access_token).toBeTruthy();
  return tokenBody.access_token;
}

// ---------------------------------------------------------------------------
// Minimal MCP client over streamable HTTP (JSON-RPC via POST, SSE responses).
// ---------------------------------------------------------------------------

interface McpSession {
  token: string;
  sessionId?: string;
  protocolVersion?: string;
}

function mcpPost(session: McpSession, body: unknown): Promise<Response> {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    accept: "application/json, text/event-stream",
    authorization: `Bearer ${session.token}`,
  };
  if (session.sessionId) headers["mcp-session-id"] = session.sessionId;
  if (session.protocolVersion) headers["mcp-protocol-version"] = session.protocolVersion;
  return worker.default.fetch(
    new Request(`${BASE}/mcp`, { method: "POST", headers, body: JSON.stringify(body) }),
  );
}

/**
 * Read JSON-RPC message `id` from a streamable-HTTP response (plain JSON or
 * SSE). Cancels the stream once found, so it works whether or not the server
 * closes the stream after responding.
 */
async function readMcpMessage(
  response: Response,
  id: number,
): Promise<{ result?: any; error?: { message: string } }> {
  const contentType = response.headers.get("content-type") ?? "";
  if (contentType.includes("application/json")) {
    return (await response.json()) as any;
  }
  expect(contentType).toContain("text/event-stream");

  const reader = response.body!.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { done, value } = await reader.read();
    if (value) buffer += decoder.decode(value, { stream: true });

    let boundary: number;
    while ((boundary = buffer.indexOf("\n\n")) !== -1) {
      const rawEvent = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      for (const line of rawEvent.split("\n")) {
        if (!line.startsWith("data:")) continue;
        const message = JSON.parse(line.slice("data:".length).trim());
        if (message.id === id) {
          await reader.cancel().catch(() => {});
          return message;
        }
      }
    }
    if (done) break;
  }
  throw new Error(`no JSON-RPC response with id ${id} in SSE stream`);
}

let nextRequestId = 1;

/** initialize + notifications/initialized against an explicit or fresh OAuth token. */
async function connect(token?: string): Promise<McpSession> {
  const session: McpSession = { token: token ?? (await getAccessToken()) };

  const initId = nextRequestId++;
  const initResponse = await mcpPost(session, {
    jsonrpc: "2.0",
    id: initId,
    method: "initialize",
    params: {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "vitest", version: "0.0.0" },
    },
  });
  expect(initResponse.status).toBe(200);
  session.sessionId = initResponse.headers.get("mcp-session-id") ?? undefined;
  expect(session.sessionId).toBeTruthy();

  const initMessage = await readMcpMessage(initResponse, initId);
  expect(initMessage.error).toBeUndefined();
  session.protocolVersion = initMessage.result.protocolVersion;

  const initialized = await mcpPost(session, { jsonrpc: "2.0", method: "notifications/initialized" });
  expect([200, 202]).toContain(initialized.status);
  return session;
}

async function rpc(session: McpSession, method: string, params?: unknown): Promise<any> {
  const id = nextRequestId++;
  const response = await mcpPost(session, { jsonrpc: "2.0", id, method, params });
  expect(response.status).toBe(200);
  const message = await readMcpMessage(response, id);
  expect(message.error).toBeUndefined();
  return message.result;
}

async function callTool(
  session: McpSession,
  name: string,
  args: Record<string, unknown>,
): Promise<{ content: Array<{ type: string; text: string }>; isError?: boolean }> {
  return rpc(session, "tools/call", { name, arguments: args });
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

describe("/mcp auth", () => {
  it("rejects unauthenticated requests", async () => {
    const response = await mcpPost(
      { token: "" },
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    );
    expect(response.status).toBe(401);
  });

  it("rejects a made-up bearer token", async () => {
    const response = await mcpPost(
      { token: "not-a-real-token" },
      { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
    );
    expect(response.status).toBe(401);
  });

  it("rejects the wrong password at /authorize without issuing a code", async () => {
    const clientId = await registerClient();
    const { challenge } = await pkcePair();
    const response = await submitAuthorize(clientId, challenge, "wrong-password");
    expect(response.status).toBe(401);
    expect(response.headers.get("location")).toBeNull();
    expect(await response.text()).toContain("Wrong password");
  });

  it("issues a token for the right password that authenticates MCP calls", async () => {
    const session = await connect();
    const result = await rpc(session, "tools/list");
    expect(result.tools.length).toBeGreaterThan(0);
  });

  it("accepts the MCP password directly as a bearer token without OAuth", async () => {
    const session = await connect(MCP_PASSWORD);
    const result = await rpc(session, "tools/list");
    expect(result.tools.length).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// Server metadata
// ---------------------------------------------------------------------------

describe("tools/list", () => {
  it("lists durable link, note, file, transcript, and retrieval tools", async () => {
    const session = await connect();
    const { tools } = await rpc(session, "tools/list");

    const byName = new Map<string, any>(tools.map((tool: any) => [tool.name, tool]));
    expect([...byName.keys()].sort()).toEqual([
      "brain_add",
      "brain_ask",
      "brain_file",
      "brain_note",
      "brain_project",
      "brain_transcript",
    ]);

    const add = byName.get("brain_add")!;
    expect(add.inputSchema.properties.url.type).toBe("string");
    expect(add.inputSchema.properties.note.type).toBe("string");
    expect(add.inputSchema.properties.comment.type).toBe("string");
    expect(add.inputSchema.properties.subject.type).toBe("string");
    expect(add.inputSchema.properties.source_context.type).toBe("string");
    expect(add.inputSchema.required).toEqual(["url"]);

    const note = byName.get("brain_note")!;
    expect(note.inputSchema.properties.text.type).toBe("string");
    expect(note.inputSchema.required).toEqual(["text"]);

    const file = byName.get("brain_file")!;
    expect(file.inputSchema.required).toEqual(["filename", "content_type", "base64"]);

    const project = byName.get("brain_project")!;
    expect(project.inputSchema.properties.project.type).toBe("string");
    expect(project.inputSchema.properties.question.type).toBe("string");
    expect(project.inputSchema.required).toEqual(["project"]);

    const transcript = byName.get("brain_transcript")!;
    expect(transcript.inputSchema.required).toEqual(["transcript"]);

    const ask = byName.get("brain_ask")!;
    expect(ask.inputSchema.properties.question.type).toBe("string");
    expect(ask.inputSchema.required).toEqual(["question"]);
    expect(ask.description).toBe("Returns matching notes from the owner's knowledge vault (retrieval only).");
  });
});

// ---------------------------------------------------------------------------
// MCP writes — shared durable D1/R2/Queue capture path
// ---------------------------------------------------------------------------

describe("durable MCP captures", () => {
  it("brain_add creates an MCP-attributed durable capture instead of writing GitHub", async () => {
    const session = await connect();
    const args = {
      url: "https://example.com/essay",
      comment: "sharp take on agents",
      title: "An essay about agents",
      subject: "Brain",
      source_context: "Codex · MCP planning",
    };

    const result = await callTool(session, "brain_add", args);
    expect(result.isError).toBeFalsy();

    const row = await onlyCapture();
    expect(row).toMatchObject({
      instance_id: INSTANCE_ID,
      capture_type: "article",
      source: "MCP · Codex · MCP planning",
      state: "queued",
      object_key: null,
    });
    expect(result.content[0]!.text).toBe(
      `Queued in Brain as ${row.id}. It is visible in Activity.`,
    );
    expect(githubPuts).toHaveLength(0);
  });

  it("brain_note keeps legacy calls working and defaults the visible source to MCP", async () => {
    const session = await connect();
    const result = await callTool(session, "brain_note", {
      text: "idea: the gateway should also accept voice memos",
    });
    expect(result.isError).toBeFalsy();

    expect(await onlyCapture()).toMatchObject({
      capture_type: "note",
      source: "MCP",
      state: "queued",
    });
    expect(githubPuts).toHaveLength(0);
  });

  it("brain_file retains the immutable original in R2", async () => {
    const session = await connect();
    const original = new TextEncoder().encode("durable attachment bytes");
    const result = await callTool(session, "brain_file", {
      filename: "Planning notes.txt",
      content_type: "text/plain",
      base64: base64(original),
      comment: "Keep this with the planning subject",
      subject: "Planning",
      source_context: "Claude",
    });
    expect(result.isError).toBeFalsy();

    const row = await onlyCapture();
    expect(row).toMatchObject({
      capture_type: "note",
      source: "MCP · Claude",
      state: "queued",
      object_content_type: "text/plain",
      object_filename: "Planning notes.txt",
      object_byte_length: original.byteLength,
      object_retention_state: "permanent",
    });
    const object = await requireBinding(env.CAPTURE_OBJECTS, "CAPTURE_OBJECTS").get(
      String(row.object_key),
    );
    expect(new Uint8Array(await object!.arrayBuffer())).toEqual(original);
    expect(githubPuts).toHaveLength(0);
  });

  it("brain_transcript stages transcript text as a permanent capture object", async () => {
    const session = await connect();
    const transcript = "Speaker A: durable words\nSpeaker B: kept verbatim";
    const result = await callTool(session, "brain_transcript", {
      transcript,
      filename: "Weekly sync.txt",
      title: "Weekly sync",
      subject: "Brain",
    });
    expect(result.isError).toBeFalsy();

    const row = await onlyCapture();
    expect(row).toMatchObject({
      capture_type: "transcript",
      source: "MCP",
      object_filename: "Weekly sync.txt",
      object_content_type: "text/plain; charset=utf-8",
      object_retention_state: "permanent",
    });
    const object = await requireBinding(env.CAPTURE_OBJECTS, "CAPTURE_OBJECTS").get(
      String(row.object_key),
    );
    expect(await object!.text()).toBe(transcript);
  });

  it("brain_add reports invalid input as a tool error without writing", async () => {
    const session = await connect();
    const result = await callTool(session, "brain_add", { url: "   " });
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toContain("at least one of url or text");
    expect(await captureCount()).toBe(0);
  });

  it("brain_add rejects conflicting legacy and current comment fields", async () => {
    const session = await connect();
    const result = await callTool(session, "brain_add", {
      url: "https://example.com",
      note: "legacy",
      comment: "current",
    });
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toContain("use either comment or legacy note");
    expect(await captureCount()).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// brain_ask — retrieval over the live paired Brain Agent
// ---------------------------------------------------------------------------

describe("brain_ask", () => {
  it("returns at most five live Agent hits and never calls GitHub search", async () => {
    const resultFixture = (name: string, index: number) => ({
      path: `sources/${name}.md`,
      title: name,
      snippet: `…fragment ${index} about design inspiration…`,
    });
    agentSearchBody = {
      results: [0, 1, 2, 3, 4, 5].map((index) =>
        resultFixture(`Design Inspiration ${index}`, index)
      ),
    };

    const session = await connect();
    const result = await callTool(session, "brain_ask", {
      question: "what do I know about design inspiration",
    });
    expect(result.isError).toBeFalsy();

    expect(agentSearches).toHaveLength(1);
    const search = new URL(agentSearches[0]!.url);
    expect(search.origin).toBe("https://brain-origin.example.com");
    expect(search.pathname).toBe("/v1/knowledge/search");
    expect(search.searchParams.get("q")).toBe("design");
    expect(search.searchParams.get("limit")).toBe("5");
    expect(agentSearches[0]!.originToken).toBe("test-origin-token");
    expect(agentSearches[0]!.authorization).toBeNull();
    expect(githubSearches).toHaveLength(0);

    const text = result.content[0]!.text;
    expect(text.startsWith(RETRIEVAL_DISCLAIMER)).toBe(true);

    const hits = JSON.parse(text.slice(RETRIEVAL_DISCLAIMER.length)) as Array<Record<string, unknown>>;
    expect(hits).toHaveLength(5);
    for (const [index, hit] of hits.entries()) {
      expect(Object.keys(hit).sort()).toEqual(["fragment", "path", "title"]);
      expect(hit.path).toBe(`sources/Design Inspiration ${index}.md`);
      expect(hit.title).toBe(`Design Inspiration ${index}`);
      expect(hit.fragment).toBe(`…fragment ${index} about design inspiration…`);
    }
  });

  it("surfaces paired Agent unavailability without falling back to GitHub", async () => {
    agentSearchStatus = 503;
    const session = await connect();
    const result = await callTool(session, "brain_ask", { question: "design inspiration" });
    expect(result.isError).toBe(true);
    expect(result.content[0]!.text).toContain("paired Brain knowledge is unavailable");
    expect(githubSearches).toHaveLength(0);
  });

  it("brain_project exposes an intentional project-oriented retrieval surface", async () => {
    agentSearchBody = {
      results: [
        {
          path: "notes/Middle Block Catalogue Layout.md",
          title: "Middle Block Catalogue Layout",
          snippet: "…project-linked catalogue decision…",
        },
      ],
    };

    const session = await connect();
    const result = await callTool(session, "brain_project", {
      project: "Middle",
      question: "catalogue layout",
    });
    expect(result.isError).toBeFalsy();

    const search = new URL(agentSearches[0]!.url);
    expect(search.searchParams.get("q")).toBe("middle");
    expect(result.content[0]!.text).toContain('Retrieved project knowledge for "Middle"');
    expect(result.content[0]!.text).toContain("Middle Block Catalogue Layout");
    expect(githubSearches).toHaveLength(0);
  });
});
