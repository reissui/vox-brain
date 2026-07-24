#!/usr/bin/env python3
"""Voice-meeting acceptance at the Queue, Agent, and canonical-vault boundary."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional


APP_DIR = Path(__file__).resolve().parents[1]
ROOT = APP_DIR.parents[1]
sys.path.insert(0, str(APP_DIR))

from queue_consumer import (  # noqa: E402
    ConsumerError,
    HTTPResponse,
    MAX_OBJECT_BYTES,
    QueueConsumer,
    QueueConsumerConfig,
    subprocess_runner,
)


class VoiceMeetingAgentAcceptanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.vault = self.root / "vault"
        self.state = self.root / "state"
        for directory in (
            "scripts",
            "inbox",
            "system/attachments",
            "notes",
            "sources",
            "maps",
            "projects",
            "people",
            "me",
            "daily",
        ):
            (self.vault / directory).mkdir(parents=True, exist_ok=True)
        (self.vault / ".brain-data-root").write_text(
            "Brain canonical data root v1\n", encoding="utf-8"
        )
        self.cli = self.vault / "scripts" / "brain"
        (self.vault / ".brain-data-root").write_text("brain-data-root-v1\n", encoding="utf-8")
        shutil.copy2(ROOT / "scripts" / "brain", self.cli)
        self.cli.chmod(self.cli.stat().st_mode | stat.S_IXUSR)
        self.transport = VoiceMeetingTransport()
        self.runner = CountingIngestRunner(self.transport.provider_secret)
        self.environment = mock.patch.dict(
            os.environ,
            {"BRAIN_DATA_ROOT": str(self.vault), "BRAIN_NO_LAUNCHCTL": "1"},
        )
        self.environment.start()
        self.configuration = QueueConsumerConfig.build(
            account_id="voice-account",
            queue_id="voice-queue",
            queue_api_token=self.transport.queue_secret,
            gateway_url="https://gateway.example.test",
            agent_token=self.transport.agent_secret,
            instance_id="voice-meeting-acceptance",
            brain_cli=str(self.cli),
            vault_path=str(self.vault),
            state_dir=str(self.state),
            batch_size=1,
            retry_delay_seconds=1,
        )

    def tearDown(self) -> None:
        self.environment.stop()
        self.temporary.cleanup()

    def test_six_mib_staged_transcript_retries_callback_and_ingests_exactly_once(self) -> None:
        line = b"[00:00:00.000-00:00:01.000] You: canonical acceptance transcript\n"
        transcript = (line * ((MAX_OBJECT_BYTES // len(line)) + 1))[:MAX_OBJECT_BYTES]
        self.assertEqual(len(transcript), 6 * 1024 * 1024)
        capture_id = "93000000-0000-4000-8000-000000000093"
        object_path = "/v1/agent/captures/{}/object".format(capture_id)
        envelope = {
            "kind": "capture",
            "instance_id": "voice-meeting-acceptance",
            "device_id": "brain-app-device",
            "idempotency_key": "93000000-0000-4000-8000-000000000093",
            "capture": {
                "id": capture_id,
                "captured_at": "2026-07-16T09:00:00.000Z",
                "type": "transcript",
                "source": "Brain.app meeting",
                "title": "Voice meeting acceptance.md",
            },
            "object": {
                "kind": "transcript",
                "capture_id": capture_id,
                "path": object_path,
                "sha256": hashlib.sha256(transcript).hexdigest(),
                "content_type": "text/plain; charset=utf-8",
                "byte_length": len(transcript),
                "filename": "Voice meeting acceptance.md",
                "retention": "permanent",
            },
        }
        self.transport.objects[object_path] = transcript
        self.transport.fail_next_delivered_report = True
        consumer = QueueConsumer(
            self.configuration,
            transport=self.transport,
            runner=self.runner,
        )

        self.transport.enqueue(envelope, "callback-offline")
        self.assertEqual(consumer.poll_once(), 1)
        self.assertEqual(self.transport.settlements[-1], {
            "acks": [],
            "retries": [{"lease_id": "callback-offline", "delay_seconds": 1}],
        })
        self.assertEqual(self.transport.delivered_report_attempts, 1)

        notes = list((self.vault / "inbox").glob("*.md"))
        self.assertEqual(len(notes), 1)
        canonical = notes[0].read_bytes()
        self.assertIn(b"type: transcript", canonical)
        self.assertIn(b"source: \"Brain.app meeting\"", canonical)
        self.assertIn(b"capture_id: " + capture_id.encode("ascii"), canonical)
        self.assertTrue(canonical.endswith(transcript))
        first_inode = notes[0].stat().st_ino
        first_digest = hashlib.sha256(canonical).hexdigest()

        self.transport.enqueue(envelope, "callback-online")
        self.assertEqual(consumer.poll_once(), 1)
        self.assertEqual(self.transport.settlements[-1], {
            "acks": [{"lease_id": "callback-online"}],
            "retries": [],
        })
        self.assertEqual(self.transport.delivered_report_attempts, 2)
        self.assertEqual(self.transport.successful_delivered_reports, 1)
        self.assertEqual(self.transport.object_requests, 1)
        self.assertEqual(self.runner.calls, 1)

        replayed_notes = list((self.vault / "inbox").glob("*.md"))
        self.assertEqual(replayed_notes, notes)
        self.assertEqual(replayed_notes[0].stat().st_ino, first_inode)
        self.assertEqual(hashlib.sha256(replayed_notes[0].read_bytes()).hexdigest(), first_digest)
        self.assertEqual(list(self.state.rglob(".brain-capture-*")), [])
        self.assertEqual(list(self.vault.rglob("*.wav")), [])
        self.assertEqual(list(self.vault.rglob("*.caf")), [])
        self.assertEqual(list(self.vault.rglob("*.mp3")), [])

        persisted = b"\n".join(
            path.read_bytes()
            for path in self.vault.rglob("*")
            if path.is_file() and path != self.cli
        )
        for secret in (
            self.transport.agent_secret,
            self.transport.queue_secret,
            self.transport.provider_secret,
        ):
            self.assertNotIn(secret.encode("utf-8"), persisted)


class VoiceMeetingTransport:
    def __init__(self) -> None:
        self.queue_secret = "queue-acceptance-secret"
        self.agent_secret = "agent-acceptance-secret"
        self.provider_secret = "codex-claude-credential-must-not-cross"
        self.messages: List[Dict[str, Any]] = []
        self.objects: Dict[str, bytes] = {}
        self.settlements: List[Dict[str, Any]] = []
        self.fail_next_delivered_report = False
        self.delivered_report_attempts = 0
        self.successful_delivered_reports = 0
        self.object_requests = 0

    def enqueue(self, envelope: Dict[str, Any], lease_id: str) -> None:
        body = base64.b64encode(
            json.dumps(envelope, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        self.messages.append({
            "id": "message-" + lease_id,
            "lease_id": lease_id,
            "attempts": 1,
            "body": body,
            "metadata": {"CF-Content-Type": "json"},
        })

    def __call__(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        body: Optional[bytes],
        timeout: float,
        limit: int,
    ) -> HTTPResponse:
        if url.endswith("/messages/pull"):
            self.assert_bearer(headers, self.queue_secret)
            messages, self.messages = self.messages, []
            return self.json_response({"success": True, "result": {"messages": messages}})
        if url.endswith("/messages/ack"):
            self.assert_bearer(headers, self.queue_secret)
            payload = json.loads((body or b"{}").decode("utf-8"))
            self.settlements.append(payload)
            return self.json_response({
                "success": True,
                "result": {
                    "ackCount": len(payload.get("acks", [])),
                    "retryCount": len(payload.get("retries", [])),
                },
            })
        if url.endswith("/object"):
            self.assert_bearer(headers, self.agent_secret)
            self.object_requests += 1
            path = url.removeprefix("https://gateway.example.test")
            value = self.objects[path]
            if limit != MAX_OBJECT_BYTES:
                raise AssertionError("transcript download must remain six-MiB bounded")
            return HTTPResponse(200, {
                "content-type": "text/plain; charset=utf-8",
                "content-length": str(len(value)),
                "x-content-sha256": hashlib.sha256(value).hexdigest(),
            }, value)
        if url.endswith("/result"):
            self.assert_bearer(headers, self.agent_secret)
            payload = json.loads((body or b"{}").decode("utf-8"))
            if payload == {"state": "delivered"}:
                self.delivered_report_attempts += 1
                if self.fail_next_delivered_report:
                    self.fail_next_delivered_report = False
                    raise ConsumerError("network_error")
                self.successful_delivered_reports += 1
            return self.json_response({"ok": True})
        raise AssertionError("unexpected acceptance request: " + url)

    @staticmethod
    def assert_bearer(headers: Mapping[str, str], expected: str) -> None:
        if headers.get("Authorization") != "Bearer " + expected:
            raise AssertionError("wrong fixed-boundary bearer")

    @staticmethod
    def json_response(value: Dict[str, Any]) -> HTTPResponse:
        return HTTPResponse(
            200,
            {"content-type": "application/json"},
            json.dumps(value).encode("utf-8"),
        )


class CountingIngestRunner:
    def __init__(self, forbidden_provider_secret: str) -> None:
        self.forbidden_provider_secret = forbidden_provider_secret
        self.calls = 0

    def __call__(self, argv, stdin: bytes, cwd: Path, timeout: float):
        self.calls += 1
        if list(argv[1:]) != ["ingest", "--json"]:
            raise AssertionError("agent must invoke only brain ingest --json")
        if self.forbidden_provider_secret.encode("utf-8") in stdin:
            raise AssertionError("provider credential crossed into canonical ingest")
        return subprocess_runner(argv, stdin, cwd, timeout)


if __name__ == "__main__":
    unittest.main()
