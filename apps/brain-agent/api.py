#!/usr/bin/env python3
"""Loopback-only, read-only HTTP API for the canonical Brain vault."""

from __future__ import annotations

import errno
import hmac
import json
import os
import re
import stat
import subprocess
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple
from urllib.parse import parse_qs, urlsplit


LOOPBACK_HOST = "127.0.0.1"
ALLOWED_KNOWLEDGE_ROOTS = (
    "maps",
    "notes",
    "sources",
    "projects",
    "people",
    "me",
    "daily",
    "inbox",
)

DEFAULT_SEARCH_LIMIT = 20
MAX_SEARCH_LIMIT = 50
MAX_QUERY_CHARS = 256
MAX_PATH_CHARS = 1_024
MAX_TITLE_CHARS = 160
MAX_SNIPPET_CHARS = 320
MAX_SEARCH_FILE_BYTES = 512 * 1024
MAX_DOCUMENT_BYTES = 48 * 1024
MAX_CLI_OUTPUT_BYTES = 48 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
MAX_REQUEST_TARGET_CHARS = 2_048
MAX_SITE_URL_CHARS = 2_048
DEFAULT_COMMAND_TIMEOUT_SECONDS = 30.0

_KNOWN_ROUTES = frozenset(
    (
        "/v1/status",
        "/v1/health",
        "/v1/knowledge/documents",
        "/v1/knowledge/search",
        "/v1/knowledge/document",
    )
)
_DIRECTORY_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


class APIError(Exception):
    """An intentionally safe error that may be returned to a caller."""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


@dataclass(frozen=True)
class BrainAPIConfig:
    """Validated configuration for one loopback Brain API server."""

    vault_path: Path
    cli_path: Path
    origin_token: str
    site_url: str
    port: int
    command_timeout: float = DEFAULT_COMMAND_TIMEOUT_SECONDS
    gateway_url: Optional[str] = None
    publisher_status_path: Optional[Path] = None

    @classmethod
    def build(
        cls,
        *,
        vault_path: str,
        cli_path: str,
        origin_token: str,
        site_url: str,
        port: int,
        command_timeout: float = DEFAULT_COMMAND_TIMEOUT_SECONDS,
        gateway_url: Optional[str] = None,
        publisher_status_path: Optional[str] = None,
    ) -> "BrainAPIConfig":
        vault = Path(vault_path)
        cli = Path(cli_path)
        if not vault.is_absolute() or not vault.is_dir():
            raise ValueError("vault_path must be an existing absolute directory")
        if not cli.is_absolute() or not cli.is_file() or not os.access(str(cli), os.X_OK):
            raise ValueError("cli_path must be an executable absolute file")
        if not isinstance(origin_token, str) or not origin_token:
            raise ValueError("origin_token must be non-empty")
        validated_site_url = _validated_site_url(site_url)
        if isinstance(port, bool) or not isinstance(port, int) or not 0 <= port <= 65_535:
            raise ValueError("port must be between 0 and 65535")
        if command_timeout <= 0:
            raise ValueError("command_timeout must be positive")
        validated_gateway_url = (
            _validated_gateway_url(gateway_url) if gateway_url is not None else None
        )
        validated_publisher_status_path = None
        if publisher_status_path is not None:
            candidate = Path(publisher_status_path)
            if not candidate.is_absolute():
                raise ValueError("publisher_status_path must be absolute")
            validated_publisher_status_path = candidate
        return cls(
            vault_path=vault.resolve(strict=True),
            cli_path=cli,
            origin_token=origin_token,
            site_url=validated_site_url,
            port=port,
            command_timeout=float(command_timeout),
            gateway_url=validated_gateway_url,
            publisher_status_path=validated_publisher_status_path,
        )


class BrainReadAPI:
    """Pure request operations used by the HTTP handler."""

    def __init__(self, config: BrainAPIConfig) -> None:
        self.config = config

    def authorized(self, supplied_tokens: Sequence[str]) -> bool:
        return len(supplied_tokens) == 1 and hmac.compare_digest(
            supplied_tokens[0].encode("utf-8"), self.config.origin_token.encode("utf-8")
        )

    def dispatch_get(self, path: str, query_string: str) -> Tuple[int, Dict[str, Any]]:
        query = self._parse_query(query_string)
        if path == "/v1/status":
            self._require_query_keys(query, ())
            payload = self._run_brain_json(("status", "--json"), allow_nonzero=False)
            payload["site_url"] = self.config.site_url
            return 200, payload
        if path == "/v1/health":
            self._require_query_keys(query, ())
            return 200, self._run_brain_json(("doctor", "--json"), allow_nonzero=True)
        if path == "/v1/knowledge/documents":
            self._require_query_keys(query, (), ("limit",))
            return 200, self._documents(self._search_limit(query.get("limit")))
        if path == "/v1/knowledge/search":
            self._require_query_keys(query, ("q",), ("limit",))
            return 200, self._search(query["q"][0], self._search_limit(query.get("limit")))
        if path == "/v1/knowledge/document":
            self._require_query_keys(query, ("path",))
            return 200, self._document(query["path"][0])
        raise APIError(404, "not_found", "Route not found")

    @staticmethod
    def _parse_query(query_string: str) -> Dict[str, List[str]]:
        try:
            return parse_qs(
                query_string,
                keep_blank_values=True,
                strict_parsing=False,
                max_num_fields=4,
            )
        except ValueError:
            raise APIError(400, "invalid_query", "Invalid query parameters")

    @staticmethod
    def _require_query_keys(
        query: Dict[str, List[str]],
        required: Sequence[str],
        optional: Sequence[str] = (),
    ) -> None:
        allowed = set(required) | set(optional)
        if set(query) != set(required) and not (
            set(required).issubset(query) and set(query).issubset(allowed)
        ):
            raise APIError(400, "invalid_query", "Invalid query parameters")
        if any(len(values) != 1 for values in query.values()):
            raise APIError(400, "invalid_query", "Invalid query parameters")

    @staticmethod
    def _search_limit(values: Optional[List[str]]) -> int:
        if values is None:
            return DEFAULT_SEARCH_LIMIT
        value = values[0]
        if not re.fullmatch(r"[0-9]+", value):
            raise APIError(400, "invalid_limit", "Search limit must be an integer")
        limit = int(value)
        if not 1 <= limit <= MAX_SEARCH_LIMIT:
            raise APIError(
                400,
                "invalid_limit",
                "Search limit is outside the allowed range",
            )
        return limit

    def _run_brain_json(
        self, arguments: Sequence[str], *, allow_nonzero: bool
    ) -> Dict[str, Any]:
        try:
            environment = dict(os.environ)
            environment["BRAIN_DATA_ROOT"] = str(self.config.vault_path)
            # The supervised Agent owns a separate BRAIN_STATE_DIR. Pin sibling
            # Telegram health to the canonical Brain state directory at the
            # exact child-process boundary so inherited launchd state cannot
            # redirect heartbeat or credential checks.
            environment["BRAIN_TELEGRAM_STATE_DIR"] = str(self.config.vault_path.parent)
            if self.config.gateway_url is not None:
                environment["BRAIN_GATEWAY_URL"] = self.config.gateway_url
            if self.config.publisher_status_path is not None:
                environment["BRAIN_SITE_PUBLISHER_STATUS_FILE"] = str(
                    self.config.publisher_status_path
                )
            result = subprocess.run(
                [str(self.config.cli_path), *arguments],
                cwd=str(self.config.vault_path),
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self.config.command_timeout,
                check=False,
            )
        except subprocess.TimeoutExpired:
            raise APIError(504, "brain_timeout", "Brain command timed out")
        except OSError:
            raise APIError(502, "brain_unavailable", "Brain command could not be executed")

        if len(result.stdout) > MAX_CLI_OUTPUT_BYTES:
            raise APIError(502, "invalid_brain_response", "Brain returned an invalid response")
        try:
            payload = json.loads(result.stdout.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise APIError(502, "invalid_brain_response", "Brain returned an invalid response")
        if not isinstance(payload, dict):
            raise APIError(502, "invalid_brain_response", "Brain returned an invalid response")
        if result.returncode != 0 and not allow_nonzero:
            raise APIError(502, "brain_command_failed", "Brain command failed")
        return payload

    def _search(self, query: str, limit: int) -> Dict[str, Any]:
        query = query.strip()
        if not query or len(query) > MAX_QUERY_CHARS or "\x00" in query:
            raise APIError(400, "invalid_query", "Search query is invalid")
        folded_query = query.casefold()
        candidates = self._markdown_paths()

        results: List[Dict[str, str]] = []
        for relative in candidates:
            try:
                raw = self._read_markdown(relative, MAX_SEARCH_FILE_BYTES, reject_oversize=False)
                text = raw.decode("utf-8")
            except (APIError, UnicodeDecodeError):
                continue
            match_at = text.casefold().find(folded_query)
            if match_at < 0:
                continue
            result = {
                "title": self._title(text, relative),
                "path": relative,
                "snippet": self._snippet(text, match_at, len(query)),
            }
            prospective = {"query": query, "results": [*results, result]}
            if len(self._encoded_json(prospective)) > MAX_RESPONSE_BYTES:
                break
            results.append(result)
            if len(results) == limit:
                break
        return {"query": query, "results": results}

    def _documents(self, limit: int) -> Dict[str, Any]:
        documents: List[Dict[str, str]] = []
        for relative in self._markdown_paths():
            try:
                raw = self._read_markdown(relative, MAX_DOCUMENT_BYTES, reject_oversize=False)
                text = raw.decode("utf-8")
            except (APIError, UnicodeDecodeError):
                continue
            document = {"title": self._title(text, relative), "path": relative}
            prospective = {"documents": [*documents, document]}
            if len(self._encoded_json(prospective)) > MAX_RESPONSE_BYTES:
                break
            documents.append(document)
            if len(documents) == limit:
                break
        return {"documents": documents}

    def _markdown_paths(self) -> List[str]:
        candidates: List[str] = []
        for root_name in ALLOWED_KNOWLEDGE_ROOTS:
            root = self.config.vault_path / root_name
            if not root.is_dir() or root.is_symlink():
                continue
            for current, directories, files in os.walk(str(root), followlinks=False):
                current_path = Path(current)
                directories[:] = sorted(
                    directory
                    for directory in directories
                    if not directory.startswith(".")
                    and not (current_path / directory).is_symlink()
                )
                for filename in sorted(files):
                    file_path = current_path / filename
                    if filename.startswith(".") or file_path.suffix.lower() != ".md":
                        continue
                    if file_path.is_symlink():
                        continue
                    relative = file_path.relative_to(self.config.vault_path).as_posix()
                    if len(relative) <= MAX_PATH_CHARS:
                        candidates.append(relative)
        return sorted(candidates, key=lambda item: (item.casefold(), item))

    @staticmethod
    def _encoded_json(payload: Dict[str, Any]) -> bytes:
        return json.dumps(
            payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")

    def _document(self, relative: str) -> Dict[str, Any]:
        raw = self._read_markdown(relative, MAX_DOCUMENT_BYTES, reject_oversize=True)
        try:
            content = raw.decode("utf-8")
        except UnicodeDecodeError:
            raise APIError(422, "invalid_document", "Document is not valid UTF-8 Markdown")
        return {
            "path": relative,
            "title": self._title(content, relative),
            "content": content,
        }

    @staticmethod
    def _validated_parts(relative: str) -> Tuple[str, ...]:
        if (
            not relative
            or len(relative) > MAX_PATH_CHARS
            or relative.startswith("/")
            or "\\" in relative
            or "\x00" in relative
        ):
            raise APIError(400, "invalid_path", "Document path is invalid")
        parts = tuple(relative.split("/"))
        if (
            len(parts) < 2
            or parts[0] not in ALLOWED_KNOWLEDGE_ROOTS
            or any(not part or part in (".", "..") or part.startswith(".") for part in parts)
            or not parts[-1].lower().endswith(".md")
        ):
            raise APIError(400, "invalid_path", "Document path is invalid")
        return parts

    def _read_markdown(
        self, relative: str, byte_limit: int, *, reject_oversize: bool
    ) -> bytes:
        parts = self._validated_parts(relative)
        descriptors: List[int] = []
        try:
            descriptor = os.open(str(self.config.vault_path), _DIRECTORY_FLAGS)
            descriptors.append(descriptor)
            for component in parts[:-1]:
                descriptor = os.open(
                    component,
                    _DIRECTORY_FLAGS | _NOFOLLOW,
                    dir_fd=descriptor,
                )
                descriptors.append(descriptor)
            file_descriptor = os.open(
                parts[-1], os.O_RDONLY | _NOFOLLOW, dir_fd=descriptors[-1]
            )
            descriptors.append(file_descriptor)
            if not stat.S_ISREG(os.fstat(file_descriptor).st_mode):
                raise APIError(404, "document_not_found", "Document not found")
            chunks: List[bytes] = []
            remaining = byte_limit + 1
            while remaining:
                chunk = os.read(file_descriptor, min(remaining, 64 * 1024))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            content = b"".join(chunks)
        except APIError:
            raise
        except OSError as error:
            if error.errno in (
                errno.EACCES,
                errno.ELOOP,
                errno.ENOENT,
                errno.ENOTDIR,
            ):
                raise APIError(404, "document_not_found", "Document not found")
            raise APIError(500, "read_failed", "Document could not be read")
        finally:
            for descriptor in reversed(descriptors):
                try:
                    os.close(descriptor)
                except OSError:
                    pass
        if len(content) > byte_limit:
            if reject_oversize:
                raise APIError(413, "document_too_large", "Document exceeds the response limit")
            return content[:byte_limit]
        return content

    @staticmethod
    def _title(content: str, relative: str) -> str:
        for line in content.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("# "):
                title = " ".join(stripped[2:].split())
                if title:
                    return title[:MAX_TITLE_CHARS]
        return Path(relative).stem[:MAX_TITLE_CHARS]

    @staticmethod
    def _snippet(content: str, match_at: int, query_length: int) -> str:
        radius = MAX_SNIPPET_CHARS
        start = max(0, match_at - radius)
        end = min(len(content), match_at + query_length + radius)
        snippet = " ".join(content[start:end].split())
        if len(snippet) > MAX_SNIPPET_CHARS:
            snippet = snippet[: MAX_SNIPPET_CHARS - 1].rstrip() + "…"
        return snippet


class _BrainAPIHandler(BaseHTTPRequestHandler):
    server_version = "BrainReadAPI"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    @property
    def api(self) -> BrainReadAPI:
        return self.server.brain_api  # type: ignore[attr-defined]

    def do_GET(self) -> None:
        self._handle_get()

    def do_HEAD(self) -> None:
        self._handle_non_get()

    def do_POST(self) -> None:
        self._handle_non_get()

    def do_PUT(self) -> None:
        self._handle_non_get()

    def do_PATCH(self) -> None:
        self._handle_non_get()

    def do_DELETE(self) -> None:
        self._handle_non_get()

    def do_OPTIONS(self) -> None:
        self._handle_non_get()

    def do_CONNECT(self) -> None:
        self._handle_non_get()

    def do_TRACE(self) -> None:
        self._handle_non_get()

    def __getattr__(self, name: str) -> Any:
        if name.startswith("do_"):
            return self._handle_non_get
        raise AttributeError(name)

    def _authorized(self) -> bool:
        supplied = self.headers.get_all("X-Brain-Origin-Token", [])
        if self.api.authorized(supplied):
            return True
        self._send_json(
            401,
            {"error": {"code": "unauthorized", "message": "Authentication required"}},
        )
        return False

    def _request_parts(self) -> Tuple[str, str]:
        if len(self.path) > MAX_REQUEST_TARGET_CHARS:
            raise APIError(414, "request_target_too_long", "Request target is too long")
        try:
            parsed = urlsplit(self.path)
        except ValueError:
            raise APIError(400, "invalid_request", "Request target is invalid")
        if parsed.scheme or parsed.netloc or parsed.fragment:
            raise APIError(400, "invalid_request", "Request target is invalid")
        return parsed.path, parsed.query

    def _handle_get(self) -> None:
        if not self._authorized():
            return
        try:
            path, query = self._request_parts()
            status, payload = self.api.dispatch_get(path, query)
            self._send_json(status, payload)
        except APIError as error:
            self._send_api_error(error)
        except Exception:
            self._send_api_error(APIError(500, "internal_error", "Request failed"))

    def _handle_non_get(self) -> None:
        if not self._authorized():
            return
        try:
            path, _ = self._request_parts()
            if path in _KNOWN_ROUTES:
                self._send_api_error(APIError(405, "method_not_allowed", "Method not allowed"))
            else:
                self._send_api_error(APIError(404, "not_found", "Route not found"))
        except APIError as error:
            self._send_api_error(error)

    def _send_api_error(self, error: APIError) -> None:
        self._send_json(
            error.status,
            {"error": {"code": error.code, "message": error.message}},
        )

    def _send_json(self, status_code: int, payload: Dict[str, Any]) -> None:
        encoded = json.dumps(
            payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
        if len(encoded) > MAX_RESPONSE_BYTES:
            status_code = 500
            encoded = b'{"error":{"code":"response_too_large","message":"Response limit exceeded"}}'
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if status_code == 401:
            self.send_header("WWW-Authenticate", 'BrainOrigin realm="brain-agent"')
        if status_code == 405:
            self.send_header("Allow", "GET")
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(encoded)
        self.close_connection = True

    def log_message(self, format: str, *args: Any) -> None:
        # Request targets may contain private search terms or document paths.
        return


class BrainAPIServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def create_server(
    *,
    vault_path: str,
    cli_path: str,
    origin_token: str,
    site_url: str,
    port: int,
    command_timeout: float = DEFAULT_COMMAND_TIMEOUT_SECONDS,
    gateway_url: Optional[str] = None,
    publisher_status_path: Optional[str] = None,
) -> BrainAPIServer:
    """Create an HTTP server that is unconditionally bound to IPv4 loopback."""

    config = BrainAPIConfig.build(
        vault_path=vault_path,
        cli_path=cli_path,
        origin_token=origin_token,
        site_url=site_url,
        port=port,
        command_timeout=command_timeout,
        gateway_url=gateway_url,
        publisher_status_path=publisher_status_path,
    )
    server = BrainAPIServer((LOOPBACK_HOST, config.port), _BrainAPIHandler)
    server.brain_api = BrainReadAPI(config)  # type: ignore[attr-defined]
    return server


def _validated_site_url(value: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value.encode("utf-8")) > MAX_SITE_URL_CHARS
        or value != value.strip()
        or "\\" in value
        or any(
            ord(character) < 0x20 or ord(character) > 0x7E
            for character in value
        )
    ):
        raise ValueError("site_url is invalid")
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        _ = parsed.port
    except ValueError as exc:
        raise ValueError("site_url is invalid") from exc
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("site_url is invalid")
    return value


def _validated_gateway_url(value: str) -> str:
    """Validate the non-secret HTTPS origin passed to gateway health checks."""

    validated = _validated_site_url(value)
    parsed = urlsplit(validated)
    if parsed.path not in ("", "/"):
        raise ValueError("gateway_url must be an origin URL")
    return validated.rstrip("/")


__all__ = [
    "ALLOWED_KNOWLEDGE_ROOTS",
    "BrainAPIConfig",
    "BrainAPIServer",
    "BrainReadAPI",
    "LOOPBACK_HOST",
    "MAX_DOCUMENT_BYTES",
    "MAX_QUERY_CHARS",
    "MAX_RESPONSE_BYTES",
    "MAX_SEARCH_LIMIT",
    "MAX_SNIPPET_CHARS",
    "create_server",
]
