# Brain wiki — Astro 7 + Veka

This folder contains the private browse/search experience for Brain. It uses
Astro 7 and adapts the structure and visual language of
[masmuss/veka](https://github.com/masmuss/veka) (MIT): warm editorial
typography, a compact three-column wiki layout, folder-led navigation, local
Pagefind search, dark mode, and very little client JavaScript.

Brain adds four product-specific views:

- `/` is a live dashboard of knowledge counts, recent updates, project state,
  and processing attention.
- `/designs` is a thumbnail-first inspiration gallery built directly from
  filed `type: design` sources and their processing-generated tags.
- `/projects` is the index of privacy-safe generated project knowledge areas.
- `/project-notes/<project>` shows processed notes and explicitly routed
  captures associated through project metadata or wikilinks.

## Private content boundary

The Astro site never reads the canonical vault during deployment. The remote runner
publisher creates a mode-`0700` temporary staging directory containing only:

- generated root pages (`index.md`, `designs.md`, and `bookmarks.md`);
- `sources/`, `notes/`, and `maps/`;
- generated privacy-safe `project-notes/`; and
- referenced, authenticated, hash-verified assets in `system/attachments/`.

The publisher passes that directory as `BRAIN_SITE_CONTENT_ROOT`, passes a
separate temporary destination as `BRAIN_SITE_OUT_DIR`, checks the exact
top-level Astro output allowlist, deploys it to Cloudflare Pages, and removes
both temporary trees. Private project prose, `me/`, `daily/`, `people/`,
`inbox/`, `.trash/`, credentials, and source code never enter the build.

## Local verification

From the repository root:

```sh
cd site
npm ci
npm run check
BRAIN_SITE_CONTENT_ROOT=.. npm run build
```

Pagefind is created during the production build. Use `npm run preview` after a
build to exercise search locally.
