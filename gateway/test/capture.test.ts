/**
 * Regression suite for issue #4 — POST /capture.
 *
 * Integration-style: requests go through the real router via
 * `exports.default.fetch()`; the only mock is the outbound GitHub
 * Contents API call (global fetch stub). Assertions target external
 * behaviour: HTTP responses and the payload written to GitHub.
 */

import { exports as worker } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { vi } from "vitest";

/** Must stay in sync with the miniflare bindings in vitest.config.ts. */
const CAPTURE_TOKEN = "test-capture-token";
const GITHUB_TOKEN = "test-github-token";

/** Filename shape from the acceptance criteria — asserted verbatim. */
const FILENAME_RE = /^inbox\/\d{4}-\d{2}-\d{2}-\d{6}-[0-9a-f]{4} (video|tweet|article|design|note)\.md$/;

interface RecordedPut {
  url: string;
  method: string;
  authorization: string | null;
  body: { message: string; content: string };
}

let githubRequests: RecordedPut[];
let githubStatus: number;
let githubResponseBody: string;
let xMetadata: Record<string, unknown> | null;
let xImage: Uint8Array | null;
let enrichmentSignalsActive: boolean[];

beforeEach(() => {
  githubRequests = [];
  githubStatus = 201;
  githubResponseBody = JSON.stringify({ content: { path: "unused" } });
  xMetadata = null;
  xImage = null;
  enrichmentSignalsActive = [];
  // The worker under test runs in this isolate, so stubbing global fetch
  // intercepts its outbound GitHub call (and would catch any unexpected one).
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request = new Request(input, init);
    const target = new URL(request.url);
    if (target.hostname === "api.fxtwitter.com") {
      enrichmentSignalsActive.push(!request.signal.aborted);
      return xMetadata
        ? Response.json(xMetadata)
        : new Response("unavailable", { status: 503 });
    }
    if (target.hostname === "pbs.twimg.com") {
      enrichmentSignalsActive.push(!request.signal.aborted);
      return xImage
        ? new Response(xImage, { headers: { "content-type": "image/jpeg" } })
        : new Response("unavailable", { status: 503 });
    }
    githubRequests.push({
      url: request.url,
      method: request.method,
      authorization: request.headers.get("authorization"),
      body: JSON.parse(await request.text()) as RecordedPut["body"],
    });
    return new Response(githubResponseBody, {
      status: githubStatus,
      headers: { "content-type": "application/json" },
    });
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function capture(body: unknown, token: string | null = CAPTURE_TOKEN): Promise<Response> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (token !== null) headers.authorization = `Bearer ${token}`;
  return worker.default.fetch(
    new Request("https://brain-gw.test/capture", {
      method: "POST",
      headers,
      body: typeof body === "string" ? body : JSON.stringify(body),
    }),
  );
}

/** Decode the base64 `content` a recorded PUT would have written to the repo. */
function writtenMarkdown(record: RecordedPut): string {
  const binary = atob(record.body.content);
  return new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)));
}

/** The UTC date baked into a returned inbox path, e.g. "2026-07-09". */
function dateFromPath(path: string): string {
  return path.slice("inbox/".length, "inbox/".length + "yyyy-MM-dd".length);
}

describe("GET /health", () => {
  it("responds 200 without auth", async () => {
    const response = await worker.default.fetch(new Request("https://brain-gw.test/health"));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
  });
});

describe("POST /capture auth", () => {
  it("rejects a missing token with 401 and writes nothing", async () => {
    const response = await capture({ url: "https://example.com" }, null);
    expect(response.status).toBe(401);
    expect(githubRequests).toHaveLength(0);
  });

  it("rejects a wrong token with 401 and writes nothing", async () => {
    const response = await capture({ url: "https://example.com" }, "not-the-token");
    expect(response.status).toBe(401);
    expect(githubRequests).toHaveLength(0);
  });
});

describe("POST /capture validation", () => {
  it("rejects a body with neither url nor text with 422", async () => {
    const response = await capture({ note: "a note alone", source: "test" });
    expect(response.status).toBe(422);
    const body = await response.json<{ error: string }>();
    expect(body.error).toMatch(/url or text/);
    expect(githubRequests).toHaveLength(0);
  });

  it("treats blank url and whitespace text as missing (422)", async () => {
    const response = await capture({ url: "", text: "   " });
    expect(response.status).toBe(422);
    expect(githubRequests).toHaveLength(0);
  });

  it("rejects an unparseable JSON body with 422", async () => {
    const response = await capture("not json {");
    expect(response.status).toBe(422);
    expect(githubRequests).toHaveLength(0);
  });

  it("rejects a declared oversized body before buffering it", async () => {
    const response = await worker.default.fetch(
      new Request("https://brain-gw.test/capture", {
        method: "POST",
        headers: {
          authorization: `Bearer ${CAPTURE_TOKEN}`,
          "content-type": "application/json",
          "content-length": String(7 * 1024 * 1024),
        },
        body: JSON.stringify({ text: "small body with dishonest length" }),
      }),
    );
    expect(response.status).toBe(413);
    expect(githubRequests).toHaveLength(0);
  });

  it("rejects an unknown type with 422", async () => {
    const response = await capture({ url: "https://example.com", type: "podcast" });
    expect(response.status).toBe(422);
    expect(githubRequests).toHaveLength(0);
  });

  it("rejects images on non-design captures", async () => {
    const response = await capture({
      url: "https://example.com/article",
      type: "article",
      image: "data:image/jpeg;base64,/9j/",
    });
    expect(response.status).toBe(422);
    expect(githubRequests).toHaveLength(0);
  });

  it("rejects image data whose signature does not match the declared format", async () => {
    const response = await capture({
      url: "https://example.com/design",
      type: "design",
      image: "data:image/jpeg;base64,aGVsbG8=",
    });
    expect(response.status).toBe(422);
    expect(githubRequests).toHaveLength(0);
  });
});

describe("type inference", () => {
  it.each([
    ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "video"],
    ["https://youtu.be/dQw4w9WgXcQ", "video"],
    ["https://x.com/karpathy/status/1234567890", "tweet"],
    ["https://twitter.com/karpathy/status/1234567890", "tweet"],
    ["https://dribbble.com/shots/999-landing", "design"],
    ["https://www.behance.net/gallery/1/brand", "design"],
    ["https://example.com/essay", "article"],
  ])("infers %s -> %s", async (url, expected) => {
    const response = await capture({ url });
    expect(response.status).toBe(201);
    const { path } = await response.json<{ path: string }>();
    expect(path).toMatch(FILENAME_RE);
    expect(path.endsWith(` ${expected}.md`)).toBe(true);
  });

  it("captures text without a url as a note", async () => {
    const response = await capture({ text: "a fleeting thought" });
    expect(response.status).toBe(201);
    const { path } = await response.json<{ path: string }>();
    expect(path).toMatch(FILENAME_RE);
    expect(path.endsWith(" note.md")).toBe(true);
  });

  it("lets an explicit type override inference", async () => {
    const response = await capture({ url: "https://example.com/shot.png", type: "design" });
    expect(response.status).toBe(201);
    const { path } = await response.json<{ path: string }>();
    expect(path.endsWith(" design.md")).toBe(true);
  });
});

describe("markdown written to GitHub", () => {
  it("writes a url capture with needs/content tag, via: gateway, and Why saved", async () => {
    const response = await capture({
      url: "https://example.com/essay",
      note: "why I saved it",
      source: "hermes",
    });
    expect(response.status).toBe(201);
    const { path } = await response.json<{ path: string }>();
    expect(path).toMatch(FILENAME_RE);

    expect(githubRequests).toHaveLength(1);
    const put = githubRequests[0]!;
    const filename = path.slice("inbox/".length);
    expect(put.method).toBe("PUT");
    expect(put.url).toBe(
      `https://api.github.com/repos/example/brain-vault/contents/inbox/${encodeURIComponent(filename)}`,
    );
    expect(put.authorization).toBe(`Bearer ${GITHUB_TOKEN}`);
    expect(put.body.message).toBe(`gateway: capture ${path}`);

    expect(writtenMarkdown(put)).toBe(
      [
        "---",
        "type: article",
        "url: https://example.com/essay",
        `captured: ${dateFromPath(path)}`,
        "status: inbox",
        "via: gateway",
        "source: hermes",
        "tags: [needs/content]",
        "---",
        "",
        "## Why saved",
        "why I saved it",
        "",
        "",
      ].join("\n"),
    );
  });

  it("writes a text capture with the text under ## Raw", async () => {
    const response = await capture({ text: "line one\nline two" });
    expect(response.status).toBe(201);
    const { path } = await response.json<{ path: string }>();

    expect(githubRequests).toHaveLength(1);
    expect(writtenMarkdown(githubRequests[0]!)).toBe(
      [
        "---",
        "type: note",
        `captured: ${dateFromPath(path)}`,
        "status: inbox",
        "via: gateway",
        "---",
        "",
        "## Raw",
        "",
        "line one",
        "line two",
        "",
      ].join("\n"),
    );
  });

  it("orders ## Why saved before ## Raw when both note and text are given", async () => {
    const response = await capture({ text: "the raw text", note: "from the road" });
    expect(response.status).toBe(201);
    const markdown = writtenMarkdown(githubRequests[0]!);
    expect(markdown).toContain("## Why saved\nfrom the road\n\n## Raw\n\nthe raw text\n");
  });

  it("stores a design screenshot as an attachment and references it from the inbox note", async () => {
    const response = await capture({
      url: "https://example.com/landing",
      type: "design",
      note: "Strong editorial hierarchy",
      image: "data:image/jpeg;base64,/9j/",
    });
    expect(response.status).toBe(201);
    const { path } = await response.json<{ path: string }>();

    expect(githubRequests).toHaveLength(2);
    const asset = githubRequests[0]!;
    const note = githubRequests[1]!;
    expect(asset.url).toMatch(/\/contents\/system\/attachments\/design-.*\.jpg$/);
    expect(asset.body.content).toBe("/9j/");
    expect(note.url).toContain(`/contents/inbox/${encodeURIComponent(path.slice("inbox/".length))}`);
    const markdown = writtenMarkdown(note);
    expect(markdown).toMatch(/^image: system\/attachments\/design-.*\.jpg$/m);
    expect(markdown).toContain("tags: [needs/context]");
    expect(markdown).toMatch(/## Preview\n\n!\[\[design-.*\.jpg\]\]/);
  });

  it("immediately replaces an X page screenshot with the original visual and post context", async () => {
    xMetadata = {
      tweet: {
        text: "A cobalt analytics dashboard with a compact filter rail.",
        url: "https://x.com/designer/status/123",
        created_at: "Tue Jul 14 12:00:00 +0000 2026",
        author: { name: "Designer", screen_name: "designer" },
        media: {
          all: [
            { type: "photo", url: "https://pbs.twimg.com/media/design-one.jpg?name=small" },
            { type: "photo", url: "https://pbs.twimg.com/media/design-two.jpg?name=small" },
          ],
        },
      },
    };
    xImage = new Uint8Array([0xff, 0xd8, 0xff, 0xdb]);

    const response = await capture({
      url: "https://x.com/designer/status/123/photo/2",
      type: "design",
      image: "data:image/jpeg;base64,/9j/",
    });
    expect(response.status).toBe(201);
    const body = await response.json<{
      path: string;
      evidence: { visual: boolean; context: boolean; source: string };
    }>();
    expect(body.evidence).toEqual({ visual: true, context: true, source: "x-api" });

    expect(githubRequests).toHaveLength(2);
    expect(enrichmentSignalsActive).toEqual([true, true]);
    expect(githubRequests[0]!.body.content).toBe("/9j/2w==");
    const markdown = writtenMarkdown(githubRequests[1]!);
    expect(markdown).toContain("POST by Designer (@designer)");
    expect(markdown).toContain("A cobalt analytics dashboard with a compact filter rail.");
    expect(markdown).not.toContain("needs/");
  });

  it("marks the exact missing evidence when a design cannot be enriched", async () => {
    const response = await capture({
      url: "https://x.com/designer/status/999/photo/1",
      type: "design",
      text: "post context survived",
    });
    expect(response.status).toBe(201);
    const markdown = writtenMarkdown(githubRequests[0]!);
    expect(markdown).toContain("tags: [needs/visual]");
    expect(markdown).not.toContain("needs/context");
  });
});

describe("GitHub failure handling", () => {
  it("surfaces a GitHub 500 as a 502 with a JSON error", async () => {
    githubStatus = 500;
    githubResponseBody = JSON.stringify({ message: "boom" });
    const response = await capture({ url: "https://example.com/essay" });
    expect(response.status).toBe(502);
    const body = await response.json<{ error: string }>();
    expect(body.error).toMatch(/github/i);
    expect(body.error).toMatch(/500/);
  });
});
