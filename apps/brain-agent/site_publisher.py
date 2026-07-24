#!/usr/bin/env python3
"""Build and deploy the private Brain site without publishing the data folder."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator, Mapping, Optional, Sequence


PROJECT = "brain-vault"
PRODUCTION_BRANCH = "main"
ROOT_PAGES = ("index.md", "designs.md", "bookmarks.md")
CONTENT_DIRECTORIES = ("sources", "notes", "maps")
GENERATED_DIRECTORIES = ("project-notes",)
FORBIDDEN_NAMES = frozenset(
    ("me", "daily", "people", "projects", "inbox", ".trash", ".git", ".github", ".obsidian")
)
PUBLIC_TOP_LEVEL = frozenset(
    (
        "404.html",
        "_astro",
        "bookmarks.html",
        "designs.html",
        "favicon.svg",
        "index.html",
        "maps",
        "notes",
        "pagefind",
        "project-notes",
        "projects.html",
        "robots.txt",
        "sources",
        "system",
        "tags",
        "tags.html",
    )
)
CAPTURE_URI = re.compile(
    r"brain://capture/([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})",
    re.IGNORECASE,
)
SHA256 = re.compile(r"^[0-9a-f]{64}$")
LOCAL_ATTACHMENT = re.compile(
    r"(?<![A-Za-z0-9_])/?(system/attachments/[A-Za-z0-9][^\]\)\"'<>\r\n]*)"
)
SAFE_FILENAME = re.compile(r"^[^/\\\x00\r\n]{1,255}$")


class PublisherError(RuntimeError):
    """A controlled publication failure with a status-safe error code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class PublisherConfig:
    gateway_url: str
    site_url: str
    account_id: str
    code_root: Path
    data_root: Path
    state_dir: Path


@dataclass(frozen=True)
class ObjectReference:
    capture_id: str
    sha256: str
    size: int
    mime: str
    filename: str


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _private_regular_json(path: Path) -> Mapping[str, Any]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            metadata = os.fstat(handle.fileno())
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
                or stat.S_IMODE(metadata.st_mode) & 0o077
            ):
                raise PublisherError("invalid_config", "publisher config must be an owner-only regular file")
            value = json.load(handle)
    except PublisherError:
        raise
    except (OSError, UnicodeError, ValueError) as error:
        raise PublisherError("invalid_config", "publisher config could not be read") from error
    if not isinstance(value, dict):
        raise PublisherError("invalid_config", "publisher config must be a JSON object")
    return value


def load_config(path: Path) -> PublisherConfig:
    if not path.is_absolute():
        raise PublisherError("invalid_config", "publisher config path must be absolute")
    value = _private_regular_json(path)
    try:
        gateway_url = value["gateway_url"]
        site_url = value["site_url"]
        account_id = value["account_id"]
        code_root = Path(value["code_root"])
        data_root = Path(value["data_root"])
        state_dir = Path(value["state_dir"])
    except (KeyError, TypeError) as error:
        raise PublisherError("invalid_config", "publisher config fields are incomplete") from error
    parsed = urllib.parse.urlsplit(gateway_url if isinstance(gateway_url, str) else "")
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
        raise PublisherError("invalid_config", "publisher gateway URL is invalid")
    parsed_site = urllib.parse.urlsplit(site_url if isinstance(site_url, str) else "")
    if (
        parsed_site.scheme != "https"
        or not parsed_site.hostname
        or parsed_site.username
        or parsed_site.password
        or parsed_site.query
        or parsed_site.fragment
    ):
        raise PublisherError("invalid_config", "publisher site URL is invalid")
    if not isinstance(account_id, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", account_id):
        raise PublisherError("invalid_config", "publisher account ID is invalid")
    roots = (code_root, data_root, state_dir)
    if any(not root.is_absolute() or not root.is_dir() for root in roots):
        raise PublisherError("invalid_config", "publisher roots must be existing absolute directories")
    resolved = tuple(root.resolve() for root in roots)
    if resolved[0] == resolved[1] or resolved[0] in resolved[1].parents or resolved[1] in resolved[0].parents:
        raise PublisherError("invalid_config", "publisher code and data roots must be separate")
    if any(
        resolved[2] == root or resolved[2] in root.parents or root in resolved[2].parents
        for root in resolved[:2]
    ):
        raise PublisherError("invalid_config", "publisher state must be separate from code and data roots")
    site = code_root / "site"
    if not (site / "astro.config.mjs").is_file() or not (site / "package.json").is_file():
        raise PublisherError("invalid_config", "Astro site source is missing from code_root")
    marker = data_root / ".brain-data-root"
    if marker.is_symlink() or not marker.is_file():
        raise PublisherError("invalid_config", "data_root is not an initialized Brain data folder")
    return PublisherConfig(gateway_url.rstrip("/"), site_url.rstrip("/"), account_id, *resolved)


def _frontmatter(text: str) -> Mapping[str, str]:
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---", 4)
    if end < 0:
        return {}
    result: dict[str, str] = {}
    for line in text[4:end].splitlines():
        if ":" not in line:
            continue
        key, raw = line.split(":", 1)
        value = raw.strip()
        if value.startswith('"'):
            try:
                decoded = json.loads(value)
                value = decoded if isinstance(decoded, str) else value
            except ValueError:
                pass
        result[key.strip()] = value
    return result


def _object_metadata(markdown: Mapping[Path, str]) -> dict[str, ObjectReference]:
    references: dict[str, ObjectReference] = {}
    mentioned = {match.group(1).lower() for text in markdown.values() for match in CAPTURE_URI.finditer(text)}
    for text in markdown.values():
        metadata = _frontmatter(text)
        match = CAPTURE_URI.fullmatch(metadata.get("brain_object", ""))
        if not match:
            continue
        capture_id = match.group(1).lower()
        digest = metadata.get("object_sha256", "")
        raw_size = metadata.get("object_size", "")
        mime = metadata.get("object_mime", "")
        filename = metadata.get("object_filename", "")
        if not SHA256.fullmatch(digest):
            raise PublisherError("invalid_object_metadata", "published object hash is invalid")
        try:
            size = int(raw_size)
        except ValueError as error:
            raise PublisherError("invalid_object_metadata", "published object size is invalid") from error
        if size < 0 or size > 2 * 1024 * 1024 * 1024:
            raise PublisherError("invalid_object_metadata", "published object size is outside the supported range")
        if not mime or any(character in mime for character in "\r\n"):
            raise PublisherError("invalid_object_metadata", "published object MIME type is invalid")
        if not SAFE_FILENAME.fullmatch(filename) or filename in (".", ".."):
            raise PublisherError("invalid_object_metadata", "published object filename is invalid")
        candidate = ObjectReference(capture_id, digest, size, mime, filename)
        if capture_id in references and references[capture_id] != candidate:
            raise PublisherError("invalid_object_metadata", "published object metadata conflicts")
        references[capture_id] = candidate
    missing = mentioned - references.keys()
    if missing:
        raise PublisherError("missing_object_metadata", "a published capture reference has no verified metadata")
    return references


def _copy_markdown_tree(source: Path, destination: Path) -> None:
    if not source.exists():
        destination.mkdir(mode=0o700, parents=True, exist_ok=True)
        return
    if source.is_symlink() or not source.is_dir():
        raise PublisherError("unsafe_content", "published content directory is unsafe")
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    for current, directories, files in os.walk(source, followlinks=False):
        current_path = Path(current)
        safe_directories: list[str] = []
        for name in sorted(directories):
            child = current_path / name
            if name.startswith(".") or child.is_symlink():
                if child.is_symlink():
                    raise PublisherError("unsafe_content", "published content contains a symlink")
                continue
            safe_directories.append(name)
            target = destination / child.relative_to(source)
            target.mkdir(mode=0o700, parents=True, exist_ok=True)
        directories[:] = safe_directories
        for name in sorted(files):
            source_file = current_path / name
            if source_file.is_symlink():
                raise PublisherError("unsafe_content", "published content contains a symlink")
            if source_file.suffix.lower() != ".md":
                continue
            metadata = source_file.stat()
            if not stat.S_ISREG(metadata.st_mode):
                raise PublisherError("unsafe_content", "published content must be regular files")
            target = destination / source_file.relative_to(source)
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            shutil.copyfile(source_file, target)
            target.chmod(0o600)


def stage_content(config: PublisherConfig, staging: Path) -> None:
    staging.mkdir(mode=0o700)
    index = config.data_root / "index.md"
    if not index.is_file() or index.is_symlink():
        raise PublisherError("missing_index", "data_root/index.md is missing or unsafe")
    shutil.copyfile(index, staging / "index.md")
    (staging / "index.md").chmod(0o600)
    for directory in CONTENT_DIRECTORIES:
        _copy_markdown_tree(config.data_root / directory, staging / directory)


def _markdown_files(root: Path) -> dict[Path, str]:
    result: dict[Path, str] = {}
    for path in sorted(root.rglob("*.md")):
        if path.is_symlink() or not path.is_file():
            raise PublisherError("unsafe_content", "staging contains an unsafe Markdown file")
        try:
            result[path] = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise PublisherError("invalid_markdown", "published Markdown could not be read") from error
    return result


def _remaining(deadline: float) -> float:
    import time

    value = deadline - time.monotonic()
    if value <= 0:
        raise PublisherError("timeout", "site publication timed out")
    return value


def _run(command: Sequence[str], cwd: Path, deadline: float, environment: Optional[Mapping[str, str]] = None) -> None:
    try:
        completed = subprocess.run(
            list(command),
            cwd=cwd,
            env=None if environment is None else dict(environment),
            stdin=subprocess.DEVNULL,
            timeout=_remaining(deadline),
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise PublisherError("timeout", "site publication timed out") from error
    except OSError as error:
        raise PublisherError("command_unavailable", "a site publication command is unavailable") from error
    if completed.returncode != 0:
        raise PublisherError("command_failed", "a site publication command failed")


def run_generators(config: PublisherConfig, staging: Path, deadline: float) -> None:
    python = Path(sys.executable)
    _run((str(python), str(config.code_root / "scripts" / "build-libraries.py"), str(staging)), config.code_root, deadline)
    _run(
        (
            str(python),
            str(config.code_root / "scripts" / "build-projects.py"),
            str(staging),
            "--projects-root",
            str(config.data_root / "projects"),
        ),
        config.code_root,
        deadline,
    )


def _fetch_object(
    config: PublisherConfig,
    reference: ObjectReference,
    destination: Path,
    token: str,
    deadline: float,
) -> None:
    url = config.gateway_url + "/v1/agent/captures/{}/object".format(reference.capture_id)
    request = urllib.request.Request(
        url,
        headers={
            "Accept": reference.mime,
            "Authorization": "Bearer " + token,
            "User-Agent": "Brain-Site-Publisher/1",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=min(30.0, _remaining(deadline))) as response:
            if response.status != 200:
                raise PublisherError("object_fetch_failed", "a capture object fetch failed")
            header_hash = response.headers.get("X-Content-SHA256", "")
            header_size = response.headers.get("Content-Length", "")
            if header_hash and header_hash != reference.sha256:
                raise PublisherError("object_mismatch", "a capture object response hash did not match Markdown")
            if header_size and header_size != str(reference.size):
                raise PublisherError("object_mismatch", "a capture object response size did not match Markdown")
            digest = hashlib.sha256()
            size = 0
            with destination.open("xb") as handle:
                destination.chmod(0o600)
                while True:
                    chunk = response.read(min(1024 * 1024, max(1, reference.size - size + 1)))
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > reference.size:
                        raise PublisherError("object_mismatch", "a capture object was larger than its Markdown size")
                    digest.update(chunk)
                    handle.write(chunk)
    except PublisherError:
        raise
    except (OSError, urllib.error.URLError) as error:
        raise PublisherError("object_fetch_failed", "a capture object fetch failed") from error
    if size != reference.size or digest.hexdigest() != reference.sha256:
        raise PublisherError("object_mismatch", "a capture object did not match its Markdown hash and size")


def resolve_capture_objects(config: PublisherConfig, staging: Path, token: str, deadline: float) -> None:
    markdown = _markdown_files(staging)
    references = _object_metadata(markdown)
    replacements: dict[str, str] = {}
    for capture_id, reference in sorted(references.items()):
        relative = Path("system") / "attachments" / capture_id / reference.filename
        destination = staging / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        _fetch_object(config, reference, destination, token, deadline)
        replacements[capture_id] = "/" + urllib.parse.quote(relative.as_posix(), safe="/")
    for path, text in markdown.items():
        updated = CAPTURE_URI.sub(lambda match: replacements[match.group(1).lower()], text)
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            path.chmod(0o600)


def copy_approved_legacy_attachments(config: PublisherConfig, staging: Path) -> None:
    references: set[str] = set()
    for text in _markdown_files(staging).values():
        for match in LOCAL_ATTACHMENT.finditer(text):
            value = urllib.parse.unquote(match.group(1).strip())
            relative = Path(value)
            if relative.is_absolute() or ".." in relative.parts:
                raise PublisherError("unsafe_attachment", "a published attachment reference is unsafe")
            references.add(relative.as_posix())
    for value in sorted(references):
        destination = staging / value
        if destination.exists():
            continue
        source = config.data_root / value
        if source.is_symlink() or not source.is_file():
            raise PublisherError("missing_attachment", "a referenced legacy attachment is missing or unsafe")
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(0o600)


def assert_staging_allowlist(staging: Path) -> None:
    actual = {path.name for path in staging.iterdir()}
    expected = set(ROOT_PAGES) | set(CONTENT_DIRECTORIES) | set(GENERATED_DIRECTORIES)
    if (staging / "system" / "attachments").exists():
        expected.add("system")
    if actual != expected:
        raise PublisherError("privacy_check_failed", "staging did not match the publication allowlist")
    for forbidden in FORBIDDEN_NAMES:
        if any(path.name == forbidden for path in staging.rglob("*")):
            raise PublisherError("privacy_check_failed", "staging contained a denied path")
    for path in staging.rglob("*"):
        if path.is_symlink():
            raise PublisherError("privacy_check_failed", "staging contained a symlink")


def secure_staging_modes(staging: Path) -> None:
    staging.chmod(0o700)
    for path in staging.rglob("*"):
        path.chmod(0o700 if path.is_dir() else 0o600)


def assert_public_allowlist(public: Path) -> None:
    if not (public / "index.html").is_file():
        raise PublisherError("privacy_check_failed", "Astro did not produce index.html")
    actual = {path.name for path in public.iterdir()}
    if actual not in (PUBLIC_TOP_LEVEL, PUBLIC_TOP_LEVEL - {"system"}):
        raise PublisherError("privacy_check_failed", "Astro output did not match the exact allowlist")
    for forbidden in FORBIDDEN_NAMES:
        if (public / forbidden).exists():
            raise PublisherError("privacy_check_failed", "Astro output contained a denied path")


def _read_status(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_status(path: Path, value: Mapping[str, Any]) -> None:
    temporary = path.with_name("." + path.name + ".tmp-" + str(os.getpid()))
    with temporary.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
    temporary.chmod(0o600)
    os.replace(temporary, path)


def _process_marker(path: Optional[Path]) -> Optional[dict[str, str]]:
    if path is None:
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise PublisherError("process_not_ready", "the latest process marker is unavailable") from error
    if not isinstance(value, dict) or not isinstance(value.get("at"), str) or not isinstance(value.get("summary"), str):
        raise PublisherError("process_not_ready", "the latest process marker is invalid")
    if not value["summary"].startswith("processed inbox ("):
        raise PublisherError("process_not_ready", "the latest successful generation was not inbox processing")
    return {"at": value["at"], "summary": value["summary"]}


@contextlib.contextmanager
def _exclusive_lock(path: Path) -> Iterator[bool]:
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        yield True


def publish(
    config: PublisherConfig,
    *,
    token: str,
    pages_token: str,
    timeout: float,
    process_marker_path: Optional[Path] = None,
    site_command: Optional[Sequence[str]] = None,
    wrangler_command: Optional[Sequence[str]] = None,
) -> str:
    import time

    if not token or any(character.isspace() for character in token):
        raise PublisherError("missing_credential", "the Agent credential is unavailable")
    if not pages_token or any(character.isspace() for character in pages_token):
        raise PublisherError("missing_credential", "the Cloudflare Pages credential is unavailable")
    status_path = config.state_dir / "site-publisher-status.json"
    lock_path = config.state_dir / "site-publisher.lock"
    with _exclusive_lock(lock_path) as acquired:
        if not acquired:
            return "already_running"
        marker = _process_marker(process_marker_path)
        previous = _read_status(status_path)
        if marker is not None and previous.get("state") == "success" and previous.get("process_marker") == marker:
            return "unchanged"
        started = utc_now()
        running = {
            "schema_version": 1,
            "state": "running",
            "started_at": started,
            "last_success_at": previous.get("last_success_at"),
            "last_failure_at": previous.get("last_failure_at"),
            "process_marker": marker,
        }
        _write_status(status_path, running)
        deadline = time.monotonic() + timeout
        temporary_root: Optional[Path] = None
        try:
            temporary_root = Path(tempfile.mkdtemp(prefix=".site-publish-", dir=config.state_dir))
            temporary_root.chmod(0o700)
            staging = temporary_root / "content"
            public = temporary_root / "public"
            stage_content(config, staging)
            run_generators(config, staging, deadline)
            resolve_capture_objects(config, staging, token, deadline)
            copy_approved_legacy_attachments(config, staging)
            secure_staging_modes(staging)
            assert_staging_allowlist(staging)
            public.mkdir(mode=0o700)
            builder = list(site_command) if site_command else [
                shutil.which("npm") or "npm",
                "run",
                "build",
            ]
            build_environment = dict(os.environ)
            build_environment["BRAIN_SITE_CONTENT_ROOT"] = str(staging)
            build_environment["BRAIN_SITE_OUT_DIR"] = str(public)
            build_environment["BRAIN_SITE_URL"] = config.site_url
            _run(builder, config.code_root / "site", deadline, build_environment)
            assert_public_allowlist(public)
            wrangler = list(wrangler_command) if wrangler_command else [
                shutil.which("npx") or "npx",
                "--yes",
                "wrangler@4",
            ]
            child_environment = dict(os.environ)
            child_environment["CLOUDFLARE_API_TOKEN"] = pages_token
            child_environment["CLOUDFLARE_ACCOUNT_ID"] = config.account_id
            _run(
                (
                    *wrangler,
                    "pages",
                    "deploy",
                    str(public),
                    "--project-name",
                    PROJECT,
                    "--branch",
                    PRODUCTION_BRANCH,
                ),
                config.code_root,
                deadline,
                child_environment,
            )
            finished = utc_now()
            _write_status(
                status_path,
                {
                    **running,
                    "state": "success",
                    "finished_at": finished,
                    "last_success_at": finished,
                    "error_code": None,
                },
            )
            return "published"
        except PublisherError as error:
            finished = utc_now()
            _write_status(
                status_path,
                {
                    **running,
                    "state": "failure",
                    "finished_at": finished,
                    "last_failure_at": finished,
                    "error_code": error.code,
                },
            )
            raise
        finally:
            if temporary_root is not None:
                shutil.rmtree(temporary_root, ignore_errors=True)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--process-marker", type=Path)
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument("--site-command", action="append")
    parser.add_argument("--wrangler-command", action="append")
    arguments = parser.parse_args(argv)
    if arguments.timeout <= 0:
        parser.error("--timeout must be positive")

    previous_handlers: dict[int, Any] = {}

    def interrupted(signum: int, _frame: Any) -> None:
        raise PublisherError("signal", "site publication interrupted by signal {}".format(signum))

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(signum, interrupted)
    try:
        config = load_config(arguments.config)
        result = publish(
            config,
            token=os.environ.get("BRAIN_AGENT_TOKEN", ""),
            pages_token=os.environ.get("CLOUDFLARE_API_TOKEN", ""),
            timeout=arguments.timeout,
            process_marker_path=arguments.process_marker,
            site_command=arguments.site_command,
            wrangler_command=arguments.wrangler_command,
        )
        print("site publisher: " + result)
        return 0
    except PublisherError as error:
        if error.code == "process_not_ready":
            print("site publisher: skipped ({})".format(error), file=sys.stderr)
            return 0
        print("site publisher: {} ({})".format(error.code, error), file=sys.stderr)
        return 1
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    raise SystemExit(main())
