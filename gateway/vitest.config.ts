import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Workers isolates and Durable Object startup are deterministic but can
    // exceed Vitest's five-second default on a cold macOS runner. Keep one
    // explicit suite-wide ceiling: long enough for startup, short enough that
    // a lost fetch/queue promise still fails the build instead of hanging.
    hookTimeout: 20_000,
    testTimeout: 20_000,
    teardownTimeout: 10_000,
  },
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        // Test doubles for the secrets (`wrangler secret put` in production).
        // Values must stay in sync with test/capture.test.ts and test/mcp.test.ts.
        bindings: {
          CAPTURE_TOKEN: "test-capture-token",
          GITHUB_TOKEN: "test-github-token",
          GITHUB_REPOSITORY: "example/brain-vault",
          AGENT_TOKEN: "test-agent-token",
          MCP_PASSWORD: "test-mcp-password",
          BRAIN_ORIGIN_TOKEN: "test-origin-token",
        },
      },
    }),
  ],
});
