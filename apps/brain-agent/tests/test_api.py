#!/usr/bin/env python3
"""Regression tests for the loopback Brain read API."""

from __future__ import annotations

import concurrent.futures
import importlib.util
import json
import os
import stat
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional, Tuple


API_PATH = Path(__file__).resolve().parents[1] / "api.py"
SPEC = importlib.util.spec_from_file_location("brain_agent_api", API_PATH)
assert SPEC is not None and SPEC.loader is not None
api = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = api
SPEC.loader.exec_module(api)


class BrainReadAPITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.vault = self.root / "vault"
        for name in api.ALLOWED_KNOWLEDGE_ROOTS:
            (self.vault / name).mkdir(parents=True)
        (self.vault / "apps").mkdir()

        self._write("notes/Alpha.md", "# Alpha\nA public needle appears here.\n")
        self._write("me/Private.md", "# Private knowledge\nprivate needle for the owner\n")
        self._write("maps/Zeta.md", "# Zeta\nAnother needle result.\n")
        self._write("sources/Article.md", "# Saved article\nsource-only phrase\n")
        self._write("apps/Leak.md", "# Machinery\nprivate needle must not escape\n")
        self._write("notes/Plain.txt", "needle in a non-Markdown file\n")
        self._write("notes/.Hidden.md", "needle in a hidden file\n")
        (self.vault / "notes" / ".hidden").mkdir()
        self._write("notes/.hidden/Secret.md", "needle in a hidden directory\n")

        self.cli = self.root / "fake-brain"
        self.cli.write_text(
            """#!/usr/bin/env python3
import json
import os
import pathlib
import sys

pathlib.Path(__file__).with_suffix('.log').open('a', encoding='utf-8').write(
    json.dumps(sys.argv[1:]) + '\\n'
)
pathlib.Path(__file__).with_suffix('.environment').open('a', encoding='utf-8').write(
    json.dumps({
        'data': os.environ.get('BRAIN_DATA_ROOT'),
        'telegram': os.environ.get('BRAIN_TELEGRAM_STATE_DIR'),
        'gateway': os.environ.get('BRAIN_GATEWAY_URL'),
        'publisher': os.environ.get('BRAIN_SITE_PUBLISHER_STATUS_FILE'),
    }) + '\\n'
)
if sys.argv[1:] == ['status', '--json']:
    print(json.dumps({'schema_version': 1, 'inbox': 2, 'kind': 'status'}))
    raise SystemExit(0)
if sys.argv[1:] == ['doctor', '--json']:
    print(json.dumps({'schema_version': 1, 'overall': 'failure', 'kind': 'health'}))
    raise SystemExit(7)
print('not json; private filesystem detail', file=sys.stderr)
raise SystemExit(9)
""",
            encoding="utf-8",
        )
        self.cli.chmod(self.cli.stat().st_mode | stat.S_IXUSR)

        self.token = "origin-token-that-must-never-leak"
        self.server = api.create_server(
            vault_path=str(self.vault),
            cli_path=str(self.cli),
            origin_token=self.token,
            site_url="https://private-site.example.test",
            port=0,
            command_timeout=5,
            gateway_url="https://gateway.example.test",
            publisher_status_path=str(self.root / "publisher-status.json"),
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        host, port = self.server.server_address[:2]
        self.base_url = "http://{}:{}".format(host, port)

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.temporary_directory.cleanup()

    def _write(self, relative: str, content: str) -> None:
        destination = self.vault / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content, encoding="utf-8")

    def _request(
        self,
        route: str,
        *,
        token: Optional[str] = None,
        include_token: bool = True,
        method: str = "GET",
        data: Optional[bytes] = None,
    ) -> Tuple[int, Dict[str, Any], bytes]:
        headers = {}
        if include_token:
            headers["X-Brain-Origin-Token"] = self.token if token is None else token
        request = urllib.request.Request(
            self.base_url + route,
            headers=headers,
            method=method,
            data=data,
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                raw = response.read()
                return response.status, json.loads(raw), raw
        except urllib.error.HTTPError as error:
            try:
                raw = error.read()
                return error.code, json.loads(raw), raw
            finally:
                error.close()

    def _route(self, endpoint: str, **query: str) -> str:
        return endpoint + "?" + urllib.parse.urlencode(query)

    def test_server_is_loopback_only_and_every_route_requires_exact_auth(self) -> None:
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        routes = (
            "/v1/status",
            "/v1/health",
            self._route("/v1/knowledge/documents", limit="2"),
            self._route("/v1/knowledge/search", q="needle", limit="2"),
            self._route("/v1/knowledge/document", path="notes/Alpha.md"),
            "/v1/not-a-route",
        )
        for route in routes:
            with self.subTest(route=route, credential="missing"):
                status, payload, _ = self._request(route, include_token=False)
                self.assertEqual(status, 401)
                self.assertEqual(payload["error"]["code"], "unauthorized")
            with self.subTest(route=route, credential="wrong"):
                status, payload, _ = self._request(route, token=self.token + " ")
                self.assertEqual(status, 401)
                self.assertEqual(payload["error"]["code"], "unauthorized")

    def test_status_and_failing_health_execute_fixed_cli_argv(self) -> None:
        status, status_payload, _ = self._request("/v1/status")
        health_status, health_payload, _ = self._request("/v1/health")

        self.assertEqual(status, 200)
        self.assertEqual(status_payload["kind"], "status")
        self.assertEqual(status_payload["site_url"], "https://private-site.example.test")
        self.assertEqual(health_status, 200)
        self.assertEqual(health_payload["overall"], "failure")
        invocations = [
            json.loads(line)
            for line in self.cli.with_suffix(".log").read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(invocations, [["status", "--json"], ["doctor", "--json"]])
        environments = [
            json.loads(line)
            for line in self.cli.with_suffix(".environment").read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(
            environments,
            [
                {
                    "data": str(self.vault.resolve()),
                    "telegram": str(self.vault.resolve().parent),
                    "gateway": "https://gateway.example.test",
                    "publisher": str(self.root / "publisher-status.json"),
                }
            ] * 2,
        )

        status, payload, raw = self._request("/v1/status?argv=process")
        self.assertEqual(status, 400)
        self.assertNotIn(self.token.encode(), raw)
        self.assertNotIn(str(self.vault).encode(), raw)
        self.assertEqual(payload["error"]["code"], "invalid_query")

    def test_site_url_is_authenticated_and_rejects_unsafe_configuration(self) -> None:
        missing_status, missing_payload, missing_raw = self._request(
            "/v1/status", include_token=False
        )
        self.assertEqual(missing_status, 401)
        self.assertNotIn(b"private-site.example.test", missing_raw)
        self.assertNotIn("site_url", missing_payload)

        status, payload, _ = self._request("/v1/status")
        self.assertEqual(status, 200)
        self.assertEqual(payload["site_url"], "https://private-site.example.test")

        for invalid in (
            "http://private-site.example.test",
            "https://user:secret@private-site.example.test",
            "https://private-site.example.test?token=secret",
            "https://private-site.example.test#fragment",
            "https://private-site.example.test\\@attacker.test",
            "https://private-site.example.test:99999",
            "x" * (api.MAX_SITE_URL_CHARS + 1),
        ):
            with self.subTest(site_url=invalid[:80]):
                with self.assertRaises(ValueError):
                    api.BrainAPIConfig.build(
                        vault_path=str(self.vault),
                        cli_path=str(self.cli),
                        origin_token=self.token,
                        site_url=invalid,
                        port=0,
                    )

        for invalid in (
            "http://gateway.example.test",
            "https://gateway.example.test/path",
            "https://user:secret@gateway.example.test",
        ):
            with self.subTest(gateway_url=invalid):
                with self.assertRaises(ValueError):
                    api.BrainAPIConfig.build(
                        vault_path=str(self.vault),
                        cli_path=str(self.cli),
                        origin_token=self.token,
                        site_url="https://private-site.example.test",
                        port=0,
                        gateway_url=invalid,
                    )

        with self.assertRaises(ValueError):
            api.BrainAPIConfig.build(
                vault_path=str(self.vault),
                cli_path=str(self.cli),
                origin_token=self.token,
                site_url="https://private-site.example.test",
                port=0,
                publisher_status_path="relative/status.json",
            )

    def test_search_includes_private_roots_only_and_is_deterministic_and_bounded(self) -> None:
        route = self._route("/v1/knowledge/search", q="needle", limit="10")
        status, payload, raw = self._request(route)

        self.assertEqual(status, 200)
        paths = [result["path"] for result in payload["results"]]
        self.assertEqual(paths, ["maps/Zeta.md", "me/Private.md", "notes/Alpha.md"])
        self.assertIn("me/Private.md", paths)
        self.assertNotIn("apps/Leak.md", paths)
        self.assertTrue(all(len(item["snippet"]) <= api.MAX_SNIPPET_CHARS for item in payload["results"]))
        self.assertLessEqual(len(raw), api.MAX_RESPONSE_BYTES)

        repeated_status, repeated, _ = self._request(route)
        self.assertEqual(repeated_status, 200)
        self.assertEqual(repeated, payload)

    def test_document_listing_is_deterministic_bounded_and_excludes_unsafe_files(self) -> None:
        status, payload, raw = self._request(
            self._route("/v1/knowledge/documents", limit="4")
        )

        self.assertEqual(status, 200)
        self.assertEqual(
            payload["documents"],
            [
                {"path": "maps/Zeta.md", "title": "Zeta"},
                {"path": "me/Private.md", "title": "Private knowledge"},
                {"path": "notes/Alpha.md", "title": "Alpha"},
                {"path": "sources/Article.md", "title": "Saved article"},
            ],
        )
        rendered = json.dumps(payload)
        self.assertNotIn("apps/Leak.md", rendered)
        self.assertNotIn("notes/.Hidden.md", rendered)
        self.assertLessEqual(len(raw), api.MAX_RESPONSE_BYTES)

        for limit in ("0", str(api.MAX_SEARCH_LIMIT + 1), "many"):
            with self.subTest(limit=limit):
                rejected, error, _ = self._request(
                    self._route("/v1/knowledge/documents", limit=limit)
                )
                self.assertEqual(rejected, 400)
                self.assertEqual(error["error"]["code"], "invalid_limit")

    def test_search_validates_query_and_limit(self) -> None:
        cases = (
            (self._route("/v1/knowledge/search", q=""), "invalid_query"),
            (
                self._route("/v1/knowledge/search", q="x" * (api.MAX_QUERY_CHARS + 1)),
                "invalid_query",
            ),
            (self._route("/v1/knowledge/search", q="needle", limit="0"), "invalid_limit"),
            (
                self._route(
                    "/v1/knowledge/search", q="needle", limit=str(api.MAX_SEARCH_LIMIT + 1)
                ),
                "invalid_limit",
            ),
        )
        for route, error_code in cases:
            with self.subTest(route=route[:80]):
                status, payload, _ = self._request(route)
                self.assertEqual(status, 400)
                self.assertEqual(payload["error"]["code"], error_code)

    def test_document_reads_allowed_markdown_and_rejects_unsafe_paths(self) -> None:
        status, payload, _ = self._request(
            self._route("/v1/knowledge/document", path="me/Private.md")
        )
        self.assertEqual(status, 200)
        self.assertEqual(payload["path"], "me/Private.md")
        self.assertEqual(payload["title"], "Private knowledge")
        self.assertIn("private needle", payload["content"])

        outside = self.root / "outside.md"
        outside.write_text("outside secret", encoding="utf-8")
        symlink = self.vault / "notes" / "Linked.md"
        symlink.symlink_to(outside)
        linked_directory = self.vault / "notes" / "linked-directory"
        linked_directory.symlink_to(self.root, target_is_directory=True)

        rejected = (
            "../outside.md",
            str(outside),
            "notes/../me/Private.md",
            "apps/Leak.md",
            "notes/Plain.txt",
            "notes/.Hidden.md",
            "notes/.hidden/Secret.md",
            "notes/Linked.md",
            "notes/linked-directory/outside.md",
            "notes\\Alpha.md",
        )
        for path in rejected:
            with self.subTest(path=path):
                status, payload, raw = self._request(
                    self._route("/v1/knowledge/document", path=path)
                )
                self.assertIn(status, (400, 404))
                self.assertIn("error", payload)
                self.assertNotIn(b"outside secret", raw)
                self.assertNotIn(self.token.encode(), raw)

    def test_response_limits_reject_large_documents_and_bound_search(self) -> None:
        self._write("notes/Huge.md", "# Huge\n" + "x" * (api.MAX_DOCUMENT_BYTES + 1))
        status, payload, raw = self._request(
            self._route("/v1/knowledge/document", path="notes/Huge.md")
        )
        self.assertEqual(status, 413)
        self.assertEqual(payload["error"]["code"], "document_too_large")
        self.assertLessEqual(len(raw), api.MAX_RESPONSE_BYTES)

        for number in range(api.MAX_SEARCH_LIMIT + 5):
            self._write(
                "daily/Result-{:03d}.md".format(number),
                "# Result {}\n{} bounded-needle {}\n".format(
                    number, "prefix " * 100, "suffix " * 100
                ),
            )
        status, payload, raw = self._request(
            self._route(
                "/v1/knowledge/search",
                q="bounded-needle",
                limit=str(api.MAX_SEARCH_LIMIT),
            )
        )
        self.assertEqual(status, 200)
        self.assertEqual(len(payload["results"]), api.MAX_SEARCH_LIMIT)
        self.assertLessEqual(len(raw), api.MAX_RESPONSE_BYTES)

    def test_route_table_is_closed_and_concurrent_reads_do_not_mutate_vault(self) -> None:
        initial = {
            path.relative_to(self.vault).as_posix(): path.read_bytes()
            for path in self.vault.rglob("*")
            if path.is_file() and not path.is_symlink()
        }
        routes = [
            self._route("/v1/knowledge/documents", limit="3"),
            self._route("/v1/knowledge/search", q="needle", limit="3"),
            self._route("/v1/knowledge/document", path="notes/Alpha.md"),
        ] * 8
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            responses = list(executor.map(lambda route: self._request(route), routes))
        self.assertTrue(all(status == 200 for status, _, _ in responses))
        after = {
            path.relative_to(self.vault).as_posix(): path.read_bytes()
            for path in self.vault.rglob("*")
            if path.is_file() and not path.is_symlink()
        }
        self.assertEqual(after, initial)

        for method in ("POST", "PUT", "DELETE", "BREW"):
            with self.subTest(method=method):
                status, payload, _ = self._request(
                    "/v1/status", method=method, data=b'{"argv":["process"]}'
                )
                self.assertEqual(status, 405)
                self.assertEqual(payload["error"]["code"], "method_not_allowed")
        status, payload, _ = self._request("/v1/commands")
        self.assertEqual(status, 404)
        self.assertEqual(payload["error"]["code"], "not_found")


if __name__ == "__main__":
    unittest.main()
