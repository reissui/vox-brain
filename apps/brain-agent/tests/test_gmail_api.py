import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


APP_DIR = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("brain_agent_gmail_api", APP_DIR / "gmail_api.py")
gmail_api = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(gmail_api)


class GmailAPITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"BRAIN_STATE_DIR": self.temp.name})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def assert_secret_free(self, value):
        rendered = repr(value).lower()
        for secret in ("client-secret", "authorization-code", "access-token", "refresh-token"):
            self.assertNotIn(secret, rendered)

    def test_fixed_handlers_are_secret_free(self):
        self.assertEqual(set(gmail_api.HANDLERS), {"start", "complete", "status", "disconnect"})
        with mock.patch.object(
            gmail_api.connector,
            "authorize_start",
            return_value={
                "authorization_url": "https://accounts.example/authorize",
                "state": "public-state",
                "expires_at": 123,
                "client_secret": "client-secret",
                "access_token": "access-token",
            },
        ):
            started = gmail_api.handle_start({"redirect_uri": "https://brain.example/callback"})
        self.assertEqual(
            started,
            {
                "authorization_url": "https://accounts.example/authorize",
                "state": "public-state",
                "expires_at": 123,
            },
        )
        with mock.patch.object(
            gmail_api.connector,
            "authorize_complete",
            return_value={"refresh_token": "refresh-token", "access_token": "access-token"},
        ) as complete:
            completed = gmail_api.handle_complete(
                {
                    "redirect_uri": "https://brain.example/callback",
                    "state": "public-state",
                    "code": "authorization-code",
                }
            )
        self.assertEqual(completed, {"status": "connected", "scope": gmail_api.connector.SCOPE})
        self.assertEqual(complete.call_args.kwargs["code"], "authorization-code")
        self.assert_secret_free(started)
        self.assert_secret_free(completed)

    def test_complete_returns_bounded_errors_without_reflecting_code(self):
        with mock.patch.object(
            gmail_api.connector,
            "authorize_complete",
            side_effect=RuntimeError("provider echoed authorization-code and client-secret"),
        ):
            with self.assertRaises(gmail_api.GmailAPIError) as caught:
                gmail_api.complete(
                    "https://brain.example/callback",
                    "state",
                    code="authorization-code",
                )
        self.assertEqual(caught.exception.code, "token_exchange_failed")
        self.assertLessEqual(len(str(caught.exception)), 160)
        self.assert_secret_free(str(caught.exception))

    def test_status_and_disconnect_have_fixed_safe_shapes(self):
        gmail_api.connector.write_private_json(gmail_api.connector.client_path(), {"installed": {}})
        gmail_api.connector.write_private_json(
            gmail_api.connector.token_path(),
            {"access_token": "access-token", "refresh_token": "refresh-token"},
        )
        with mock.patch.object(gmail_api.connector, "status", return_value="configured"), mock.patch.object(
            gmail_api.connector,
            "gmail_get",
            return_value={"emailAddress": "owner@example.com", "access_token": "access-token"},
        ):
            result = gmail_api.handle_status({})
        self.assertEqual(
            result,
            {
                "status": "connected",
                "scope": gmail_api.connector.SCOPE,
                "account": "owner@example.com",
            },
        )
        self.assert_secret_free(result)

        with mock.patch.object(gmail_api.connector, "disconnect", return_value="refresh-token") as revoke:
            disconnected = gmail_api.handle_disconnect({})
        self.assertEqual(disconnected, {"status": "disconnected"})
        revoke.assert_called_once_with(preserve_client=True)
        self.assert_secret_free(disconnected)

    def test_status_distinguishes_disconnected_and_reconnect_required(self):
        self.assertEqual(gmail_api.status(), {"status": "disconnected"})
        gmail_api.connector.write_private_json(gmail_api.connector.client_path(), {"installed": {}})
        gmail_api.connector.write_private_json(gmail_api.connector.token_path(), {"refresh_token": "secret"})
        with mock.patch.object(gmail_api.connector, "status", side_effect=RuntimeError("refresh failed")):
            self.assertEqual(
                gmail_api.status(),
                {"status": "reconnect_required", "scope": gmail_api.connector.SCOPE},
            )

    def test_denial_and_elapsed_session_are_persisted_as_secret_free_statuses(self):
        with mock.patch.object(
            gmail_api.connector,
            "authorize_start",
            return_value={
                "authorization_url": "https://accounts.example/authorize?state=provider-state",
                "state": "provider-state",
                "expires_at": 1_100,
            },
        ):
            gmail_api.start("https://brain.example/callback")

        session_path = gmail_api._authorization_session_path()
        self.assertEqual(
            session_path.read_text(encoding="utf-8").strip(),
            '{\n  "status": "pending",\n  "expires_at": 1100\n}',
        )
        with mock.patch.object(gmail_api.time, "time", return_value=1_101):
            self.assertEqual(gmail_api.handle_status({}), {"status": "expired"})
        self.assertEqual(
            gmail_api.connector.read_json(session_path),
            {"status": "expired"},
        )

        with mock.patch.object(
            gmail_api.connector,
            "authorize_start",
            return_value={
                "authorization_url": "https://accounts.example/authorize?state=next-state",
                "state": "next-state",
                "expires_at": 2_000,
            },
        ):
            gmail_api.start("https://brain.example/callback")
        with mock.patch.object(
            gmail_api.connector,
            "authorize_complete",
            side_effect=RuntimeError("Google authorization was declined"),
        ):
            with self.assertRaises(gmail_api.GmailAPIError) as caught:
                gmail_api.complete(
                    "https://brain.example/callback",
                    "next-state",
                    error="access_denied",
                )
        self.assertEqual(caught.exception.code, "authorization_denied")
        self.assertEqual(gmail_api.handle_status({}), {"status": "denied"})
        persisted = session_path.read_text(encoding="utf-8")
        self.assertEqual(gmail_api.connector.read_json(session_path), {"status": "denied"})
        for secret in ("provider-state", "next-state", "access_denied", "code_verifier"):
            self.assertNotIn(secret, persisted)

    def test_success_and_disconnect_clear_authorization_session(self):
        gmail_api._write_authorization_session("pending", 2_000)
        with mock.patch.object(gmail_api.connector, "authorize_complete", return_value={}):
            gmail_api.complete("https://brain.example/callback", "state", code="code")
        self.assertFalse(gmail_api._authorization_session_path().exists())

        gmail_api._write_authorization_session("denied")
        with mock.patch.object(gmail_api.connector, "disconnect", return_value="removed"):
            gmail_api.disconnect()
        self.assertFalse(gmail_api._authorization_session_path().exists())

    def test_handlers_reject_unknown_fields_and_ambiguous_callbacks(self):
        with self.assertRaises(gmail_api.GmailAPIError):
            gmail_api.handle_start({"redirect_uri": "https://brain.example/callback", "client_secret": "no"})
        with self.assertRaises(gmail_api.GmailAPIError):
            gmail_api.handle_complete(
                {
                    "redirect_uri": "https://brain.example/callback",
                    "state": "state",
                    "code": "code",
                    "error": "access_denied",
                }
            )


if __name__ == "__main__":
    unittest.main()
