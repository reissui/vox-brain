import { getCollection, type CollectionEntry } from "astro:content";

export type BrainEntry =
  | CollectionEntry<"rootPages">
  | CollectionEntry<"notes">
  | CollectionEntry<"sources">
  | CollectionEntry<"maps">
  | CollectionEntry<"projectNotes">;

const COLLECTION_PATH: Record<BrainEntry["collection"], string> = {
  rootPages: "",
  notes: "notes",
  sources: "sources",
  maps: "maps",
  projectNotes: "project-notes",
};

export async function getBrainEntries(): Promise<BrainEntry[]> {
  const groups = await Promise.all([
    getCollection("rootPages"),
    getCollection("notes"),
    getCollection("sources"),
    getCollection("maps"),
    getCollection("projectNotes"),
  ]);
  return groups.flat() as BrainEntry[];
}

export function slugSegment(value: string): string {
  return value
    .replace(/\s/g, "-")
    .replaceAll("&", "-and-")
    .replaceAll("%", "-percent")
    .replace(/[?#]/g, "");
}

export function entryHref(entry: BrainEntry): string {
  if (entry.collection === "rootPages") {
    if (entry.id === "index") return "/";
    return `/${slugSegment(entry.id)}`;
  }
  const prefix = COLLECTION_PATH[entry.collection];
  return `/${prefix}/${entry.id.split("/").map(slugSegment).join("/")}`;
}

export function entryTitle(entry: BrainEntry): string {
  return (
    entry.data.title ||
    entry.id
      .split("/")
      .at(-1)!
      .replaceAll("-", " ")
      .replace(/\b\w/g, (letter) => letter.toUpperCase())
  );
}

export function entryDate(entry: BrainEntry): Date | undefined {
  const data = entry.data;
  for (const value of [
    data.updatedAt,
    data.updated,
    data.modified,
    data.captured,
    data.createdAt,
    data.created,
  ]) {
    if (value instanceof Date && !Number.isNaN(value.valueOf())) return value;
  }
  return undefined;
}

export function entryKind(entry: BrainEntry): string {
  if (entry.data.type) return entry.data.type;
  if (entry.collection === "projectNotes") return "project";
  return entry.collection.replace(/s$/, "");
}

export function formatDate(date?: Date): string {
  if (!date) return "Undated";
  return new Intl.DateTimeFormat("en-GB", {
    day: "numeric",
    month: "short",
    year: "numeric",
  }).format(date);
}

export function formatRelativeDate(date?: Date, now = new Date()): string {
  if (!date) return "Date not recorded";
  const days = Math.floor((now.valueOf() - date.valueOf()) / 86_400_000);
  if (days <= 0) return "Today";
  if (days === 1) return "Yesterday";
  if (days < 14) return `${days} days ago`;
  return formatDate(date);
}

export function summaryFromBody(body = ""): string {
  const tldr = body.match(/^\*\*TL;DR\*\*\s*[—-]\s*(.+)$/m)?.[1];
  if (tldr) return stripMarkdown(tldr);
  const paragraph = body
    .replace(/^---[\s\S]*?---\s*/, "")
    .split(/\n\s*\n/)
    .map((value) => value.trim())
    .find((value) => value && !value.startsWith("#") && !value.startsWith("<"));
  return stripMarkdown(paragraph || "");
}

function stripMarkdown(value: string): string {
  return value
    .replace(/!\[\[.*?\]\]/g, "")
    .replace(/\[\[([^|\]]+)\|?([^\]]*)\]\]/g, "$2$1")
    .replace(/[*_`>#]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

export function designCategories(entry: BrainEntry): string[] {
  return entry.data.tags
    .filter((tag) => !tag.startsWith("needs/"))
    .map((tag) => tag.replace(/^design\//, ""))
    .filter((tag, index, values) => values.indexOf(tag) === index);
}

export function publicImagePath(value?: string | null): string | undefined {
  if (!value) return undefined;
  if (/^https?:\/\//.test(value)) return value;
  return `/${value.replace(/^\/+/, "")}`;
}

export function tagHref(tag: string): string {
  return `/tags/${tag.split("/").map(encodeURIComponent).join("/")}`;
}

export interface ProjectSummary {
  entry: BrainEntry;
  name: string;
  status: string;
  processed: number;
  waiting: number;
  needsAttention: number;
  total: number;
}

export function projectSummary(entry: BrainEntry): ProjectSummary {
  const body = entry.body || "";
  const count = (label: string) => {
    const match = body.match(
      new RegExp(`<dt>${label}</dt>\\s*<dd>(\\d+)</dd>`, "i"),
    );
    return match ? Number(match[1]) : 0;
  };
  const title = entryTitle(entry).replace(/\s+—\s+Project notes$/, "");
  const status =
    body.match(/class="brain-project-status">([^<]+)</i)?.[1] || "Active";
  const processed = count("Processed");
  const waiting = count("Waiting");
  const needsAttention = count("Needs attention");
  return {
    entry,
    name: title,
    status,
    processed,
    waiting,
    needsAttention,
    total: processed + waiting + needsAttention,
  };
}
