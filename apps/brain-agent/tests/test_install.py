#!/usr/bin/env python3
"""Hermetic regression tests for the remote Brain Agent installer."""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple


APP_DIR = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / "target-home"
        self.vault = self.root / "remote-vault"
        self.data = self.root / "external-data"
        self.bin_dir = self.root / "fake-bin"
        self.logs = self.root / "fake-logs"
        self.app_dir = self.root / "brain-agent"
        self.install_root = self.root / "installed"
        self.launch_agents = self.install_root / "LaunchAgents"
        self.config_dir = self.install_root / "Brain Agent"
        self.state_dir = self.config_dir / "state"
        self.log_dir = self.config_dir / "logs"
        for directory in (self.home, self.vault, self.bin_dir, self.logs, self.app_dir):
            directory.mkdir(parents=True)
        for name in (
            "install.sh",
            "app.voxbrain.agent.plist",
            "app.voxbrain.site-publisher.plist",
            "cloudflared.example.yml",
            "service.py",
            "site_publisher.py",
            "migrate_data.py",
        ):
            shutil.copy2(APP_DIR / name, self.app_dir / name)
        self.installer = self.app_dir / "install.sh"
        (self.vault / "inbox").mkdir()
        self.vault_marker = self.vault / "inbox" / "canonical.md"
        self.vault_marker.write_text("canonical remote vault\n", encoding="utf-8")
        self.requests: List[Tuple[str, str, str, bytes]] = []
        self.user_agents: List[str] = []
        self.queue_success = True
        self._write_fakes()
        self._start_http_server()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=2)
        self.temp.cleanup()

    def _executable(self, name: str, content: str) -> Path:
        path = self.bin_dir / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)
        return path

    def _write_fakes(self) -> None:
        self.security = self._executable(
            "security",
            """#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$FAKE_SECURITY_LOG"
case "$*" in
  *app.voxbrain.agent-token*) printf '%s\\n' agent-secret ;;
  *app.voxbrain.origin-token*) printf '%s\\n' origin-secret ;;
  *app.voxbrain.queue-api-token*) printf '%s\\n' queue-secret ;;
  *app.voxbrain.pages-api-token*) printf '%s\\n' pages-secret ;;
  *) exit 1 ;;
esac
""",
        )
        self.launchctl = self._executable(
            "launchctl",
            """#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$FAKE_LAUNCHCTL_LOG"
if [ "${FAKE_BOOTSTRAP_FAIL_ONCE:-}" = 1 ] && [ "${1:-}" = bootstrap ] \
  && [ ! -f "$FAKE_BOOTSTRAP_MARKER" ]; then
  : > "$FAKE_BOOTSTRAP_MARKER"
  exit 5
fi
exit 0
""",
        )
        self.cloudflared = self._executable(
            "cloudflared",
            """#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$FAKE_CLOUDFLARED_LOG"
exit 0
""",
        )
        self.codex = self._executable(
            "codex",
            """#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$FAKE_CODEX_LOG"
[ "$*" = "login status" ] || exit 1
printf '%s\\n' 'Logged in using ChatGPT'
""",
        )
        self.brain = self._executable(
            "brain",
            """#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$FAKE_BRAIN_LOG"
case "$1:$2" in
  status:--json)
    printf '%s\\n' '{"schema_version":1,"services":[{"id":"telegram","configured":true,"running":true}]}'
    ;;
  doctor:--json)
    printf '%s\\n' '{"schema_version":1,"overall":"healthy","checks":[]}'
    ;;
  gmail:status)
    [ -z "$FAKE_GMAIL_FAIL" ] || exit 1
    [ "$3" = "--check-api" ] || exit 1
    printf '%s\\n' configured
    ;;
  *) exit 1 ;;
esac
""",
        )

    def _start_http_server(self) -> None:
        test = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, _format: str, *_args: object) -> None:
                return

            def _record(self, body: bytes = b"") -> None:
                test.user_agents.append(self.headers.get("User-Agent", ""))
                test.requests.append(
                    (
                        self.command,
                        self.path,
                        self.headers.get("Authorization", ""),
                        body,
                    )
                )

            def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                self._record(body)
                if self.path != "/v1/agent/heartbeat":
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"ok":true}')

            def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                self._record()
                if self.path != "/client/v4/accounts/account-test/queues/queue-test":
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                response = {"success": test.queue_success, "result": {"queue_id": "queue-test"}}
                self.wfile.write(json.dumps(response).encode("utf-8"))

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.gateway_url = "http://127.0.0.1:{}".format(self.server.server_port)

    def environment(self, **extra: str) -> Dict[str, str]:
        environment = dict(os.environ)
        environment.update(
            {
                "HOME": str(self.home),
                "USER": "brain-agent-test",
                "LAUNCH_AGENTS_DIR": str(self.launch_agents),
                "BRAIN_AGENT_HOME": str(self.home),
                "BRAIN_AGENT_UID": str(os.getuid()),
                "BRAIN_AGENT_CONFIG_DIR": str(self.config_dir),
                "BRAIN_AGENT_STATE_DIR": str(self.state_dir),
                "BRAIN_AGENT_LOG_DIR": str(self.log_dir),
                "BRAIN_AGENT_PYTHON3": sys.executable,
                "BRAIN_AGENT_LAUNCHCTL": str(self.launchctl),
                "BRAIN_AGENT_SECURITY": str(self.security),
                "BRAIN_AGENT_CLOUDFLARED": str(self.cloudflared),
                "BRAIN_AGENT_CODEX": str(self.codex),
                "BRAIN_AGENT_CLOUDFLARE_API_BASE": self.gateway_url + "/client/v4",
                "BRAIN_AGENT_HTTP_TIMEOUT": "2",
                "FAKE_SECURITY_LOG": str(self.logs / "security.log"),
                "FAKE_LAUNCHCTL_LOG": str(self.logs / "launchctl.log"),
                "FAKE_CLOUDFLARED_LOG": str(self.logs / "cloudflared.log"),
                "FAKE_CODEX_LOG": str(self.logs / "codex.log"),
                "FAKE_BRAIN_LOG": str(self.logs / "brain.log"),
                "FAKE_BOOTSTRAP_MARKER": str(self.logs / "bootstrap-failed-once"),
                "FAKE_GMAIL_FAIL": "",
            }
        )
        environment.update(extra)
        return environment

    def arguments(self, extra: Sequence[str] = ()) -> List[str]:
        return [
            str(self.installer),
            "--instance-id",
            "mini-test",
            "--gateway-url",
            self.gateway_url,
            "--site-url",
            "https://private.example.test",
            "--code-root",
            str(self.app_dir),
            "--data-root",
            str(self.data),
            "--source-data-root",
            str(self.vault),
            "--tunnel-hostname",
            "brain-origin.example.test",
            "--account-id",
            "account-test",
            "--queue-id",
            "queue-test",
            "--brain-cli",
            str(self.brain),
            *extra,
        ]

    def install(
        self,
        *,
        extra_args: Sequence[str] = (),
        extra_environment: Optional[Dict[str, str]] = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = self.environment(**(extra_environment or {}))
        return subprocess.run(
            self.arguments(extra_args),
            cwd=APP_DIR.parent.parent,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    @staticmethod
    def mode(path: Path) -> int:
        return stat.S_IMODE(path.stat().st_mode)

    def test_installs_private_idempotent_service_and_loopback_tunnel(self) -> None:
        first = self.install()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        for message in (
            "PASS cloudflared loopback route",
            "PASS launchctl state",
            "PASS site publisher launchctl state",
            "PASS Codex ChatGPT login",
            "PASS Telegram remote service state",
            "PASS Gmail optional connection",
            "PASS gateway heartbeat",
            "PASS queue access",
        ):
            self.assertIn(message, first.stdout)

        config_path = self.config_dir / "agent.json"
        env_path = self.config_dir / "agent.env"
        tunnel_path = self.config_dir / "cloudflared.yml"
        plist_path = self.launch_agents / "app.voxbrain.agent.plist"
        publisher_env_path = self.config_dir / "site-publisher.env"
        publisher_plist_path = self.launch_agents / "app.voxbrain.site-publisher.plist"
        for private_file in (
            config_path,
            env_path,
            publisher_env_path,
            tunnel_path,
            plist_path,
            publisher_plist_path,
        ):
            self.assertEqual(self.mode(private_file), 0o600, private_file)
        for private_dir in (self.config_dir, self.state_dir, self.log_dir):
            self.assertEqual(self.mode(private_dir), 0o700, private_dir)

        config = json.loads(config_path.read_text(encoding="utf-8"))
        self.assertEqual(
            config,
            {
                "instance_id": "mini-test",
                "gateway_url": self.gateway_url,
                "site_url": "https://private.example.test",
                "account_id": "account-test",
                "queue_id": "queue-test",
                "code_root": str(self.app_dir),
                "data_root": str(self.data),
                "brain_cli_path": str(self.brain),
                "api_port": 8765,
                "state_dir": str(self.state_dir),
            },
        )
        env_text = env_path.read_text(encoding="utf-8")
        self.assertIn("BRAIN_AGENT_TOKEN=agent-secret", env_text)
        self.assertIn("BRAIN_ORIGIN_TOKEN=origin-secret", env_text)
        self.assertIn("BRAIN_QUEUE_API_TOKEN=queue-secret", env_text)
        self.assertNotIn("pages-secret", env_text)
        publisher_environment = publisher_env_path.read_text(encoding="utf-8")
        self.assertIn("BRAIN_AGENT_TOKEN=agent-secret", publisher_environment)
        self.assertIn("CLOUDFLARE_API_TOKEN=pages-secret", publisher_environment)
        self.assertNotIn("origin-secret", publisher_environment)
        self.assertNotIn("queue-secret", publisher_environment)

        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
        self.assertEqual(plist["Label"], "app.voxbrain.agent")
        self.assertIs(plist["KeepAlive"], True)
        self.assertIs(plist["RunAtLoad"], True)
        arguments = plist["ProgramArguments"]
        self.assertEqual(arguments[0:2], ["/bin/sh", "-c"])
        self.assertIn('. "$1"', arguments[2])
        self.assertEqual(arguments[4], str(env_path))
        self.assertEqual(arguments[5], sys.executable)
        self.assertEqual(arguments[6], str(self.app_dir / "service.py"))
        self.assertEqual(arguments[7], str(config_path))
        expected_path = "{}:{}".format(
            self.home / ".local/bin",
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        )
        self.assertEqual(plist["EnvironmentVariables"]["PATH"], expected_path)
        self.assertEqual(plist["StandardOutPath"], str(self.log_dir / "agent.stdout.log"))
        self.assertEqual(plist["StandardErrorPath"], str(self.log_dir / "agent.stderr.log"))
        self.assertEqual(plist["EnvironmentVariables"]["BRAIN_DATA_ROOT"], str(self.data))
        self.assertEqual(plist["EnvironmentVariables"]["BRAIN_SOURCE_ROOT"], str(self.app_dir))

        with publisher_plist_path.open("rb") as handle:
            publisher_plist = plistlib.load(handle)
        self.assertEqual(publisher_plist["Label"], "app.voxbrain.site-publisher")
        self.assertEqual(
            publisher_plist["WatchPaths"],
            [str(self.data / "system" / "site-publish-ready.json")],
        )
        self.assertEqual(publisher_plist["StartInterval"], 900)
        self.assertNotIn("KeepAlive", publisher_plist)
        publisher_arguments = publisher_plist["ProgramArguments"]
        self.assertIn(str(self.app_dir / "site_publisher.py"), publisher_arguments)
        self.assertIn(str(config_path), publisher_arguments)
        self.assertIn(str(publisher_env_path), publisher_arguments)

        rendered_public = (
            config_path.read_text(encoding="utf-8")
            + plist_path.read_text(encoding="utf-8")
            + publisher_plist_path.read_text(encoding="utf-8")
        )
        for secret in ("agent-secret", "origin-secret", "queue-secret", "pages-secret"):
            self.assertNotIn(secret, rendered_public)
        self.assertNotIn("/Users/example", rendered_public)
        self.assertNotIn("~/dev/brain", rendered_public)

        tunnel = tunnel_path.read_text(encoding="utf-8")
        self.assertIn("hostname: brain-origin.example.test", tunnel)
        self.assertIn("service: http://127.0.0.1:8765", tunnel)
        self.assertIn("service: http_status:404", tunnel)
        self.assertNotIn("0.0.0.0", tunnel)
        self.assertIn("outbound-only", tunnel)
        self.assertIn("do not", tunnel)
        self.assertIn("port-forward", tunnel)
        self.assertEqual(
            (self.data / "inbox" / "canonical.md").read_text(encoding="utf-8"),
            "canonical remote vault\n",
        )
        self.assertTrue((self.data / ".brain-data-root").is_file())
        manifest = json.loads(
            (self.state_dir / "data-migration-manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["data_root"], str(self.data.resolve()))

        heartbeat = next(body for method, path, _auth, body in self.requests if method == "POST")
        payload = json.loads(heartbeat)
        self.assertEqual(payload["instance_id"], "mini-test")
        self.assertEqual(payload["agent_version"], "1")
        auth_by_path = {path: auth for _method, path, auth, _body in self.requests}
        self.assertEqual(auth_by_path["/v1/agent/heartbeat"], "Bearer agent-secret")
        self.assertEqual(
            auth_by_path["/client/v4/accounts/account-test/queues/queue-test"],
            "Bearer queue-secret",
        )
        self.assertTrue(self.user_agents)
        self.assertTrue(all(value == "Brain-Agent/1" for value in self.user_agents))

        second = self.install(extra_args=("--api-port", "9876"))
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        updated_config = json.loads(config_path.read_text(encoding="utf-8"))
        self.assertEqual(updated_config["api_port"], 9876)
        self.assertIn("http://127.0.0.1:9876", tunnel_path.read_text(encoding="utf-8"))
        self.assertEqual(
            [path.name for path in self.launch_agents.glob("app.voxbrain.agent*.plist")],
            ["app.voxbrain.agent.plist"],
        )
        self.assertTrue(publisher_plist_path.is_file())
        launchctl_calls = (self.logs / "launchctl.log").read_text(encoding="utf-8").splitlines()
        self.assertEqual(sum(line.startswith("bootstrap ") for line in launchctl_calls), 4)
        self.assertEqual(sum(line.startswith("bootout ") for line in launchctl_calls), 4)
        self.assertEqual(sum(line.startswith("print ") for line in launchctl_calls), 4)
        self.assertFalse(any("app.voxbrain.telegram" in line for line in launchctl_calls))
        brain_calls = (self.logs / "brain.log").read_text(encoding="utf-8").splitlines()
        self.assertEqual(brain_calls.count("status --json"), 2)
        self.assertEqual(brain_calls.count("doctor --json"), 2)
        self.assertEqual(brain_calls.count("gmail status --check-api"), 2)
        self.assertFalse(any("automate" in line or "telegram" in line for line in brain_calls))
        security_calls = (self.logs / "security.log").read_text(encoding="utf-8")
        for service in (
            "app.voxbrain.agent-token",
            "app.voxbrain.origin-token",
            "app.voxbrain.queue-api-token",
            "app.voxbrain.pages-api-token",
        ):
            self.assertEqual(security_calls.count(service), 2)
        cloudflared_calls = (self.logs / "cloudflared.log").read_text(encoding="utf-8")
        self.assertEqual(cloudflared_calls.count("ingress validate"), 2)
        self.assertEqual(cloudflared_calls.count("ingress rule"), 2)
        self.assertEqual(self.vault_marker.read_text(encoding="utf-8"), "canonical remote vault\n")

    def test_rollback_restores_previous_runtime_without_touching_data(self) -> None:
        self.launch_agents.mkdir(parents=True)
        self.config_dir.mkdir(parents=True)
        previous = {
            self.config_dir / "agent.json": b"previous config\n",
            self.config_dir / "agent.env": b"previous environment\n",
            self.launch_agents / "app.voxbrain.agent.plist": b"previous plist\n",
        }
        for path, content in previous.items():
            path.write_bytes(content)
            path.chmod(0o600)

        installed = self.install()
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        source_before = self.vault_marker.read_bytes()
        data_before = (self.data / "inbox" / "canonical.md").read_bytes()
        rolled_back = subprocess.run(
            [str(self.installer), "rollback"],
            cwd=APP_DIR.parent.parent,
            env=self.environment(),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(rolled_back.returncode, 0, rolled_back.stdout + rolled_back.stderr)
        for path, content in previous.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertEqual(self.vault_marker.read_bytes(), source_before)
        self.assertEqual((self.data / "inbox" / "canonical.md").read_bytes(), data_before)

    def test_failed_migration_never_replaces_existing_runtime_config(self) -> None:
        self.config_dir.mkdir(parents=True)
        config = self.config_dir / "agent.json"
        config.write_bytes(b"previous production config\n")
        config.chmod(0o600)
        (self.vault / "notes").mkdir()
        (self.vault / "notes" / "unsafe.md").symlink_to(self.vault_marker)

        result = self.install()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlinks are not allowed", result.stderr)
        self.assertEqual(config.read_bytes(), b"previous production config\n")
        self.assertFalse((self.config_dir / "agent.env").exists())
        self.assertFalse((self.launch_agents / "app.voxbrain.agent.plist").exists())

    def test_retries_a_transient_launchctl_bootstrap_failure(self) -> None:
        result = self.install(extra_environment={"FAKE_BOOTSTRAP_FAIL_ONCE": "1"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.logs / "launchctl.log").read_text(encoding="utf-8").splitlines()
        self.assertEqual(sum(line.startswith("bootout ") for line in calls), 2)
        self.assertEqual(sum(line.startswith("bootstrap ") for line in calls), 3)

    def test_optional_gmail_failure_does_not_hide_core_results(self) -> None:
        result = self.install(extra_environment={"FAKE_GMAIL_FAIL": "1"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("WARN Gmail optional connection unavailable", result.stdout)
        self.assertIn("PASS gateway heartbeat", result.stdout)
        self.assertIn("PASS queue access", result.stdout)
        self.assertIn("PASS Telegram remote service state", result.stdout)

    def test_failed_queue_check_remains_fatal_when_gmail_is_unavailable(self) -> None:
        self.queue_success = False
        result = self.install(extra_environment={"FAKE_GMAIL_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn("WARN Gmail optional connection unavailable", combined)
        self.assertIn("PASS gateway heartbeat", combined)
        self.assertIn("FAIL queue access", combined)
        self.assertIn("required Brain Agent verification group", combined)

    def test_rejects_missing_or_invalid_explicit_deployment_values(self) -> None:
        arguments = self.arguments()
        hostname_at = arguments.index("--tunnel-hostname")
        missing_hostname = arguments[:hostname_at] + arguments[hostname_at + 2 :]
        missing = subprocess.run(
            missing_hostname,
            cwd=APP_DIR.parent.parent,
            env=self.environment(),
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("--tunnel-hostname is required", missing.stderr)
        self.assertFalse(self.launch_agents.exists())

        invalid = self.install(extra_args=("--gateway-url", "http://gateway.example.test"))
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("gateway URL must use HTTPS", invalid.stderr)
        self.assertFalse(self.launch_agents.exists())

        unsafe_site = self.install(
            extra_args=("--site-url", "https://user:secret@private.example.test?token=secret")
        )
        self.assertNotEqual(unsafe_site.returncode, 0)
        self.assertIn("site URL is invalid", unsafe_site.stderr)
        self.assertFalse(self.launch_agents.exists())

    def test_missing_keychain_credential_fails_before_writing_service(self) -> None:
        broken_security = self._executable(
            "security-missing",
            """#!/bin/sh
case "$*" in
  *app.voxbrain.agent-token*) printf '%s\\n' agent-secret ;;
  *app.voxbrain.origin-token*) printf '%s\\n' origin-secret ;;
  *) exit 1 ;;
esac
""",
        )
        result = self.install(
            extra_environment={"BRAIN_AGENT_SECURITY": str(broken_security)}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("app.voxbrain.queue-api-token is missing", result.stderr)
        self.assertFalse(self.launch_agents.exists())


if __name__ == "__main__":
    unittest.main()
