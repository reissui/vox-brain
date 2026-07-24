#!/usr/bin/env python3
"""Strict, secret-free configuration for the remote Brain Agent service."""

from __future__ import annotations

import json
import os
import re
import stat
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping, Optional, Tuple
from urllib.parse import urlsplit


MAX_CONFIG_BYTES = 64 * 1024
MAX_SITE_URL_CHARS = 2_048
SECRET_ENV_NAMES = {
    "agent_token": "BRAIN_AGENT_TOKEN",
    "origin_token": "BRAIN_ORIGIN_TOKEN",
    "queue_api_token": "BRAIN_QUEUE_API_TOKEN",
}
_CONFIG_FIELDS = frozenset(
    (
        "instance_id",
        "gateway_url",
        "site_url",
        "account_id",
        "queue_id",
        "code_root",
        "data_root",
        "brain_cli_path",
        "api_port",
        "state_dir",
    )
)
_LEGACY_CONFIG_FIELDS = (_CONFIG_FIELDS - {"code_root", "data_root"}) | {"vault_path"}
_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class ConfigError(RuntimeError):
    """A bounded configuration failure that never contains secret material."""


@dataclass(frozen=True)
class AgentSecrets:
    agent_token: str = field(repr=False)
    origin_token: str = field(repr=False)
    queue_api_token: str = field(repr=False)

    def values(self) -> Tuple[str, ...]:
        return (self.agent_token, self.origin_token, self.queue_api_token)


@dataclass(frozen=True, init=False)
class AgentConfig:
    instance_id: str
    gateway_url: str
    site_url: str
    account_id: str
    queue_id: str
    brain_cli_path: Path
    api_port: int
    state_dir: Path
    secrets: AgentSecrets = field(repr=False)
    code_root: Path
    data_root: Path

    def __init__(
        self,
        *,
        instance_id: str,
        gateway_url: str,
        site_url: str,
        account_id: str,
        queue_id: str,
        brain_cli_path: Path,
        api_port: int,
        state_dir: Path,
        secrets: AgentSecrets,
        code_root: Optional[Path] = None,
        data_root: Optional[Path] = None,
        vault_path: Optional[Path] = None,
    ) -> None:
        # ``vault_path`` is accepted as a source-compatible constructor alias
        # while callers migrate. Persisted production config never uses it.
        content_root = data_root if data_root is not None else vault_path
        if content_root is None:
            raise TypeError("data_root is required")
        cli = Path(brain_cli_path)
        source_root = cli.parent.parent if code_root is None else Path(code_root)
        for name, value in (
            ("instance_id", instance_id),
            ("gateway_url", gateway_url),
            ("site_url", site_url),
            ("account_id", account_id),
            ("queue_id", queue_id),
            ("brain_cli_path", cli),
            ("api_port", api_port),
            ("state_dir", Path(state_dir)),
            ("secrets", secrets),
            ("code_root", source_root),
            ("data_root", Path(content_root)),
        ):
            object.__setattr__(self, name, value)

    @property
    def vault_path(self) -> Path:
        """Temporary read-only alias for components still named around a vault."""

        return self.data_root


def load_config(path: str, environ: Optional[Mapping[str, str]] = None) -> AgentConfig:
    """Load one owner-only JSON file and resolve credentials from the environment."""

    source = Path(path)
    if not source.is_absolute():
        raise ConfigError("configuration path must be absolute")
    descriptor = _open_owner_only(source)
    try:
        with os.fdopen(descriptor, "rb") as handle:
            raw = handle.read(MAX_CONFIG_BYTES + 1)
    except OSError as exc:
        raise ConfigError("configuration could not be read") from exc
    if len(raw) > MAX_CONFIG_BYTES:
        raise ConfigError("configuration is too large")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ConfigError("configuration is not valid JSON") from exc
    if not isinstance(value, dict) or set(value) not in (_CONFIG_FIELDS, _LEGACY_CONFIG_FIELDS):
        raise ConfigError("configuration fields are invalid")

    instance_id = _identifier(value, "instance_id")
    account_id = _identifier(value, "account_id")
    queue_id = _identifier(value, "queue_id")
    gateway_url = _gateway_url(value.get("gateway_url"))
    site_url = _site_url(value.get("site_url"))
    if set(value) == _CONFIG_FIELDS:
        code_root = _existing_directory(value, "code_root")
        data_root = _existing_directory(value, "data_root")
    else:
        data_root = _existing_directory(value, "vault_path")
        code_root = _executable_file(value, "brain_cli_path").parent.parent
    brain_cli_path = _executable_file(value, "brain_cli_path")
    state_dir = _existing_directory(value, "state_dir")
    api_port = value.get("api_port")
    if isinstance(api_port, bool) or not isinstance(api_port, int) or not 1 <= api_port <= 65_535:
        raise ConfigError("api_port must be between 1 and 65535")

    environment = os.environ if environ is None else environ
    secret_values: dict[str, str] = {}
    for name, environment_name in SECRET_ENV_NAMES.items():
        secret = environment.get(environment_name, "")
        if not secret or any(character.isspace() for character in secret):
            raise ConfigError("required secret environment variable is missing")
        secret_values[name] = secret
    if len(set(secret_values.values())) != len(secret_values):
        raise ConfigError("service credentials must be independent")

    return AgentConfig(
        instance_id=instance_id,
        gateway_url=gateway_url,
        site_url=site_url,
        account_id=account_id,
        queue_id=queue_id,
        vault_path=data_root,
        brain_cli_path=brain_cli_path,
        api_port=api_port,
        state_dir=state_dir,
        secrets=AgentSecrets(**secret_values),
        code_root=code_root,
        data_root=data_root,
    )


def _open_owner_only(path: Path) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(str(path), flags)
    except OSError as exc:
        raise ConfigError("configuration must be an owner-only regular file") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ConfigError("configuration must be an owner-only regular file")
        if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) & 0o077:
            raise ConfigError("configuration must be owned and readable only by its owner")
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def _identifier(value: dict[str, Any], name: str) -> str:
    result = value.get(name)
    if not isinstance(result, str) or not _SAFE_ID.fullmatch(result):
        raise ConfigError("{} is invalid".format(name))
    return result


def _gateway_url(value: Any) -> str:
    if not isinstance(value, str):
        raise ConfigError("gateway_url is invalid")
    parsed = urlsplit(value)
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ConfigError("gateway_url is invalid")
    return value.rstrip("/")


def _site_url(value: Any) -> str:
    """Validate the owner-facing private-site destination without normalizing it."""

    if (
        not isinstance(value, str)
        or not value
        or len(value.encode("utf-8")) > MAX_SITE_URL_CHARS
        or value != value.strip()
        or "\\" in value
        or any(
            ord(character) < 0x20 or ord(character) > 0x7E
            for character in value
        )
    ):
        raise ConfigError("site_url is invalid")
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        _ = parsed.port
    except ValueError as exc:
        raise ConfigError("site_url is invalid") from exc
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ConfigError("site_url is invalid")
    return value


def _absolute_path(value: dict[str, Any], name: str) -> Path:
    raw = value.get(name)
    if not isinstance(raw, str) or not raw or "\x00" in raw:
        raise ConfigError("{} must be an absolute path".format(name))
    path = Path(raw)
    if not path.is_absolute():
        raise ConfigError("{} must be an absolute path".format(name))
    return path


def _existing_directory(value: dict[str, Any], name: str) -> Path:
    path = _absolute_path(value, name)
    if not path.is_dir():
        raise ConfigError("{} must be an existing directory".format(name))
    return path.resolve(strict=True)


def _executable_file(value: dict[str, Any], name: str) -> Path:
    path = _absolute_path(value, name)
    if not path.is_file() or not os.access(str(path), os.X_OK):
        raise ConfigError("{} must be an executable file".format(name))
    return path.resolve(strict=True)


__all__ = [
    "AgentConfig",
    "AgentSecrets",
    "ConfigError",
    "MAX_CONFIG_BYTES",
    "MAX_SITE_URL_CHARS",
    "SECRET_ENV_NAMES",
    "load_config",
]
