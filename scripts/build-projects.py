#!/usr/bin/env python3
"""Generate privacy-safe project cards and linked-note review pages."""

from __future__ import annotations

import argparse
import ast
import html
import json
import re
import sys
from dataclasses import dataclass, replace
from datetime import date
from pathlib import Path
from typing import Iterable, Optional

START_MARKER = "<!-- PROJECTS:START -->"
END_MARKER = "<!-- PROJECTS:END -->"
STATUS_ORDER = {"active": 0, "paused": 1, "done": 2}
GENERATED_DIRECTORY = "project-notes"
GENERATED_BY = "build-projects.py"
PUBLISHED_DIRECTORIES = ("notes", "sources")
WIKILINK = re.compile(r"\[\[([^\]\n]+)\]\]")


@dataclass(frozen=True)
class Project:
    name: str
    title: str
    status: str
    started: str
    last_active: str
    parent: str
    slug: str
    links: frozenset[str]

    @property
    def activity(self) -> str:
        return max(self.started, self.last_active)

    @property
    def match_keys(self) -> frozenset[str]:
        relative = self.name if self.parent == "." else f"{self.parent}/{self.name}"
        return frozenset(
            {
                normalize_key(self.name),
                normalize_key(relative),
                normalize_key(f"projects/{relative}"),
            }
        )


@dataclass(frozen=True)
class ProjectNote:
    title: str
    kind: str
    captured: str
    state: str
    state_label: str
    url: str

    @property
    def search_text(self) -> str:
        return " ".join((self.title, self.kind, self.captured, self.state_label)).lower()


def _strip_yaml_comment(value: str) -> str:
    quote = ""
    escaped = False
    for index, character in enumerate(value):
        if escaped:
            escaped = False
            continue
        if character == "\\" and quote == '"':
            escaped = True
            continue
        if character in "'\"":
            if not quote:
                quote = character
            elif quote == character:
                quote = ""
            continue
        if character == "#" and not quote and (index == 0 or value[index - 1].isspace()):
            return value[:index].strip()
    if quote:
        raise ValueError("unterminated quoted scalar")
    return value.strip()


def _yaml_value(raw: str) -> object:
    value = _strip_yaml_comment(raw)
    if not value:
        return None
    if value[0] in "'\"":
        try:
            parsed = ast.literal_eval(value)
        except (SyntaxError, ValueError) as error:
            raise ValueError("invalid quoted scalar") from error
        if not isinstance(parsed, str):
            raise ValueError("invalid quoted scalar")
        return parsed
    if value.startswith("["):
        if not value.endswith("]"):
            raise ValueError("unterminated flow sequence")
        inner = value[1:-1].strip()
        return [] if not inner else [_yaml_value(item) for item in inner.split(",")]
    if value.startswith(("{", "|", ">", "&", "*", "!")):
        raise ValueError("unsupported YAML value")
    if value.lower() in ("true", "false"):
        return value.lower() == "true"
    if value.lower() in ("null", "~"):
        return None
    return value


def parse_frontmatter(text: str) -> tuple[dict[str, object], str]:
    if not text.startswith("---\n"):
        return {}, text
    match = re.match(r"\A---\n(.*?)\n---(?:\n|\Z)", text, flags=re.DOTALL)
    if not match:
        raise ValueError("frontmatter starts with '---' but has no closing '---'")
    values: dict[str, object] = {}
    for offset, line in enumerate(match.group(1).splitlines(), 2):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[:1].isspace() or ":" not in line:
            raise ValueError(f"malformed YAML frontmatter at line {offset}: expected a scalar mapping")
        key, raw = line.split(":", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", key):
            raise ValueError(f"malformed YAML frontmatter at line {offset}: invalid metadata key")
        if key in values:
            raise ValueError(f"malformed YAML frontmatter at line {offset}: duplicate metadata key: {key!r}")
        try:
            values[key] = _yaml_value(raw)
        except ValueError as error:
            raise ValueError(f"malformed YAML frontmatter at line {offset}: {error}") from error
    return values, text[match.end() :]


def valid_date(value: object, field: str) -> str:
    if isinstance(value, date):
        return value.isoformat()
    if not isinstance(value, str):
        raise ValueError(f"{field} must be YYYY-MM-DD")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        raise ValueError(f"{field} must be YYYY-MM-DD")
    try:
        date.fromisoformat(value)
    except ValueError as error:
        raise ValueError(f"{field} is not a valid date") from error
    return value


def section(body: str, heading: str) -> str:
    match = re.search(
        rf"^## {re.escape(heading)}\s*$\n(.*?)(?=^##\s|\Z)",
        body,
        flags=re.MULTILINE | re.DOTALL,
    )
    return match.group(1).strip() if match else ""


def scalar(value: object, field: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a string")
    return value


def normalize_key(value: str) -> str:
    value = value.strip().replace("\\", "/")
    if value.lower().endswith(".md"):
        value = value[:-3]
    return value.strip("/").casefold()


def wikilinks(text: str) -> frozenset[str]:
    targets: set[str] = set()
    for match in WIKILINK.finditer(text):
        target = match.group(1).split("|", 1)[0].split("#", 1)[0].strip()
        if target:
            targets.add(normalize_key(target))
    return frozenset(targets)


def metadata_values(frontmatter: dict[str, object], *fields: str) -> frozenset[str]:
    values: set[str] = set()
    for field in fields:
        value = frontmatter.get(field)
        candidates: Iterable[object]
        if isinstance(value, list):
            candidates = value
        else:
            candidates = (value,)
        for candidate in candidates:
            if isinstance(candidate, str) and candidate.strip():
                values.add(normalize_key(candidate))
    return frozenset(values)


def site_slug(value: str) -> str:
    result = re.sub(r"\s", "-", value).replace("&", "-and-").replace("%", "-percent")
    result = result.replace("?", "").replace("#", "")
    if not result or result in (".", "..") or "/" in result or "\\" in result:
        raise ValueError("project path cannot produce a safe notes-page slug")
    return result


def load_project(path: Path, projects_dir: Path, body: str, frontmatter: dict[str, object]) -> Project:
    status = scalar(frontmatter.get("status", ""), "status").lower()
    if status not in STATUS_ORDER:
        raise ValueError("status must be one of: active, paused, done")
    started = valid_date(frontmatter.get("started", ""), "started")

    # Only structured dates are read from the body. Log prose and all other
    # freeform project content must never enter the generated homepage.
    log = section(body, "Log")
    dates = re.findall(r"^\s*[-*+]\s+(\d{4}-\d{2}-\d{2})\s+[—-]\s+.+$", log, flags=re.MULTILINE)
    if not dates:
        raise ValueError("'## Log' must contain at least one dated entry")
    for value in dates:
        valid_date(value, "log date")

    relative = path.relative_to(projects_dir).with_suffix("")
    return Project(
        name=path.stem,
        # Filenames are the canonical, deliberately public display label. Do
        # not publish a freeform frontmatter title.
        title=path.stem,
        status=status,
        started=started,
        last_active=max(dates),
        parent=path.parent.relative_to(projects_dir).as_posix(),
        slug=site_slug("--".join(relative.parts)),
        links=wikilinks(body),
    )


def load_projects(root: Path, projects_dir: Optional[Path] = None) -> list[Project]:
    projects: list[Project] = []
    errors: list[str] = []
    projects_dir = (root / "projects") if projects_dir is None else projects_dir
    if projects_dir.exists():
        paths = sorted(
            projects_dir.rglob("*.md"),
            key=lambda path: (
                path.relative_to(projects_dir).as_posix().casefold(),
                path.relative_to(projects_dir).as_posix(),
            ),
        )
        for path in paths:
            try:
                if path.is_symlink():
                    raise ValueError("project metadata must not be a symlink")
                text = path.read_text(encoding="utf-8")
                frontmatter, body = parse_frontmatter(text)
                note_type = scalar(frontmatter.get("type", ""), "type").lower()
                if note_type != "project":
                    continue
                projects.append(load_project(path, projects_dir, body, frontmatter))
            except (OSError, UnicodeError, ValueError) as error:
                try:
                    display_path = path.relative_to(root)
                except ValueError:
                    display_path = Path("projects") / path.relative_to(projects_dir)
                errors.append(f"{display_path}: {error}")
    if errors:
        raise ValueError("invalid project metadata:\n  " + "\n  ".join(errors))

    title_counts: dict[str, int] = {}
    for project in projects:
        key = project.title.casefold()
        title_counts[key] = title_counts.get(key, 0) + 1
    projects = [
        replace(
            project,
            title=f"{project.title} — {'projects' if project.parent == '.' else project.parent}/",
        )
        if title_counts[project.title.casefold()] > 1
        else project
        for project in projects
    ]
    slug_counts: dict[str, int] = {}
    for project in projects:
        key = project.slug.casefold()
        slug_counts[key] = slug_counts.get(key, 0) + 1
    duplicate_slugs = sorted(slug for slug, count in slug_counts.items() if count > 1)
    if duplicate_slugs:
        raise ValueError("project note-page slugs collide: " + ", ".join(duplicate_slugs))
    return sorted(
        projects,
        key=lambda item: (STATUS_ORDER[item.status], -date.fromisoformat(item.activity).toordinal(), item.title.casefold()),
    )


def esc(value: str) -> str:
    return html.escape(value, quote=True)


def _note_keys(path: Path, root: Path) -> frozenset[str]:
    relative = path.relative_to(root).with_suffix("").as_posix()
    return frozenset({normalize_key(path.stem), normalize_key(relative)})


def _note_url(path: Path, root: Path) -> str:
    relative = path.relative_to(root).with_suffix("")
    return "/" + "/".join(site_slug(part) for part in relative.parts)


def _captured(frontmatter: dict[str, object], path: Path) -> str:
    value = frontmatter.get("captured")
    if isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        try:
            return date.fromisoformat(value).isoformat()
        except ValueError:
            pass
    match = re.match(r"(\d{4}-\d{2}-\d{2})", path.name)
    if match:
        try:
            return date.fromisoformat(match.group(1)).isoformat()
        except ValueError:
            pass
    return ""


def _kind(frontmatter: dict[str, object], path: Path) -> str:
    value = frontmatter.get("type")
    return value.strip().lower() if isinstance(value, str) and value.strip() else path.parent.name.rstrip("s") or "note"


def _title(frontmatter: dict[str, object], path: Path, *, pending: bool) -> str:
    value = frontmatter.get("title")
    if isinstance(value, str) and value.strip():
        return value.strip()
    captured = _captured(frontmatter, path)
    return f"Capture from {captured}" if pending and captured else ("Waiting capture" if pending else path.stem)


def _state(frontmatter: dict[str, object], *, pending: bool) -> tuple[str, str]:
    if not pending:
        return "processed", "Processed"
    tags = frontmatter.get("tags", [])
    values = tags if isinstance(tags, list) else [tags]
    if any(isinstance(tag, str) and tag.strip().lower().startswith("needs/") for tag in values):
        return "needs-attention", "Needs attention"
    return "waiting", "Waiting"


def _matches(project: Project, path: Path, root: Path, body: str, frontmatter: dict[str, object]) -> bool:
    direct = metadata_values(frontmatter, "entity", "project", "projects") | wikilinks(body)
    return bool(direct & project.match_keys or project.links & _note_keys(path, root))


def _load_note(path: Path, root: Path, *, pending: bool) -> tuple[dict[str, object], str, ProjectNote]:
    if path.is_symlink():
        raise ValueError("project-linked note metadata must not be a symlink")
    text = path.read_text(encoding="utf-8")
    frontmatter, body = parse_frontmatter(text)
    state, state_label = _state(frontmatter, pending=pending)
    return (
        frontmatter,
        body,
        ProjectNote(
            title=_title(frontmatter, path, pending=pending),
            kind=_kind(frontmatter, path),
            captured=_captured(frontmatter, path),
            state=state,
            state_label=state_label,
            url="" if pending else _note_url(path, root),
        ),
    )


def load_project_notes(root: Path, data_root: Path, projects: list[Project]) -> dict[str, list[ProjectNote]]:
    result = {project.slug: [] for project in projects}
    errors: list[str] = []
    candidates: list[tuple[Path, Path, bool]] = []
    for directory in PUBLISHED_DIRECTORIES:
        base = root / directory
        if base.exists():
            candidates.extend((path, root, False) for path in sorted(base.rglob("*.md")))
    inbox = data_root / "inbox"
    if inbox.exists():
        candidates.extend(
            (path, data_root, True)
            for path in sorted(inbox.rglob("*.md"))
            if path.name.casefold() != "readme.md"
        )

    for path, content_root, pending in candidates:
        try:
            frontmatter, body, note = _load_note(path, content_root, pending=pending)
            for project in projects:
                if _matches(project, path, content_root, body, frontmatter):
                    result[project.slug].append(note)
        except (OSError, UnicodeError, ValueError) as error:
            try:
                display_path = path.relative_to(data_root if pending else root)
            except ValueError:
                display_path = path
            errors.append(f"{display_path}: {error}")
    if errors:
        raise ValueError("invalid project-linked note metadata:\n  " + "\n  ".join(errors))

    state_order = {"needs-attention": 0, "waiting": 1, "processed": 2}
    for notes in result.values():
        notes.sort(
            key=lambda note: (
                state_order[note.state],
                -(date.fromisoformat(note.captured).toordinal() if note.captured else 0),
                note.title.casefold(),
            )
        )
    return result


def project_card(project: Project, notes: list[ProjectNote]) -> str:
    searchable = f"{project.title} {project.status}".lower()
    note_label = f"{len(notes)} linked {'note' if len(notes) == 1 else 'notes'}"
    return (
        f'<article class="brain-project-card brain-project-card--{esc(project.status)}" '
        f'data-library-card data-tags="{esc(project.status)}" data-search="{esc(searchable)}">'
        '<div class="brain-project-head">'
        f'<h3><a href="/{GENERATED_DIRECTORY}/{esc(project.slug)}">{esc(project.title)}</a></h3>'
        f'<span class="brain-project-status">{esc(project.status.title())}</span>'
        "</div>"
        '<div class="brain-project-meta">'
        f'<span>Started <time datetime="{esc(project.started)}">{esc(project.started)}</time></span>'
        f'<span>Last active <time datetime="{esc(project.last_active)}">{esc(project.last_active)}</time></span>'
        "</div>"
        f'<a class="brain-project-notes-link" href="/{GENERATED_DIRECTORY}/{esc(project.slug)}">{esc(note_label)}</a>'
        "</article>"
    )


def render(projects: list[Project], project_notes: dict[str, list[ProjectNote]]) -> str:
    counts = {status: sum(project.status == status for project in projects) for status in STATUS_ORDER}
    buttons = ['<button class="is-active" type="button" data-library-filter="all" aria-pressed="true">All</button>']
    buttons.extend(
        f'<button type="button" data-library-filter="{status}">{status.title()} ({counts[status]})</button>'
        for status in STATUS_ORDER
    )
    cards = "\n".join(project_card(project, project_notes[project.slug]) for project in projects)
    empty = '<p class="brain-library-empty" data-library-empty hidden>No projects match this view.</p>'
    return (
        '<section class="brain-projects brain-library" data-library-kind="project">\n'
        '  <div class="brain-library-tools brain-project-tools">\n'
        '    <label><span>Search projects</span><input type="search" name="project-search" data-library-search '
        'placeholder="Find by title"></label>\n'
        f'    <div class="brain-library-filters" role="group" aria-label="Filter projects by status">{"".join(buttons)}</div>\n'
        "  </div>\n"
        '  <div class="brain-project-grid">\n'
        f'{cards}\n'
        "  </div>\n"
        f'  {empty}\n'
        "</section>"
    )


def project_note_row(note: ProjectNote) -> str:
    date_markup = (
        f'<time datetime="{esc(note.captured)}">{esc(note.captured)}</time>' if note.captured else "Undated"
    )
    title = (
        f'<a href="{esc(note.url)}">{esc(note.title)}</a>'
        if note.url
        else f'<span>{esc(note.title)}</span>'
    )
    availability = (
        "Open the processed Brain note."
        if note.url
        else "The capture is retained and will become clickable after processing."
    )
    return (
        f'<article class="brain-project-note-row brain-project-note-row--{esc(note.state)}" '
        f'data-library-card data-tags="{esc(note.state)}" data-search="{esc(note.search_text)}">'
        '<div class="brain-project-note-main">'
        '<div class="brain-project-note-meta">'
        f'<span class="brain-project-note-state">{esc(note.state_label)}</span>'
        f'<span>{esc(note.kind.replace("-", " ").title())}</span>'
        f'<span>{date_markup}</span>'
        "</div>"
        f'<h2>{title}</h2>'
        f'<p>{esc(availability)}</p>'
        "</div>"
        "</article>"
    )


def project_page(project: Project, notes: list[ProjectNote]) -> str:
    counts = {
        state: sum(note.state == state for note in notes)
        for state in ("processed", "waiting", "needs-attention")
    }
    filters = [
        '<button class="is-active" type="button" data-library-filter="all" aria-pressed="true">All</button>',
        f'<button type="button" data-library-filter="processed">Processed ({counts["processed"]})</button>',
        f'<button type="button" data-library-filter="waiting">Waiting ({counts["waiting"]})</button>',
        f'<button type="button" data-library-filter="needs-attention">Needs attention ({counts["needs-attention"]})</button>',
    ]
    rows = "\n".join(project_note_row(note) for note in notes)
    count_label = f"{len(notes)} linked {'note' if len(notes) == 1 else 'notes'}"
    description = f"Processed notes and explicitly routed captures connected to {project.title}."
    empty_text = (
        "No notes are associated yet. This page will populate after processing links a note or capture to the project."
        if not notes
        else "No notes match this view. Clear the search or choose another status."
    )
    empty = (
        '<div class="brain-library-empty" data-library-empty>'
        f"{empty_text}"
        "</div>"
    )
    return f'''---
title: {json.dumps(project.title + " — Project notes", ensure_ascii=False)}
description: {json.dumps(description, ensure_ascii=False)}
type: map
status: filed
generated_by: {GENERATED_BY}
---

<a class="brain-project-back" href="/projects">All projects</a>

<div class="brain-project-note-intro">
  <div class="brain-project-note-heading">
    <p>Project knowledge</p>
    <span class="brain-project-status">{esc(project.status.title())}</span>
  </div>
  <p>{esc(description)} Waiting captures appear only when they already have an explicit project link; raw inbox and project prose remain private.</p>
  <dl class="brain-project-note-stats">
    <div><dt>Processed</dt><dd>{counts["processed"]}</dd></div>
    <div><dt>Waiting</dt><dd>{counts["waiting"]}</dd></div>
    <div><dt>Needs attention</dt><dd>{counts["needs-attention"]}</dd></div>
  </dl>
</div>

<section class="brain-library brain-project-note-library" data-library-kind="note">
  <div class="brain-project-note-toolbar">
    <span data-library-count>{esc(count_label)}</span>
  </div>
  <div class="brain-library-tools">
    <label><span>Search project notes</span><input type="search" name="project-note-search" data-library-search placeholder="Find by title, type, or date"></label>
    <div class="brain-library-filters" role="group" aria-label="Filter project notes by processing state">{"".join(filters)}</div>
  </div>
  <div class="brain-project-note-list">
{rows}
  </div>
  {empty}
</section>
'''


def expected_project_pages(projects: list[Project], project_notes: dict[str, list[ProjectNote]]) -> dict[str, str]:
    return {f"{project.slug}.md": project_page(project, project_notes[project.slug]) for project in projects}


def current_project_pages(root: Path) -> dict[str, str]:
    directory = root / GENERATED_DIRECTORY
    if not directory.exists():
        return {}
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"{GENERATED_DIRECTORY} must be a regular directory")
    result: dict[str, str] = {}
    for path in sorted(directory.iterdir()):
        if path.is_symlink() or not path.is_file() or path.suffix.lower() != ".md":
            raise ValueError(f"{GENERATED_DIRECTORY} may contain only generated Markdown pages")
        text = path.read_text(encoding="utf-8")
        frontmatter, _body = parse_frontmatter(text)
        if frontmatter.get("generated_by") != GENERATED_BY:
            raise ValueError(f"refusing to replace unmanaged page: {GENERATED_DIRECTORY}/{path.name}")
        result[path.name] = text
    return result


def write_project_pages(root: Path, pages: dict[str, str]) -> bool:
    directory = root / GENERATED_DIRECTORY
    directory.mkdir(mode=0o700, exist_ok=True)
    current = current_project_pages(root)
    changed = current != pages
    if not changed:
        return False
    for stale in current.keys() - pages.keys():
        (directory / stale).unlink()
    for name, text in pages.items():
        path = directory / name
        if current.get(name) != text:
            path.write_text(text, encoding="utf-8")
    return True


def replace_generated(index: str, generated: str) -> str:
    if index.count(START_MARKER) != 1 or index.count(END_MARKER) != 1:
        raise ValueError("index.md must contain exactly one PROJECTS marker pair")
    start = index.index(START_MARKER)
    end = index.index(END_MARKER)
    if end < start:
        raise ValueError("PROJECTS:END appears before PROJECTS:START")
    return index[: start + len(START_MARKER)] + "\n" + generated + "\n" + index[end:]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument(
        "--projects-root",
        type=Path,
        help="read private project metadata from this directory while writing only to root/index.md",
    )
    parser.add_argument("--check", action="store_true", help="fail without writing when index.md is stale")
    args = parser.parse_args()
    root = args.root.resolve()
    index_path = root / "index.md"
    try:
        current = index_path.read_text(encoding="utf-8")
        projects_root = args.projects_root.resolve() if args.projects_root else None
        projects = load_projects(root, projects_root)
        data_root = projects_root.parent if projects_root else root
        project_notes = load_project_notes(root, data_root, projects)
        expected = replace_generated(current, render(projects, project_notes))
        expected_pages = expected_project_pages(projects, project_notes)
        current_pages = current_project_pages(root)
    except (OSError, ValueError) as error:
        print(f"projects: error: {error}", file=sys.stderr)
        return 2

    if args.check:
        if current != expected or current_pages != expected_pages:
            print("projects: generated project views are stale; run scripts/build-projects.py", file=sys.stderr)
            return 1
        print(f"projects: generated views are current ({len(projects)} project(s))")
        return 0

    pages_changed = write_project_pages(root, expected_pages)
    if current != expected:
        index_path.write_text(expected, encoding="utf-8")
        index_changed = True
    else:
        index_changed = False
    action = "updated" if index_changed or pages_changed else "unchanged"
    print(f"projects: {action} project views ({len(projects)} project(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
