import importlib.util
import json
import os
import tempfile
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock


APP_DIR = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("brain_gmail", APP_DIR / "gmail.py")
gmail = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(gmail)


def encoded(value):
    import base64
    return base64.urlsafe_b64encode(value.encode()).decode().rstrip("=")


class GmailTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"BRAIN_STATE_DIR": self.temp.name})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def write_client(self):
        client = {
            "installed": {
                "client_id": "local-client-id",
                "client_secret": "local-client-secret",
                "auth_uri": "https://accounts.google.test/authorize",
                "token_uri": "https://accounts.google.test/token",
            }
        }
        gmail.write_private_json(gmail.client_path(), client)
        return client

    def test_private_json_is_owner_only(self):
        path = Path(self.temp.name) / "secret.json"
        gmail.write_private_json(path, {"refresh_token": "secret"})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_message_parser_prefers_plain_text_and_keeps_provenance(self):
        message = {
            "id": "m1",
            "threadId": "t1",
            "internalDate": "1720000000000",
            "labelIds": ["INBOX"],
            "payload": {
                "headers": [
                    {"name": "Subject", "value": "Project price"},
                    {"name": "From", "value": "Alex <alex@example.com>"},
                    {"name": "Date", "value": "Wed, 03 Jul 2024 12:00:00 +0000"},
                ],
                "mimeType": "multipart/alternative",
                "parts": [
                    {"mimeType": "text/plain", "body": {"data": encoded("The price is £4,000.")}},
                    {"mimeType": "text/html", "body": {"data": encoded("<p>Wrong duplicate</p>")}},
                ],
            },
        }
        record = gmail.message_record(message)
        self.assertEqual(record["subject"], "Project price")
        self.assertIn("£4,000", record["body"])
        self.assertNotIn("Wrong duplicate", record["body"])
        self.assertEqual(record["gmail_url"], "https://mail.google.com/mail/u/0/#all/t1")

    def test_search_is_read_only_and_fetches_full_messages(self):
        listed = {"resultSizeEstimate": 1, "messages": [{"id": "m1", "threadId": "t1"}]}
        full = {"id": "m1", "threadId": "t1", "payload": {"headers": [], "body": {"data": encoded("Body")}}}
        with mock.patch.object(gmail, "gmail_get", side_effect=[listed, full]) as get:
            result = gmail.search("from:alex", 5)
        self.assertEqual(result["returned"], 1)
        self.assertIn("transient", result["notice"])
        self.assertEqual(get.call_args_list[0].args[0], "/messages")
        self.assertEqual(get.call_args_list[1].args[1], {"format": "full"})

    def test_mcp_lists_only_read_tools(self):
        response = gmail.mcp_response({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        names = [tool["name"] for tool in response["result"]["tools"]]
        self.assertEqual(names, ["gmail_search", "gmail_get_thread"])

    def test_mcp_tool_errors_are_returned_without_crashing_server(self):
        with mock.patch.object(gmail, "search", side_effect=RuntimeError("expired")):
            response = gmail.mcp_response(
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "gmail_search", "arguments": {"query": "x"}}}
            )
        self.assertTrue(response["result"]["isError"])
        self.assertIn("expired", response["result"]["content"][0]["text"])

    def test_disconnect_revokes_best_effort_and_removes_local_authorization(self):
        gmail.write_private_json(gmail.client_path(), {"installed": {}})
        gmail.write_private_json(gmail.token_path(), {"refresh_token": "secret-refresh"})
        with mock.patch.object(gmail.urllib.request, "urlopen") as revoke:
            message = gmail.disconnect()
        self.assertIn("disconnected", message.lower())
        self.assertFalse(gmail.client_path().exists())
        self.assertFalse(gmail.token_path().exists())
        request = revoke.call_args.args[0]
        self.assertEqual(request.full_url, "https://oauth2.googleapis.com/revoke")
        self.assertIn(b"secret-refresh", request.data)

    def test_remote_pkce_lifecycle_is_single_use_and_owner_only(self):
        self.write_client()
        redirect_uri = "https://brain.example/v1/gmail/callback"
        started = gmail.authorize_start(redirect_uri, now=1_000)
        self.assertEqual(set(started), {"authorization_url", "state", "expires_at"})
        self.assertEqual(started["expires_at"], 1_000 + gmail.OAUTH_PENDING_SECONDS)
        padded_state = started["state"] + "=" * (-len(started["state"]) % 4)
        self.assertEqual(len(gmail.base64.urlsafe_b64decode(padded_state)), 32)

        query = urllib.parse.parse_qs(urllib.parse.urlsplit(started["authorization_url"]).query)
        self.assertEqual(query["scope"], [gmail.SCOPE])
        self.assertEqual(query["redirect_uri"], [redirect_uri])
        self.assertEqual(query["state"], [started["state"]])
        self.assertEqual(query["code_challenge_method"], ["S256"])
        pending = json.loads(gmail.pending_oauth_path().read_text(encoding="utf-8"))
        self.assertEqual(gmail.pending_oauth_path().stat().st_mode & 0o777, 0o600)
        self.assertNotIn("client_secret", pending)
        self.assertNotIn("code", pending)

        token_response = {
            "access_token": "new-access",
            "refresh_token": "new-refresh",
            "expires_in": 3600,
            "scope": gmail.SCOPE,
        }
        with mock.patch.object(gmail, "form_post", return_value=token_response) as exchange:
            completed = gmail.authorize_complete(
                redirect_uri,
                started["state"],
                code="one-time-code",
                now=1_001,
            )
        self.assertEqual(completed, {"status": "connected", "scope": gmail.SCOPE})
        request = exchange.call_args.args[1]
        self.assertEqual(request["code"], "one-time-code")
        self.assertEqual(request["code_verifier"], pending["code_verifier"])
        self.assertFalse(gmail.pending_oauth_path().exists())
        self.assertEqual(gmail.token_path().stat().st_mode & 0o777, 0o600)
        stored = json.loads(gmail.token_path().read_text(encoding="utf-8"))
        self.assertEqual(stored["refresh_token"], "new-refresh")
        self.assertEqual(stored["scope"], gmail.SCOPE)

        with mock.patch.object(gmail, "form_post") as replay_exchange:
            with self.assertRaisesRegex(RuntimeError, "already been used"):
                gmail.authorize_complete(redirect_uri, started["state"], code="replayed", now=1_002)
        replay_exchange.assert_not_called()
        self.assertEqual(json.loads(gmail.token_path().read_text())["refresh_token"], "new-refresh")

    def test_remote_failures_preserve_a_valid_connection(self):
        self.write_client()
        gmail.write_private_json(
            gmail.token_path(),
            {"access_token": "old-access", "refresh_token": "old-refresh", "scope": gmail.SCOPE},
        )
        redirect_uri = "https://brain.example/v1/gmail/callback"
        started = gmail.authorize_start(redirect_uri, now=2_000)

        with self.assertRaisesRegex(RuntimeError, "state did not match"):
            gmail.authorize_complete(redirect_uri, "wrong-state", code="code", now=2_001)
        self.assertTrue(gmail.pending_oauth_path().exists())
        self.assertEqual(json.loads(gmail.token_path().read_text())["refresh_token"], "old-refresh")

        with mock.patch.object(gmail, "form_post", side_effect=RuntimeError("provider reflected code")):
            with self.assertRaisesRegex(RuntimeError, "token exchange failed") as caught:
                gmail.authorize_complete(redirect_uri, started["state"], code="secret-code", now=2_002)
        self.assertNotIn("secret-code", str(caught.exception))
        self.assertFalse(gmail.pending_oauth_path().exists())
        self.assertEqual(json.loads(gmail.token_path().read_text())["refresh_token"], "old-refresh")

        expired = gmail.authorize_start(redirect_uri, now=3_000)
        with self.assertRaisesRegex(RuntimeError, "expired"):
            gmail.authorize_complete(redirect_uri, expired["state"], code="code", now=4_000)
        self.assertFalse(gmail.pending_oauth_path().exists())
        self.assertEqual(json.loads(gmail.token_path().read_text())["refresh_token"], "old-refresh")

        denied = gmail.authorize_start(redirect_uri, now=5_000)
        with self.assertRaisesRegex(RuntimeError, "declined"):
            gmail.authorize_complete(
                redirect_uri,
                denied["state"],
                error="access_denied",
                now=5_001,
            )
        self.assertFalse(gmail.pending_oauth_path().exists())
        self.assertEqual(json.loads(gmail.token_path().read_text())["refresh_token"], "old-refresh")

    def test_remote_redirect_and_scope_remain_strictly_read_only(self):
        self.write_client()
        with self.assertRaisesRegex(RuntimeError, "HTTPS"):
            gmail.authorize_start("http://brain.example/callback")
        started = gmail.authorize_start("https://brain.example/callback", now=6_000)
        with mock.patch.object(
            gmail,
            "form_post",
            return_value={
                "access_token": "access",
                "refresh_token": "refresh",
                "scope": "https://www.googleapis.com/auth/gmail.modify",
            },
        ):
            with self.assertRaisesRegex(RuntimeError, "unexpected scope"):
                gmail.authorize_complete(
                    "https://brain.example/callback",
                    started["state"],
                    code="code",
                    now=6_001,
                )
        self.assertFalse(gmail.token_path().exists())
        self.assertEqual([tool["name"] for tool in gmail.TOOLS], ["gmail_search", "gmail_get_thread"])


if __name__ == "__main__":
    unittest.main()
