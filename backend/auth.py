"""File-based sign-in + signed session cookies for the cockpit.

Sign-in is validated against a plaintext credentials file the operator owns and
edits (default ``~/.firstmate-cockpit/credentials``). This is a localhost-only
desktop app, so a local plaintext credentials file is acceptable and intended.

The credentials file format is two ``key = value`` lines::

    username = manjesh
    password = Welcome@123!

On first run the file is created with the defaults so the captain can edit it.

A successful login gets a signed session token (HMAC-SHA256 over the username +
issue time, using a random secret persisted next to the credentials). The token
is set as an httponly cookie and verified on every gated request; no dependency
beyond the standard library is used, which keeps the py2app bundle simple.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import secrets
import time
from typing import Optional

from .config import DEFAULT_PASSWORD, DEFAULT_USERNAME, config

SESSION_COOKIE = "fm_session"
# How long a session stays valid, in seconds (30 days).
SESSION_TTL = 30 * 24 * 3600


# --- credentials file --------------------------------------------------------

def _ensure_cred_file() -> None:
    """Create the credentials file with defaults if it does not exist."""
    path = config.cred_file
    if path.exists():
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f"username = {DEFAULT_USERNAME}\npassword = {DEFAULT_PASSWORD}\n",
            encoding="utf-8",
        )
        # The file holds a plaintext password; keep it owner-only.
        os.chmod(path, 0o600)
    except OSError:
        pass  # if we can't write it, load_credentials falls back to defaults


def load_credentials() -> dict:
    """Read {username, password} from the credentials file.

    Creates the file with defaults on first call. Falls back to the built-in
    defaults if the file is missing a field or cannot be read.
    """
    _ensure_cred_file()
    creds = {"username": DEFAULT_USERNAME, "password": DEFAULT_PASSWORD}
    try:
        text = config.cred_file.read_text(encoding="utf-8")
    except OSError:
        return creds
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip().lower()
        if key in ("username", "password"):
            creds[key] = value.strip()
    return creds


def validate(username: str, password: str) -> bool:
    """True only when BOTH username and password match the credentials file."""
    creds = load_credentials()
    user_ok = hmac.compare_digest(username or "", creds["username"])
    pass_ok = hmac.compare_digest(password or "", creds["password"])
    return user_ok and pass_ok


# --- session signing ---------------------------------------------------------

def _secret() -> bytes:
    """Load (or create) the persistent session-signing secret."""
    path = config.session_key_file
    try:
        raw = path.read_bytes()
        if len(raw) >= 32:
            return raw
    except OSError:
        pass
    key = secrets.token_bytes(32)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(key)
        os.chmod(path, 0o600)
    except OSError:
        pass  # in-memory key still works for this process
    return key


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _unb64(text: str) -> bytes:
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def make_token(username: str) -> str:
    """Mint a signed session token for ``username``."""
    payload = f"{username}|{int(time.time())}".encode("utf-8")
    sig = hmac.new(_secret(), payload, hashlib.sha256).digest()
    return f"{_b64(payload)}.{_b64(sig)}"


def verify_token(token: Optional[str]) -> Optional[str]:
    """Return the username if ``token`` is a valid, unexpired session, else None."""
    if not token or "." not in token:
        return None
    payload_b64, _, sig_b64 = token.partition(".")
    try:
        payload = _unb64(payload_b64)
        sig = _unb64(sig_b64)
    except (ValueError, TypeError):
        return None
    expected = hmac.new(_secret(), payload, hashlib.sha256).digest()
    if not hmac.compare_digest(sig, expected):
        return None
    try:
        username, _, issued = payload.decode("utf-8").partition("|")
        if time.time() - int(issued) > SESSION_TTL:
            return None
    except (ValueError, UnicodeDecodeError):
        return None
    return username or None


def is_authenticated(cookies: dict) -> bool:
    """True if the request carries a valid session cookie."""
    return verify_token(cookies.get(SESSION_COOKIE)) is not None
