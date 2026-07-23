"""Configuration + firstmate-home discovery.

The cockpit is a read-mostly companion to a firstmate home. It never writes into
that home; it only reads its files and shells out to its ``bin/`` scripts. All
settings can be overridden via environment variables so the packaged app can
point at wherever the user keeps firstmate.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

# App settings persist here (never inside the firstmate home).
APP_CONFIG_DIR = Path.home() / "Library" / "Application Support" / "firstmate-cockpit"
CONFIG_FILE = APP_CONFIG_DIR / "config.json"

# Sign-in credentials + the session-signing key live in a directory the operator
# owns and can edit by hand. This is a localhost-only desktop app, so a plaintext
# local credentials file is acceptable and intended.
DEFAULT_CRED_DIR = Path.home() / ".firstmate-cockpit"
DEFAULT_USERNAME = "manjesh"
DEFAULT_PASSWORD = "Welcome@123!"


def _load_saved() -> dict:
    try:
        return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, ValueError, OSError):
        return {}


def _find_fm_home() -> Path:
    """Locate the firstmate home.

    Priority: FM_HOME env var, then a couple of conventional locations, then a
    best-effort default. We only *read* this directory.
    """
    env = os.environ.get("FM_HOME") or os.environ.get("FIRSTMATE_HOME")
    if env:
        return Path(env).expanduser().resolve()

    candidates = [
        Path.home() / "manjesh" / "firstmate",
        Path.home() / "firstmate",
    ]
    for c in candidates:
        if (c / "AGENTS.md").exists() or (c / "bin" / "fm-crew-state.sh").exists():
            return c.resolve()
    # Fall back to the first candidate; callers surface a clear error if missing.
    return candidates[0].resolve()


class Config:
    def __init__(self) -> None:
        self.fm_home: Path = _find_fm_home()
        # tmux target of the *first mate* session (the interactive agent you
        # normally talk to). Used by control endpoints to type into its pane.
        # Example: "firstmate:0" or "main:0.0". Empty => control-to-firstmate
        # is disabled with a clear message until configured.
        # tmux target of the first mate. Env var wins (explicit override), else
        # the value saved from the in-app Settings panel.
        saved = _load_saved()
        self.firstmate_target: str = os.environ.get("FIRSTMATE_TARGET") or saved.get("firstmate_target", "")
        # The captain's display name, shown in the app.
        self.captain: str = os.environ.get("FM_CAPTAIN", "Manjesh")
        # Live-poll cadence for the WebSocket fleet push, in seconds.
        self.poll_interval: float = float(os.environ.get("FM_POLL_INTERVAL", "3"))
        # Host/port the FastAPI sidecar binds to.
        self.host: str = os.environ.get("FM_COCKPIT_HOST", "127.0.0.1")
        self.port: int = int(os.environ.get("FM_COCKPIT_PORT", "8765"))
        # Timeout for any single fm-* script invocation, in seconds.
        self.script_timeout: float = float(os.environ.get("FM_SCRIPT_TIMEOUT", "20"))
        # Where sign-in credentials live. A plain file the operator owns; the
        # default location is created with defaults on first run (see auth.py).
        cred_env = os.environ.get("FM_CREDENTIALS_FILE")
        self.cred_file: Path = (
            Path(cred_env).expanduser() if cred_env else DEFAULT_CRED_DIR / "credentials"
        )
        # The session-signing secret persists next to the credentials so signed
        # cookies survive an app restart.
        self.session_key_file: Path = self.cred_file.parent / "session.key"

    # --- convenience paths (all under fm_home) ---
    @property
    def bin(self) -> Path:
        return self.fm_home / "bin"

    @property
    def data(self) -> Path:
        return self.fm_home / "data"

    @property
    def state(self) -> Path:
        return self.fm_home / "state"

    def home_ok(self) -> bool:
        return (self.bin / "fm-crew-state.sh").exists()

    def set_firstmate_target(self, target: str) -> None:
        """Update the first-mate target at runtime and persist it."""
        self.firstmate_target = (target or "").strip()
        try:
            APP_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            data = _load_saved()
            data["firstmate_target"] = self.firstmate_target
            CONFIG_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")
        except OSError:
            pass  # in-memory update still applies for this session


config = Config()
