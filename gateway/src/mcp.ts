/**
 * Brain's remote MCP server.
 *
 * MCP keeps its existing OAuth/password boundary, but every write is handed to
 * the durable capture ingress used by paired clients. That means D1 owns the
 * activity record, R2 owns immutable files/transcripts, and Queue owns Agent
 * delivery. MCP never writes canonical Markdown or GitHub content directly.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { McpAgent } from "agents/mcp";
import { z } from "zod";
import { searchVault } from "./ask";
import { handleCaptureRequest } from "./capture-api";
import type { Env } from "./index";

/** Prefixed to every brain_ask reply so models treat hits as evidence, not an answer. */
export const RETRIEVAL_DISCLAIMER =
  "Retrieved notes from the owner's vault (raw search hits — read them yourself; this is not a synthesized answer):";

const MCP_SOURCE_PREFIX = "MCP";
const MCP_DEVICE_NAME = "MCP clients";
const INSTANCE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$/;

type ToolResult = {
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
};

interface CaptureResponse {
  id?: unknown;
  state?: unknown;
  error?: unknown;
}

const commentSchema = z.string().optional().describe(
  "the owner's comment or reason for saving this, preserved verbatim.",
);
const titleSchema = z.string().max(500).optional().describe(
  "An optional human-readable title from the source chat or document.",
);
const subjectSchema = z.string().max(300).optional().describe(
  "The project, person, or subject this belongs to.",
);
const sourceContextSchema = z.string().max(160).optional().describe(
  "The originating AI chat or client, for example 'Claude · Brain planning'.",
);

export class BrainMcpAgent extends McpAgent<Env> {
  server = new McpServer({ name: "brain-gw", version: "0.3.0" });

  async init(): Promise<void> {
    this.server.registerTool(
      "brain_add",
      {
        description:
          "Save a link to Brain through its durable capture queue. Include the user's comment and subject when available.",
        inputSchema: {
          url: z.string().describe("The URL to save."),
          note: z.string().optional().describe(
            "Legacy alias for comment. Use comment for new calls and do not send both.",
          ),
          comment: commentSchema,
          title: titleSchema,
          subject: subjectSchema,
          source_context: sourceContextSchema,
        },
      },
      async ({ url, note, comment, title, subject, source_context }) => {
        if (note !== undefined && comment !== undefined) {
          return toolError("use either comment or legacy note, not both");
        }
        return this.writeCapture({
          url,
          note: comment ?? note,
          title,
          entity: subject,
          source: mcpSource(source_context),
        });
      },
    );

    this.server.registerTool(
      "brain_note",
      {
        description:
          "Save verbatim text to Brain through its durable capture queue, with optional source-chat context.",
        inputSchema: {
          text: z.string().describe("The text to remember, verbatim."),
          comment: commentSchema,
          title: titleSchema,
          subject: subjectSchema,
          source_context: sourceContextSchema,
        },
      },
      async ({ text, comment, title, subject, source_context }) => this.writeCapture({
        type: "note",
        text,
        note: comment,
        title,
        entity: subject,
        source: mcpSource(source_context),
      }),
    );

    this.server.registerTool(
      "brain_file",
      {
        description:
          "Save a file attachment to Brain. The original bytes are retained durably and the comment, title, subject, and chat context travel with it.",
        inputSchema: {
          filename: z.string().min(1).max(180).describe("The original filename."),
          content_type: z.string().min(3).max(255).describe(
            "The file's MIME type, for example application/pdf or image/png.",
          ),
          base64: z.string().min(1).describe("The complete file encoded as standard base64."),
          comment: commentSchema,
          title: titleSchema,
          subject: subjectSchema,
          source_context: sourceContextSchema,
        },
      },
      async ({ filename, content_type, base64, comment, title, subject, source_context }) =>
        this.writeCapture({
          type: "note",
          text: `File shared via MCP: ${filename}`,
          note: comment,
          title,
          entity: subject,
          source: mcpSource(source_context),
          object: { filename, content_type, base64 },
        }),
    );

    this.server.registerTool(
      "brain_transcript",
      {
        description:
          "Save a meeting or conversation transcript to Brain as a durable transcript capture.",
        inputSchema: {
          transcript: z.string().describe("The complete transcript, verbatim."),
          filename: z.string().min(1).max(180).optional().describe(
            "An optional source filename; defaults to transcript.txt.",
          ),
          comment: commentSchema,
          title: titleSchema,
          subject: subjectSchema,
          source_context: sourceContextSchema,
        },
      },
      async ({ transcript, filename, comment, title, subject, source_context }) =>
        this.writeCapture({
          type: "transcript",
          transcript,
          filename,
          note: comment,
          title,
          entity: subject,
          source: mcpSource(source_context),
        }),
    );

    this.server.registerTool(
      "brain_ask",
      {
        description: "Returns matching notes from the owner's knowledge vault (retrieval only).",
        inputSchema: {
          question: z.string().describe("What to look up in the vault."),
        },
      },
      async ({ question }) => {
        const result = await searchVault(this.env, question);
        if (!result.ok) return toolError(result.error);
        return toolText(`${RETRIEVAL_DISCLAIMER}\n\n${JSON.stringify(result.hits, null, 2)}`);
      },
    );

    this.server.registerTool(
      "brain_project",
      {
        description:
          "Returns live vault notes connected to a named project, optionally narrowed by a question (retrieval only).",
        inputSchema: {
          project: z.string().min(1).max(300).describe(
            "The canonical project name, for example Middle or Second Brain.",
          ),
          question: z.string().max(500).optional().describe(
            "Optional words to narrow the project retrieval.",
          ),
        },
      },
      async ({ project, question }) => {
        const query = [project.trim(), question?.trim()].filter(Boolean).join(" ");
        const result = await searchVault(this.env, query);
        if (!result.ok) return toolError(result.error);
        const heading =
          `Retrieved project knowledge for ${JSON.stringify(project.trim())} ` +
          "(raw search hits — read them yourself; this is not a synthesized answer):";
        return toolText(`${heading}\n\n${JSON.stringify(result.hits, null, 2)}`);
      },
    );
  }

  private async writeCapture(payload: Record<string, unknown>): Promise<ToolResult> {
    try {
      const credential = await ensureMcpCaptureDevice(this.env);
      const response = await handleCaptureRequest(
        new Request("https://brain.internal/v1/captures", {
          method: "POST",
          headers: {
            authorization: `Bearer ${credential}`,
            "content-type": "application/json",
            "idempotency-key": crypto.randomUUID(),
          },
          body: JSON.stringify(payload),
        }),
        this.env,
      );
      const result: CaptureResponse = await response.json<CaptureResponse>().catch(() => ({}));
      if (
        response.status !== 202 ||
        typeof result.id !== "string" ||
        result.state !== "queued"
      ) {
        return toolError(
          typeof result.error === "string"
            ? result.error
            : "Brain did not confirm that the capture was durably queued.",
        );
      }
      return toolText(`Queued in Brain as ${result.id}. It is visible in Activity.`);
    } catch {
      return toolError("Brain's durable capture service is unavailable.");
    }
  }
}

async function ensureMcpCaptureDevice(env: Env): Promise<string> {
  const instanceId = env.INSTANCE_ID ?? env.BRAIN_INSTANCE_ID;
  if (typeof instanceId !== "string" || !INSTANCE_PATTERN.test(instanceId)) {
    throw new Error("MCP capture instance is not configured");
  }
  if (typeof env.MCP_PASSWORD !== "string" || env.MCP_PASSWORD.length === 0) {
    throw new Error("MCP password is not configured");
  }

  const instanceDigest = await sha256Bytes(`brain-mcp-device-id\0${instanceId}`);
  const deviceId = `mcp-${hex(instanceDigest).slice(0, 32)}`;
  const credentialBytes = await sha256Bytes(
    `brain-mcp-capture-credential\0${instanceId}\0${env.MCP_PASSWORD}`,
  );
  const credential = base64url(credentialBytes);
  const tokenDigest = hex(await sha256Bytes(credential));
  const now = new Date().toISOString();

  const result = await env.DB.prepare(
    `INSERT INTO devices
      (id, instance_id, name, token_digest, scopes, claimed_at, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       name = excluded.name,
       token_digest = excluded.token_digest,
       scopes = excluded.scopes,
       pairing_code_digest = NULL,
       pairing_expires_at = NULL,
       claimed_at = excluded.claimed_at,
       revoked_at = NULL,
       updated_at = excluded.updated_at
     WHERE devices.instance_id = excluded.instance_id`,
  )
    .bind(
      deviceId,
      instanceId,
      MCP_DEVICE_NAME,
      tokenDigest,
      JSON.stringify(["capture"]),
      now,
      now,
      now,
    )
    .run();
  if (result.meta.changes !== 1) throw new Error("MCP capture device conflict");
  return credential;
}

function mcpSource(context?: string): string {
  const normalized = context?.trim();
  return normalized ? `${MCP_SOURCE_PREFIX} · ${normalized}` : MCP_SOURCE_PREFIX;
}

async function sha256Bytes(value: string): Promise<Uint8Array> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return new Uint8Array(digest);
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function toolText(text: string): ToolResult {
  return { content: [{ type: "text", text }] };
}

function toolError(message: string): ToolResult {
  return { content: [{ type: "text", text: message }], isError: true };
}
