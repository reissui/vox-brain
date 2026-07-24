#!/usr/bin/env python3
"""Regression tests for the external Brain data cutover."""

from __future__ import annotations

import io
import json
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


APP_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(APP_DIR))

import migrate_data  # noqa: E402


class MigrateDataTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.data = self.root / "Brain Data"
        self.state = self.root / "agent-state"
        (self.source / "inbox").mkdir(parents=True)
        (self.source / "notes" / "nested").mkdir(parents=True)
        (self.source / "inbox" / "Capture.md").write_bytes(b"exact capture\n")
        (self.source / "bookmarks.md").write_bytes(b"# Legacy bookmarks\n")
        (self.source / "notes" / "nested" / "Knowledge.md").write_bytes(
            b"# Knowledge\n\nPreserve me.\n"
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_dry_run_reports_exact_paths_without_mutating(self) -> None:
        output = io.StringIO()
        with redirect_stdout(output):
            result = migrate_data.main(
                [
                    "dry-run",
                    "--source-root",
                    str(self.source),
                    "--data-root",
                    str(self.data),
                    "--json",
                ]
            )
        self.assertEqual(result, 0)
        report = json.loads(output.getvalue())
        self.assertEqual(
            report["copied"],
            ["bookmarks.md", "inbox/Capture.md", "notes/nested/Knowledge.md"],
        )
        self.assertEqual(report["skipped"], [])
        self.assertFalse(self.data.exists())
        self.assertFalse(self.state.exists())

    def test_apply_is_verified_and_idempotent(self) -> None:
        first = migrate_data.apply(self.source, self.data, self.state)
        self.assertEqual(
            list(first.copied),
            ["bookmarks.md", "inbox/Capture.md", "notes/nested/Knowledge.md"],
        )
        self.assertEqual(
            (self.data / "notes" / "nested" / "Knowledge.md").read_bytes(),
            b"# Knowledge\n\nPreserve me.\n",
        )
        manifest = json.loads(
            (self.state / migrate_data.MANIFEST_NAME).read_text(encoding="utf-8")
        )
        self.assertEqual(sorted(manifest["sha256"]), list(first.copied))
        self.assertEqual(
            stat.S_IMODE((self.state / migrate_data.MANIFEST_NAME).stat().st_mode), 0o600
        )
        migrate_data.verify_manifest(self.state, self.data)

        second = migrate_data.apply(self.source, self.data, self.state)
        self.assertEqual(second.copied, ())
        self.assertEqual(
            list(second.skipped),
            ["bookmarks.md", "inbox/Capture.md", "notes/nested/Knowledge.md"],
        )

    def test_hash_mismatch_refuses_manifest_and_cutover(self) -> None:
        original = migrate_data._copy_one

        def corrupt(source: Path, destination: Path, digest: str) -> None:
            original(source, destination, digest)
            if destination.name == "Knowledge.md":
                destination.write_bytes(b"corrupted after copy\n")

        with mock.patch.object(migrate_data, "_copy_one", side_effect=corrupt):
            with self.assertRaisesRegex(
                migrate_data.MigrationError, "manifest verification failed"
            ):
                migrate_data.apply(self.source, self.data, self.state)
        self.assertFalse((self.state / migrate_data.MANIFEST_NAME).exists())
        self.assertEqual((self.source / "inbox" / "Capture.md").read_bytes(), b"exact capture\n")

    def test_symlink_in_source_or_destination_is_refused(self) -> None:
        (self.source / "notes" / "link.md").symlink_to(
            self.source / "inbox" / "Capture.md"
        )
        with self.assertRaisesRegex(migrate_data.MigrationError, "symlinks"):
            migrate_data.plan(self.source, self.data)
        (self.source / "notes" / "link.md").unlink()

        (self.data / "notes").mkdir(parents=True)
        (self.data / "notes" / "nested").symlink_to(self.source / "notes" / "nested")
        with self.assertRaisesRegex(migrate_data.MigrationError, "unsafe path"):
            migrate_data.plan(self.source, self.data)

    def test_manifest_verification_precedes_runtime_cutover(self) -> None:
        runtime = self.root / "agent.json"
        runtime.write_text("old\n", encoding="utf-8")
        runtime.chmod(0o600)
        migrate_data.backup_runtime(self.state, [runtime])
        runtime.write_text("new\n", encoding="utf-8")

        with self.assertRaises(migrate_data.MigrationError):
            migrate_data.verify_manifest(self.state, self.data)
        self.assertEqual(runtime.read_text(encoding="utf-8"), "new\n")

        migrate_data.apply(self.source, self.data, self.state)
        migrate_data.verify_manifest(self.state, self.data)
        runtime.write_text("cut over\n", encoding="utf-8")
        self.assertEqual(runtime.read_text(encoding="utf-8"), "cut over\n")

    def test_rollback_restores_runtime_and_preserves_both_data_copies(self) -> None:
        existing = self.root / "agent.json"
        created = self.root / "agent.env"
        existing.write_bytes(b"old config\n")
        existing.chmod(0o640)
        migrate_data.apply(self.source, self.data, self.state)
        source_before = (self.source / "inbox" / "Capture.md").read_bytes()
        data_before = (self.data / "inbox" / "Capture.md").read_bytes()
        migrate_data.backup_runtime(self.state, [existing, created])
        existing.write_bytes(b"new config\n")
        created.write_bytes(b"new environment\n")

        restored = migrate_data.rollback_runtime(self.state)

        self.assertEqual(
            restored,
            [str(existing.resolve(strict=False)), str(created.resolve(strict=False))],
        )
        self.assertEqual(existing.read_bytes(), b"old config\n")
        self.assertEqual(stat.S_IMODE(existing.stat().st_mode), 0o640)
        self.assertFalse(created.exists())
        self.assertEqual((self.source / "inbox" / "Capture.md").read_bytes(), source_before)
        self.assertEqual((self.data / "inbox" / "Capture.md").read_bytes(), data_before)


if __name__ == "__main__":
    unittest.main()
