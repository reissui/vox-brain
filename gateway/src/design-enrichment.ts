import type { Capture, CapturedImage } from "./capture";

const MAX_METADATA_BYTES = 512 * 1024;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
const FETCH_TIMEOUT_MS = 8_000;

export interface DesignEnrichment {
  capture: Capture;
  source: "x-api" | "client" | "pending";
}

/**
 * Enrich explicit X design captures on the request path so the inbox receives
 * the post text and original visual, not only an X URL or a page screenshot.
 * Failure is deliberately soft: the client's evidence is preserved and the
 * inbox tags tell the Librarian what still needs retrying.
 */
export async function enrichDesignCapture(capture: Capture): Promise<DesignEnrichment> {
  if (capture.type !== "design") return describe(capture);
  const status = xStatus(capture.url);
  if (!status) return describe(capture);

  try {
    const metadataResponse = await fetch(`https://api.fxtwitter.com/status/${status.id}`, {
      headers: { "user-agent": "brain-gw/1.0" },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!metadataResponse.ok) return describe(capture);
    const metadataBytes = await readBounded(metadataResponse, MAX_METADATA_BYTES);
    if (!metadataBytes) return describe(capture);

    const tweet = parseTweet(new TextDecoder().decode(metadataBytes));
    if (!tweet) return describe(capture);

    const sourceText = formatTweet(tweet);
    const text = mergeEvidence(sourceText, capture.text);
    const mediaUrl = selectPhoto(tweet.media, status.photoIndex);
    const sourceImage = mediaUrl ? await fetchImage(preferOriginal(mediaUrl)) : undefined;

    return {
      capture: {
        ...capture,
        text: text || capture.text,
        // Prefer the source visual. A page screenshot remains the fail-soft
        // fallback when the media host is unavailable.
        image: sourceImage ?? capture.image,
      },
      source: sourceImage || sourceText ? "x-api" : capture.image || capture.text ? "client" : "pending",
    };
  } catch {
    return describe(capture);
  }
}

function describe(capture: Capture): DesignEnrichment {
  return {
    capture,
    source: capture.image || capture.text ? "client" : "pending",
  };
}

interface XStatus {
  id: string;
  photoIndex: number;
}

function xStatus(url: string | undefined): XStatus | undefined {
  if (!url) return undefined;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return undefined;
  }
  const hostname = parsed.hostname.toLowerCase();
  const isX = ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].includes(hostname);
  if (!isX) return undefined;
  const match = /\/status\/(\d+)(?:\/photo\/(\d+))?/.exec(parsed.pathname);
  if (!match?.[1]) return undefined;
  const requested = Number(match[2] ?? "1");
  return { id: match[1], photoIndex: Number.isSafeInteger(requested) && requested > 0 ? requested : 1 };
}

interface TweetMedia {
  type: string;
  url: string;
}

interface TweetData {
  authorName: string;
  authorHandle: string;
  createdAt: string;
  url: string;
  text: string;
  media: TweetMedia[];
}

function parseTweet(json: string): TweetData | undefined {
  let decoded: unknown;
  try {
    decoded = JSON.parse(json);
  } catch {
    return undefined;
  }
  const root = record(decoded);
  const tweet = record(root?.tweet);
  if (!tweet) return undefined;
  const author = record(tweet.author);
  const mediaRoot = record(tweet.media);
  const media = Array.isArray(mediaRoot?.all)
    ? mediaRoot.all.flatMap((item): TweetMedia[] => {
        const entry = record(item);
        const type = string(entry?.type);
        const url = string(entry?.url);
        return type && url ? [{ type, url }] : [];
      })
    : [];
  const result = {
    authorName: string(author?.name),
    authorHandle: string(author?.screen_name),
    createdAt: string(tweet.created_at),
    url: string(tweet.url),
    text: string(tweet.text),
    media,
  };
  return result.text || result.authorName || result.authorHandle || result.url ? result : undefined;
}

function formatTweet(tweet: TweetData): string {
  const byline = [
    tweet.authorName || "Unknown author",
    tweet.authorHandle ? `(@${tweet.authorHandle})` : "",
  ].filter(Boolean).join(" ");
  const lines = [`POST by ${byline}${tweet.createdAt ? ` — ${tweet.createdAt}` : ""}`];
  if (tweet.url) lines.push(`URL: ${tweet.url}`);
  if (tweet.text) lines.push("", tweet.text);
  return lines.join("\n").trim();
}

function mergeEvidence(source: string, client: string | undefined): string {
  const cleanSource = source.trim();
  const cleanClient = client?.trim() ?? "";
  if (!cleanSource) return cleanClient;
  if (!cleanClient || cleanClient.includes(cleanSource)) return cleanClient || cleanSource;
  if (cleanSource.includes(cleanClient)) return cleanSource;
  return `${cleanSource}\n\nCAPTURED PAGE CONTEXT:\n${cleanClient}`;
}

function selectPhoto(media: TweetMedia[], requestedIndex: number): string | undefined {
  const photos = media.filter((item) => item.type === "photo" || item.type === "image");
  return photos[requestedIndex - 1]?.url ?? photos[0]?.url;
}

function preferOriginal(value: string): string {
  try {
    const url = new URL(value);
    if (url.hostname === "pbs.twimg.com" && url.pathname.startsWith("/media/")) {
      url.searchParams.set("name", "orig");
    }
    return url.toString();
  } catch {
    return value;
  }
}

async function fetchImage(url: string): Promise<CapturedImage | undefined> {
  try {
    const response = await fetch(url, {
      headers: { "user-agent": "brain-gw/1.0" },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!response.ok) return undefined;
    const bytes = await readBounded(response, MAX_IMAGE_BYTES);
    if (!bytes) return undefined;
    const mimeType = imageMime(response.headers.get("content-type"), bytes);
    if (!mimeType) return undefined;
    return { mimeType, base64: base64Bytes(bytes) };
  } catch {
    return undefined;
  }
}

async function readBounded(response: Response, limit: number): Promise<Uint8Array | undefined> {
  const declared = Number(response.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > limit) return undefined;
  if (!response.body) return new Uint8Array();

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      return undefined;
    }
    chunks.push(value);
  }
  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

function imageMime(header: string | null, bytes: Uint8Array): CapturedImage["mimeType"] | undefined {
  const value = header?.split(";", 1)[0]?.trim().toLowerCase();
  if (value === "image/jpeg" || value === "image/png" || value === "image/webp") return value;
  if (bytes[0] === 0xff && bytes[1] === 0xd8) return "image/jpeg";
  if (bytes.length >= 8 && String.fromCharCode(...bytes.subarray(0, 8)) === "\x89PNG\r\n\x1a\n") return "image/png";
  if (bytes.length >= 12 && String.fromCharCode(...bytes.subarray(0, 4)) === "RIFF" && String.fromCharCode(...bytes.subarray(8, 12)) === "WEBP") return "image/webp";
  return undefined;
}

function base64Bytes(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x2000;
  for (let index = 0; index < bytes.length; index += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
  }
  return btoa(binary);
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function string(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}
