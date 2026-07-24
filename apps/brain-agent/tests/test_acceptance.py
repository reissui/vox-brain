#!/usr/bin/env python3
"""Remote-first acceptance across the installed Brain Agent boundaries."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import plistlib
import shutil
import stat
import sys
import tempfile
import threading
import unittest
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence
from unittest import mock


APP_DIR = Path(__file__).resolve().parents[1]
ROOT = APP_DIR.parents[1]
sys.path.insert(0, str(APP_DIR))

import config  # noqa: E402
import service  # noqa: E402
from queue_consumer import (  # noqa: E402
    CommandResult,
    ConsumerError,
    HTTPResponse,
    QueueConsumer,
    QueueConsumerConfig,
    subprocess_runner,
)


class AcceptanceTransport:
    def __init__(self) -> None:
        self.messages: List[Dict[str, Any]] = []
        self.calls: List[Dict[str, Any]] = []
        self.acknowledgements: List[Dict[str, Any]] = []
        self.reports: List[Dict[str, Any]] = []
        self.report_failures = 0
        self.objects: Dict[str, tuple[bytes, str]] = {}

    def __call__(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        body: Optional[bytes],
        timeout: float,
        limit: int,
    ) -> HTTPResponse:
        self.calls.append(
            {
                "method": method,
                "url": url,
                "headers": dict(headers),
                "body": body,
                "timeout": timeout,
                "limit": limit,
            }
        )
        if url.endswith("/messages/pull"):
            messages, self.messages = self.messages, []
            return self._json({"success": True, "result": {"messages": messages}})
        if url.endswith("/messages/ack"):
            payload = json.loads((body or b"{}").decode("utf-8"))
            self.acknowledgements.append(payload)
            return self._json({"success": True, "result": {"ackCount": 1, "retryCount": 0}})
        if url.endswith("/result"):
            if self.report_failures:
                self.report_failures -= 1
                raise ConsumerError("network_error")
            payload = json.loads((body or b"{}").decode("utf-8"))
            self.reports.append({"url": url, "payload": payload})
            return self._json({"ok": True})
        if "/object" in url:
            contents, content_type = self.objects[url]
            return HTTPResponse(
                200,
                {"content-type": content_type, "content-length": str(len(contents))},
                contents,
            )
        raise AssertionError("unexpected acceptance request: " + url)

    def enqueue(self, envelope: Dict[str, Any], lease: str) -> None:
        encoded = base64.b64encode(
            json.dumps(envelope, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        self.messages.append(
            {
                "id": "message-" + lease,
                "lease_id": lease,
                "attempts": 1,
                "body": encoded,
                "metadata": {"CF-Content-Type": "json"},
            }
        )

    @staticmethod
    def _json(value: Dict[str, Any]) -> HTTPResponse:
        return HTTPResponse(
            200,
            {"content-type": "application/json"},
            json.dumps(value).encode("utf-8"),
        )


class RecordingRunner:
    def __init__(self) -> None:
        self.calls: List[Dict[str, Any]] = []

    def __call__(
        self, argv: Sequence[str], stdin: bytes, cwd: Path, timeout: float
    ) -> CommandResult:
        self.calls.append(
            {"argv": list(argv), "stdin": stdin, "cwd": cwd, "timeout": timeout}
        )
        return CommandResult(0, b"acceptance complete", b"")


class FixedClock:
    def now(self) -> datetime:
        return datetime(2026, 7, 16, 9, 30, tzinfo=timezone.utc)


class RemoteFirstAgentAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.vault = self.root / "vault"
        self.state = self.root / "state"
        (self.vault / "scripts").mkdir(parents=True)
        (self.vault / "inbox").mkdir()
        (self.vault / "system" / "attachments").mkdir(parents=True)
        (self.vault / ".brain-data-root").write_text("brain-data-root-v1\n", encoding="utf-8")
        for name in ("notes", "sources", "maps", "projects", "people", "me", "daily"):
            (self.vault / name).mkdir()
        (self.vault / ".brain-data-root").write_text(
            "Brain canonical data root v1\n", encoding="utf-8"
        )
        self.cli = self.vault / "scripts" / "brain"
        shutil.copy2(ROOT / "scripts" / "brain", self.cli)
        self.cli.chmod(self.cli.stat().st_mode | stat.S_IXUSR)
        self.transport = AcceptanceTransport()
        self.environment = mock.patch.dict(
            os.environ,
            {"BRAIN_DATA_ROOT": str(self.vault), "BRAIN_NO_LAUNCHCTL": "1"},
        )
        self.environment.start()
        self.configuration = QueueConsumerConfig.build(
            account_id="account-acceptance",
            queue_id="queue-acceptance",
            queue_api_token="queue-secret",
            gateway_url="https://gateway.example.test",
            agent_token="agent-secret",
            instance_id="brain-acceptance",
            brain_cli=str(self.cli),
            vault_path=str(self.vault),
            state_dir=str(self.state),
            batch_size=10,
            retry_delay_seconds=1,
        )

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    def transcript_envelope(self) -> Dict[str, Any]:
        return {
            "kind": "capture",
            "instance_id": "brain-acceptance",
            "device_id": "brain-app-device",
            "idempotency_key": "64000000-0000-4000-8000-000000000064",
            "capture": {
                "id": "64000000-0000-4000-8000-000000000064",
                "captured_at": "2026-07-16T09:00:00.000Z",
                "type": "transcript",
                "source": "Mac Parakeet via Brain.app",
                "text": "Speaker A: ship the remote-first app.\nSpeaker B: agreed.",
                "title": "Remote First Standup.txt",
            },
        }

    def test_queue_retry_ingests_transcript_once_and_never_handles_audio(self) -> None:
        envelope = self.transcript_envelope()
        self.transport.report_failures = 1
        consumer = QueueConsumer(
            self.configuration,
            transport=self.transport,
            runner=subprocess_runner,
        )

        self.transport.enqueue(envelope, "offline-at-report")
        self.assertEqual(consumer.poll_once(), 1)
        first_settlement = self.transport.acknowledgements[-1]
        self.assertEqual(first_settlement["acks"], [])
        self.assertEqual(
            first_settlement["retries"],
            [{"lease_id": "offline-at-report", "delay_seconds": 1}],
        )

        notes = list((self.vault / "inbox").glob("*.md"))
        self.assertEqual(len(notes), 1)
        first_bytes = notes[0].read_bytes()
        self.assertIn(envelope["capture"]["text"].encode("utf-8"), first_bytes)

        self.transport.enqueue(envelope, "online-retry")
        self.assertEqual(consumer.poll_once(), 1)
        self.assertEqual(
            self.transport.acknowledgements[-1],
            {"acks": [{"lease_id": "online-retry"}], "retries": []},
        )
        self.assertEqual(len(list((self.vault / "inbox").glob("*.md"))), 1)
        self.assertEqual(notes[0].read_bytes(), first_bytes)
        self.assertEqual(self.transport.reports[-1]["payload"], {"state": "delivered"})
        self.assertFalse(any("/object" in call["url"] for call in self.transport.calls))
        self.assertEqual(list(self.state.glob(".brain-capture-*")), [])
        self.assertEqual(
            list(self.vault.rglob("*.mp3")) + list(self.vault.rglob("*.m4a")),
            [],
        )

    def test_binary_delivery_records_permanent_reference_without_local_bytes(self) -> None:
        contents = b"%PDF-1.7\n\x00permanent-original\xff"
        capture_id = "65000000-0000-4000-8000-000000000065"
        object_path = "/v1/agent/captures/{}/object".format(capture_id)
        envelope = {
            "kind": "capture",
            "instance_id": "brain-acceptance",
            "device_id": "brain-app-device",
            "idempotency_key": capture_id,
            "capture": {
                "id": capture_id,
                "captured_at": "2026-07-16T09:05:00.000Z",
                "type": "design",
                "source": "Brain.app",
                "note": "Reference the permanent PDF.",
            },
            "object": {
                "path": object_path,
                "sha256": hashlib.sha256(contents).hexdigest(),
                "content_type": "application/pdf",
                "byte_length": len(contents),
                "filename": "Owner brief.pdf",
                "retention": "permanent",
            },
        }
        self.transport.objects["https://gateway.example.test" + object_path] = (
            contents,
            "application/pdf",
        )
        self.transport.enqueue(envelope, "binary-delivery")
        consumer = QueueConsumer(
            self.configuration,
            transport=self.transport,
            runner=subprocess_runner,
        )

        self.assertEqual(consumer.poll_once(), 1)

        notes = list((self.vault / "inbox").glob("*65000000*.md"))
        self.assertEqual(len(notes), 1)
        note = notes[0].read_text(encoding="utf-8")
        self.assertIn('brain_object: "brain://capture/' + capture_id + '"', note)
        self.assertIn("object_sha256: " + hashlib.sha256(contents).hexdigest(), note)
        self.assertIn('object_mime: "application/pdf"', note)
        self.assertIn("object_size: " + str(len(contents)), note)
        self.assertIn('object_filename: "Owner brief.pdf"', note)
        self.assertEqual(list((self.vault / "system" / "attachments").iterdir()), [])
        self.assertFalse(any(path.is_file() and path.read_bytes() == contents for path in self.vault.rglob("*")))
        self.assertEqual(list(self.state.rglob(".brain-capture-*")), [])
        self.assertEqual(self.transport.reports[-1]["payload"], {"state": "delivered"})

    def test_only_allowlisted_jobs_execute_as_fixed_direct_argv_and_settle(self) -> None:
        runner = RecordingRunner()
        consumer = QueueConsumer(
            self.configuration,
            transport=self.transport,
            runner=runner,
        )
        for index, (kind, question) in enumerate(
            (("ask", "What shipped?"), ("process", None), ("digest", None)),
            start=1,
        ):
            action: Dict[str, Any] = {"id": "job-{}".format(index), "kind": kind}
            if question is not None:
                action["question"] = question
            self.transport.enqueue(
                {"kind": "action", "instance_id": "brain-acceptance", "action": action},
                "job-{}".format(index),
            )

        self.assertEqual(consumer.poll_once(), 3)
        self.assertEqual(
            [call["argv"] for call in runner.calls],
            [
                [str(self.cli), "ask", "What shipped?"],
                [str(self.cli), "process"],
                [str(self.cli), "digest"],
            ],
        )
        self.assertTrue(all(call["cwd"] == self.vault.resolve() for call in runner.calls))
        self.assertEqual(len(self.transport.acknowledgements[-1]["acks"]), 3)
        self.assertEqual(self.transport.acknowledgements[-1]["retries"], [])

        self.transport.enqueue(
            {
                "kind": "action",
                "instance_id": "brain-acceptance",
                "action": {"id": "job-shell", "kind": "shell", "argv": ["rm", "-rf", "/"]},
            },
            "job-shell",
        )
        consumer.poll_once()
        self.assertEqual(len(runner.calls), 3)
        self.assertEqual(self.transport.reports[-1]["payload"], {
            "state": "failed",
            "error": "action_not_allowed",
        })

    def test_ask_executes_against_external_non_git_data_root_and_returns_citations(self) -> None:
        source_root = self.root / "source"
        data_root = self.root / "external-data"
        state_root = self.root / "external-state"
        (source_root / "scripts").mkdir(parents=True)
        (source_root / ".git").mkdir()
        (data_root / "notes").mkdir(parents=True)
        (data_root / "notes" / "External.md").write_text(
            "# External\nCanonical external knowledge.\n", encoding="utf-8"
        )
        cli = source_root / "scripts" / "brain"
        cli.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "root = pathlib.Path(os.environ['BRAIN_DATA_ROOT'])\n"
            "pathlib.Path(__file__).with_suffix('.log').write_text(json.dumps({\n"
            "  'argv': sys.argv[1:], 'cwd': os.getcwd(), 'data_root': str(root),\n"
            "  'has_note': (root / 'notes' / 'External.md').is_file(),\n"
            "}), encoding='utf-8')\n"
            "print('Canonical answer from [[notes/External]].')\n",
            encoding="utf-8",
        )
        cli.chmod(0o700)
        configuration = QueueConsumerConfig.build(
            account_id="account-acceptance",
            queue_id="queue-acceptance",
            queue_api_token="queue-secret",
            gateway_url="https://gateway.example.test",
            agent_token="agent-secret",
            instance_id="brain-acceptance",
            brain_cli=str(cli),
            vault_path=str(data_root),
            state_dir=str(state_root),
            batch_size=1,
        )
        transport = AcceptanceTransport()
        transport.enqueue(
            {
                "kind": "action",
                "instance_id": "brain-acceptance",
                "action": {
                    "id": "external-ask",
                    "kind": "ask",
                    "question": "Where is the canonical note?",
                },
            },
            "external-ask",
        )

        self.assertFalse((data_root / ".git").exists())
        self.assertEqual(
            QueueConsumer(configuration, transport=transport, runner=subprocess_runner).poll_once(),
            1,
        )
        invocation = json.loads(cli.with_suffix(".log").read_text(encoding="utf-8"))
        self.assertEqual(invocation["argv"], ["ask", "Where is the canonical note?"])
        self.assertEqual(invocation["cwd"], str(data_root.resolve()))
        self.assertEqual(invocation["data_root"], str(data_root.resolve()))
        self.assertTrue(invocation["has_note"])
        self.assertEqual(transport.reports[-1]["payload"], {
            "state": "completed",
            "output": "Canonical answer from [[notes/External]].\n",
        })

    def test_live_api_gmail_heartbeat_launch_config_and_path_remain_local(self) -> None:
        fake_cli = self.root / "fake-brain"
        fake_cli.write_text(
            "#!/bin/sh\n"
            "case \"$1:$2\" in\n"
            "status:--json) printf '%s\\n' '{\"schema_version\":1,\"inbox\":1}' ;;\n"
            "doctor:--json) printf '%s\\n' '{\"schema_version\":1,\"overall\":\"activity\"}' ;;\n"
            "*) exit 64 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        fake_cli.chmod(0o700)
        (self.vault / "notes" / "Remote.md").write_text(
            "# Remote\nCanonical acceptance knowledge.\n", encoding="utf-8"
        )
        secrets = config.AgentSecrets(
            agent_token="agent-secret-local",
            origin_token="origin-secret-local",
            queue_api_token="queue-secret-local",
        )
        runtime_config = config.AgentConfig(
            instance_id="brain-acceptance",
            gateway_url="https://gateway.example.test",
            site_url="https://private.example.test",
            account_id="account-acceptance",
            queue_id="queue-acceptance",
            vault_path=self.vault,
            brain_cli_path=fake_cli,
            api_port=0,
            state_dir=self.state,
            secrets=secrets,
        )
        server = service.create_origin_server(runtime_config)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        host, port = server.server_address[:2]

        def get(path: str) -> Dict[str, Any]:
            request = urllib.request.Request("http://{}:{}{}".format(host, port, path))
            request.add_header("X-Brain-Origin-Token", secrets.origin_token)
            with urllib.request.urlopen(request, timeout=2) as response:
                return json.loads(response.read().decode("utf-8"))

        try:
            self.assertEqual(host, "127.0.0.1")
            self.assertEqual(get("/v1/status")["inbox"], 1)
            self.assertEqual(get("/v1/status")["site_url"], "https://private.example.test")
            self.assertEqual(get("/v1/health")["overall"], "activity")
            self.assertEqual(
                get("/v1/knowledge/documents?limit=1")["documents"],
                [{"path": "notes/Remote.md", "title": "Remote"}],
            )
            self.assertEqual(
                get("/v1/knowledge/search?q=acceptance")["results"][0]["path"],
                "notes/Remote.md",
            )
            self.assertIn(
                "Canonical acceptance knowledge",
                get("/v1/knowledge/document?path=notes%2FRemote.md")["content"],
            )
            with mock.patch.dict(
                service.gmail_api.HANDLERS,
                {"status": lambda payload: {
                    "status": "connected",
                    "account": "owner@example.test",
                }},
            ):
                gmail = get("/v1/agent/gmail/status")
            self.assertEqual(gmail, {
                "status": "connected",
                "account": "owner@example.test",
            })
            self.assertNotIn("secret", json.dumps(gmail))
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

        agent = service.BrainAgentService(
            runtime_config,
            object(),
            object(),
            summary_reader=lambda path: {
                "path": path,
                "credential": secrets.agent_token,
            },
            clock=FixedClock(),
        )
        agent._last_successful_queue_poll = "2026-07-16T09:29:00.000Z"
        heartbeat = agent.heartbeat_payload()
        self.assertEqual(heartbeat["instance_id"], "brain-acceptance")
        self.assertEqual(heartbeat["last_successful_queue_poll"], "2026-07-16T09:29:00.000Z")
        self.assertEqual(heartbeat["status"]["credential"], "[redacted]")
        self.assertEqual(heartbeat["health"]["credential"], "[redacted]")

        environment = {"HOME": str(self.root / "home"), "PATH": "/custom/bin:/usr/bin"}
        path = service.bootstrap_path(environment).split(os.pathsep)
        self.assertEqual(path[:5], [
            str(self.root / "home" / ".local" / "bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ])
        self.assertEqual(path[-1], "/custom/bin")

        template = (APP_DIR / "app.voxbrain.agent.plist").read_text(encoding="utf-8")
        replacements = {
            "@ENV_FILE@": "/private/agent.env",
            "@PYTHON@": sys.executable,
            "@SERVICE@": str(APP_DIR / "service.py"),
            "@CONFIG@": "/private/agent.json",
            "@WORKING_DIRECTORY@": str(APP_DIR),
            "@HOME@": str(self.root / "home"),
            "@PATH@": ":".join(path),
            "@STDOUT@": "/private/stdout.log",
            "@STDERR@": "/private/stderr.log",
        }
        for marker, value in replacements.items():
            template = template.replace(marker, value)
        launch = plistlib.loads(template.encode("utf-8"))
        self.assertTrue(launch["RunAtLoad"])
        self.assertTrue(launch["KeepAlive"])
        self.assertEqual(launch["ProgramArguments"][0:2], ["/bin/sh", "-c"])
        self.assertEqual(launch["ProgramArguments"][4], "/private/agent.env")
        self.assertEqual(launch["ProgramArguments"][7], "/private/agent.json")
        self.assertEqual(launch["EnvironmentVariables"]["PATH"], ":".join(path))
        installer = (APP_DIR / "install.sh").read_text(encoding="utf-8")
        self.assertIn('chmod 600 "$plist_tmp"', installer)
        self.assertIn('mv -f "$plist_tmp" "$PLIST"', installer)
        self.assertIn('print("PASS gateway heartbeat")', installer)
        self.assertIn('print("PASS queue access")', installer)


if __name__ == "__main__":
    unittest.main()
