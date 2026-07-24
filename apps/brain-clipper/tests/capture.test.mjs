import assert from "node:assert/strict"
import test from "node:test"
import { buildCapture, normalizeGatewayUrl, sendCapture } from "../capture.js"
import { formatPageEvidence } from "../design.js"

test("normalizes a secure gateway URL", () => {
  assert.equal(normalizeGatewayUrl(" https://brain.example.workers.dev/// "), "https://brain.example.workers.dev")
  assert.throws(() => normalizeGatewayUrl("http://brain.example"), /HTTPS/)
})

test("builds automatic and explicit-design captures", () => {
  assert.deepEqual(buildCapture({ url: "https://x.com/a/status/1", type: "auto" }), {
    source: "chrome-extension",
    url: "https://x.com/a/status/1",
  })
  assert.deepEqual(buildCapture({ url: "https://x.com/a/status/1", text: "selected", type: "design", image: "data:image/jpeg;base64,/9j/" }), {
    source: "chrome-extension",
    url: "https://x.com/a/status/1",
    text: "selected",
    type: "design",
    image: "data:image/jpeg;base64,/9j/",
  })
})

test("sends a capture without leaking the token into the body", async () => {
  let recorded
  const result = await sendCapture(
    { gatewayUrl: "https://brain.example.workers.dev", token: "secret" },
    { url: "https://example.com", source: "chrome-extension" },
    async (url, init) => {
      recorded = { url, init }
      return new Response(JSON.stringify({ path: "inbox/item.md" }), { status: 201 })
    },
  )
  assert.equal(result.path, "inbox/item.md")
  assert.equal(recorded.url, "https://brain.example.workers.dev/capture")
  assert.equal(recorded.init.headers.Authorization, "Bearer secret")
  assert.doesNotMatch(recorded.init.body, /secret/)
})

test("formats visible design evidence as searchable source context", () => {
  assert.equal(
    formatPageEvidence({
      title: "  Dashboard   study ",
      description: "Cobalt analytics interface",
      content: "Dense metric cards with a compact filter rail",
      selection: "compact filter rail",
    }),
    [
      "PAGE TITLE: Dashboard study",
      "DESCRIPTION: Cobalt analytics interface",
      "VISIBLE DESIGN CONTEXT:\nDense metric cards with a compact filter rail",
    ].join("\n\n"),
  )
})

test("surfaces gateway errors", async () => {
  await assert.rejects(
    sendCapture(
      { gatewayUrl: "https://brain.example.workers.dev", token: "secret" },
      { url: "https://example.com" },
      async () => new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 }),
    ),
    /unauthorized/,
  )
})
