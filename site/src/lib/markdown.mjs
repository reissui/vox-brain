import fs from "node:fs";
import path from "node:path";
import { findAndReplace } from "mdast-util-find-and-replace";

const root = path.resolve(
  process.env.BRAIN_SITE_CONTENT_ROOT || path.join(process.cwd(), ".."),
);
const allowed = ["notes", "sources", "maps", "project-notes"];
const links = new Map();
const attachments = new Map();

function slugSegment(value) {
  return value
    .replace(/\s/g, "-")
    .replaceAll("&", "-and-")
    .replaceAll("%", "-percent")
    .replace(/[?#]/g, "");
}

for (const directory of allowed) {
  const base = path.join(root, directory);
  if (!fs.existsSync(base)) continue;
  for (const file of fs.readdirSync(base, { recursive: true })) {
    if (typeof file !== "string" || !file.endsWith(".md")) continue;
    const relative = file.slice(0, -3);
    const route = `/${directory}/${relative.split(path.sep).map(slugSegment).join("/")}`;
    links.set(relative.toLocaleLowerCase(), route);
    links.set(path.basename(relative).toLocaleLowerCase(), route);
  }
}

const attachmentRoot = path.join(root, "system", "attachments");
if (fs.existsSync(attachmentRoot)) {
  for (const file of fs.readdirSync(attachmentRoot, { recursive: true })) {
    if (typeof file !== "string") continue;
    attachments.set(
      path.basename(file).toLocaleLowerCase(),
      `/system/attachments/${file}`,
    );
  }
}

function resolveWikiLink(name) {
  const normalized = name.replace(/\.md$/i, "").replaceAll("\\", "/");
  return (
    links.get(normalized.toLocaleLowerCase()) ||
    links.get(path.basename(normalized).toLocaleLowerCase()) ||
    `/notes/${normalized.split("/").map(slugSegment).join("/")}`
  );
}

export const wikiLinkOptions = {
  pageResolver: (name) => [name],
  hrefTemplate: (name) => resolveWikiLink(name),
};

export function remarkBrainSyntax() {
  return (tree) => {
    findAndReplace(tree, [
      [
        /!\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g,
        (_match, filename, alt) => ({
          type: "image",
          url:
            attachments.get(path.basename(filename).toLocaleLowerCase()) ||
            `/system/attachments/${filename}`,
          alt: alt || "",
        }),
      ],
      [
        /==([^=]+)==/g,
        (_match, content) => ({
          type: "html",
          value: `<mark>${content}</mark>`,
        }),
      ],
    ]);
  };
}
