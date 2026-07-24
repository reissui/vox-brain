/**
 * Types the `exports` loopback from "cloudflare:workers" (used by the tests)
 * with this Worker's actual exports, so `exports.default.fetch(...)` typechecks.
 */
declare namespace Cloudflare {
  interface Env {
    CAPTURE_TOKEN?: string;
    DB?: D1Database;
    CAPTURE_OBJECTS?: R2Bucket;
    BRAIN_QUEUE?: Queue;
  }

  interface GlobalProps {
    mainModule: typeof import("../src/index");
  }
}

declare module "*.sql?raw" {
  const sql: string;
  export default sql;
}
