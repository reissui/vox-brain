#!/usr/bin/env python3
"""Build the public-safe design and bookmark overview pages from filed sources."""

from __future__ import annotations

import argparse
import html
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote


GENERIC_TAGS = {"needs/content", "source", "bookmark"}


@dataclass
class Source:
    path: Path
    title: str
    kind: str
    url: str
    captured: str
    image: str
    tags: list[str]
    summary: str
    why: str
    details: str

    @property
    def note_url(self) -> str:
        return "/" + quote(self.path.with_suffix("").as_posix(), safe="/")

    @property
    def categories(self) -> list[str]:
        useful = [tag for tag in self.tags if tag not in GENERIC_TAGS and tag != self.kind]
        if self.kind == "design":
            useful = [tag for tag in useful if tag != "design"]
        return useful or [self.kind or "uncategorised"]


def parse_frontmatter(text: str) -> dict[str, str]:
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---", 4)
    if end < 0:
        return {}
    values: dict[str, str] = {}
    for line in text[4:end].splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip().strip('"\'')
    return values


def parse_tags(raw: str) -> list[str]:
    value = raw.strip()
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    return [tag.strip().strip('"\'') for tag in value.split(",") if tag.strip()]


def section(text: str, heading: str) -> str:
    match = re.search(
        rf"^## {re.escape(heading)}\s*$\n(.*?)(?=^## |\Z)",
        text,
        flags=re.MULTILINE | re.DOTALL,
    )
    if not match:
        return ""
    value = match.group(1).strip()
    value = re.sub(r"^>\s?", "", value, flags=re.MULTILINE)
    return plain_text(value)


def summary(text: str) -> str:
    match = re.search(r"^\*\*TL;DR\*\*\s*[—-]\s*(.+)$", text, flags=re.MULTILINE)
    return plain_text(match.group(1)) if match else ""


def plain_text(value: str) -> str:
    value = re.sub(r"!\[\[[^\]]+\]\]", "", value)
    value = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", value)
    value = re.sub(r"\[\[([^\]]+)\]\]", r"\1", value)
    value = re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", value)
    value = re.sub(r"[*_`]+", "", value)
    return " ".join(value.split())


def image_path(frontmatter: dict[str, str], text: str) -> str:
    # Permanent capture originals live in R2. The private remote runner publisher
    # resolves this stable URI into its owner-only staging tree before Astro
    # sees the generated page.
    candidate = frontmatter.get("brain_object", "")
    if candidate.startswith("brain://capture/"):
        return candidate
    candidate = frontmatter.get("image", "")
    if not candidate:
        match = re.search(r"^IMAGE-LOCAL:\s*(\S+)$", text, flags=re.MULTILINE)
        if match:
            candidate = match.group(1)
    if not candidate:
        match = re.search(r"!\[\[([^\]|]+\.(?:png|jpe?g|webp|gif))(?:\|[^\]]+)?\]\]", text, flags=re.I)
        if match:
            candidate = "system/attachments/" + Path(match.group(1)).name
    candidate = candidate.lstrip("/")
    if candidate and not candidate.startswith("system/attachments/"):
        candidate = "system/attachments/" + Path(candidate).name
    return candidate


def load_sources(root: Path) -> list[Source]:
    result: list[Source] = []
    sources_dir = root / "sources"
    if not sources_dir.exists():
        return result
    for path in sorted(sources_dir.rglob("*.md")):
        text = path.read_text(encoding="utf-8")
        fm = parse_frontmatter(text)
        kind = fm.get("type", "").lower()
        url = fm.get("url", "")
        tags = parse_tags(fm.get("tags", ""))
        if kind == "transcript" or not url or any(tag.startswith("needs/") for tag in tags):
            continue
        result.append(
            Source(
                path=path.relative_to(root),
                title=fm.get("title") or path.stem,
                kind=kind or "article",
                url=url,
                captured=fm.get("captured", ""),
                image=image_path(fm, text),
                tags=tags,
                summary=summary(text),
                why=section(text, "Why saved"),
                details=" ".join(
                    value for value in (section(text, "Key points"), section(text, "Visual index")) if value
                ),
            )
        )
    return sorted(result, key=lambda item: (item.captured, item.title.lower()), reverse=True)


def esc(value: str) -> str:
    return html.escape(value, quote=True)


def label(tag: str) -> str:
    return tag.rsplit("/", 1)[-1].replace("-", " ").title()


def filters(items: list[Source]) -> str:
    categories = sorted({category for item in items for category in item.categories}, key=label)
    buttons = ['<button class="is-active" type="button" data-library-filter="all">All</button>']
    buttons.extend(
        f'<button type="button" data-library-filter="{esc(category)}">{esc(label(category))}</button>'
        for category in categories
    )
    return (
        '<div class="brain-library-tools">'
        '<label><span>Search</span><input type="search" data-library-search placeholder="Find by title, context, or tag"></label>'
        f'<div class="brain-library-filters" role="group" aria-label="Filter library">{"".join(buttons)}</div>'
        "</div>"
    )


def tag_chips(item: Source) -> str:
    return "".join(f"<span>{esc(label(tag))}</span>" for tag in item.categories[:4])


def design_card(item: Source) -> str:
    searchable = " ".join([item.title, item.summary, item.why, item.details, *item.tags]).lower()
    tags = " ".join(item.categories)
    if item.image:
        image_url = item.image if item.image.startswith("brain://capture/") else "/" + item.image
        media = (
            f'<img src="{esc(image_url)}" alt="Design capture: {esc(item.title)}" loading="lazy" decoding="async">'
        )
    else:
        media = '<div class="brain-library-placeholder"><span>Preview pending</span></div>'
    context = item.summary or "Context will be added when the Librarian can retrieve this source."
    why = f'<p class="brain-library-why"><strong>Capture context</strong> {esc(item.why)}</p>' if item.why else ""
    return (
        f'<article class="brain-design-card" data-library-card data-tags="{esc(tags)}" data-search="{esc(searchable)}">'
        f'<a class="brain-design-media" href="{esc(item.url)}" target="_blank" rel="noopener noreferrer">{media}</a>'
        '<div class="brain-design-copy">'
        f'<div class="brain-library-meta"><span>{esc(item.captured or "Undated")}</span><div>{tag_chips(item)}</div></div>'
        f'<h2><a href="{esc(item.note_url)}">{esc(item.title)}</a></h2>'
        f'<p>{esc(context)}</p>'
        f'{why}'
        f'<a class="brain-source-link" href="{esc(item.url)}" target="_blank" rel="noopener noreferrer">Open original <span aria-hidden="true">↗</span></a>'
        "</div></article>"
    )


def bookmark_row(item: Source) -> str:
    searchable = " ".join([item.title, item.summary, item.why, item.details, item.kind, *item.tags]).lower()
    tags = " ".join(item.categories)
    context = item.summary or "The Librarian has not added a source summary yet."
    why = f'<p class="brain-library-why"><strong>Capture context</strong> {esc(item.why)}</p>' if item.why else ""
    return (
        f'<article class="brain-bookmark-row" data-library-card data-tags="{esc(tags)}" data-search="{esc(searchable)}">'
        '<div class="brain-bookmark-main">'
        f'<div class="brain-library-meta"><span>{esc(label(item.kind))}</span><span>{esc(item.captured or "Undated")}</span></div>'
        f'<h2><a href="{esc(item.url)}" target="_blank" rel="noopener noreferrer">{esc(item.title)}</a></h2>'
        f'<p>{esc(context)}</p>'
        f'{why}'
        "</div>"
        f'<div class="brain-bookmark-side"><div class="brain-tag-row">{tag_chips(item)}</div><a href="{esc(item.note_url)}">Brain note</a></div>'
        "</article>"
    )


def page(title: str, lede: str, items: list[Source], kind: str, cards: str) -> str:
    count_label = f"{len(items)} saved {kind if len(items) == 1 else kind + 's'}"
    empty = (
        '<div class="brain-library-empty" data-library-empty>'
        "Nothing matches this view yet. Clear the search or save something new."
        "</div>"
    )
    return f"""---
title: {title}
description: {lede}
tags: [pkm, library]
---

<div class="brain-library-hero">
  <p class="brain-eyebrow">Living collection</p>
  <h1>{title}</h1>
  <p>{lede}</p>
  <span data-library-count>{count_label}</span>
</div>

<section class="brain-library" data-library-kind="{kind}">
{filters(items)}
<div class="brain-library-grid brain-library-grid--{kind}">
{cards}
</div>
{empty}
</section>
"""


def build(root: Path) -> tuple[int, int]:
    sources = load_sources(root)
    designs = [item for item in sources if item.kind == "design"]
    bookmarks = [item for item in sources if item.kind != "design"]
    (root / "designs.md").write_text(
        page(
            "Design library",
            "A visual wall of references saved from around the web, organised by the evidence and tags in your Brain.",
            designs,
            "design",
            "\n".join(design_card(item) for item in designs),
        ),
        encoding="utf-8",
    )
    (root / "bookmarks.md").write_text(
        page(
            "Bookmark library",
            "Saved links with the reason, useful context, and connected Brain note kept together.",
            bookmarks,
            "bookmark",
            "\n".join(bookmark_row(item) for item in bookmarks),
        ),
        encoding="utf-8",
    )
    return len(designs), len(bookmarks)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    designs, bookmarks = build(args.root.resolve())
    print(f"libraries: {designs} design(s), {bookmarks} bookmark(s)")


if __name__ == "__main__":
    main()
