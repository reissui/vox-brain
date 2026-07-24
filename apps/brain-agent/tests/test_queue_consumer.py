#!/usr/bin/env python3
"""Regression tests for the outbound Brain queue consumer."""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence


APP_DIR = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("brain_agent_queue_consumer", APP_DIR / "queue_consumer.py")
assert SPEC is not None and SPEC.loader is not None
consumer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = consumer
SPEC.loader.exec_module(consumer)


class FakeHTTP:
    def __init__(self) -> None:
        self.calls: List[Dict[str, Any]] = []
        self.messages: List[Dict[str, Any]] = []
        self.objects: Dict[str, bytes] = {}
        self.object_headers: Dict[str, Dict[str, str]] = {}
        self.reports: List[Dict[str, Any]] = []
        self.fail_objects = False
        self.fail_reports = False

    def __call__(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        body: Optional[bytes],
        timeout: float,
        limit: int,
    ) -> consumer.HTTPResponse:
        call = {
            "method": method,
            "url": url,
            "headers": dict(headers),
            "body": body,
            "timeout": timeout,
            "limit": limit,
        }
        self.calls.append(call)
        if url.endswith("/messages/pull"):
            messages = self.messages
            self.messages = []
            return self._json({"success": True, "result": {"messages": messages}})
        if url.endswith("/messages/ack"):
            return self._json({"success": True, "result": {"ackCount": 1, "retryCount": 0}})
        if "/object" in url:
            if self.fail_objects:
                raise consumer.ConsumerError("network_error")
            return consumer.HTTPResponse(
                200,
                self.object_headers.get(url, {"content-type": "image/png"}),
                self.objects[url],
            )
        if url.endswith("/result"):
            if self.fail_reports:
                raise consumer.ConsumerError("network_error")
            payload = json.loads((body or b"").decode("utf-8"))
            self.reports.append({"url": url, "payload": payload})
            return self._json({"ok": True})
        raise AssertionError("unexpected request: " + url)

    @staticmethod
    def _json(value: Dict[str, Any]) -> consumer.HTTPResponse:
        return consumer.HTTPResponse(
            200,
            {"content-type": "application/json"},
            json.dumps(value).encode("utf-8"),
        )

    def enqueue(
        self,
        envelope: Dict[str, Any],
        lease: str = "lease-1",
        *,
        legacy_base64: bool = False,
    ) -> None:
        raw = json.dumps(envelope, separators=(",", ":")).encode("utf-8")
        self.messages.append(
            {
                "id": "message-" + lease,
                "lease_id": lease,
                "attempts": 1,
                # Cloudflare's HTTP pull contract returns JSON messages as the
                # original JSON string. Keep the old encoded form available so
                # upgrades can drain messages produced by earlier fixtures.
                "body": (
                    base64.b64encode(raw).decode("ascii")
                    if legacy_base64 else raw.decode("utf-8")
                ),
                "metadata": {"CF-Content-Type": "json"},
            }
        )

    def ack_payloads(self) -> List[Dict[str, Any]]:
        return [
            json.loads(call["body"].decode("utf-8"))
            for call in self.calls
            if call["url"].endswith("/messages/ack")
        ]


class FakeRunner:
    def __init__(self) -> None:
        self.calls: List[Dict[str, Any]] = []
        self.results: List[consumer.CommandResult] = []
        self.inspect_object = False
        self.inspect_transcript = False
        self.state_dir: Optional[Path] = None

    def __call__(
        self, argv: Sequence[str], stdin: bytes, cwd: Path, timeout: float
    ) -> consumer.CommandResult:
        object_mode = None
        object_bytes = None
        object_path: Optional[Path] = None
        if self.inspect_object:
            payload = json.loads(stdin)
            object_path = Path(payload["object_path"])
            object_mode = stat.S_IMODE(object_path.stat().st_mode)
            object_bytes = object_path.read_bytes()
        transcript_paths: List[Path] = []
        transcript_modes: List[int] = []
        transcript_bytes: List[bytes] = []
        if self.inspect_transcript and self.state_dir is not None:
            transcript_paths = list(self.state_dir.rglob(".brain-capture-*.txt"))
            transcript_modes = [stat.S_IMODE(path.stat().st_mode) for path in transcript_paths]
            transcript_bytes = [path.read_bytes() for path in transcript_paths]
        self.calls.append(
            {
                "argv": list(argv),
                "stdin": stdin,
                "cwd": cwd,
                "timeout": timeout,
                "object_path": object_path,
                "object_mode": object_mode,
                "object_bytes": object_bytes,
                "transcript_paths": transcript_paths,
                "transcript_modes": transcript_modes,
                "transcript_bytes": transcript_bytes,
            }
        )
        if self.results:
            return self.results.pop(0)
        return consumer.CommandResult(0, b"ok", b"")


class QueueConsumerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.vault = self.root / "vault"
        self.vault.mkdir()
        self.state = self.root / "state"
        self.cli = self.root / "brain"
        self.cli.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.cli.chmod(0o700)
        self.queue_secret = "queue-secret-must-not-leak"
        self.agent_secret = "agent-secret-must-not-leak"
        self.http = FakeHTTP()
        self.runner = FakeRunner()
        self.runner.state_dir = self.state
        self.config = consumer.QueueConsumerConfig.build(
            account_id="account-123",
            queue_id="queue-456",
            queue_api_token=self.queue_secret,
            gateway_url="https://gateway.test",
            agent_token=self.agent_secret,
            instance_id="brain-home",
            brain_cli=str(self.cli),
            vault_path=str(self.vault),
            state_dir=str(self.state),
            batch_size=4,
            visibility_timeout_ms=120000,
            retry_delay_seconds=9,
        )
        self.subject = consumer.QueueConsumer(
            self.config, transport=self.http, runner=self.runner
        )

    def test_urllib_transport_identifies_the_agent(self) -> None:
        response = mock.MagicMock()
        response.status = 200
        response.headers = {}
        response.read.return_value = b"{}"
        context = mock.MagicMock()
        context.__enter__.return_value = response
        with mock.patch.object(consumer.urllib.request, "urlopen", return_value=context) as urlopen:
            result = consumer.urllib_transport(
                "GET", "https://gateway.test/health", {}, None, 1.0, 1024
            )
        request = urlopen.call_args.args[0]
        self.assertEqual(request.get_header("User-agent"), "Brain-Agent/1")
        self.assertEqual(result.status, 200)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def capture(self, capture_id: str = "capture-1") -> Dict[str, Any]:
        return {
            "kind": "capture",
            "instance_id": "brain-home",
            "device_id": "device-1",
            "idempotency_key": "key-1",
            "capture": {
                "id": capture_id,
                "captured_at": "2026-07-15T12:00:00.000Z",
                "type": "note",
                "source": "test",
                "text": "exact user bytes\nno final newline",
            },
        }

    def transcript_capture(
        self, transcript: bytes, capture_id: str = "meeting-1"
    ) -> Dict[str, Any]:
        envelope = self.capture(capture_id)
        envelope["capture"]["type"] = "transcript"
        envelope["capture"].pop("text", None)
        path = "/v1/agent/captures/{}/object".format(capture_id)
        envelope["object"] = {
            "kind": "transcript",
            "capture_id": capture_id,
            "path": path,
            "sha256": hashlib.sha256(transcript).hexdigest(),
            "content_type": consumer.TRANSCRIPT_OBJECT_TYPE,
            "byte_length": len(transcript),
            "filename": "meeting.txt",
            "retention": "permanent",
        }
        url = "https://gateway.test" + path
        self.http.objects[url] = transcript
        self.http.object_headers[url] = {
            "content-type": consumer.TRANSCRIPT_OBJECT_TYPE,
            "content-length": str(len(transcript)),
        }
        return envelope

    def binary_capture(
        self,
        contents: bytes,
        capture_id: str = "capture-1",
        content_type: str = "image/png",
        filename: str = "screenshot.png",
    ) -> Dict[str, Any]:
        envelope = self.capture(capture_id)
        envelope["capture"]["type"] = "design"
        path = "/v1/agent/captures/{}/object".format(capture_id)
        envelope["object"] = {
            "path": path,
            "sha256": hashlib.sha256(contents).hexdigest(),
            "content_type": content_type,
            "byte_length": len(contents),
            "filename": filename,
            "retention": "permanent",
        }
        url = "https://gateway.test" + path
        self.http.objects[url] = contents
        self.http.object_headers[url] = {
            "content-type": content_type,
            "content-length": str(len(contents)),
        }
        return envelope

    def action(self, command: str, job_id: str = "job-1", **values: Any) -> Dict[str, Any]:
        return {
            "kind": "action",
            "instance_id": "brain-home",
            "action": {"id": job_id, "kind": command, **values},
        }

    def test_pull_uses_configured_cloudflare_endpoint_and_json_message_contract(self) -> None:
        self.assertEqual(self.subject.poll_once(), 0)
        pull = self.http.calls[0]
        self.assertEqual(
            pull["url"],
            "https://api.cloudflare.com/client/v4/accounts/account-123/queues/queue-456/messages/pull",
        )
        self.assertEqual(pull["method"], "POST")
        self.assertEqual(pull["headers"]["Authorization"], "Bearer " + self.queue_secret)
        self.assertEqual(pull["headers"]["Accept"], "application/json")
        self.assertEqual(
            json.loads(pull["body"]),
            {"batch_size": 4, "visibility_timeout_ms": 120000},
        )
        rendered = repr(self.http.ack_payloads())
        self.assertNotIn(self.queue_secret, rendered)
        self.assertNotIn(self.agent_secret, rendered)

    def test_cloudflare_json_body_dispatches_an_action_instead_of_retrying_forever(self) -> None:
        self.http.enqueue(self.action("process", "job-live-json"))

        self.assertEqual(self.subject.poll_once(), 1)

        self.assertEqual(self.runner.calls[0]["argv"], [str(self.cli), "process"])
        self.assertEqual(
            [report["payload"]["state"] for report in self.http.reports],
            ["running", "completed"],
        )
        self.assertEqual(
            self.http.ack_payloads()[-1]["acks"],
            [{"lease_id": "lease-1"}],
        )

    def test_legacy_base64_json_body_remains_drainable(self) -> None:
        self.http.enqueue(
            self.action("digest", "job-legacy-json"),
            legacy_base64=True,
        )

        self.assertEqual(self.subject.poll_once(), 1)
        self.assertEqual(self.runner.calls[0]["argv"], [str(self.cli), "digest"])

    def test_retried_invalid_message_remains_visible_in_backlog_health(self) -> None:
        current = datetime(2026, 7, 21, 12, 0, tzinfo=timezone.utc)
        self.http.messages.append(
            {
                "id": "invalid-live-message",
                "lease_id": "invalid-live-lease",
                "attempts": 1,
                "body": "not-json",
                "metadata": {"CF-Content-Type": "json"},
                "timestamp_ms": int((current - timedelta(seconds=120)).timestamp() * 1000),
            }
        )
        subject = consumer.QueueConsumer(
            self.config,
            transport=self.http,
            runner=self.runner,
            now=lambda: current,
        )

        self.assertEqual(subject.poll_once(), 1)

        snapshot = subject.operational_snapshot(current)
        self.assertEqual(snapshot["backlog_count"], 1)
        self.assertEqual(snapshot["oldest_backlog_age_seconds"], 120)
        self.assertEqual(self.http.ack_payloads()[-1]["acks"], [])

    def test_operational_snapshot_reports_heartbeat_backlog_and_bounded_process(self) -> None:
        current = [datetime(2026, 7, 15, 12, 2, tzinfo=timezone.utc)]
        started = threading.Event()
        release = threading.Event()

        def blocking_runner(
            argv: Sequence[str], stdin: bytes, cwd: Path, timeout: float
        ) -> consumer.CommandResult:
            started.set()
            self.assertTrue(release.wait(2))
            return consumer.CommandResult(0, b"ok", b"")

        subject = consumer.QueueConsumer(
            self.config,
            transport=self.http,
            runner=blocking_runner,
            now=lambda: current[0],
        )
        self.http.enqueue(self.capture("capture-health"))
        result: list[int] = []
        thread = threading.Thread(target=lambda: result.append(subject.poll_once()))
        thread.start()
        self.assertTrue(started.wait(1))

        snapshot = subject.operational_snapshot()
        self.assertEqual(snapshot["backlog_count"], 1)
        self.assertEqual(snapshot["oldest_backlog_age_seconds"], 120)
        self.assertEqual(snapshot["process"]["state"], "running")
        self.assertEqual(snapshot["process"]["label"], "capture:capture-health")
        self.assertEqual(snapshot["process"]["declared_bound_seconds"], 3600)
        progress = self.state / "agent-progress.json"
        self.assertTrue(progress.is_file())
        self.assertEqual(stat.S_IMODE(progress.stat().st_mode), 0o600)
        self.assertNotIn(self.queue_secret, progress.read_text())
        self.assertNotIn(self.agent_secret, progress.read_text())

        current[0] += timedelta(seconds=3601)
        self.assertEqual(subject.operational_snapshot()["process"]["state"], "stuck")
        release.set()
        thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result, [1])
        completed = subject.operational_snapshot()
        self.assertEqual(completed["backlog_count"], 0)
        self.assertEqual(completed["process"]["state"], "idle")
        self.assertEqual(completed["poll_age_seconds"], 0)

    def test_capture_downloads_verifies_and_ingests_exact_payload_before_ack(self) -> None:
        image = b"\x89PNG\r\n\x1a\nremote-image"
        envelope = self.binary_capture(image)
        self.runner.inspect_object = True
        self.http.enqueue(envelope)

        self.assertEqual(self.subject.poll_once(), 1)

        self.assertEqual(len(self.runner.calls), 1)
        call = self.runner.calls[0]
        self.assertEqual(call["argv"], [str(self.cli), "ingest", "--json"])
        self.assertEqual(call["cwd"], self.vault.resolve())
        expected = dict(envelope["capture"])
        actual = json.loads(call["stdin"])
        object_path = Path(actual.pop("object_path"))
        expected.update(
            {
                "object_sha256": envelope["object"]["sha256"],
                "object_mime": "image/png",
                "object_size": len(image),
                "object_filename": "screenshot.png",
            }
        )
        self.assertEqual(actual, expected)
        self.assertEqual(
            call["stdin"],
            json.dumps(
                {**expected, "object_path": str(object_path)},
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8"),
        )
        self.assertEqual(call["object_mode"], 0o600)
        self.assertEqual(call["object_bytes"], image)
        self.assertEqual(call["object_path"], object_path)
        self.assertEqual(stat.S_IMODE(object_path.parent.stat().st_mode), 0o700)
        self.assertFalse(object_path.exists())
        self.assertEqual(self.http.reports[-1]["payload"], {"state": "delivered"})
        ack = self.http.ack_payloads()[-1]
        self.assertEqual(ack, {"acks": [{"lease_id": "lease-1"}], "retries": []})
        report_index = next(
            index for index, item in enumerate(self.http.calls) if item["url"].endswith("/result")
        )
        ack_index = next(
            index for index, item in enumerate(self.http.calls) if item["url"].endswith("/messages/ack")
        )
        self.assertLess(report_index, ack_index)

    def test_digest_mismatch_and_network_error_report_failure_and_retry(self) -> None:
        for index, failure in enumerate(("digest", "network"), start=1):
            with self.subTest(failure=failure):
                envelope = self.binary_capture(b"different", "capture-" + str(index))
                path = envelope["object"]["path"]
                envelope["object"]["sha256"] = hashlib.sha256(b"advertised").hexdigest()
                self.http.objects["https://gateway.test" + path] = b"different"
                self.http.fail_objects = failure == "network"
                self.http.enqueue(envelope, "lease-" + str(index))
                self.subject.poll_once()
                report = self.http.reports[-1]["payload"]
                self.assertEqual(report["state"], "failed")
                self.assertTrue(report["retryable"])
                expected = "network_error" if failure == "network" else "object_digest_mismatch"
                self.assertEqual(report["error"], expected)
                ack = self.http.ack_payloads()[-1]
                self.assertEqual(ack["acks"], [])
                self.assertEqual(
                    ack["retries"],
                    [{"delay_seconds": 9, "lease_id": "lease-" + str(index)}],
                )
                self.assertEqual(len(self.runner.calls), 0)
                self.http.fail_objects = False

    def test_transcript_object_reconstructs_exact_ingest_json_and_cleans_owner_file(self) -> None:
        transcript = "Speaker A: exact words\nSpeaker B: café\n終わり".encode("utf-8")
        envelope = self.transcript_capture(transcript)
        self.runner.inspect_transcript = True
        self.http.enqueue(envelope)

        self.assertEqual(self.subject.poll_once(), 1)

        self.assertEqual(len(self.runner.calls), 1)
        call = self.runner.calls[0]
        payload = json.loads(call["stdin"].decode("utf-8"))
        expected = dict(envelope["capture"])
        expected["text"] = transcript.decode("utf-8")
        self.assertEqual(payload, expected)
        self.assertEqual(call["stdin"], consumer._json_bytes(expected))
        self.assertEqual(call["transcript_modes"], [0o600])
        self.assertEqual(call["transcript_bytes"], [transcript])
        self.assertFalse(call["transcript_paths"][0].exists())
        object_call = next(call for call in self.http.calls if "/object" in call["url"])
        self.assertEqual(object_call["limit"], consumer.MAX_OBJECT_BYTES)
        self.assertEqual(self.http.reports[-1]["payload"], {"state": "delivered"})

    def test_transcript_digest_length_mime_and_utf8_failures_retry_and_clean(self) -> None:
        cases = (
            ("digest", b"exact", "object_digest_mismatch"),
            ("length", b"exact", "object_length_mismatch"),
            ("mime", b"exact", "object_content_type_mismatch"),
            ("utf8", b"\xff", "object_invalid_utf8"),
        )
        for index, (failure, contents, expected_error) in enumerate(cases, start=20):
            with self.subTest(failure=failure):
                capture_id = "meeting-{}".format(index)
                envelope = self.transcript_capture(contents, capture_id)
                descriptor = envelope["object"]
                url = "https://gateway.test" + descriptor["path"]
                if failure == "digest":
                    descriptor["sha256"] = hashlib.sha256(b"different").hexdigest()
                elif failure == "length":
                    descriptor["byte_length"] = len(contents) + 1
                elif failure == "mime":
                    self.http.object_headers[url]["content-type"] = "application/octet-stream"
                self.http.enqueue(envelope, "lease-{}".format(index))

                self.subject.poll_once()

                self.assertEqual(self.runner.calls, [])
                self.assertEqual(self.http.reports[-1]["payload"]["error"], expected_error)
                self.assertTrue(self.http.reports[-1]["payload"]["retryable"])
                self.assertEqual(list(self.state.rglob(".brain-capture-*")), [])
                self.assertEqual(self.http.ack_payloads()[-1]["acks"], [])

    def test_transcript_retries_same_capture_after_download_failure(self) -> None:
        transcript = b"retry exact transcript"
        envelope = self.transcript_capture(transcript, "meeting-retry")
        url = "https://gateway.test" + envelope["object"]["path"]
        self.http.fail_objects = True
        self.http.enqueue(envelope, "first-attempt")
        self.subject.poll_once()
        self.assertEqual(self.runner.calls, [])
        self.assertEqual(self.http.reports[-1]["payload"]["error"], "network_error")

        self.http.fail_objects = False
        self.http.enqueue(envelope, "second-attempt")
        self.subject.poll_once()
        self.assertEqual(len(self.runner.calls), 1)
        self.assertEqual(json.loads(self.runner.calls[0]["stdin"])["id"], "meeting-retry")
        self.assertEqual(json.loads(self.runner.calls[0]["stdin"])["text"], transcript.decode())
        self.assertEqual(self.http.objects[url], transcript)
        self.assertEqual(self.http.reports[-1]["payload"], {"state": "delivered"})

    def test_transcript_temp_is_removed_when_delivered_callback_retries(self) -> None:
        transcript = b"callback retry transcript"
        envelope = self.transcript_capture(transcript, "meeting-callback")
        self.runner.inspect_transcript = True
        self.http.fail_reports = True
        self.http.enqueue(envelope, "callback-first")
        self.subject.poll_once()
        self.assertEqual(len(self.runner.calls), 1)
        self.assertEqual(list(self.state.rglob(".brain-capture-*")), [])

        self.http.fail_reports = False
        self.http.enqueue(envelope, "callback-second")
        self.subject.poll_once()
        self.assertEqual(len(self.runner.calls), 1)
        self.assertEqual(self.http.reports[-1]["payload"], {"state": "delivered"})
        self.assertEqual(self.http.ack_payloads()[-1]["acks"], [{"lease_id": "callback-second"}])

    def test_nonzero_ingest_is_reported_retried_and_not_completed(self) -> None:
        self.runner.results.append(
            consumer.CommandResult(7, b"", (self.agent_secret + " internal detail").encode())
        )
        self.http.enqueue(self.capture())
        self.subject.poll_once()
        self.assertEqual(self.http.reports[-1]["payload"]["error"], "ingest_failed")
        self.assertIn("[redacted]", self.http.reports[-1]["payload"]["detail"])
        self.assertNotIn(self.agent_secret, repr(self.http.reports))
        self.assertEqual(self.http.ack_payloads()[-1]["acks"], [])
        self.assertEqual(len(self.runner.calls), 1)

        self.http.enqueue(self.capture(), "lease-replay")
        self.subject.poll_once()
        self.assertEqual(len(self.runner.calls), 2)

    def test_binary_temp_is_removed_for_ingest_failure_timeout_cancellation_and_report_retry(self) -> None:
        scenarios = ("failure", "timeout", "cancellation", "report")
        for index, scenario in enumerate(scenarios, start=70):
            with self.subTest(scenario=scenario):
                root = self.root / scenario
                root.mkdir()
                state = root / "state"
                config = consumer.QueueConsumerConfig.build(
                    account_id="account-123",
                    queue_id="queue-456",
                    queue_api_token=self.queue_secret,
                    gateway_url="https://gateway.test",
                    agent_token=self.agent_secret,
                    instance_id="brain-home",
                    brain_cli=str(self.cli),
                    vault_path=str(self.vault),
                    state_dir=str(state),
                    retry_delay_seconds=9,
                )
                runner = FakeRunner()
                runner.inspect_object = True
                if scenario == "failure":
                    runner.results.append(consumer.CommandResult(7, b"", b"failed"))
                elif scenario == "timeout":
                    def raise_timeout(*_args: Any) -> consumer.CommandResult:
                        raise subprocess.TimeoutExpired(["brain", "ingest"], 1)
                    runner = raise_timeout  # type: ignore[assignment]
                elif scenario == "cancellation":
                    def cancel(*_args: Any) -> consumer.CommandResult:
                        raise KeyboardInterrupt()
                    runner = cancel  # type: ignore[assignment]
                http = FakeHTTP()
                subject = consumer.QueueConsumer(config, transport=http, runner=runner)
                contents = ("bytes-" + scenario).encode()
                capture_id = "capture-{}".format(index)
                path = "/v1/agent/captures/{}/object".format(capture_id)
                envelope = self.capture(capture_id)
                envelope["capture"]["type"] = "design"
                envelope["object"] = {
                    "path": path,
                    "sha256": hashlib.sha256(contents).hexdigest(),
                    "content_type": "application/pdf",
                    "byte_length": len(contents),
                    "filename": "proof.pdf",
                    "retention": "permanent",
                }
                http.objects["https://gateway.test" + path] = contents
                http.object_headers["https://gateway.test" + path] = {
                    "content-type": "application/pdf",
                    "content-length": str(len(contents)),
                }
                if scenario == "report":
                    http.fail_reports = True
                http.enqueue(envelope, scenario)
                if scenario == "cancellation":
                    with self.assertRaises(KeyboardInterrupt):
                        subject.poll_once()
                else:
                    subject.poll_once()
                self.assertEqual(list(state.rglob(".brain-capture-*")), [])

    def test_completed_replay_acks_without_repeating_capture_or_action(self) -> None:
        self.http.enqueue(self.capture())
        self.subject.poll_once()
        self.http.enqueue(self.capture(), "capture-replay")
        self.subject.poll_once()
        self.assertEqual(len(self.runner.calls), 1)
        self.assertEqual(
            self.http.ack_payloads()[-1],
            {"acks": [{"lease_id": "capture-replay"}], "retries": []},
        )

        self.http.enqueue(self.action("process"), "job-first")
        self.subject.poll_once()
        self.http.enqueue(self.action("process"), "job-replay")
        self.subject.poll_once()
        self.assertEqual(len(self.runner.calls), 2)
        self.assertEqual(
            self.http.ack_payloads()[-1],
            {"acks": [{"lease_id": "job-replay"}], "retries": []},
        )

    def test_locally_finished_job_replay_only_retries_its_durable_report(self) -> None:
        self.http.fail_reports = True
        self.http.enqueue(self.action("process"), "first")
        self.subject.poll_once()
        self.assertEqual(len(self.runner.calls), 1)
        self.assertEqual(self.http.ack_payloads()[-1]["acks"], [])

        self.http.fail_reports = False
        self.http.enqueue(self.action("process"), "report-replay")
        self.subject.poll_once()
        self.assertEqual(len(self.runner.calls), 1)
        self.assertEqual(self.http.reports[-1]["payload"]["state"], "completed")
        self.assertEqual(
            self.http.ack_payloads()[-1],
            {"acks": [{"lease_id": "report-replay"}], "retries": []},
        )

    def test_in_progress_lease_is_retried_without_execution(self) -> None:
        self.assertEqual(self.subject.store.claim("job:job-1"), "claimed")
        self.http.enqueue(self.action("digest"))
        self.subject.poll_once()
        self.assertEqual(self.runner.calls, [])
        self.assertEqual(self.http.reports, [])
        self.assertEqual(self.http.ack_payloads()[-1]["acks"], [])

    def test_actions_are_exactly_allowlisted_direct_argv_and_bounded(self) -> None:
        cases = (
            ("ask", {"question": "What links to [[Agents]]?"}, [str(self.cli), "ask", "What links to [[Agents]]?"]),
            ("process", {}, [str(self.cli), "process"]),
            ("digest", {}, [str(self.cli), "digest"]),
        )
        for index, (command, values, expected) in enumerate(cases, start=1):
            self.runner.results.append(
                consumer.CommandResult(0, b"x" * (consumer.MAX_CLI_OUTPUT_BYTES + 100), b"")
            )
            self.http.enqueue(self.action(command, "job-" + str(index), **values), "lease-" + str(index))
            self.subject.poll_once()
            self.assertEqual(self.runner.calls[-1]["argv"], expected)
            self.assertEqual(self.runner.calls[-1]["stdin"], b"")
            self.assertEqual(self.http.reports[-1]["payload"]["state"], "completed")
            self.assertEqual(
                len(self.http.reports[-1]["payload"]["output"]),
                consumer.MAX_CLI_OUTPUT_BYTES,
            )

        before = len(self.runner.calls)
        self.http.enqueue(self.action("shell", "job-denied", argv=["rm", "-rf", "/"]), "denied")
        self.subject.poll_once()
        self.assertEqual(len(self.runner.calls), before)
        self.assertEqual(
            self.http.reports[-1]["payload"],
            {"state": "failed", "error": "action_not_allowed"},
        )
        self.assertEqual(self.http.ack_payloads()[-1]["acks"], [])

    def test_nonzero_action_and_timeout_report_terminal_failure_then_retry(self) -> None:
        self.runner.results.append(
            consumer.CommandResult(
                5,
                b"partial",
                (self.queue_secret + " " + self.agent_secret).encode("utf-8"),
            )
        )
        self.http.enqueue(self.action("process"))
        self.subject.poll_once()
        report = self.http.reports[-1]["payload"]
        self.assertEqual(report["state"], "failed")
        self.assertEqual(report["error"], "action_failed")
        self.assertNotIn(self.queue_secret, repr(report))
        self.assertNotIn(self.agent_secret, repr(report))
        self.assertEqual(self.http.ack_payloads()[-1]["acks"], [])

        class TimeoutRunner:
            def __call__(self, argv: Sequence[str], stdin: bytes, cwd: Path, timeout: float):
                raise subprocess.TimeoutExpired(list(argv), timeout)

        timed = consumer.QueueConsumer(
            self.config, transport=self.http, runner=TimeoutRunner()
        )
        self.http.enqueue(self.action("digest", "job-timeout"), "timeout")
        timed.poll_once()
        self.assertEqual(self.http.reports[-1]["payload"]["error"], "command_timeout")
        self.assertEqual(self.http.ack_payloads()[-1]["acks"], [])

    def test_audio_object_is_never_requested_or_stored_for_a_transcript(self) -> None:
        envelope = self.capture("meeting-1")
        envelope["capture"]["type"] = "transcript"
        envelope["object"] = {
            "path": "/v1/agent/captures/meeting-1/object",
            "sha256": hashlib.sha256(b"audio").hexdigest(),
            "content_type": "audio/mpeg",
        }
        self.http.enqueue(envelope)
        self.subject.poll_once()
        object_calls = [call for call in self.http.calls if "/object" in call["url"]]
        self.assertEqual(object_calls, [])
        self.assertEqual(self.runner.calls, [])
        self.assertEqual(
            self.http.reports[-1]["payload"]["error"], "transcript_object_forbidden"
        )
        self.assertEqual(
            list(self.state.glob(".brain-capture-*")), []
        )


if __name__ == "__main__":
    unittest.main()
