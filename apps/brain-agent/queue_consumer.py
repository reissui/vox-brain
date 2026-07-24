#!/usr/bin/env python3
"""Outbound-only Cloudflare Queue consumer for remote Brain work.

The consumer has deliberately small boundaries: Cloudflare Queue pull/ack,
fixed agent routes on the configured gateway, and one absolute Brain CLI.  It
does not accept an origin URL, an executable, or arbitrary argv from a message.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import stat
import subprocess
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple


CLOUDFLARE_API_BASE = "https://api.cloudflare.com/client/v4"
DEFAULT_BATCH_SIZE = 1
DEFAULT_VISIBILITY_TIMEOUT_MS = 60 * 60 * 1000
DEFAULT_HTTP_TIMEOUT_SECONDS = 30.0
DEFAULT_COMMAND_TIMEOUT_SECONDS = 60 * 60.0
DEFAULT_RETRY_DELAY_SECONDS = 30
MAX_QUEUE_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_OBJECT_BYTES = 6 * 1024 * 1024
MAX_GATEWAY_RESPONSE_BYTES = 256 * 1024
MAX_CLI_OUTPUT_BYTES = 48 * 1024
USER_AGENT = "Brain-Agent/1"
ALLOWED_ACTIONS = frozenset(("ask", "process", "digest"))
TRANSCRIPT_OBJECT_TYPE = "text/plain; charset=utf-8"

_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_OBJECT_PATH = re.compile(r"^/v1/agent/captures/([^/]+)/object$")
_CONTENT_TYPE = re.compile(
    r"^[a-z0-9][a-z0-9!#$&^_.+-]{0,126}/[a-z0-9][a-z0-9!#$&^_.+-]{0,126}$"
)


class ConsumerError(Exception):
    """An operational failure with a bounded, credential-free report code."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class QueueConsumerConfig:
    account_id: str
    queue_id: str
    queue_api_token: str
    gateway_url: str
    agent_token: str
    instance_id: str
    brain_cli: Path
    vault_path: Path
    state_dir: Path
    batch_size: int = DEFAULT_BATCH_SIZE
    visibility_timeout_ms: int = DEFAULT_VISIBILITY_TIMEOUT_MS
    http_timeout: float = DEFAULT_HTTP_TIMEOUT_SECONDS
    command_timeout: float = DEFAULT_COMMAND_TIMEOUT_SECONDS
    retry_delay_seconds: int = DEFAULT_RETRY_DELAY_SECONDS
    cloudflare_api_base: str = CLOUDFLARE_API_BASE

    @classmethod
    def build(
        cls,
        *,
        account_id: str,
        queue_id: str,
        queue_api_token: str,
        gateway_url: str,
        agent_token: str,
        instance_id: str,
        brain_cli: str,
        vault_path: str,
        state_dir: str,
        batch_size: int = DEFAULT_BATCH_SIZE,
        visibility_timeout_ms: int = DEFAULT_VISIBILITY_TIMEOUT_MS,
        http_timeout: float = DEFAULT_HTTP_TIMEOUT_SECONDS,
        command_timeout: float = DEFAULT_COMMAND_TIMEOUT_SECONDS,
        retry_delay_seconds: int = DEFAULT_RETRY_DELAY_SECONDS,
        cloudflare_api_base: str = CLOUDFLARE_API_BASE,
    ) -> "QueueConsumerConfig":
        for name, value in (
            ("account_id", account_id),
            ("queue_id", queue_id),
            ("instance_id", instance_id),
        ):
            if not isinstance(value, str) or not _SAFE_ID.fullmatch(value):
                raise ValueError("{} is invalid".format(name))
        for name, value in (
            ("queue_api_token", queue_api_token),
            ("agent_token", agent_token),
        ):
            if not isinstance(value, str) or not value or any(character.isspace() for character in value):
                raise ValueError("{} must be a non-empty bearer token".format(name))

        gateway = _validated_base_url(gateway_url, "gateway_url")
        cloudflare = _validated_base_url(cloudflare_api_base, "cloudflare_api_base")
        cli = Path(brain_cli)
        vault = Path(vault_path)
        state = Path(state_dir)
        if not cli.is_absolute() or not cli.is_file() or not os.access(str(cli), os.X_OK):
            raise ValueError("brain_cli must be an executable absolute file")
        if not vault.is_absolute() or not vault.is_dir():
            raise ValueError("vault_path must be an existing absolute directory")
        if not state.is_absolute():
            raise ValueError("state_dir must be absolute")
        if isinstance(batch_size, bool) or not 1 <= batch_size <= 100:
            raise ValueError("batch_size must be between 1 and 100")
        if isinstance(visibility_timeout_ms, bool) or not 1_000 <= visibility_timeout_ms <= 43_200_000:
            raise ValueError("visibility_timeout_ms is outside the supported range")
        if http_timeout <= 0 or command_timeout <= 0:
            raise ValueError("timeouts must be positive")
        if isinstance(retry_delay_seconds, bool) or not 0 <= retry_delay_seconds <= 43_200:
            raise ValueError("retry_delay_seconds is outside the supported range")
        return cls(
            account_id=account_id,
            queue_id=queue_id,
            queue_api_token=queue_api_token,
            gateway_url=gateway,
            agent_token=agent_token,
            instance_id=instance_id,
            brain_cli=cli,
            vault_path=vault.resolve(strict=True),
            state_dir=state,
            batch_size=batch_size,
            visibility_timeout_ms=visibility_timeout_ms,
            http_timeout=float(http_timeout),
            command_timeout=float(command_timeout),
            retry_delay_seconds=retry_delay_seconds,
            cloudflare_api_base=cloudflare,
        )


@dataclass(frozen=True)
class HTTPResponse:
    status: int
    headers: Mapping[str, str]
    body: bytes


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: bytes
    stderr: bytes


@dataclass(frozen=True)
class DownloadedObject:
    path: Path
    kind: str
    sha256: str
    content_type: str
    byte_length: int
    filename: str


Transport = Callable[[str, str, Mapping[str, str], Optional[bytes], float, int], HTTPResponse]
Runner = Callable[[Sequence[str], bytes, Path, float], CommandResult]


def urllib_transport(
    method: str,
    url: str,
    headers: Mapping[str, str],
    body: Optional[bytes],
    timeout: float,
    limit: int,
) -> HTTPResponse:
    """Issue one bounded HTTP request without logging request material."""

    request_headers = dict(headers)
    request_headers.setdefault("User-Agent", USER_AGENT)
    request = urllib.request.Request(url, method=method, headers=request_headers, data=body)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read(limit + 1)
            if len(payload) > limit:
                raise ConsumerError("http_response_too_large")
            return HTTPResponse(
                status=response.status,
                headers={key.lower(): value for key, value in response.headers.items()},
                body=payload,
            )
    except ConsumerError:
        raise
    except urllib.error.HTTPError as error:
        try:
            error.read(limit + 1)
        finally:
            error.close()
        raise ConsumerError("http_status_error")
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ConsumerError("network_error")


def subprocess_runner(
    argv: Sequence[str], stdin: bytes, cwd: Path, timeout: float
) -> CommandResult:
    """Run fixed argv directly against the configured data root."""

    try:
        environment = dict(os.environ)
        environment["BRAIN_DATA_ROOT"] = str(cwd)
        completed = subprocess.run(
            list(argv),
            cwd=str(cwd),
            env=environment,
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise ConsumerError("command_timeout")
    except OSError:
        raise ConsumerError("command_unavailable")
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)


class CompletionStore:
    """Small owner-only, process-safe idempotency ledger."""

    def __init__(self, directory: Path) -> None:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError("state_dir must be a real directory")
        try:
            directory.chmod(0o700)
        except OSError:
            pass
        self.directory = directory
        self._lock = threading.Lock()

    def claim(self, key: str) -> str:
        """Return claimed, completed, finished, or in_progress."""

        path = self._path(key)
        with self._lock:
            try:
                descriptor = os.open(
                    str(path),
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                )
            except FileExistsError:
                return self._existing_status(path)
            except OSError:
                raise ConsumerError("state_unavailable")
            try:
                _write_all(descriptor, b'{"status":"in_progress"}')
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            return "claimed"

    def complete(self, key: str) -> None:
        path = self._path(key)
        self._replace(path, b'{"status":"completed"}')

    def finish(self, key: str, report: Dict[str, Any]) -> None:
        """Durably retain a terminal result until its gateway report succeeds."""

        self._replace(
            self._path(key),
            _json_bytes({"status": "finished", "report": report}),
        )

    def pending_report(self, key: str) -> Dict[str, Any]:
        path = self._path(key)
        try:
            value = self._read(path)
        except FileNotFoundError:
            raise ConsumerError("state_unavailable")
        report = value.get("report")
        if value.get("status") != "finished" or not isinstance(report, dict):
            raise ConsumerError("state_unavailable")
        return report

    def release(self, key: str) -> None:
        path = self._path(key)
        with self._lock:
            try:
                if self._existing_status(path) == "in_progress":
                    path.unlink()
            except FileNotFoundError:
                return
            except OSError:
                raise ConsumerError("state_unavailable")

    def _path(self, key: str) -> Path:
        digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
        return self.directory / (digest + ".json")

    @staticmethod
    def _existing_status(path: Path) -> str:
        value = CompletionStore._read(path)
        status_value = value.get("status")
        if status_value not in ("in_progress", "finished", "completed"):
            raise ConsumerError("state_unavailable")
        return status_value

    @staticmethod
    def _read(path: Path) -> Dict[str, Any]:
        try:
            if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode):
                raise ConsumerError("state_unavailable")
            value = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            raise
        except ConsumerError:
            raise
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            raise ConsumerError("state_unavailable")
        if not isinstance(value, dict):
            raise ConsumerError("state_unavailable")
        return value

    def _replace(self, destination: Path, contents: bytes) -> None:
        temporary: Optional[Path] = None
        with self._lock:
            try:
                descriptor, name = tempfile.mkstemp(prefix=".completion-", dir=str(self.directory))
                temporary = Path(name)
                os.fchmod(descriptor, 0o600)
                try:
                    _write_all(descriptor, contents)
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
                os.replace(str(temporary), str(destination))
                temporary = None
            except OSError:
                raise ConsumerError("state_unavailable")
            finally:
                if temporary is not None:
                    try:
                        temporary.unlink()
                    except OSError:
                        pass


class QueueConsumer:
    def __init__(
        self,
        config: QueueConsumerConfig,
        *,
        transport: Transport = urllib_transport,
        runner: Runner = subprocess_runner,
        store: Optional[CompletionStore] = None,
        now: Optional[Callable[[], datetime]] = None,
    ) -> None:
        self.config = config
        self.transport = transport
        self.runner = runner
        self.store = store or CompletionStore(config.state_dir / "queue-completions")
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._telemetry_lock = threading.Lock()
        self._last_poll_started_at: Optional[datetime] = None
        self._last_successful_poll_at: Optional[datetime] = None
        self._backlog_count = 0
        self._oldest_backlog_at: Optional[datetime] = None
        self._work_started_at: Optional[datetime] = None
        self._work_label: Optional[str] = None
        self.capture_temp_dir = config.state_dir / "capture-temp"
        self.capture_temp_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.capture_temp_dir.is_symlink() or not self.capture_temp_dir.is_dir():
            raise ValueError("capture temp directory must be a real directory")
        try:
            self.capture_temp_dir.chmod(0o700)
        except OSError:
            pass

    def poll_once(self) -> int:
        """Pull one batch, process it serially, and settle every valid lease."""
        self._begin_poll()
        succeeded = False
        remaining_backlog: Optional[int] = None
        try:
            pulled = self._queue_json(
                "pull",
                {
                    "batch_size": self.config.batch_size,
                    "visibility_timeout_ms": self.config.visibility_timeout_ms,
                },
            )
            result = pulled.get("result")
            messages = result.get("messages") if isinstance(result, dict) else None
            if not isinstance(messages, list):
                raise ConsumerError("invalid_queue_response")
            reported_backlog = result.get("message_backlog_count")
            if isinstance(reported_backlog, bool) or not isinstance(reported_backlog, int):
                reported_backlog = len(messages)
            reported_backlog = max(len(messages), reported_backlog)
            self._set_backlog(messages, reported_backlog)
            remaining_backlog = reported_backlog

            acknowledgements: List[Dict[str, str]] = []
            retries: List[Dict[str, Any]] = []
            for message in messages:
                lease = message.get("lease_id") if isinstance(message, dict) else None
                if not isinstance(lease, str) or not lease:
                    continue
                began_work = False
                try:
                    envelope = self._decode_message(message)
                    self._begin_work(envelope)
                    began_work = True
                    outcome = self._handle_envelope(envelope)
                except ConsumerError:
                    outcome = "retry"
                finally:
                    if began_work:
                        self._finish_work()
                if outcome == "ack":
                    acknowledgements.append({"lease_id": lease})
                else:
                    retry: Dict[str, Any] = {"lease_id": lease}
                    if self.config.retry_delay_seconds:
                        retry["delay_seconds"] = self.config.retry_delay_seconds
                    retries.append(retry)

            if acknowledgements or retries:
                self._queue_json("ack", {"acks": acknowledgements, "retries": retries})
                # Retried leases remain pending. Successfully acknowledged
                # leases are the only messages removed from the pull response's
                # best-effort total.
                remaining_backlog = max(0, reported_backlog - len(acknowledgements))
            succeeded = True
            return len(messages)
        finally:
            self._finish_poll(succeeded, remaining_backlog)

    def operational_snapshot(self, at: Optional[datetime] = None) -> Dict[str, Any]:
        """Return bounded, content-free Queue and process progress diagnostics."""

        current = (at or self._now()).astimezone(timezone.utc)
        with self._telemetry_lock:
            last_poll = self._last_successful_poll_at
            backlog = self._backlog_count
            oldest = self._oldest_backlog_at
            work_started = self._work_started_at
            work_label = self._work_label

        def age(value: Optional[datetime]) -> Optional[int]:
            if value is None:
                return None
            return max(0, int((current - value.astimezone(timezone.utc)).total_seconds()))

        work_age = age(work_started)
        return {
            "last_successful_poll": _iso_timestamp(last_poll),
            "poll_age_seconds": age(last_poll),
            "backlog_count": backlog,
            "oldest_backlog_age_seconds": age(oldest) if backlog else None,
            "process": {
                "state": (
                    "stuck" if work_age is not None and work_age > int(self.config.command_timeout)
                    else "running" if work_started is not None else "idle"
                ),
                "label": work_label,
                "started_at": _iso_timestamp(work_started),
                "progress_age_seconds": work_age,
                "declared_bound_seconds": int(self.config.command_timeout),
            },
        }

    def _begin_poll(self) -> None:
        with self._telemetry_lock:
            self._last_poll_started_at = self._now()

    def _set_backlog(self, messages: Sequence[Any], backlog_count: int) -> None:
        oldest: Optional[datetime] = None
        for message in messages:
            if not isinstance(message, dict):
                continue
            parsed: Optional[datetime] = None
            timestamp_ms = message.get("timestamp_ms")
            if isinstance(timestamp_ms, (int, float)) and not isinstance(timestamp_ms, bool):
                try:
                    parsed = datetime.fromtimestamp(timestamp_ms / 1000, timezone.utc)
                except (OverflowError, OSError, ValueError):
                    parsed = None
            try:
                envelope = self._decode_message(message)
            except ConsumerError:
                envelope = {}
            raw = envelope.get("capture", {}).get("captured_at") \
                if isinstance(envelope.get("capture"), dict) else envelope.get("created_at")
            parsed = _parse_timestamp(raw) or parsed
            if parsed is not None and (oldest is None or parsed < oldest):
                oldest = parsed
        with self._telemetry_lock:
            self._backlog_count = backlog_count
            self._oldest_backlog_at = oldest

    def _finish_poll(self, succeeded: bool, remaining_backlog: Optional[int]) -> None:
        now = self._now()
        with self._telemetry_lock:
            if succeeded:
                self._last_successful_poll_at = now
                self._backlog_count = remaining_backlog or 0
                if self._backlog_count == 0:
                    self._oldest_backlog_at = None
        self._write_progress_file()

    def _begin_work(self, envelope: Mapping[str, Any]) -> None:
        kind = str(envelope.get("kind", "work"))[:32]
        value = envelope.get("capture") if kind == "capture" else envelope.get("action")
        identifier = value.get("id") if isinstance(value, dict) else None
        label = kind + (":" + identifier if isinstance(identifier, str) else "")
        with self._telemetry_lock:
            self._work_started_at = self._now()
            self._work_label = label[:160]
        self._write_progress_file()

    def _finish_work(self) -> None:
        with self._telemetry_lock:
            self._work_started_at = None
            self._work_label = None
        self._write_progress_file()

    def _write_progress_file(self) -> None:
        """Best-effort diagnostics must never prevent capture delivery."""

        temporary: Optional[Path] = None
        try:
            self.config.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            destination = self.config.state_dir / "agent-progress.json"
            payload = self.operational_snapshot()
            descriptor, name = tempfile.mkstemp(
                prefix=".agent-progress.", dir=str(self.config.state_dir)
            )
            temporary = Path(name)
            os.fchmod(descriptor, 0o600)
            try:
                _write_all(
                    descriptor,
                    (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
                    .encode("utf-8"),
                )
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            os.replace(str(temporary), str(destination))
            temporary = None
        except OSError:
            return
        finally:
            if temporary is not None:
                try:
                    temporary.unlink()
                except OSError:
                    pass

    def run_forever(self, stop_event: threading.Event, poll_interval: float = 5.0) -> None:
        """Short-poll until asked to stop; transient failures remain retryable."""

        while not stop_event.is_set():
            try:
                count = self.poll_once()
            except ConsumerError:
                count = 0
            if count == 0:
                stop_event.wait(poll_interval)

    def _queue_json(self, action: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        url = "{}/accounts/{}/queues/{}/messages/{}".format(
            self.config.cloudflare_api_base,
            urllib.parse.quote(self.config.account_id, safe=""),
            urllib.parse.quote(self.config.queue_id, safe=""),
            action,
        )
        value = self._request_json(
            "POST",
            url,
            self.config.queue_api_token,
            payload,
            MAX_QUEUE_RESPONSE_BYTES,
        )
        if value.get("success") is not True:
            raise ConsumerError("queue_request_failed")
        return value

    def _decode_message(self, message: Dict[str, Any]) -> Dict[str, Any]:
        body = message.get("body")
        metadata = message.get("metadata")
        content_type = metadata.get("CF-Content-Type") if isinstance(metadata, dict) else None
        if content_type != "json" or not isinstance(body, str):
            raise ConsumerError("invalid_message_content_type")

        # HTTP pull returns a JSON message as its original JSON string. Older
        # test and pre-release producers represented those bytes as base64, so
        # accept that form only as a compatibility fallback.
        try:
            decoded = body.encode("utf-8")
            if len(decoded) > MAX_QUEUE_RESPONSE_BYTES:
                raise ConsumerError("message_too_large")
            envelope = json.loads(decoded.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            try:
                decoded = base64.b64decode(body, validate=True)
                if len(decoded) > MAX_QUEUE_RESPONSE_BYTES:
                    raise ConsumerError("message_too_large")
                envelope = json.loads(decoded.decode("utf-8"))
            except ConsumerError:
                raise
            except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
                raise ConsumerError("invalid_message_body")
        if not isinstance(envelope, dict):
            raise ConsumerError("invalid_message_body")
        return envelope

    def _handle_envelope(self, envelope: Dict[str, Any]) -> str:
        if envelope.get("instance_id") != self.config.instance_id:
            raise ConsumerError("wrong_instance")
        kind = envelope.get("kind")
        if kind == "capture":
            return self._handle_capture(envelope)
        if kind in ("action", "job"):
            return self._handle_action(envelope)
        raise ConsumerError("unknown_message_kind")

    def _handle_capture(self, envelope: Dict[str, Any]) -> str:
        capture = envelope.get("capture")
        if not isinstance(capture, dict):
            raise ConsumerError("invalid_capture")
        capture_id = capture.get("id")
        if not isinstance(capture_id, str) or not _SAFE_ID.fullmatch(capture_id):
            raise ConsumerError("invalid_capture")
        key = "capture:" + capture_id
        claim = self.store.claim(key)
        if claim == "completed":
            return "ack"
        if claim == "in_progress":
            return "retry"
        if claim == "finished":
            self._report_capture(capture_id, self.store.pending_report(key))
            self.store.complete(key)
            return "ack"

        downloaded: Optional[DownloadedObject] = None
        try:
            payload = dict(capture)
            object_value = envelope.get("object")
            if object_value is not None:
                downloaded = self._download_object(capture_id, capture, object_value)
                if downloaded.kind == "transcript":
                    try:
                        payload["text"] = downloaded.path.read_bytes().decode("utf-8")
                    except UnicodeDecodeError:
                        raise ConsumerError("object_invalid_utf8")
                    except OSError:
                        raise ConsumerError("attachment_storage_failed")
                    payload.pop("transcript", None)
                else:
                    payload.update(
                        {
                            "object_path": str(downloaded.path),
                            "object_sha256": downloaded.sha256,
                            "object_mime": downloaded.content_type,
                            "object_size": downloaded.byte_length,
                            "object_filename": downloaded.filename,
                        }
                    )
            stdin = _json_bytes(payload)
            result = self._run((str(self.config.brain_cli), "ingest", "--json"), stdin)
            if downloaded is not None:
                self._remove_downloaded(downloaded)
                downloaded = None
            if result.returncode != 0:
                self._report_capture_failure(capture_id, "ingest_failed", result.stderr)
                self.store.release(key)
                return "retry"
            report = {"state": "delivered"}
            self.store.finish(key, report)
            self._report_capture(capture_id, report)
            self.store.complete(key)
            return "ack"
        except ConsumerError as error:
            if downloaded is not None:
                self._remove_downloaded(downloaded)
                downloaded = None
            try:
                if self.store.claim(key) == "finished":
                    return "retry"
            except ConsumerError:
                pass
            try:
                self._report_capture_failure(capture_id, error.code, b"")
            except ConsumerError:
                pass
            self.store.release(key)
            return "retry"
        finally:
            if downloaded is not None:
                self._remove_downloaded(downloaded)

    @staticmethod
    def _remove_downloaded(downloaded: DownloadedObject) -> None:
        try:
            downloaded.path.unlink()
        except FileNotFoundError:
            return
        except OSError:
            raise ConsumerError("attachment_cleanup_failed")

    def _download_object(
        self, capture_id: str, capture: Dict[str, Any], value: Any
    ) -> DownloadedObject:
        if not isinstance(value, dict):
            raise ConsumerError("invalid_object")
        path = value.get("path")
        digest = value.get("sha256")
        content_type = value.get("content_type")
        declared_length = value.get("byte_length")
        filename = value.get("filename")
        retention = value.get("retention")
        match = _OBJECT_PATH.fullmatch(path) if isinstance(path, str) else None
        if match is None or match.group(1) != capture_id:
            raise ConsumerError("invalid_object")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ConsumerError("invalid_object")

        object_kind = value.get("kind")
        if object_kind == "transcript":
            if capture.get("type") != "transcript":
                raise ConsumerError("transcript_object_forbidden")
            if set(value) != {
                "kind", "capture_id", "path", "sha256", "content_type", "byte_length",
                "filename", "retention"
            }:
                raise ConsumerError("invalid_object")
            if (
                value.get("capture_id") != capture_id
                or content_type != TRANSCRIPT_OBJECT_TYPE
                or isinstance(declared_length, bool)
                or not isinstance(declared_length, int)
                or declared_length < 0
                or declared_length > MAX_OBJECT_BYTES
            ):
                raise ConsumerError("invalid_object")
        else:
            if capture.get("type") == "transcript":
                raise ConsumerError("transcript_object_forbidden")
            if set(value) != {
                "path", "sha256", "content_type", "byte_length", "filename", "retention"
            }:
                raise ConsumerError("invalid_object")
            if (
                object_kind is not None
                or not isinstance(content_type, str)
                or _CONTENT_TYPE.fullmatch(content_type) is None
                or content_type.startswith("text/")
                or isinstance(declared_length, bool)
                or not isinstance(declared_length, int)
                or declared_length < 0
                or declared_length > MAX_OBJECT_BYTES
            ):
                raise ConsumerError("invalid_object")
        if (
            not isinstance(filename, str)
            or not filename
            or len(filename) > 180
            or filename in (".", "..")
            or "/" in filename
            or "\\" in filename
            or any(ord(character) < 32 or ord(character) == 127 for character in filename)
            or retention != "permanent"
        ):
            raise ConsumerError("invalid_object")

        response = self.transport(
            "GET",
            self.config.gateway_url + path,
            {
                "Accept": "application/octet-stream",
                "Authorization": "Bearer " + self.config.agent_token,
            },
            None,
            self.config.http_timeout,
            MAX_OBJECT_BYTES,
        )
        if not 200 <= response.status < 300:
            raise ConsumerError("object_download_failed")
        if len(response.body) > MAX_OBJECT_BYTES:
            raise ConsumerError("object_too_large")
        response_content_type = _header(response.headers, "content-type")
        if response_content_type != content_type:
            raise ConsumerError("object_content_type_mismatch")
        if len(response.body) != declared_length:
            raise ConsumerError("object_length_mismatch")
        response_length = _header(response.headers, "content-length")
        if response_length is not None:
            try:
                if int(response_length) != len(response.body):
                    raise ConsumerError("object_length_mismatch")
            except ValueError:
                raise ConsumerError("object_length_mismatch")
        actual = hashlib.sha256(response.body).hexdigest()
        if not hmac.compare_digest(actual, digest):
            raise ConsumerError("object_digest_mismatch")

        suffix = ".txt" if object_kind == "transcript" else ".bin"
        temporary: Optional[Path] = None
        try:
            descriptor, name = tempfile.mkstemp(
                prefix=".brain-capture-", suffix=suffix, dir=str(self.capture_temp_dir)
            )
            temporary = Path(name)
            os.fchmod(descriptor, 0o600)
            try:
                _write_all(descriptor, response.body)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            try:
                stored_length = temporary.stat().st_size
                stored_digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
            except OSError:
                raise ConsumerError("attachment_storage_failed")
            if stored_length != declared_length:
                raise ConsumerError("object_length_mismatch")
            if not hmac.compare_digest(stored_digest, digest):
                raise ConsumerError("object_digest_mismatch")
            result_path = temporary
            temporary = None
            return DownloadedObject(
                result_path,
                object_kind or "binary",
                digest,
                content_type,
                declared_length,
                filename,
            )
        except OSError:
            raise ConsumerError("attachment_storage_failed")
        finally:
            if temporary is not None:
                try:
                    temporary.unlink()
                except OSError:
                    pass

    def _handle_action(self, envelope: Dict[str, Any]) -> str:
        action = envelope.get("action")
        if action is None:
            action = envelope.get("job")
        if not isinstance(action, dict):
            raise ConsumerError("invalid_action")
        job_id = action.get("id")
        command = action.get("kind")
        if not isinstance(job_id, str) or not _SAFE_ID.fullmatch(job_id):
            raise ConsumerError("invalid_action")
        key = "job:" + job_id
        claim = self.store.claim(key)
        if claim == "completed":
            return "ack"
        if claim == "in_progress":
            return "retry"
        if claim == "finished":
            self._report_job(job_id, self.store.pending_report(key))
            self.store.complete(key)
            return "ack"

        if command not in ALLOWED_ACTIONS:
            report = {"state": "failed", "error": "action_not_allowed"}
            try:
                self.store.finish(key, report)
                self._report_job(job_id, report)
                self.store.complete(key)
            except ConsumerError:
                pass
            return "retry"

        argv: Tuple[str, ...]
        if command == "ask":
            question = action.get("question")
            if not isinstance(question, str) or not question or "\x00" in question:
                report = {"state": "failed", "error": "invalid_question"}
                try:
                    self.store.finish(key, report)
                    self._report_job(job_id, report)
                    self.store.complete(key)
                except ConsumerError:
                    pass
                return "retry"
            argv = (str(self.config.brain_cli), "ask", question)
        else:
            argv = (str(self.config.brain_cli), command)

        try:
            try:
                self._report_job(job_id, {"state": "running"})
            except ConsumerError:
                # The durable local claim still prevents duplicate execution;
                # the terminal callback remains authoritative on recovery.
                pass
            result = self._run(argv, b"")
            stdout = self._safe_output(result.stdout)
            if result.returncode == 0:
                report = {"state": "completed", "output": stdout}
                self.store.finish(key, report)
                self._report_job(job_id, report)
                self.store.complete(key)
                return "ack"
            report = {
                "state": "failed",
                "output": stdout,
                "error": "action_failed",
                "detail": self._safe_output(result.stderr),
            }
            self.store.finish(key, report)
            self._report_job(job_id, report)
            self.store.complete(key)
            return "retry"
        except ConsumerError as error:
            try:
                if self.store.claim(key) == "finished":
                    return "retry"
            except ConsumerError:
                pass
            report = {"state": "failed", "error": error.code}
            try:
                self.store.finish(key, report)
                self._report_job(job_id, report)
                self.store.complete(key)
            except ConsumerError:
                pass
            return "retry"

    def _run(self, argv: Sequence[str], stdin: bytes) -> CommandResult:
        try:
            return self.runner(argv, stdin, self.config.vault_path, self.config.command_timeout)
        except ConsumerError:
            raise
        except subprocess.TimeoutExpired:
            raise ConsumerError("command_timeout")
        except OSError:
            raise ConsumerError("command_unavailable")
        except Exception:
            raise ConsumerError("command_failed")

    def _report_capture_failure(self, capture_id: str, code: str, stderr: bytes) -> None:
        report: Dict[str, Any] = {"state": "failed", "error": code, "retryable": True}
        detail = self._safe_output(stderr)
        if detail:
            report["detail"] = detail
        self._report_capture(capture_id, report)

    def _report_capture(self, capture_id: str, report: Dict[str, Any]) -> None:
        self._gateway_json("/v1/agent/captures/{}/result".format(capture_id), report)

    def _report_job(self, job_id: str, report: Dict[str, Any]) -> None:
        self._gateway_json("/v1/agent/jobs/{}/result".format(job_id), report)

    def _gateway_json(self, path: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        return self._request_json(
            "POST",
            self.config.gateway_url + path,
            self.config.agent_token,
            payload,
            MAX_GATEWAY_RESPONSE_BYTES,
        )

    def _request_json(
        self,
        method: str,
        url: str,
        token: str,
        payload: Dict[str, Any],
        limit: int,
    ) -> Dict[str, Any]:
        response = self.transport(
            method,
            url,
            {
                "Accept": "application/json",
                "Authorization": "Bearer " + token,
                "Content-Type": "application/json",
            },
            _json_bytes(payload),
            self.config.http_timeout,
            limit,
        )
        if not 200 <= response.status < 300:
            raise ConsumerError("http_status_error")
        try:
            value = json.loads(response.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ConsumerError("invalid_json_response")
        if not isinstance(value, dict):
            raise ConsumerError("invalid_json_response")
        return value

    def _safe_output(self, value: bytes) -> str:
        bounded = value[:MAX_CLI_OUTPUT_BYTES]
        text = bounded.decode("utf-8", errors="replace")
        for secret in (self.config.queue_api_token, self.config.agent_token):
            text = text.replace(secret, "[redacted]")
        return text


def _json_bytes(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def _write_all(descriptor: int, contents: bytes) -> None:
    offset = 0
    while offset < len(contents):
        written = os.write(descriptor, contents[offset:])
        if written <= 0:
            raise OSError("short write")
        offset += written


def _header(headers: Mapping[str, str], name: str) -> Optional[str]:
    lowered = name.lower()
    for key, value in headers.items():
        if key.lower() == lowered:
            return value
    return None


def _parse_timestamp(value: Any) -> Optional[datetime]:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


def _iso_timestamp(value: Optional[datetime]) -> Optional[str]:
    if value is None:
        return None
    return value.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _validated_base_url(value: str, name: str) -> str:
    if not isinstance(value, str):
        raise ValueError("{} must be an HTTP URL".format(name))
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise ValueError("{} must be an HTTP URL".format(name))
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("{} must not contain credentials, query, or fragment".format(name))
    return value.rstrip("/")
