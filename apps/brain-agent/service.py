#!/usr/bin/env python3
"""One supervised process for the remote Brain Agent runtime."""

from __future__ import annotations

import argparse
import json
import logging
import os
import queue
import signal
import subprocess
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, MutableMapping, Optional, Sequence, Tuple

import api
import gmail_api
from config import AgentConfig, ConfigError, load_config
from queue_consumer import (
    ConsumerError,
    MAX_GATEWAY_RESPONSE_BYTES,
    QueueConsumer,
    QueueConsumerConfig,
    Transport,
    urllib_transport,
)


AGENT_VERSION = "1"
HEARTBEAT_INTERVAL_SECONDS = 60.0
QUEUE_POLL_INTERVAL_SECONDS = 5.0
HEARTBEAT_PATH = "/v1/agent/heartbeat"
MAX_GMAIL_REQUEST_BYTES = 16 * 1024
MAX_ORIGIN_REQUESTS = 8
REQUIRED_PATH_SUFFIXES = (
    ".local/bin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
)

SummaryReader = Callable[[str], Dict[str, Any]]


class SystemClock:
    def now(self) -> datetime:
        return datetime.now(timezone.utc)

    def wait(self, event: threading.Event, seconds: float) -> bool:
        return event.wait(seconds)


class SecretRedactingFilter(logging.Filter):
    """Last-resort protection for component log messages."""

    def __init__(self, secrets: Sequence[str]) -> None:
        super().__init__()
        self._secrets = tuple(secret for secret in secrets if secret)

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            rendered = record.getMessage()
        except Exception:
            rendered = "log_message_unavailable"
        for secret in self._secrets:
            rendered = rendered.replace(secret, "[redacted]")
        record.msg = rendered
        record.args = ()
        return True


class _OriginHandler(api._BrainAPIHandler):  # type: ignore[attr-defined]
    """Extend the read-only server with the four fixed Gmail adapter calls."""

    _GMAIL_PREFIX = "/v1/agent/gmail/"

    def do_GET(self) -> None:
        try:
            path, query = self._request_parts()
        except api.APIError as error:
            self._send_api_error(error)
            return
        if path == self._GMAIL_PREFIX + "status":
            self._handle_gmail("status", query, {})
            return
        super().do_GET()

    def do_POST(self) -> None:
        try:
            path, query = self._request_parts()
        except api.APIError as error:
            self._send_api_error(error)
            return
        operation = path[len(self._GMAIL_PREFIX) :] if path.startswith(self._GMAIL_PREFIX) else ""
        if operation not in gmail_api.HANDLERS:
            super().do_POST()
            return
        if not self._authorized():
            return
        try:
            payload = self._read_json_body()
        except api.APIError as error:
            self._send_api_error(error)
            return
        self._handle_gmail(operation, query, payload, authenticated=True)

    def _read_json_body(self) -> Dict[str, Any]:
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        length_value = self.headers.get("Content-Length", "")
        if content_type != "application/json" or not length_value.isdigit():
            raise api.APIError(400, "invalid_request", "A JSON request body is required")
        length = int(length_value)
        if length > MAX_GMAIL_REQUEST_BYTES:
            raise api.APIError(413, "request_too_large", "Request body is too large")
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise api.APIError(400, "invalid_request", "Request body is invalid")
        if not isinstance(payload, dict):
            raise api.APIError(400, "invalid_request", "Request body is invalid")
        return payload

    def _handle_gmail(
        self,
        operation: str,
        query: str,
        payload: Dict[str, Any],
        authenticated: bool = False,
    ) -> None:
        if not authenticated and not self._authorized():
            return
        if query:
            self._send_api_error(api.APIError(400, "invalid_query", "Query parameters are not allowed"))
            return
        try:
            result = gmail_api.HANDLERS[operation](payload)
            self._send_json(200, result)
        except gmail_api.GmailAPIError as error:
            self._send_json(400, {"error": {"code": error.code, "message": str(error)}})
        except api.APIError as error:
            self._send_api_error(error)
        except Exception:
            self._send_api_error(api.APIError(500, "gmail_unavailable", "Gmail is temporarily unavailable"))


class _OriginServer(api.BrainAPIServer):
    """Threaded origin with a hard cap on concurrent request handlers."""

    def __init__(self, server_address: Any, handler: Any) -> None:
        self._request_slots = threading.BoundedSemaphore(MAX_ORIGIN_REQUESTS)
        super().__init__(server_address, handler)

    def process_request(self, request: Any, client_address: Any) -> None:
        if not self._request_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._request_slots.release()
            raise

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()


class _OperationalBrainReadAPI(api.BrainReadAPI):
    """Attach service-owned diagnostics to the existing Brain health report."""

    def __init__(self, config: api.BrainAPIConfig) -> None:
        super().__init__(config)
        self.health_provider: Optional[Callable[[Dict[str, Any]], Dict[str, Any]]] = None

    def dispatch_get(self, path: str, query_string: str) -> Tuple[int, Dict[str, Any]]:
        status, payload = super().dispatch_get(path, query_string)
        if path == "/v1/health" and self.health_provider is not None:
            payload = self.health_provider(payload)
        return status, payload


def create_origin_server(config: AgentConfig) -> api.BrainAPIServer:
    read_config = api.BrainAPIConfig.build(
        vault_path=str(config.data_root),
        cli_path=str(config.brain_cli_path),
        origin_token=config.secrets.origin_token,
        site_url=config.site_url,
        port=config.api_port,
        gateway_url=config.gateway_url,
        publisher_status_path=str(config.state_dir / "site-publisher-status.json"),
    )
    server = _OriginServer((api.LOOPBACK_HOST, read_config.port), _OriginHandler)
    server.brain_api = _OperationalBrainReadAPI(read_config)  # type: ignore[attr-defined]
    return server


def bootstrap_path(
    environ: Optional[MutableMapping[str, str]] = None, home: Optional[str] = None
) -> str:
    """Prepend the deterministic launchd PATH without losing explicit extras."""

    target = os.environ if environ is None else environ
    home_path = home if home is not None else target.get("HOME", str(Path.home()))
    if not os.path.isabs(home_path):
        home_path = str(Path.home())
    required = (os.path.join(home_path, REQUIRED_PATH_SUFFIXES[0]),) + REQUIRED_PATH_SUFFIXES[1:]
    existing = tuple(part for part in target.get("PATH", "").split(os.pathsep) if part)
    ordered = []
    for entry in required + existing:
        if entry not in ordered:
            ordered.append(entry)
    target["PATH"] = os.pathsep.join(ordered)
    return target["PATH"]


def configure_runtime_environment(
    config: AgentConfig, environ: Optional[MutableMapping[str, str]] = None
) -> None:
    """Keep Agent telemetry state separate from sibling service health state."""

    target = os.environ if environ is None else environ
    target["BRAIN_STATE_DIR"] = str(config.state_dir)
    # The canonical data root is <Brain state>/Vault. Supplying the sibling
    # service state explicitly keeps child health checks independent of the
    # Agent's own BRAIN_STATE_DIR and of launchd's inherited environment.
    target["BRAIN_TELEGRAM_STATE_DIR"] = str(config.data_root.parent)


def build_queue_consumer(config: AgentConfig) -> QueueConsumer:
    queue_config = QueueConsumerConfig.build(
        account_id=config.account_id,
        queue_id=config.queue_id,
        queue_api_token=config.secrets.queue_api_token,
        gateway_url=config.gateway_url,
        agent_token=config.secrets.agent_token,
        instance_id=config.instance_id,
        brain_cli=str(config.brain_cli_path),
        vault_path=str(config.data_root),
        state_dir=str(config.state_dir),
        batch_size=1,
    )
    return QueueConsumer(queue_config)


class BrainAgentService:
    """Supervise one queue loop, one loopback server, and one heartbeat loop."""

    def __init__(
        self,
        config: AgentConfig,
        consumer: Any,
        server: Any,
        *,
        transport: Transport = urllib_transport,
        summary_reader: Optional[SummaryReader] = None,
        clock: Optional[Any] = None,
        logger: Optional[logging.Logger] = None,
        queue_poll_interval: float = QUEUE_POLL_INTERVAL_SECONDS,
    ) -> None:
        self.config = config
        self.consumer = consumer
        self.server = server
        self.transport = transport
        self.clock = SystemClock() if clock is None else clock
        self.logger = logging.getLogger("brain-agent") if logger is None else logger
        self.logger.addFilter(SecretRedactingFilter(config.secrets.values()))
        self.queue_poll_interval = float(queue_poll_interval)
        self.stop_event = threading.Event()
        self._mutation_lock = threading.Lock()
        self._poll_lock = threading.Lock()
        self._last_successful_queue_poll: Optional[str] = None
        self._failures: queue.Queue[Tuple[str, BaseException]] = queue.Queue()
        self._threads: list[threading.Thread] = []
        self._summary_reader = summary_reader or self._read_summary_from_server
        brain_api = getattr(server, "brain_api", None)
        if isinstance(brain_api, _OperationalBrainReadAPI):
            brain_api.health_provider = self._augment_health

    @property
    def last_successful_queue_poll(self) -> Optional[str]:
        with self._poll_lock:
            return self._last_successful_queue_poll

    def request_stop(self) -> None:
        self.stop_event.set()

    def run(self) -> int:
        components = (
            ("queue", self._queue_loop),
            ("http", self._http_loop),
            ("heartbeat", self._heartbeat_loop),
        )
        self._threads = [
            threading.Thread(
                name="brain-agent-" + name,
                target=self._supervise,
                args=(name, target),
                daemon=False,
            )
            for name, target in components
        ]
        self.logger.info("service_starting instance=%s", self.config.instance_id)
        for thread in self._threads:
            thread.start()

        exit_code = 0
        while not self.stop_event.is_set():
            try:
                component, error = self._failures.get(timeout=0.1)
            except queue.Empty:
                continue
            self.logger.error("component_failed component=%s type=%s", component, type(error).__name__)
            exit_code = 1
            self.stop_event.set()

        self.server.shutdown()
        for thread in self._threads:
            thread.join()
        self.server.server_close()
        while not self._failures.empty():
            component, error = self._failures.get_nowait()
            if exit_code == 0:
                self.logger.error(
                    "component_failed component=%s type=%s", component, type(error).__name__
                )
            exit_code = 1
        self.logger.info("service_stopped code=%d", exit_code)
        return exit_code

    def _supervise(self, name: str, target: Callable[[], None]) -> None:
        try:
            target()
            if not self.stop_event.is_set():
                raise RuntimeError("component stopped unexpectedly")
        except BaseException as error:
            self._failures.put((name, error))

    def _queue_loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                with self._mutation_lock:
                    count = self.consumer.poll_once()
                with self._poll_lock:
                    self._last_successful_queue_poll = _timestamp(self.clock.now())
            except ConsumerError:
                self.logger.warning("queue_poll_failed")
                count = 0
            if count == 0:
                self.clock.wait(self.stop_event, self.queue_poll_interval)

    def _http_loop(self) -> None:
        self.server.serve_forever(poll_interval=0.1)

    def _heartbeat_loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                self._post_heartbeat()
            except ConsumerError:
                self.logger.warning("heartbeat_failed")
            self.clock.wait(self.stop_event, HEARTBEAT_INTERVAL_SECONDS)

    def _post_heartbeat(self) -> None:
        response = self.transport(
            "POST",
            self.config.gateway_url + HEARTBEAT_PATH,
            {
                "Accept": "application/json",
                "Authorization": "Bearer " + self.config.secrets.agent_token,
                "Content-Type": "application/json",
            },
            json.dumps(
                self.heartbeat_payload(),
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8"),
            30.0,
            MAX_GATEWAY_RESPONSE_BYTES,
        )
        if not 200 <= response.status < 300:
            raise ConsumerError("heartbeat_request_failed")

    def heartbeat_payload(self) -> Dict[str, Any]:
        payload = {
            "instance_id": self.config.instance_id,
            "generated_at": _timestamp(self.clock.now()),
            "status": self._safe_summary("/v1/status"),
            "health": self._safe_summary("/v1/health"),
            "agent_version": AGENT_VERSION,
            "last_successful_queue_poll": self.last_successful_queue_poll,
        }
        return _redact(payload, self.config.secrets.values())

    def _augment_health(self, report: Dict[str, Any]) -> Dict[str, Any]:
        """Merge content-free Queue, launchd, and progress evidence."""

        current = self.clock.now().astimezone(timezone.utc)
        snapshot_method = getattr(self.consumer, "operational_snapshot", None)
        if callable(snapshot_method):
            operations = snapshot_method(current)
        else:
            operations = {
                "last_successful_poll": self.last_successful_queue_poll,
                "poll_age_seconds": None,
                "backlog_count": 0,
                "oldest_backlog_age_seconds": None,
                "process": {
                    "state": "idle",
                    "label": None,
                    "started_at": None,
                    "progress_age_seconds": None,
                    "declared_bound_seconds": 0,
                },
            }

        last_poll = self.last_successful_queue_poll or operations.get("last_successful_poll")
        poll_age = _age_seconds(last_poll, current)
        if poll_age is None:
            poll_state, poll_summary = "activity", "Queue consumer is starting"
        elif poll_age <= max(30, int(self.queue_poll_interval * 4)):
            poll_state, poll_summary = "pass", "Queue consumer heartbeat is current"
        else:
            poll_state, poll_summary = "failure", "Queue consumer heartbeat is stale"

        backlog_count = operations.get("backlog_count", 0)
        backlog_age = operations.get("oldest_backlog_age_seconds")
        if isinstance(backlog_count, bool) or not isinstance(backlog_count, int):
            backlog_count = 0
        if backlog_count == 0:
            backlog_state, backlog_summary = "pass", "Queue backlog is clear"
        elif isinstance(backlog_age, int) and backlog_age > 90:
            backlog_state, backlog_summary = "warning", "Oldest queued work is overdue"
        else:
            backlog_state, backlog_summary = "activity", "Queue work is being consumed"

        process = operations.get("process") if isinstance(operations.get("process"), dict) else {}
        persisted = self._persisted_progress(current)
        if process.get("state") == "idle" and persisted.get("state") == "stuck":
            process = persisted
            operations["process"] = persisted
        process_state = process.get("state")
        if process_state == "stuck":
            work_state, work_summary = "failure", "Agent process exceeded its declared bound"
        elif process_state == "running":
            work_state, work_summary = "activity", "Agent work is making bounded progress"
        else:
            work_state, work_summary = "pass", "No Agent process is stuck"

        automation = self._automation_progress(current)
        launchd = self._launchd_states()
        operations["automation"] = automation
        operations["launchd"] = launchd
        automation_state = "pass" if automation["last_progress_at"] is not None else "warning"
        automation_summary = (
            "Librarian progress is recorded"
            if automation_state == "pass" else "Librarian has not recorded progress yet"
        )

        checks = list(report.get("checks", [])) if isinstance(report.get("checks"), list) else []
        checks.extend([
            _health_check(
                "agent.queue_heartbeat", poll_state, poll_summary,
                "Last successful Queue poll: {}.".format(last_poll or "not yet"),
                "launchctl kickstart -k gui/$(id -u)/app.voxbrain.agent" if poll_state == "failure" else None,
            ),
            _health_check(
                "agent.queue_backlog", backlog_state, backlog_summary,
                "{} item(s) observed; oldest age: {} seconds.".format(
                    backlog_count, backlog_age if backlog_age is not None else "unknown"
                ),
                "tail -n 200 -F \"$HOME/Library/Application Support/Brain Agent/logs/agent.stderr.log\""
                if backlog_state == "warning" else None,
            ),
            _health_check(
                "agent.process_progress", work_state, work_summary,
                "State: {}; progress age: {}; declared bound: {} seconds.".format(
                    process_state or "unknown",
                    process.get("progress_age_seconds", "unknown"),
                    process.get("declared_bound_seconds", "unknown"),
                ),
                "launchctl kickstart -k gui/$(id -u)/app.voxbrain.agent"
                if work_state == "failure" else None,
            ),
            _health_check(
                "automation.progress", automation_state, automation_summary,
                "Last progress: {}. launchd is {}.".format(
                    automation["last_progress_at"] or "not yet", launchd["automation"]
                ),
                "scripts/brain automate on hourly" if automation_state == "warning" else None,
            ),
        ])
        return _health_report_with_operations(report, checks, operations)

    def _persisted_progress(self, current: datetime) -> Dict[str, Any]:
        path = self.config.state_dir / "agent-progress.json"
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            process = value.get("process") if isinstance(value, dict) else None
            if not isinstance(process, dict) or process.get("state") != "running":
                return {}
            age = _age_seconds(process.get("started_at"), current)
            bound = process.get("declared_bound_seconds")
            if isinstance(age, int) and isinstance(bound, int) and age > bound:
                return {**process, "state": "stuck", "progress_age_seconds": age}
        except (OSError, ValueError, TypeError):
            pass
        return {}

    def _automation_progress(self, current: datetime) -> Dict[str, Any]:
        path = self.config.data_root / "system" / "last-run.json"
        timestamp: Optional[str] = None
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(value, dict) and isinstance(value.get("at"), str):
                timestamp = value["at"]
        except (OSError, ValueError, TypeError):
            pass
        return {
            "last_progress_at": timestamp,
            "progress_age_seconds": _age_seconds(timestamp, current),
        }

    @staticmethod
    def _launchd_states() -> Dict[str, str]:
        return {
            "agent": "running",
            "automation": _launchd_state("app.voxbrain"),
        }

    def _safe_summary(self, path: str) -> Dict[str, Any]:
        try:
            result = self._summary_reader(path)
            if not isinstance(result, dict):
                raise TypeError("summary must be an object")
            return result
        except Exception:
            return {"available": False}

    def _read_summary_from_server(self, path: str) -> Dict[str, Any]:
        _, payload = self.server.brain_api.dispatch_get(path, "")
        return payload


def _timestamp(value: datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    normalized = value.astimezone(timezone.utc)
    return normalized.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _age_seconds(value: Any, current: datetime) -> Optional[int]:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return max(0, int((current - parsed.astimezone(timezone.utc)).total_seconds()))


def _launchd_state(label: str) -> str:
    executable = "/bin/launchctl"
    if not os.path.exists(executable):
        return "unknown"
    try:
        result = subprocess.run(
            [executable, "print", "gui/{}/{}".format(os.getuid(), label)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
            text=True,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    if result.returncode != 0:
        return "not_loaded"
    return "running" if "state = running" in result.stdout else "loaded"


def _health_check(
    identifier: str,
    state: str,
    summary: str,
    detail: str,
    remediation: Optional[str],
) -> Dict[str, Any]:
    return {
        "id": identifier,
        "scope": "agent",
        "state": state,
        "summary": summary,
        "detail": detail,
        "remediation": remediation,
    }


def _health_report_with_operations(
    report: Dict[str, Any],
    checks: Sequence[Dict[str, Any]],
    operations: Dict[str, Any],
) -> Dict[str, Any]:
    counts = {"pass": 0, "activity": 0, "warning": 0, "failure": 0}
    for check in checks:
        state = check.get("state")
        if state in counts:
            counts[state] += 1
    overall = (
        "failure" if counts["failure"] else
        "warning" if counts["warning"] else
        "activity" if counts["activity"] else "healthy"
    )
    return {**report, "overall": overall, "counts": counts, "checks": list(checks), "operations": operations}


def _redact(value: Any, secrets: Sequence[str]) -> Any:
    if isinstance(value, str):
        for secret in secrets:
            value = value.replace(secret, "[redacted]")
        return value
    if isinstance(value, dict):
        return {str(key): _redact(item, secrets) for key, item in value.items()}
    if isinstance(value, list):
        return [_redact(item, secrets) for item in value]
    return value


def _configure_logging() -> logging.Logger:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    return logging.getLogger("brain-agent")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Run the remote Brain Agent")
    parser.add_argument("config", help="absolute path to the owner-only JSON configuration")
    arguments = parser.parse_args(argv)
    logger = _configure_logging()
    bootstrap_path()
    try:
        config = load_config(arguments.config)
        configure_runtime_environment(config)
        consumer = build_queue_consumer(config)
        server = create_origin_server(config)
    except (ConfigError, ValueError, OSError) as error:
        logger.error("service_configuration_failed type=%s", type(error).__name__)
        return 2

    service = BrainAgentService(config, consumer, server, logger=logger)

    def stop(_signum: int, _frame: Any) -> None:
        service.request_stop()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    return service.run()


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = [
    "AGENT_VERSION",
    "BrainAgentService",
    "HEARTBEAT_INTERVAL_SECONDS",
    "HEARTBEAT_PATH",
    "SecretRedactingFilter",
    "bootstrap_path",
    "build_queue_consumer",
    "create_origin_server",
    "main",
]
