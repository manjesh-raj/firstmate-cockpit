"""Safe wrappers around the firstmate ``bin/`` scripts.

Every call runs with ``cwd`` set to the firstmate home and ``FM_HOME`` exported,
uses an argument list (never ``shell=True``) so nothing the user types can be
interpreted by a shell, and is bounded by a timeout. Read wrappers are pure;
control wrappers (send/merge) are the only ones that can change fleet state, and
they only ever drive firstmate's own guarded helpers.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from typing import Optional

from .config import config


@dataclass
class ScriptResult:
    ok: bool
    stdout: str
    stderr: str
    code: int


def _run(script: str, *args: str, timeout: Optional[float] = None) -> ScriptResult:
    """Run bin/<script> with the given args. Returns captured output."""
    path = config.bin / script
    if not path.exists():
        return ScriptResult(False, "", f"script not found: {script}", 127)

    env = _child_env()
    try:
        proc = subprocess.run(
            ["bash", str(path), *args],
            cwd=str(config.fm_home),
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout or config.script_timeout,
        )
    except subprocess.TimeoutExpired:
        return ScriptResult(False, "", f"{script} timed out", 124)
    except Exception as exc:  # pragma: no cover - defensive
        return ScriptResult(False, "", f"{script} failed to launch: {exc}", 1)

    return ScriptResult(proc.returncode == 0, proc.stdout, proc.stderr, proc.returncode)


def _home():
    from pathlib import Path

    return Path.home()


def _child_env() -> dict:
    """Environment for fm-* / tmux subprocesses.

    Forces a UTF-8 locale: a GUI app launched via Finder/`open` inherits no
    LANG/LC_ALL, so children default to ASCII and captured pane output (box-
    drawing chars, ✻, ❯, …) fails to decode. This plus encoding='utf-8' on the
    read side keeps captures clean.
    """
    return {
        "PATH": _base_path(),
        "HOME": str(_home()),
        "FM_HOME": str(config.fm_home),
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "PYTHONUTF8": "1",
        "PYTHONIOENCODING": "utf-8",
    }


def _base_path() -> str:
    """A sensible PATH so scripts can find git, gh-axi, tmux, jq, etc."""
    import os

    parts = [
        str(_home() / ".nvm" / "versions" / "node" / "v22.23.1" / "bin"),
        str(_home() / ".local" / "bin"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]
    # Preserve anything already on PATH too.
    existing = os.environ.get("PATH", "")
    if existing:
        parts.append(existing)
    return ":".join(parts)


# --- read wrappers -----------------------------------------------------------

def crew_state(task_id: str) -> ScriptResult:
    """Authoritative current-state line for a task. Read-only."""
    return _run("fm-crew-state.sh", task_id, timeout=15)


def peek(target: str, lines: int = 40) -> ScriptResult:
    """Bounded tail of a crew (or first-mate) endpoint. Read-only."""
    return _run("fm-peek.sh", target, str(lines), timeout=15)


# --- control wrappers --------------------------------------------------------

def send(target: str, text: str) -> ScriptResult:
    """Type one line into a pane, then Enter. Exits non-zero on swallowed Enter."""
    return _run("fm-send.sh", target, text, timeout=25)


def merge_pr(pr_url: str) -> ScriptResult:
    """Merge a PR-ready task via firstmate's guarded helper."""
    return _run("fm-pr-merge.sh", pr_url, timeout=60)


def send_key(target: str, key: str) -> ScriptResult:
    """Send a single key (Up/Down/Enter/Escape/a digit) to a pane, no newline.

    For driving the first mate's interactive menus and permission prompts the
    way you would in the terminal.
    """
    return _run("fm-send.sh", target, "--key", key, timeout=15)


def tmux_panes():
    """List all tmux panes, or None if no tmux server is running.

    Used to auto-detect a first-mate pane for the Settings panel. Returns a list
    of {target, session, window, pane, command, path}.
    """
    env = _child_env()
    # Use an explicit multi-char delimiter (not \t, which can get mangled in
    # transit) that won't appear in a command name or path.
    sep = "|FM|"
    fields = [
        "#{session_name}", "#{window_index}", "#{pane_index}",
        "#{pane_current_command}", "#{pane_current_path}",
    ]
    fmt = sep.join(fields)
    try:
        proc = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", fmt],
            env=env, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=6,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, Exception):
        return None
    if proc.returncode != 0:
        return None  # no server / tmux not available
    panes = []
    for line in proc.stdout.splitlines():
        parts = line.split(sep)
        if len(parts) >= 5:
            s, w, p, cmd, path = parts[0], parts[1], parts[2], parts[3], parts[4]
            panes.append(
                {"target": f"{s}:{w}.{p}", "session": s, "window": w,
                 "pane": p, "command": cmd, "path": path}
            )
    return panes
