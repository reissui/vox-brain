import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { unified } from "@astrojs/markdown-remark";
import mdx from "@astrojs/mdx";
import tailwindcss from "@tailwindcss/vite";
import pagefind from "astro-pagefind";
import { defineConfig } from "astro/config";
import rehypeRaw from "rehype-raw";
import remarkGfm from "remark-gfm";
import wikiLink from "remark-wiki-link";
import { remarkBrainSyntax, wikiLinkOptions } from "./src/lib/markdown.mjs";

const siteRoot = path.dirname(fileURLToPath(import.meta.url));
const contentRoot = path.resolve(
  process.env.BRAIN_SITE_CONTENT_ROOT || path.join(siteRoot, ".."),
);
const outDir = path.resolve(
  process.env.BRAIN_SITE_OUT_DIR || path.join(siteRoot, "dist"),
);

function copyPublishedAssets() {
  return {
    name: "brain-published-assets",
    hooks: {
      "astro:build:done": () => {
        const attachments = path.join(contentRoot, "system", "attachments");
        if (fs.existsSync(attachments)) {
          fs.cpSync(attachments, path.join(outDir, "system", "attachments"), {
            recursive: true,
            force: false,
            errorOnExist: true,
          });
        }
      },
    },
  };
}

export default defineConfig({
  site: process.env.BRAIN_SITE_URL || "https://brain-vault.example.pages.dev",
  output: "static",
  outDir,
  build: { format: "file" },
  integrations: [pagefind(), mdx(), copyPublishedAssets()],
  vite: {
    plugins: [tailwindcss()],
    resolve: { alias: { "@": path.join(siteRoot, "src") } },
  },
  markdown: {
    processor: unified({
      remarkPlugins: [remarkGfm, remarkBrainSyntax, [wikiLink, wikiLinkOptions]],
      rehypePlugins: [rehypeRaw],
    }),
    shikiConfig: {
      themes: { light: "github-light", dark: "github-dark" },
    },
  },
});
