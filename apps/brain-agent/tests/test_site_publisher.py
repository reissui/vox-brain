#!/usr/bin/env python3
"""Hermetic regression tests for Git-free private-site publication."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


APP = Path(__file__).resolve().parents[1]
REPO = APP.parents[1]
sys.path.insert(0, str(APP))

from site_publisher import PUBLIC_TOP_LEVEL, PublisherError, load_config, publish  # noqa: E402


CAPTURE_ID = "65000000-0000-4000-8000-000000000065"


class SitePublisherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.code = self.root / "application-code"
        self.data = self.root / "personal-data"
        self.state = self.root / "runtime-state"
        self.bin = self.root / "commands"
        self.events = self.root / "events.log"
        self.snapshot = self.root / "site-snapshot.json"
        for path in (self.code / "scripts", self.code / "site", self.data, self.state, self.bin):
            path.mkdir(parents=True)
        shutil.copy2(REPO / "scripts" / "build-libraries.py", self.code / "scripts")
        shutil.copy2(REPO / "scripts" / "build-projects.py", self.code / "scripts")
        (self.code / "site" / "astro.config.mjs").write_text("// fixture\n")
        (self.code / "site" / "package.json").write_text('{"private":true}\n')
        self.object_bytes = b"permanent-r2-original\x00\xff"
        self.object_hash = hashlib.sha256(self.object_bytes).hexdigest()
        self.requests: list[tuple[str, str]] = []
        self._write_data()
        self._write_commands()
        self._start_server()
        self.config_path = self.state / "agent.json"
        self.config_path.write_text(
            json.dumps(
                {
                    "instance_id": "mini-test",
                    "gateway_url": self.gateway_url,
                    "site_url": "https://private.example.test",
                    "account_id": "account-test",
                    "queue_id": "queue-test",
                    "code_root": str(self.code),
                    "data_root": str(self.data),
                    "brain_cli_path": str(self.code / "scripts" / "brain"),
                    "api_port": 8765,
                    "state_dir": str(self.state),
                }
            ),
            encoding="utf-8",
        )
        self.config_path.chmod(0o600)
        self.config = load_config(self.config_path)

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=2)
        self.temporary.cleanup()

    def _write_data(self) -> None:
        for directory in (
            "sources/designs",
            "notes",
            "maps",
            "projects",
            "system/attachments",
            "me",
            "daily",
            "people",
            "inbox",
            ".trash",
        ):
            (self.data / directory).mkdir(parents=True)
        (self.data / "index.md").write_text(
            "# Brain\n\n<!-- PROJECTS:START -->\nold\n<!-- PROJECTS:END -->\n",
            encoding="utf-8",
        )
        (self.data / ".brain-data-root").write_text("Brain canonical data root v1\n")
        (self.data / "sources" / "designs" / "R2 Design.md").write_text(
            """---
type: design
title: Permanent design
url: https://example.test/design
captured: 2026-07-20
tags: [design/reference]
brain_object: "brain://capture/65000000-0000-4000-8000-000000000065"
object_sha256: {digest}
object_mime: "image/png"
object_size: {size}
object_filename: "reference.png"
---

**TL;DR** — A useful permanent design.

## Original

[Open](brain://capture/65000000-0000-4000-8000-000000000065)
""".format(digest=self.object_hash, size=len(self.object_bytes)),
            encoding="utf-8",
        )
        (self.data / "notes" / "Legacy.md").write_text(
            "# Legacy\n\n![Approved](/system/attachments/legacy.png)\n", encoding="utf-8"
        )
        (self.data / "notes" / "Project brief.md").write_text(
            """---
type: note
entity: Private Project
captured: 2026-07-20
status: filed
---

# Reviewable project brief
""",
            encoding="utf-8",
        )
        (self.data / "maps" / "INDEX.md").write_text("# Map\n", encoding="utf-8")
        (self.data / "system" / "attachments" / "legacy.png").write_bytes(b"legacy-approved")
        (self.data / "projects" / "Private Project.md").write_text(
            """---
type: project
status: active
started: 2026-07-01
---

## Secret prose

Never publish this sentence.

## Log

- 2026-07-20 — private activity
""",
            encoding="utf-8",
        )
        for private in ("me/profile.md", "daily/2026-07-20.md", "people/Person.md", "inbox/raw.md", ".trash/old.md"):
            (self.data / private).write_text("private sentinel: " + private, encoding="utf-8")
        (self.data / "sources" / ".credential.env").write_text("TOKEN=never-stage\n", encoding="utf-8")

    def _executable(self, name: str, body: str) -> Path:
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)
        return path

    def _write_commands(self) -> None:
        self.site_builder = self._executable(
            "astro-build",
            """#!/usr/bin/env python3
import json, os, pathlib, stat, sys, time
staging=pathlib.Path(os.environ['BRAIN_SITE_CONTENT_ROOT'])
public=pathlib.Path(os.environ['BRAIN_SITE_OUT_DIR'])
with open(os.environ['FAKE_EVENTS'],'a') as f: f.write('astro\\n')
if os.environ.get('FAKE_SITE_SLEEP'): time.sleep(float(os.environ['FAKE_SITE_SLEEP']))
paths=[]
for path in staging.rglob('*'):
    paths.append({'path':str(path.relative_to(staging)),'mode':stat.S_IMODE(path.stat().st_mode)})
source=(staging/'sources/designs/R2 Design.md').read_text()
designs=(staging/'designs.md').read_text()
snapshot={'paths':paths,'source':source,'designs':designs,
          'index':(staging/'index.md').read_text(),
          'project_page':(staging/'project-notes/Private-Project.md').read_text(),
          'r2_hash':__import__('hashlib').sha256((staging/'system/attachments/65000000-0000-4000-8000-000000000065/reference.png').read_bytes()).hexdigest(),
          'legacy':(staging/'system/attachments/legacy.png').read_text()}
pathlib.Path(os.environ['FAKE_SNAPSHOT']).write_text(json.dumps(snapshot))
directories={'_astro','maps','notes','pagefind','project-notes','sources','system','tags'}
for name in os.environ['PUBLIC_TOP_LEVEL'].split(','):
    target=public/name
    if name in directories: target.mkdir(parents=True,exist_ok=True)
    else: target.write_text('built')
""",
        )
        self.wrangler = self._executable(
            "wrangler",
            """#!/usr/bin/env python3
import os, sys
assert os.environ['CLOUDFLARE_API_TOKEN']=='pages-secret'
assert os.environ['CLOUDFLARE_ACCOUNT_ID']=='account-test'
args=sys.argv[1:]
assert args[0:2]==['pages','deploy']
assert args[-4:]==['--project-name','brain-vault','--branch','main']
with open(os.environ['FAKE_EVENTS'],'a') as f: f.write('wrangler\\n')
raise SystemExit(int(os.environ.get('FAKE_WRANGLER_EXIT','0')))
""",
        )

    def _start_server(self) -> None:
        test = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, _format: str, *_args: object) -> None:
                return

            def do_GET(self) -> None:  # noqa: N802
                test.requests.append((self.path, self.headers.get("Authorization", "")))
                if self.path != "/v1/agent/captures/{}/object".format(CAPTURE_ID):
                    self.send_error(404)
                    return
                body = test.object_bytes
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("X-Content-SHA256", hashlib.sha256(body).hexdigest())
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.gateway_url = "http://127.0.0.1:{}".format(self.server.server_port)

    def environment(self, **extra: str) -> dict[str, str]:
        result = dict(os.environ)
        result.update(
            {
                "FAKE_EVENTS": str(self.events),
                "FAKE_SNAPSHOT": str(self.snapshot),
                "PUBLIC_TOP_LEVEL": ",".join(sorted(PUBLIC_TOP_LEVEL)),
            }
        )
        result.update(extra)
        return result

    def invoke(self, **environment: str) -> str:
        previous = dict(os.environ)
        os.environ.clear()
        os.environ.update(self.environment(**environment))
        try:
            return publish(
                self.config,
                token="agent-secret",
                pages_token="pages-secret",
                timeout=5,
                site_command=[str(self.site_builder)],
                wrangler_command=[str(self.wrangler)],
            )
        finally:
            os.environ.clear()
            os.environ.update(previous)

    def assert_no_staging(self) -> None:
        self.assertEqual(list(self.state.glob(".site-publish-*")), [])

    def test_allowlists_fetches_verifies_deploys_in_order_and_cleans_up(self) -> None:
        self.assertFalse((self.code / ".git").exists())
        self.assertFalse((self.data / ".git").exists())
        self.assertEqual(self.invoke(), "published")
        self.assertEqual(self.requests, [
            ("/v1/agent/captures/{}/object".format(CAPTURE_ID), "Bearer agent-secret")
        ])
        self.assertEqual(self.events.read_text(encoding="utf-8").splitlines(), ["astro", "wrangler"])
        snapshot = json.loads(self.snapshot.read_text(encoding="utf-8"))
        paths = {item["path"] for item in snapshot["paths"]}
        for forbidden in ("me", "daily", "people", "projects", "inbox", ".trash", ".credential.env"):
            self.assertFalse(any(path == forbidden or path.startswith(forbidden + "/") for path in paths))
        self.assertIn("Private Project", snapshot["index"])
        self.assertIn("Project brief", snapshot["project_page"])
        self.assertIn('href="/notes/Project-brief"', snapshot["project_page"])
        self.assertNotIn("Never publish this sentence", snapshot["source"] + snapshot["designs"] + snapshot["index"])
        self.assertNotIn("Never publish this sentence", snapshot["project_page"])
        self.assertNotIn("Reviewable project brief", snapshot["project_page"])
        self.assertNotIn("brain://capture/", snapshot["source"] + snapshot["designs"])
        self.assertIn("/system/attachments/{}/reference.png".format(CAPTURE_ID), snapshot["designs"])
        self.assertEqual(snapshot["r2_hash"], self.object_hash)
        self.assertEqual(snapshot["legacy"], "legacy-approved")
        self.assertTrue(all(item["mode"] in (0o600, 0o700) for item in snapshot["paths"]))
        status = json.loads((self.state / "site-publisher-status.json").read_text())
        self.assertEqual(status["state"], "success")
        self.assertIsNone(status["error_code"])
        self.assertEqual(stat.S_IMODE((self.state / "site-publisher-status.json").stat().st_mode), 0o600)
        self.assertNotIn("pages-secret", json.dumps(status))
        self.assert_no_staging()

    def test_object_mismatch_aborts_before_astro_and_cleans_up(self) -> None:
        self.object_bytes = b"tampered"
        with self.assertRaisesRegex(PublisherError, "did not match") as caught:
            self.invoke()
        self.assertEqual(caught.exception.code, "object_mismatch")
        self.assertFalse(self.events.exists())
        status = json.loads((self.state / "site-publisher-status.json").read_text())
        self.assertEqual(status["state"], "failure")
        self.assertEqual(status["error_code"], "object_mismatch")
        self.assert_no_staging()

    def test_deploy_failure_serialization_and_timeout_all_cleanup(self) -> None:
        with self.assertRaises(PublisherError) as deploy_failure:
            self.invoke(FAKE_WRANGLER_EXIT="9")
        self.assertEqual(deploy_failure.exception.code, "command_failed")
        self.assert_no_staging()

        lock = (self.state / "site-publisher.lock").open("w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.invoke(), "already_running")
        finally:
            lock.close()

        with self.assertRaises(PublisherError) as timeout:
            previous = dict(os.environ)
            os.environ.update(self.environment(FAKE_SITE_SLEEP="1"))
            try:
                publish(
                    self.config,
                    token="agent-secret",
                    pages_token="pages-secret",
                    timeout=0.05,
                    site_command=[str(self.site_builder)],
                    wrangler_command=[str(self.wrangler)],
                )
            finally:
                os.environ.clear()
                os.environ.update(previous)
        self.assertEqual(timeout.exception.code, "timeout")
        self.assert_no_staging()

    def test_process_marker_prevents_duplicate_deploy(self) -> None:
        marker = self.data / "system" / "last-run.json"
        marker.write_text('{"at":"2026-07-20T10:00:00Z","summary":"processed inbox (2026-07-20)"}\n')
        previous = dict(os.environ)
        os.environ.update(self.environment())
        try:
            first = publish(
                self.config,
                token="agent-secret",
                pages_token="pages-secret",
                timeout=5,
                process_marker_path=marker,
                site_command=[str(self.site_builder)],
                wrangler_command=[str(self.wrangler)],
            )
            second = publish(
                self.config,
                token="agent-secret",
                pages_token="pages-secret",
                timeout=5,
                process_marker_path=marker,
                site_command=[str(self.site_builder)],
                wrangler_command=[str(self.wrangler)],
            )
        finally:
            os.environ.clear()
            os.environ.update(previous)
        self.assertEqual((first, second), ("published", "unchanged"))
        self.assertEqual(self.events.read_text().splitlines().count("wrangler"), 1)

    def test_termination_signal_cleans_staging(self) -> None:
        command = [
            sys.executable,
            str(APP / "site_publisher.py"),
            "--config",
            str(self.config_path),
            "--timeout",
            "10",
            "--site-command",
            str(self.site_builder),
            "--wrangler-command",
            str(self.wrangler),
        ]
        environment = self.environment(
            BRAIN_AGENT_TOKEN="agent-secret",
            CLOUDFLARE_API_TOKEN="pages-secret",
            FAKE_SITE_SLEEP="5",
        )
        process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not list(self.state.glob(".site-publish-*")):
            time.sleep(0.01)
        self.assertTrue(list(self.state.glob(".site-publish-*")))
        process.send_signal(signal.SIGTERM)
        _stdout, stderr = process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("signal", stderr)
        self.assert_no_staging()


if __name__ == "__main__":
    unittest.main()
