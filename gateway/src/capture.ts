/**
 * Capture validation, type inference, and inbox markdown building.
 *
 * The markdown byte-format mirrors `scripts/brain` (`new_item` + `cmd_add`):
 * frontmatter `type` / `url` (when present) / `captured` / `status: inbox`,
 * then optional `## Why saved` and `## Raw` sections. The gateway adds
 * `via: gateway` (like `cmd_paste` adds `via: clipboard`), `source:` when
 * given, and precise retry tags when capture-time evidence is incomplete.
 */

export const CAPTURE_TYPES = ["video", "tweet", "article", "design", "note"] as const;
export type CaptureType = (typeof CAPTURE_TYPES)[number];

/** Raw UTF-8 transcript limit shared by remote capture validation and staging. */
export const MAX_TRANSCRIPT_BYTES = 6 * 1024 * 1024;

export interface Capture {
  type: CaptureType;
  url?: string;
  text?: string;
  note?: string;
  source?: string;
  image?: CapturedImage;
}

export interface CapturedImage {
  mimeType: "image/jpeg" | "image/png" | "image/webp";
  base64: string;
}

export type ParseResult = { ok: true; capture: Capture } | { ok: false; error: string };

const STRING_FIELDS = ["type", "url", "text", "note", "source", "image"] as const;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

/** Validate a decoded JSON body into a Capture, or say why not (→ 422). */
export function parseCapture(body: unknown): ParseResult {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "body must be a JSON object" };
  }
  const record = body as Record<string, unknown>;
  for (const key of STRING_FIELDS) {
    const value = record[key];
    if (value !== undefined && value !== null && typeof value !== "string") {
      return { ok: false, error: `${key} must be a string` };
    }
  }

  const type = (record.type ?? undefined) as string | undefined;
  let url = ((record.url as string | undefined) ?? "").trim();
  const text = (record.text as string | undefined) ?? "";
  const note = (record.note as string | undefined) ?? "";
  const source = ((record.source as string | undefined) ?? "").trim();

  if (!url && !text.trim()) {
    return { ok: false, error: "at least one of url or text is required" };
  }
  if (type !== undefined && !(CAPTURE_TYPES as readonly string[]).includes(type)) {
    return { ok: false, error: `type must be one of: ${CAPTURE_TYPES.join(", ")}` };
  }
  if (/[\r\n]/.test(url)) {
    return { ok: false, error: "url must be a single line" };
  }
  if (/[\r\n]/.test(source)) {
    return { ok: false, error: "source must be a single line" };
  }
  if (url) url = normalizeUrl(url);

  const resolvedType = (type as CaptureType | undefined) ?? (url ? inferType(url) : "note");
  const rawImage = ((record.image as string | undefined) ?? "").trim();
  let image: CapturedImage | undefined;
  if (rawImage) {
    if (resolvedType !== "design") {
      return { ok: false, error: "image is only accepted for design captures" };
    }
    const parsedImage = parseImageDataUrl(rawImage);
    if (typeof parsedImage === "string") return { ok: false, error: parsedImage };
    image = parsedImage;
  }

  return {
    ok: true,
    capture: {
      type: resolvedType,
      url: url || undefined,
      text: text.trim() ? text : undefined,
      note: note.trim() ? note : undefined,
      source: source || undefined,
      image,
    },
  };
}

function parseImageDataUrl(value: string): CapturedImage | string {
  const match = /^data:(image\/(?:jpeg|png|webp));base64,([A-Za-z0-9+/]+={0,2})$/.exec(value);
  if (!match) return "image must be a base64 JPEG, PNG, or WebP data URL";
  const mimeType = match[1] as CapturedImage["mimeType"] | undefined;
  const base64 = match[2];
  if (!mimeType || !base64) return "image must be a base64 JPEG, PNG, or WebP data URL";
  const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
  const bytes = Math.floor((base64.length * 3) / 4) - padding;
  if (bytes > MAX_IMAGE_BYTES) return "image must be 4 MiB or smaller";
  let prefix: string;
  try {
    prefix = atob(base64.slice(0, 24));
  } catch {
    return "image contains invalid base64 data";
  }
  const valid =
    (mimeType === "image/jpeg" && prefix.charCodeAt(0) === 0xff && prefix.charCodeAt(1) === 0xd8) ||
    (mimeType === "image/png" && prefix.startsWith("\x89PNG\r\n\x1a\n")) ||
    (mimeType === "image/webp" && prefix.startsWith("RIFF") && prefix.slice(8, 12) === "WEBP");
  if (!valid) return "image data does not match its declared format";
  return { mimeType, base64 };
}

/** Mirror `cmd_add`: prepend https:// unless the url already has a scheme. */
function normalizeUrl(url: string): string {
  return url.startsWith("http") ? url : `https://${url}`;
}

/** Infer the capture type from a url — same table as `detect_type` in scripts/brain. */
export function inferType(url: string): CaptureType {
  const lower = url.toLowerCase();
  try {
    const { hostname, pathname } = new URL(lower);
    const hostIs = (domain: string) => hostname === domain || hostname.endsWith(`.${domain}`);
    if (hostIs("youtube.com") || hostIs("youtu.be")) return "video";
    if ((hostIs("x.com") || hostIs("twitter.com")) && pathname.includes("/status/")) return "tweet";
    if (
      hostIs("dribbble.com") ||
      hostIs("behance.net") ||
      hostIs("mobbin.com") ||
      hostname.includes("pinterest.") ||
      hostIs("awwwards.com") ||
      hostIs("godly.website") ||
      hostIs("land-book.com")
    ) {
      return "design";
    }
  } catch {
    // Unparseable url: fall back to the substring patterns `detect_type` uses.
    if (lower.includes("youtube.com") || lower.includes("youtu.be")) return "video";
    if ((lower.includes("x.com/") || lower.includes("twitter.com/")) && lower.includes("/status/")) {
      return "tweet";
    }
    const designHosts = ["dribbble.com", "behance.net", "mobbin.com", "pinterest.", "awwwards.com", "godly.website", "land-book.com"];
    if (designHosts.some((host) => lower.includes(host))) return "design";
  }
  return "article";
}

/** `inbox/<UTC yyyy-MM-dd-HHmmss>-<4 hex> <type>.md` — like STAMP in scripts/brain, plus 4 random hex for collision safety. */
export function buildInboxPath(type: CaptureType, now: Date): string {
  const stamp = `${utcDate(now)}-${pad(now.getUTCHours())}${pad(now.getUTCMinutes())}${pad(now.getUTCSeconds())}`;
  const bytes = new Uint8Array(2);
  crypto.getRandomValues(bytes);
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `inbox/${stamp}-${hex} ${type}.md`;
}

export function buildAttachmentPath(inboxPath: string, mimeType: CapturedImage["mimeType"]): string {
  const filename = inboxPath.slice("inbox/".length).replace(/ [^/]+\.md$/, "");
  const extension = mimeType === "image/jpeg" ? "jpg" : mimeType.split("/")[1];
  return `system/attachments/design-${filename}.${extension}`;
}

/** Which entry point wrote the capture — recorded as `via:` in frontmatter. */
export type CaptureVia = "gateway" | "mcp";

/** Render the inbox note, byte-compatible with `scripts/brain cmd_add` output. */
export function buildMarkdown(
  capture: Capture,
  now: Date,
  via: CaptureVia = "gateway",
  attachmentPath?: string,
): string {
  let md = `---\ntype: ${capture.type}\n`;
  if (capture.url) md += `url: ${capture.url}\n`;
  md += `captured: ${utcDate(now)}\nstatus: inbox\nvia: ${via}\n`;
  if (capture.source) md += `source: ${capture.source}\n`;
  if (attachmentPath) md += `image: ${attachmentPath}\n`;
  const tags = retryTags(capture, attachmentPath);
  if (tags.length) md += `tags: [${tags.join(", ")}]\n`;
  md += `---\n\n`;
  if (capture.note) md += `## Why saved\n${capture.note}\n\n`;
  if (capture.text) md += `## Raw\n\n${capture.text}\n`;
  if (attachmentPath) md += `\n## Preview\n\n![[${attachmentPath.split("/").at(-1)}]]\n`;
  return md;
}

function retryTags(capture: Capture, attachmentPath?: string): string[] {
  if (!capture.url) return [];
  if (capture.type !== "design") return ["needs/content"];
  const tags: string[] = [];
  if (!attachmentPath) tags.push("needs/visual");
  if (!capture.text) tags.push("needs/context");
  return tags;
}

function utcDate(now: Date): string {
  return `${now.getUTCFullYear()}-${pad(now.getUTCMonth() + 1)}-${pad(now.getUTCDate())}`;
}

function pad(value: number): string {
  return String(value).padStart(2, "0");
}
