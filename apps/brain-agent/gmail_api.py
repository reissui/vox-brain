"""Secret-free Gmail operations exposed by the remote Brain Agent.

The Google client configuration, PKCE verifier, and tokens are owned by the
local connector. This adapter deliberately exposes only four fixed operations
and whitelists every response field crossing the agent boundary.
"""

from __future__ import annotations

import importlib.util
import json
import time
from pathlib import Path
from typing import Any, Callable, Dict, Optional


CONNECTOR_PATH = Path(__file__).resolve().parents[1] / "gmail-connector" / "gmail.py"
_SPEC = importlib.util.spec_from_file_location("brain_agent_gmail_connector", CONNECTOR_PATH)
if _SPEC is None or _SPEC.loader is None:  # pragma: no cover - installation error
    raise RuntimeError("Brain Gmail connector is unavailable")
connector = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(connector)

MAX_ACCOUNT_CHARS = 320
AUTHORIZATION_SESSION_FILENAME = "gmail-authorization-session.json"
AUTHORIZATION_SESSION_STATES = {"pending", "denied", "expired"}


class GmailAPIError(RuntimeError):
    """A bounded error safe to serialize outside the remote runner."""

    def __init__(self, code: str, message: str) -> None:
        self.code = code
        super().__init__(message[:160])


def _required_text(payload: Dict[str, Any], name: str, maximum: int) -> str:
    value = payload.get(name)
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise GmailAPIError("invalid_request", "Gmail authorization request is invalid")
    return value.strip()


def _optional_text(payload: Dict[str, Any], name: str, maximum: int) -> str:
    value = payload.get(name, "")
    if value is None:
        return ""
    if not isinstance(value, str) or len(value) > maximum:
        raise GmailAPIError("invalid_request", "Gmail authorization request is invalid")
    return value.strip()


def _only_fields(payload: Dict[str, Any], allowed: set[str]) -> None:
    if not isinstance(payload, dict) or any(key not in allowed for key in payload):
        raise GmailAPIError("invalid_request", "Gmail authorization request is invalid")


def _safe_connector_error(operation: str, error: RuntimeError) -> GmailAPIError:
    detail = str(error).lower()
    if "declined" in detail:
        return GmailAPIError("authorization_denied", "Google authorization was declined")
    if "expired" in detail:
        return GmailAPIError("authorization_expired", "Gmail authorization expired; start again")
    if "state" in detail or "redirect uri" in detail or "already been used" in detail or "transaction" in detail:
        return GmailAPIError("invalid_authorization", "Gmail authorization is invalid or already used")
    if operation == "start" and ("not connected" in detail or "credential" in detail or "oauth client" in detail):
        return GmailAPIError("configuration_required", "Server-side Gmail OAuth configuration is required")
    if operation == "complete":
        return GmailAPIError("token_exchange_failed", "Gmail authorization could not be completed")
    if operation == "disconnect":
        return GmailAPIError("disconnect_failed", "Gmail authorization could not be removed")
    return GmailAPIError("gmail_unavailable", "Gmail is temporarily unavailable")


def _authorization_session_path() -> Path:
    return connector.state_dir() / AUTHORIZATION_SESSION_FILENAME


def _write_authorization_session(status: str, expires_at: int = 0) -> None:
    if status not in AUTHORIZATION_SESSION_STATES:
        raise ValueError("invalid Gmail authorization session status")
    value: Dict[str, Any] = {"status": status}
    if status == "pending":
        value["expires_at"] = int(expires_at)
    connector.write_private_json(_authorization_session_path(), value)


def _clear_authorization_session() -> None:
    try:
        _authorization_session_path().unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise GmailAPIError("gmail_unavailable", "Gmail is temporarily unavailable") from exc


def _authorization_session(now: Optional[float] = None) -> Optional[str]:
    """Return only a public consent outcome; never expose state or PKCE data."""
    try:
        value = json.loads(_authorization_session_path().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return None
    if not isinstance(value, dict) or set(value) - {"status", "expires_at"}:
        return None
    status = value.get("status")
    if status not in AUTHORIZATION_SESSION_STATES:
        return None
    if status != "pending":
        return str(status)
    try:
        expires_at = int(value.get("expires_at", 0) or 0)
    except (TypeError, ValueError):
        return None
    current_time = time.time() if now is None else now
    if expires_at <= current_time:
        _write_authorization_session("expired")
        return "expired"
    return "pending"


def start(redirect_uri: str) -> Dict[str, Any]:
    """Start remote consent, returning only public ceremony data."""
    try:
        result = connector.authorize_start(redirect_uri)
    except RuntimeError as exc:
        raise _safe_connector_error("start", exc) from exc
    response = {
        "authorization_url": str(result.get("authorization_url", ""))[:4_096],
        "state": str(result.get("state", ""))[:256],
        "expires_at": int(result.get("expires_at", 0) or 0),
    }
    _write_authorization_session("pending", response["expires_at"])
    return response


def complete(redirect_uri: str, state: str, code: str = "", error: str = "") -> Dict[str, str]:
    """Relay a callback without reflecting its code or any resulting token."""
    try:
        connector.authorize_complete(redirect_uri, state, code=code, error=error)
    except RuntimeError as exc:
        safe_error = _safe_connector_error("complete", exc)
        if safe_error.code == "authorization_denied":
            _write_authorization_session("denied")
        elif safe_error.code == "authorization_expired":
            _write_authorization_session("expired")
        raise safe_error from exc
    _clear_authorization_session()
    return {"status": "connected", "scope": connector.SCOPE}


def status() -> Dict[str, str]:
    """Report a connection state without returning local credential material."""
    session = _authorization_session()
    if session in {"denied", "expired"}:
        return {"status": session}
    if session == "pending":
        return {"status": "disconnected"}
    if not connector.client_path().is_file() or not connector.token_path().is_file():
        return {"status": "disconnected"}
    try:
        connector.status(False)
        profile = connector.gmail_get("/profile")
    except RuntimeError:
        return {"status": "reconnect_required", "scope": connector.SCOPE}
    account = str(profile.get("emailAddress", "")).strip()[:MAX_ACCOUNT_CHARS]
    result = {"status": "connected", "scope": connector.SCOPE}
    if account:
        result["account"] = account
    return result


def disconnect() -> Dict[str, str]:
    """Revoke and remove the local authorization, returning no token data."""
    try:
        # Server-side client configuration belongs to the instance, not to a
        # particular grant, so hosted reconnect remains possible after this.
        connector.disconnect(preserve_client=True)
    except RuntimeError as exc:
        raise _safe_connector_error("disconnect", exc) from exc
    _clear_authorization_session()
    return {"status": "disconnected"}


def handle_start(payload: Dict[str, Any]) -> Dict[str, Any]:
    _only_fields(payload, {"redirect_uri"})
    return start(_required_text(payload, "redirect_uri", 2_048))


def handle_complete(payload: Dict[str, Any]) -> Dict[str, str]:
    _only_fields(payload, {"redirect_uri", "state", "code", "error"})
    redirect_uri = _required_text(payload, "redirect_uri", 2_048)
    state = _required_text(payload, "state", 256)
    code = _optional_text(payload, "code", 4_096)
    error = _optional_text(payload, "error", 256)
    if bool(code) == bool(error):
        raise GmailAPIError("invalid_request", "Gmail callback must contain one result")
    return complete(redirect_uri, state, code=code, error=error)


def handle_status(payload: Optional[Dict[str, Any]] = None) -> Dict[str, str]:
    value = {} if payload is None else payload
    _only_fields(value, set())
    return status()


def handle_disconnect(payload: Optional[Dict[str, Any]] = None) -> Dict[str, str]:
    value = {} if payload is None else payload
    _only_fields(value, set())
    return disconnect()


HANDLERS: Dict[str, Callable[[Dict[str, Any]], Dict[str, Any]]] = {
    "start": handle_start,
    "complete": handle_complete,
    "status": handle_status,
    "disconnect": handle_disconnect,
}
