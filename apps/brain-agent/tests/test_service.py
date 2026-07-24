#!/usr/bin/env python3
"""Regression tests for the single supervised Brain Agent process."""

from __future__ import annotations

import io
import json
import logging
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Mapping, Optional
from unittest import mock


APP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(APP_DIR))

import config  # noqa: E402
import service  # noqa: E402
from queue_consumer import HTTPResponse  # noqa: E402


class FakeServer:
    def __init__(self) -> None:
        self.serve_calls = 0
        self.shutdown_calls = 0
        self.close_calls = 0
        self.serving = threading.Event()
        self.stopped = threading.Event()

    def serve_forever(self, poll_interval: float = 0.1) -> None:
        self.serve_calls += 1
        self.serving.set()
        self.stopped.wait()

    def shutdown(self) -> None:
        self.shutdown_calls += 1
        self.stopped.set()

    def server_close(self) -> None:
        self.close_calls += 1


class BlockingConsumer:
    def __init__(self) -> None:
        self.calls = 0
        self.active = 0
        self.maximum_active = 0
        self.started = threading.Event()
        self.release = threading.Event()

    def poll_once(self) -> int:
        self.calls += 1
        self.active += 1
        self.maximum_active = max(self.maximum_active, self.active)
        self.started.set()
        self.release.wait()
        self.active -= 1
        return 1


class FailingConsumer:
    def __init__(self, detail: str) -> None:
        self.detail = detail

    def poll_once(self) -> int:
        raise RuntimeError(self.detail)


class OperationalConsumer:
    def __init__(self, snapshot: Dict[str, Any]) -> None:
        self.snapshot = snapshot

    def operational_snapshot(self, current: datetime) -> Dict[str, Any]:
        return dict(self.snapshot)


class AdvancingClock:
    def __init__(self, stop_after_waits: int = 2) -> None:
        self.current = datetime(2026, 7, 15, 10, 0, tzinfo=timezone.utc)
        self.waits = []
        self.stop_after_waits = stop_after_waits

    def now(self) -> datetime:
        return self.current

    def wait(self, event: threading.Event, seconds: float) -> bool:
        self.waits.append(seconds)
        self.current += timedelta(seconds=seconds)
        if len(self.waits) >= self.stop_after_waits:
            event.set()
        return event.is_set()


class BrainAgentServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.vault = self.root / "remote-vault"
        self.state = self.root / "remote-state"
        self.vault.mkdir()
        self.state.mkdir()
        self.cli = self.root / "brain"
        self.cli.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = status ]; then\n"
            "  printf '%s\\n' '{\"schema_version\":1,\"inbox\":2}'\n"
            "else\n"
            "  printf '%s\\n' '{\"schema_version\":1,\"overall\":\"pass\"}'\n"
            "fi\n",
            encoding="utf-8",
        )
        self.cli.chmod(0o700)
        self.secrets = config.AgentSecrets(
            agent_token="agent-secret-value",
            origin_token="origin-secret-value",
            queue_api_token="queue-secret-value",
        )
        self.configuration = config.AgentConfig(
            instance_id="brain-home",
            gateway_url="https://brain.example.test",
            site_url="https://private.example.test",
            account_id="account-123",
            queue_id="queue-456",
            vault_path=self.vault,
            brain_cli_path=self.cli,
            api_port=8765,
            state_dir=self.state,
            secrets=self.secrets,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _transport(self, calls: list[Dict[str, Any]]):
        def send(
            method: str,
            url: str,
            headers: Mapping[str, str],
            body: Optional[bytes],
            timeout: float,
            limit: int,
        ) -> HTTPResponse:
            calls.append(
                {
                    "method": method,
                    "url": url,
                    "headers": dict(headers),
                    "body": json.loads((body or b"{}").decode("utf-8")),
                    "timeout": timeout,
                    "limit": limit,
                }
            )
            return HTTPResponse(204, {}, b"")

        return send

    def _logger(self):
        stream = io.StringIO()
        logger = logging.Logger("brain-agent-test-{}".format(id(stream)))
        handler = logging.StreamHandler(stream)
        logger.addHandler(handler)
        logger.setLevel(logging.DEBUG)
        return logger, stream

    def test_owner_only_config_loads_remote_paths_and_environment_secrets(self) -> None:
        path = self.root / "agent.json"
        document = {
            "instance_id": "brain-home",
            "gateway_url": "https://brain.example.test/",
            "site_url": "https://private.example.test",
            "account_id": "account-123",
            "queue_id": "queue-456",
            "vault_path": str(self.vault),
            "brain_cli_path": str(self.cli),
            "api_port": 8765,
            "state_dir": str(self.state),
        }
        path.write_text(json.dumps(document), encoding="utf-8")
        path.chmod(0o600)
        environment = {
            "BRAIN_AGENT_TOKEN": self.secrets.agent_token,
            "BRAIN_ORIGIN_TOKEN": self.secrets.origin_token,
            "BRAIN_QUEUE_API_TOKEN": self.secrets.queue_api_token,
        }

        loaded = config.load_config(str(path), environment)

        self.assertEqual(loaded.gateway_url, "https://brain.example.test")
        self.assertEqual(loaded.site_url, "https://private.example.test")
        self.assertEqual(loaded.vault_path, self.vault.resolve())
        self.assertEqual(loaded.brain_cli_path, self.cli.resolve())
        self.assertEqual(loaded.secrets.agent_token, self.secrets.agent_token)
        rendered = repr(loaded)
        for secret in self.secrets.values():
            self.assertNotIn(secret, path.read_text(encoding="utf-8"))
            self.assertNotIn(secret, rendered)

        path.chmod(0o644)
        with self.assertRaises(config.ConfigError):
            config.load_config(str(path), environment)

    def test_path_bootstrap_has_launchd_tools_first_and_preserves_extras(self) -> None:
        environment = {"HOME": "/Users/remote", "PATH": "/custom/bin:/usr/bin"}
        result = service.bootstrap_path(environment)
        self.assertEqual(
            result.split(":"),
            [
                "/Users/remote/.local/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/custom/bin",
            ],
        )

    def test_runtime_environment_keeps_agent_and_telegram_state_separate(self) -> None:
        environment = {"BRAIN_TELEGRAM_STATE_DIR": "/stale/inherited-state"}

        service.configure_runtime_environment(self.configuration, environment)

        self.assertEqual(environment["BRAIN_STATE_DIR"], str(self.state))
        self.assertEqual(
            environment["BRAIN_TELEGRAM_STATE_DIR"],
            str(self.vault.parent),
        )

        inferred: Dict[str, str] = {}
        service.configure_runtime_environment(self.configuration, inferred)
        self.assertEqual(
            inferred["BRAIN_TELEGRAM_STATE_DIR"],
            str(self.vault.parent),
        )

    def test_config_requires_one_safe_https_site_url(self) -> None:
        path = self.root / "site-config.json"
        environment = {
            "BRAIN_AGENT_TOKEN": self.secrets.agent_token,
            "BRAIN_ORIGIN_TOKEN": self.secrets.origin_token,
            "BRAIN_QUEUE_API_TOKEN": self.secrets.queue_api_token,
        }
        base = {
            "instance_id": "brain-home",
            "gateway_url": "https://brain.example.test",
            "site_url": "https://private.example.test",
            "account_id": "account-123",
            "queue_id": "queue-456",
            "code_root": str(self.root),
            "data_root": str(self.vault),
            "brain_cli_path": str(self.cli),
            "api_port": 8765,
            "state_dir": str(self.state),
        }
        for invalid in (
            None,
            "http://private.example.test",
            "https://user:secret@private.example.test",
            "https://private.example.test?token=secret",
            "https://private.example.test#fragment",
            "https://private.example.test/é",
            "https://private.example.test:99999",
            "x" * (config.MAX_SITE_URL_CHARS + 1),
        ):
            document = dict(base)
            if invalid is None:
                document.pop("site_url")
            else:
                document["site_url"] = invalid
            path.write_text(json.dumps(document), encoding="utf-8")
            path.chmod(0o600)
            with self.subTest(site_url=str(invalid)[:80]):
                with self.assertRaises(config.ConfigError):
                    config.load_config(str(path), environment)

    def test_origin_server_composes_live_reads_and_fixed_gmail_adapter(self) -> None:
        runtime_config = config.AgentConfig(
            instance_id=self.configuration.instance_id,
            gateway_url=self.configuration.gateway_url,
            site_url=self.configuration.site_url,
            account_id=self.configuration.account_id,
            queue_id=self.configuration.queue_id,
            vault_path=self.configuration.vault_path,
            brain_cli_path=self.configuration.brain_cli_path,
            api_port=0,
            state_dir=self.configuration.state_dir,
            secrets=self.configuration.secrets,
        )
        server = service.create_origin_server(runtime_config)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        port = server.server_address[1]

        def get(path: str) -> Dict[str, Any]:
            request = urllib.request.Request("http://127.0.0.1:{}{}".format(port, path))
            request.add_header("X-Brain-Origin-Token", self.secrets.origin_token)
            with urllib.request.urlopen(request, timeout=1.0) as response:
                return json.loads(response.read().decode("utf-8"))

        try:
            self.assertEqual(server.server_address[0], "127.0.0.1")
            self.assertEqual(
                get("/v1/status"),
                {
                    "schema_version": 1,
                    "inbox": 2,
                    "site_url": "https://private.example.test",
                },
            )
            with mock.patch.dict(
                service.gmail_api.HANDLERS,
                {"status": lambda payload: {"status": "connected", "account": "owner@example.test"}},
            ):
                self.assertEqual(
                    get("/v1/agent/gmail/status"),
                    {"status": "connected", "account": "owner@example.test"},
                )
        finally:
            server.shutdown()
            thread.join(2.0)
            server.server_close()

    def test_heartbeat_payload_is_current_redacted_and_never_faster_than_minutely(self) -> None:
        clock = AdvancingClock(stop_after_waits=2)
        calls: list[Dict[str, Any]] = []
        reader_calls = []

        def summary(path: str) -> Dict[str, Any]:
            reader_calls.append(path)
            if path == "/v1/status":
                return {"inbox": 2, "detail": self.secrets.agent_token}
            return {"overall": "pass"}

        runtime = service.BrainAgentService(
            self.configuration,
            object(),
            FakeServer(),
            transport=self._transport(calls),
            summary_reader=summary,
            clock=clock,
        )
        runtime._last_successful_queue_poll = "2026-07-15T09:59:00.000Z"

        runtime._heartbeat_loop()

        self.assertEqual(clock.waits, [60.0, 60.0])
        self.assertEqual(len(calls), 2)
        self.assertEqual([call["url"] for call in calls], [
            "https://brain.example.test/v1/agent/heartbeat",
            "https://brain.example.test/v1/agent/heartbeat",
        ])
        first, second = (call["body"] for call in calls)
        self.assertEqual(first["instance_id"], "brain-home")
        self.assertEqual(first["generated_at"], "2026-07-15T10:00:00.000Z")
        self.assertEqual(second["generated_at"], "2026-07-15T10:01:00.000Z")
        self.assertEqual(first["agent_version"], service.AGENT_VERSION)
        self.assertEqual(first["status"], {"detail": "[redacted]", "inbox": 2})
        self.assertEqual(first["health"], {"overall": "pass"})
        self.assertEqual(first["last_successful_queue_poll"], "2026-07-15T09:59:00.000Z")
        self.assertEqual(reader_calls, ["/v1/status", "/v1/health"] * 2)

    def test_live_health_reports_queue_backlog_progress_and_stuck_process(self) -> None:
        clock = AdvancingClock(stop_after_waits=99)
        (self.vault / "system").mkdir()
        (self.vault / "system" / "last-run.json").write_text(json.dumps({
            "at": "2026-07-15T09:30:00Z",
            "summary": "processed inbox",
        }))
        process = {
            "state": "stuck",
            "label": "capture:safe-id",
            "started_at": "2026-07-15T08:00:00.000Z",
            "progress_age_seconds": 7200,
            "declared_bound_seconds": 3600,
        }
        consumer = OperationalConsumer({
            "last_successful_poll": "2026-07-15T09:59:58.000Z",
            "poll_age_seconds": 2,
            "backlog_count": 1,
            "oldest_backlog_age_seconds": 120,
            "process": process,
        })
        server = service.create_origin_server(config.AgentConfig(
            instance_id=self.configuration.instance_id,
            gateway_url=self.configuration.gateway_url,
            site_url=self.configuration.site_url,
            account_id=self.configuration.account_id,
            queue_id=self.configuration.queue_id,
            vault_path=self.configuration.vault_path,
            brain_cli_path=self.configuration.brain_cli_path,
            api_port=0,
            state_dir=self.configuration.state_dir,
            secrets=self.configuration.secrets,
        ))
        service.BrainAgentService(
            self.configuration,
            consumer,
            server,
            clock=clock,
        )
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            request = urllib.request.Request(
                "http://127.0.0.1:{}/v1/health".format(server.server_address[1]),
                headers={"X-Brain-Origin-Token": self.secrets.origin_token},
            )
            with urllib.request.urlopen(request, timeout=1.0) as response:
                health = json.loads(response.read().decode("utf-8"))
        finally:
            server.shutdown()
            thread.join(2)
            server.server_close()

        self.assertEqual(health["overall"], "failure")
        self.assertEqual(health["operations"]["backlog_count"], 1)
        self.assertEqual(health["operations"]["process"], process)
        self.assertEqual(
            health["operations"]["automation"]["last_progress_at"],
            "2026-07-15T09:30:00Z",
        )
        checks = {item["id"]: item for item in health["checks"]}
        self.assertEqual(checks["agent.queue_heartbeat"]["state"], "pass")
        self.assertEqual(checks["agent.queue_backlog"]["state"], "warning")
        self.assertEqual(checks["agent.process_progress"]["state"], "failure")
        self.assertIn("launchctl kickstart", checks["agent.process_progress"]["remediation"])

    def test_startup_runs_one_of_each_component_and_shutdown_waits_for_active_lease(self) -> None:
        consumer = BlockingConsumer()
        server = FakeServer()
        heartbeat_calls: list[Dict[str, Any]] = []
        runtime = service.BrainAgentService(
            self.configuration,
            consumer,
            server,
            transport=self._transport(heartbeat_calls),
            summary_reader=lambda path: {"path": path},
            queue_poll_interval=0.01,
        )
        result = []
        thread = threading.Thread(target=lambda: result.append(runtime.run()))
        thread.start()

        self.assertTrue(consumer.started.wait(1.0))
        self.assertTrue(server.serving.wait(1.0))
        deadline = time.monotonic() + 1.0
        while not heartbeat_calls and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(server.serve_calls, 1)
        self.assertEqual(consumer.calls, 1)
        self.assertEqual(consumer.maximum_active, 1)
        self.assertEqual(len(heartbeat_calls), 1)
        self.assertTrue(server.serving.is_set(), "reads stay available during a mutation")

        runtime.request_stop()
        time.sleep(0.15)
        self.assertTrue(thread.is_alive(), "shutdown must wait for the active queue lease")
        consumer.release.set()
        thread.join(2.0)

        self.assertFalse(thread.is_alive())
        self.assertEqual(result, [0])
        self.assertEqual(server.shutdown_calls, 1)
        self.assertEqual(server.close_calls, 1)
        self.assertEqual(len(heartbeat_calls), 1)

    def test_component_crash_exits_nonzero_without_logging_secrets(self) -> None:
        server = FakeServer()
        logger, logs = self._logger()
        runtime = service.BrainAgentService(
            self.configuration,
            FailingConsumer("crash " + self.secrets.agent_token),
            server,
            transport=self._transport([]),
            summary_reader=lambda path: {"path": path},
            logger=logger,
        )

        result = runtime.run()

        self.assertEqual(result, 1)
        self.assertIn("component_failed component=queue type=RuntimeError", logs.getvalue())
        for secret in self.secrets.values():
            self.assertNotIn(secret, logs.getvalue())
        self.assertEqual(server.shutdown_calls, 1)


if __name__ == "__main__":
    unittest.main()
