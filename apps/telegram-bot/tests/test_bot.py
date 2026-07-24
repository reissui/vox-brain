import importlib.util
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


APP_DIR = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("brain_telegram", APP_DIR / "bot.py")
bot = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(bot)


class BotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "sources" / "transcripts").mkdir(parents=True)
        (self.root / "daily").mkdir()
        (self.root / "notes").mkdir()
        (self.root / "projects").mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def test_discovers_only_unchecked_confirmation_questions(self):
        (self.root / "sources" / "transcripts" / "Planning.md").write_text(
            "## Needs confirmation\n\n- [ ] Q: Which project owns this?\n- [x] Q: Is Friday confirmed?\n\n## Transcript\n",
            encoding="utf-8",
        )
        questions = bot.meeting_questions(self.root)
        self.assertEqual(len(questions), 1)
        self.assertEqual(questions[0]["title"], "Planning")
        self.assertEqual(questions[0]["question"], "Which project owns this?")

    def test_reads_command_center_without_other_daily_sections(self):
        (self.root / "daily" / (bot.time.strftime("%Y-%m-%d") + ".md")).write_text(
            "## Command center\n\n### Today\n\n- Ship it\n\n## Filed today\n\n- Private detail\n",
            encoding="utf-8",
        )
        result = bot.command_center(self.root)
        self.assertIn("Ship it", result)
        self.assertNotIn("Private detail", result)

    def test_validates_and_limits_agent_actions(self):
        value = {
            "reply": "Done",
            "captures": [
                {"kind": "note", "text": "Remember this", "url": "", "comment": ""},
                {"kind": "shell", "text": "rm -rf", "url": "", "comment": ""},
            ],
            "answers_pending_question": False,
            "learning_candidate": "",
        }
        result = bot.validate_agent_response(value)
        self.assertEqual(result["captures"], [value["captures"][0]])

    def test_state_is_written_owner_only(self):
        path = self.root / "state" / "telegram.json"
        state = bot.State(path)
        state.data["offset"] = 42
        state.save()
        self.assertEqual(json.loads(path.read_text())["offset"], 42)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_splits_long_telegram_messages(self):
        chunks = bot.split_message("word " * 2000, limit=200)
        self.assertGreater(len(chunks), 2)
        self.assertTrue(all(len(chunk) <= 200 for chunk in chunks))

    def test_renders_telegram_html_without_exposing_markdown(self):
        (self.root / "notes" / "Public Note.md").write_text("# Public Note\n", encoding="utf-8")
        (self.root / "projects" / "Private Project.md").write_text("# Private\n", encoding="utf-8")
        rendered = bot.telegram_html(
            "### New\n\n- [[Public Note]] — **useful** `detail`\n- [[Private Project]]\n"
            "- [source](https://example.com?a=1&b=2)\n- <unsafe>",
            self.root,
            "https://brain.example",
        )
        self.assertIn("<b>New</b>", rendered)
        self.assertIn(
            '<a href="https://brain.example/notes/Public-Note">Public Note</a>',
            rendered,
        )
        self.assertIn("• Private Project", rendered)
        self.assertIn("<b>useful</b> <code>detail</code>", rendered)
        self.assertIn('<a href="https://example.com?a=1&amp;b=2">source</a>', rendered)
        self.assertIn("&lt;unsafe&gt;", rendered)
        self.assertNotIn("[[", rendered)
        self.assertNotIn("###", rendered)
        self.assertNotIn("**", rendered)

    def test_telegram_send_uses_html_parse_mode(self):
        (self.root / "notes" / "Linked.md").write_text("# Linked\n", encoding="utf-8")
        client = bot.Telegram("token", self.root, "https://brain.example")
        with mock.patch.object(client, "call", return_value=True) as call:
            client.send(42, "See [[Linked]]")
        method, data = call.call_args.args
        self.assertEqual(method, "sendMessage")
        self.assertEqual(data["parse_mode"], "HTML")
        self.assertIn('<a href="https://brain.example/notes/Linked">Linked</a>', data["text"])

    def test_pair_confirmation_is_visible_on_stderr_not_captured_stdout(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            confirmed = bot.confirm_pair("resuix", 1582173206, lambda: "y")
        self.assertTrue(confirmed)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("Pair this account? [y/N]", stderr.getvalue())

    def test_local_capture_fallback_writes_a_processable_inbox_note(self):
        (self.root / "inbox").mkdir()
        path = bot.capture_locally(
            self.root,
            {"kind": "bookmark", "url": "https://example.com/useful", "comment": "Useful pattern", "text": ""},
        )
        saved = (self.root / path).read_text(encoding="utf-8")
        self.assertIn("type: article", saved)
        self.assertIn("via: telegram", saved)
        self.assertIn("## Why saved\nUseful pattern", saved)

    def test_setting_reads_owner_only_headless_secret_file(self):
        state_dir = self.root / "state"
        secret_path = state_dir / "telegram-secrets.json"
        bot.write_private_json(
            secret_path,
            {"token": "file-token", "user_id": "123", "chat_id": "456"},
        )
        with mock.patch.dict(
            bot.os.environ,
            {"BRAIN_STATE_DIR": str(state_dir), "BRAIN_TELEGRAM_TOKEN": ""},
        ), mock.patch.object(bot, "keychain_get", return_value=""):
            self.assertEqual(bot.setting("BRAIN_TELEGRAM_TOKEN", bot.TOKEN_SERVICE), "file-token")
        self.assertEqual(secret_path.stat().st_mode & 0o777, 0o600)

    def test_applies_a_sol_learning_to_private_interaction_memory(self):
        state = bot.State(self.root / "state.json")
        learning = {
            "decision": "upsert",
            "kind": "communication",
            "instruction": "Use simple language and real Telegram links.",
            "applies_when": "All Telegram conversations",
            "evidence": "I want simple language and proper links.",
            "replace_ids": [],
        }
        self.assertTrue(bot.apply_learning(state, learning, "gpt-5.6-sol"))
        learned = bot.interaction_memory(state)
        self.assertEqual(len(learned), 1)
        self.assertEqual(learned[-1]["judged_by"], "gpt-5.6-sol")
        self.assertIn("simple language", bot.memory_summary(state))

    def test_handle_text_routes_learning_to_sol_and_saves_it_to_brain(self):
        state = bot.State(self.root / "state.json")
        response = {
            "reply": "Understood.",
            "captures": [],
            "answers_pending_question": False,
            "learning_candidate": "Always use simple language.",
        }
        learning = {
            "decision": "upsert",
            "kind": "communication",
            "instruction": "Use simple language.",
            "applies_when": "All Telegram conversations",
            "evidence": "Always use simple language.",
            "replace_ids": [],
        }
        with mock.patch.object(bot, "run_agent", return_value=response), mock.patch.object(
            bot, "run_learning", return_value=learning
        ) as run_learning, mock.patch.object(bot, "capture_action", return_value="inbox/learning.md"):
            reply = bot.handle_text(
                self.root,
                state,
                "Always use simple language.",
                "gpt-5.6-terra",
                "gpt-5.6-sol",
            )
        self.assertEqual(run_learning.call_args.args[4], "gpt-5.6-sol")
        self.assertIn("I've learned that", reply)
        self.assertIn("saved the change to Brain", reply)
        self.assertEqual(bot.interaction_memory(state)[-1]["instruction"], "Use simple language.")

    def test_learning_never_falls_back_from_sol(self):
        state = bot.State(self.root / "state.json")
        with mock.patch.object(bot, "run_codex_json", return_value={
            "decision": "none",
            "kind": "context",
            "instruction": "",
            "applies_when": "",
            "evidence": "",
            "replace_ids": [],
        }) as run_codex:
            bot.run_learning(self.root, state, "hello", "hello", "gpt-5.6-sol")
        self.assertEqual(run_codex.call_args.args[3], "gpt-5.6-sol")
        self.assertFalse(run_codex.call_args.kwargs["allow_model_fallback"])

    def test_learning_rejects_a_non_sol_override(self):
        state = bot.State(self.root / "state.json")
        with self.assertRaisesRegex(RuntimeError, "Sol model"):
            bot.run_learning(self.root, state, "Always be brief", "Always be brief", "gpt-5.6-terra")

    def test_gmail_mcp_is_added_only_when_connector_is_configured(self):
        connector = self.root / "apps" / "gmail-connector" / "gmail.py"
        connector.parent.mkdir(parents=True)
        connector.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        connector.chmod(0o700)
        config = bot.gmail_mcp_config(self.root)
        self.assertIn("mcp_servers.gmail.command=" + json.dumps(str(connector)), config)

        connector.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        self.assertEqual(bot.gmail_mcp_config(self.root), [])


if __name__ == "__main__":
    unittest.main()
