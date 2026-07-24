import path from "node:path";
import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { z } from "astro/zod";

const root = path.resolve(
  process.env.BRAIN_SITE_CONTENT_ROOT || path.join(process.cwd(), ".."),
);

const optionalString = z.string().nullish();
const optionalDate = z.coerce.date().nullish();

const schema = z.looseObject({
  title: optionalString,
  description: optionalString,
  type: optionalString,
  url: optionalString,
  image: optionalString,
  captured: optionalDate,
  created: optionalDate,
  createdAt: optionalDate,
  updated: optionalDate,
  updatedAt: optionalDate,
  modified: optionalDate,
  tags: z
    .array(z.string())
    .nullish()
    .transform((tags) => tags ?? []),
  status: optionalString,
});

const preserveId = ({ entry }: { entry: string }) =>
  entry.replace(/\.(md|mdx)$/i, "");

const rootPages = defineCollection({
  loader: glob({ base: root, pattern: "*.md", generateId: preserveId }),
  schema,
});
const notes = defineCollection({
  loader: glob({
    base: path.join(root, "notes"),
    pattern: "**/*.md",
    generateId: preserveId,
  }),
  schema,
});
const sources = defineCollection({
  loader: glob({
    base: path.join(root, "sources"),
    pattern: "**/*.md",
    generateId: preserveId,
  }),
  schema,
});
const maps = defineCollection({
  loader: glob({
    base: path.join(root, "maps"),
    pattern: "**/*.md",
    generateId: preserveId,
  }),
  schema,
});
const projectNotes = defineCollection({
  loader: glob({
    base: path.join(root, "project-notes"),
    pattern: "**/*.md",
    generateId: preserveId,
  }),
  schema,
});

export const collections = { rootPages, notes, sources, maps, projectNotes };
