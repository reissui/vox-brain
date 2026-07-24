#!/usr/bin/env python3
"""Copy legacy Brain content into its Git-independent data directory safely."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


CONTENT_DIRECTORIES = (
    ".obsidian",
    ".trash",
    "daily",
    "inbox",
    "maps",
    "me",
    "notes",
    "people",
    "projects",
    "sources",
    "system/attachments",
)
CONTENT_FILES = (
    "HOME.md",
    "bookmarks.md",
    "designs.md",
    "index.md",
    "system/last-run.json",
)
DATA_ROOT_MARKER = ".brain-data-root"
MANIFEST_NAME = "data-migration-manifest.json"
RUNTIME_BACKUP_NAME = "pre-data-cutover-runtime.json"
RUNTIME_BACKUP_DIRECTORY = "pre-data-cutover-runtime"
BUFFER_SIZE = 1024 * 1024


class MigrationError(RuntimeError):
    """A safe failure which never includes file contents or credentials."""


@dataclass(frozen=True)
class Plan:
    source_root: Path
    data_root: Path
    hashes: Mapping[str, str]
    copied: Tuple[str, ...]
    skipped: Tuple[str, ...]

    def report(self, mode: str) -> Dict[str, object]:
        return {
            "mode": mode,
            "source_root": str(self.source_root),
            "data_root": str(self.data_root),
            "copied": list(self.copied),
            "skipped": list(self.skipped),
            "file_count": len(self.hashes),
        }


def _absolute(path: str, name: str) -> Path:
    result = Path(path)
    if not result.is_absolute():
        raise MigrationError("{} must be an absolute path".format(name))
    return result.resolve(strict=False)


def _is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _validate_distinct_roots(source_root: Path, data_root: Path) -> None:
    if source_root == data_root or _is_relative_to(data_root, source_root) or _is_relative_to(
        source_root, data_root
    ):
        raise MigrationError("source_root and data_root must be separate directory trees")


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(str(path), flags)
    except OSError as exc:
        raise MigrationError("could not read a migration file safely") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise MigrationError("migration content must contain only regular files and directories")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            for block in iter(lambda: handle.read(BUFFER_SIZE), b""):
                digest.update(block)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest()


def _walk_regular_files(root: Path, relative_root: str) -> Iterable[Tuple[str, Path]]:
    start = root
    for component in Path(relative_root).parts:
        start = start / component
        if not start.exists() and not start.is_symlink():
            return
        try:
            metadata = start.lstat()
        except OSError as exc:
            raise MigrationError("could not inspect migration content") from exc
        if stat.S_ISLNK(metadata.st_mode):
            raise MigrationError("symlinks are not allowed in migration content")
        if not stat.S_ISDIR(metadata.st_mode):
            raise MigrationError("migration content roots must be directories")

    pending = [start]
    while pending:
        directory = pending.pop()
        try:
            entries = sorted(os.scandir(directory), key=lambda item: item.name, reverse=True)
        except OSError as exc:
            raise MigrationError("could not inspect migration content") from exc
        for entry in entries:
            relative = Path(entry.path).relative_to(root).as_posix()
            try:
                if entry.is_symlink():
                    raise MigrationError("symlinks are not allowed in migration content: " + relative)
                if entry.is_dir(follow_symlinks=False):
                    pending.append(Path(entry.path))
                elif entry.is_file(follow_symlinks=False):
                    yield relative, Path(entry.path)
                else:
                    raise MigrationError("special files are not allowed in migration content: " + relative)
            except OSError as exc:
                raise MigrationError("could not inspect migration content: " + relative) from exc


def _source_hashes(source_root: Path) -> Dict[str, str]:
    if not source_root.is_dir():
        raise MigrationError("source_root must be an existing directory")
    hashes: Dict[str, str] = {}
    for relative_root in CONTENT_DIRECTORIES:
        for relative, path in _walk_regular_files(source_root, relative_root):
            hashes[relative] = _hash_file(path)
    for relative in CONTENT_FILES:
        path = source_root / relative
        if not path.exists() and not path.is_symlink():
            continue
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise MigrationError("personal content must be a regular non-symlink file: " + relative)
        hashes[relative] = _hash_file(path)
    if not hashes:
        raise MigrationError("source_root contains no Brain content files")
    return dict(sorted(hashes.items()))


def _inspect_destination(data_root: Path, relative: str, expected_hash: str) -> str:
    destination = data_root / relative
    current = data_root
    for component in Path(relative).parts[:-1]:
        current = current / component
        if current.exists() or current.is_symlink():
            metadata = current.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise MigrationError("destination contains an unsafe path: " + relative)
    if not destination.exists() and not destination.is_symlink():
        return "copy"
    metadata = destination.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise MigrationError("destination contains an unsafe path: " + relative)
    if _hash_file(destination) != expected_hash:
        raise MigrationError("destination conflicts with source content: " + relative)
    return "skip"


def _validate_destination_roots(data_root: Path) -> None:
    if data_root.exists() and not data_root.is_dir():
        raise MigrationError("data_root must be a directory")
    for relative in CONTENT_DIRECTORIES:
        destination = data_root
        for component in Path(relative).parts:
            destination = destination / component
            if destination.exists() or destination.is_symlink():
                metadata = destination.lstat()
                if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                    raise MigrationError("destination contains an unsafe content root: " + relative)
    for relative in CONTENT_FILES:
        destination = data_root / relative
        current = data_root
        for component in Path(relative).parts[:-1]:
            current = current / component
            if current.exists() or current.is_symlink():
                metadata = current.lstat()
                if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                    raise MigrationError("destination contains an unsafe content path: " + relative)
        if destination.exists() or destination.is_symlink():
            metadata = destination.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise MigrationError("destination contains an unsafe content path: " + relative)


def plan(source_root: Path, data_root: Path) -> Plan:
    if data_root.is_symlink():
        raise MigrationError("data_root must not be a symlink")
    source = source_root.resolve(strict=True)
    destination = data_root.resolve(strict=False)
    _validate_distinct_roots(source, destination)
    _validate_destination_roots(destination)
    hashes = _source_hashes(source)
    copied: List[str] = []
    skipped: List[str] = []
    for relative, digest in hashes.items():
        if _inspect_destination(destination, relative, digest) == "copy":
            copied.append(relative)
        else:
            skipped.append(relative)
    return Plan(source, destination, hashes, tuple(copied), tuple(skipped))


def _copy_one(source: Path, destination: Path, expected_hash: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".brain-migrate-", dir=destination.parent)
    temporary = Path(temporary_name)
    try:
        source_descriptor = -1
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            source_descriptor = os.open(
                str(source),
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
            source_metadata = os.fstat(source_descriptor)
            if not stat.S_ISREG(source_metadata.st_mode):
                raise MigrationError("migration source changed during copy")
            with os.fdopen(source_descriptor, "rb") as input_file:
                source_descriptor = -1
                shutil.copyfileobj(input_file, output, BUFFER_SIZE)
                output.flush()
                os.fsync(output.fileno())
        if source_descriptor >= 0:
            os.close(source_descriptor)
            source_descriptor = -1
        os.chmod(temporary, stat.S_IMODE(source_metadata.st_mode) & 0o700 or 0o600)
        if _hash_file(temporary) != expected_hash:
            raise MigrationError("copied file failed SHA-256 verification")
        try:
            os.link(temporary, destination)
        except FileExistsError:
            if _hash_file(destination) != expected_hash:
                raise MigrationError("destination changed during migration")
    finally:
        if source_descriptor >= 0:
            os.close(source_descriptor)
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _atomic_json(path: Path, value: object, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def _ensure_data_directories(data_root: Path) -> None:
    data_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    for relative in CONTENT_DIRECTORIES:
        directory = data_root / relative
        if directory.exists() or directory.is_symlink():
            metadata = directory.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise MigrationError("destination contains an unsafe content root: " + relative)
        else:
            directory.mkdir(parents=True, mode=0o700)


def _manifest_document(migration: Plan) -> Dict[str, object]:
    return {
        "schema_version": 1,
        "source_root": str(migration.source_root),
        "data_root": str(migration.data_root),
        "sha256": dict(migration.hashes),
    }


def verify_manifest(
    state_dir: Path, expected_data_root: Optional[Path] = None
) -> Dict[str, object]:
    manifest_path = state_dir / MANIFEST_NAME
    try:
        document = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise MigrationError("verified data migration manifest is missing or invalid") from exc
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise MigrationError("verified data migration manifest is invalid")
    data_root_value = document.get("data_root")
    hashes = document.get("sha256")
    if not isinstance(data_root_value, str) or not isinstance(hashes, dict):
        raise MigrationError("verified data migration manifest is invalid")
    data_root = Path(data_root_value)
    if expected_data_root is not None and data_root.resolve(strict=False) != expected_data_root.resolve(
        strict=False
    ):
        raise MigrationError("verified data migration manifest targets another data_root")
    for relative, expected_hash in sorted(hashes.items()):
        if (
            not isinstance(relative, str)
            or not isinstance(expected_hash, str)
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
        ):
            raise MigrationError("verified data migration manifest is invalid")
        if _inspect_destination(data_root, relative, expected_hash) != "skip":
            raise MigrationError("verified data migration file is missing: " + relative)
    marker = data_root / DATA_ROOT_MARKER
    if marker.is_symlink() or not marker.is_file():
        raise MigrationError("Brain data root marker is missing")
    return document


def apply(source_root: Path, data_root: Path, state_dir: Path) -> Plan:
    migration = plan(source_root, data_root)
    _ensure_data_directories(migration.data_root)
    for relative in migration.copied:
        _copy_one(
            migration.source_root / relative,
            migration.data_root / relative,
            migration.hashes[relative],
        )
    marker = migration.data_root / DATA_ROOT_MARKER
    if marker.exists() or marker.is_symlink():
        if marker.is_symlink() or not marker.is_file():
            raise MigrationError("Brain data root marker is unsafe")
    else:
        marker.write_text("Brain canonical data root v1\n", encoding="utf-8")
        marker.chmod(0o600)
    for relative, digest in migration.hashes.items():
        if _hash_file(migration.data_root / relative) != digest:
            raise MigrationError("destination manifest verification failed: " + relative)
    _atomic_json(state_dir / MANIFEST_NAME, _manifest_document(migration))
    verify_manifest(state_dir, migration.data_root)
    return migration


def backup_runtime(state_dir: Path, runtime_files: Sequence[Path]) -> Dict[str, object]:
    manifest_path = state_dir / RUNTIME_BACKUP_NAME
    requested = [str(path.resolve(strict=False)) for path in runtime_files]
    if manifest_path.exists():
        document = json.loads(manifest_path.read_text(encoding="utf-8"))
        if document.get("paths") != requested:
            raise MigrationError("existing runtime backup targets different paths")
        return document

    backup_directory = state_dir / RUNTIME_BACKUP_DIRECTORY
    backup_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    entries = []
    for index, path in enumerate(runtime_files):
        target = path.resolve(strict=False)
        existed = target.exists() or target.is_symlink()
        entry = {"path": str(target), "existed": existed, "backup": None, "mode": None}
        if existed:
            metadata = target.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise MigrationError("runtime backup paths must be regular non-symlink files")
            backup = backup_directory / str(index)
            shutil.copyfile(target, backup, follow_symlinks=False)
            backup.chmod(0o600)
            entry["backup"] = str(backup)
            entry["mode"] = stat.S_IMODE(metadata.st_mode)
        entries.append(entry)
    document = {"schema_version": 1, "paths": requested, "entries": entries}
    _atomic_json(manifest_path, document)
    return document


def rollback_runtime(state_dir: Path) -> List[str]:
    manifest_path = state_dir / RUNTIME_BACKUP_NAME
    try:
        document = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise MigrationError("runtime rollback backup is missing or invalid") from exc
    entries = document.get("entries") if isinstance(document, dict) else None
    if document.get("schema_version") != 1 or not isinstance(entries, list):
        raise MigrationError("runtime rollback backup is invalid")
    restored: List[str] = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise MigrationError("runtime rollback backup is invalid")
        destination = Path(entry["path"])
        if not destination.is_absolute():
            raise MigrationError("runtime rollback backup is invalid")
        if destination.is_symlink():
            raise MigrationError("runtime rollback refuses a symlink destination")
        if entry.get("existed") is True:
            backup_value = entry.get("backup")
            mode = entry.get("mode")
            if not isinstance(backup_value, str) or not isinstance(mode, int):
                raise MigrationError("runtime rollback backup is invalid")
            backup = Path(backup_value)
            if backup.is_symlink() or not backup.is_file():
                raise MigrationError("runtime rollback backup is incomplete")
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=".brain-rollback-", dir=destination.parent
            )
            os.close(descriptor)
            try:
                shutil.copyfile(backup, temporary_name, follow_symlinks=False)
                os.chmod(temporary_name, mode)
                os.replace(temporary_name, destination)
            finally:
                try:
                    os.unlink(temporary_name)
                except FileNotFoundError:
                    pass
        else:
            if destination.exists():
                if not destination.is_file() or destination.is_symlink():
                    raise MigrationError("runtime rollback refuses an unsafe destination")
                destination.unlink()
        restored.append(str(destination))
    return restored


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("dry-run", "apply", "status"):
        child = subparsers.add_parser(command)
        child.add_argument("--source-root", required=command != "status")
        child.add_argument("--data-root", required=True)
        child.add_argument("--state-dir", required=command != "dry-run")
        child.add_argument("--json", action="store_true")
    backup = subparsers.add_parser("backup-runtime")
    backup.add_argument("--state-dir", required=True)
    backup.add_argument("--runtime-file", action="append", required=True)
    rollback = subparsers.add_parser("rollback")
    rollback.add_argument("--state-dir", required=True)
    return parser


def _print_report(report: Mapping[str, object], as_json: bool) -> None:
    if as_json:
        print(json.dumps(report, sort_keys=True))
        return
    for path in report.get("copied", []):
        print("COPY " + str(path))
    for path in report.get("skipped", []):
        print("SKIP " + str(path))
    print("{}: {} file(s)".format(report["mode"], report.get("file_count", 0)))


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        state_value = getattr(arguments, "state_dir", None)
        state_dir = _absolute(state_value, "state_dir") if state_value is not None else None
        if arguments.command == "dry-run":
            migration = plan(
                _absolute(arguments.source_root, "source_root"),
                _absolute(arguments.data_root, "data_root"),
            )
            _print_report(migration.report("dry-run"), arguments.json)
        elif arguments.command == "apply":
            migration = apply(
                _absolute(arguments.source_root, "source_root"),
                _absolute(arguments.data_root, "data_root"),
                state_dir,
            )
            _print_report(migration.report("applied"), arguments.json)
        elif arguments.command == "status":
            data_root = _absolute(arguments.data_root, "data_root")
            document = verify_manifest(state_dir, data_root)
            report = {
                "mode": "verified",
                "source_root": document["source_root"],
                "data_root": document["data_root"],
                "copied": [],
                "skipped": sorted(document["sha256"]),
                "file_count": len(document["sha256"]),
            }
            _print_report(report, arguments.json)
        elif arguments.command == "backup-runtime":
            backup_runtime(state_dir, tuple(_absolute(path, "runtime_file") for path in arguments.runtime_file))
            print("runtime backup ready")
        elif arguments.command == "rollback":
            restored = rollback_runtime(state_dir)
            for path in restored:
                print("RESTORE " + path)
            print("rollback restored runtime configuration; both data copies were preserved")
        return 0
    except (MigrationError, OSError, ValueError, json.JSONDecodeError) as exc:
        print("error: {}".format(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
