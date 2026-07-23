"""Embed the first mate's tmux session as a real terminal over a WebSocket.

Instead of scraping the pane, we attach a live tmux client inside a PTY and
bridge its bytes to xterm.js in the browser. Everything - scrollback, arrow
menus, selection - behaves exactly like the terminal, because it *is* one.

To avoid resizing the captain's real terminal, we attach to a *grouped* session
(shares the same windows, independent size/active-window) and tear it down on
disconnect.
"""

from __future__ import annotations

import asyncio
import contextlib
import fcntl
import json
import os
import pty
import re
import secrets
import signal
import struct
import subprocess
import termios

from fastapi import WebSocket, WebSocketDisconnect

from .config import config
from .scripts import _child_env


def _split_target(target: str):
    """'firstmate:1.1' -> ('firstmate', '1'). Window optional."""
    session = target.split(":", 1)[0]
    window = None
    if ":" in target:
        rest = target.split(":", 1)[1]
        window = rest.split(".", 1)[0] or None
    return session, window


def _tmux(env, *args, timeout=6):
    return subprocess.run(["tmux", *args], env=env, capture_output=True, text=True, timeout=timeout)


def _group_name(session: str, suffix: str = "") -> str:
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", session)
    # A per-connection suffix keeps two cockpit instances (or two windows) from
    # fighting over one shared mirror session and killing each other's attach.
    tag = f"_{suffix}" if suffix else ""
    return f"cockpit_{safe}{tag}"


def _setup_group(env, session: str, window, suffix: str = ""):
    """Create a grouped session mirroring `session`, focused on `window`."""
    group = _group_name(session, suffix)
    _tmux(env, "kill-session", "-t", group)  # clear any stale one (ignore errors)
    r = _tmux(env, "new-session", "-d", "-s", group, "-t", session)
    if r.returncode != 0:
        return None, (r.stderr.strip() or "could not create grouped session")
    if window:
        _tmux(env, "select-window", "-t", f"{group}:{window}")
    # this view's size follows its own client (not the smallest attached)
    _tmux(env, "set-option", "-t", group, "window-size", "latest")
    # hide tmux's own status bar in the embedded view - show just Claude Code.
    # (per-session option; the captain's real session is unaffected.)
    _tmux(env, "set-option", "-t", group, "status", "off")
    return group, None


def _teardown_group(env, group: str):
    try:
        _tmux(env, "kill-session", "-t", group)
    except Exception:
        pass


def _set_winsize(fd: int, rows: int, cols: int):
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except Exception:
        pass


async def terminal_bridge(ws: WebSocket):
    await ws.accept()
    target = config.firstmate_target
    if not target:
        await ws.send_text(json.dumps({"type": "fatal", "msg": "No first-mate target configured."}))
        await ws.close()
        return

    env = _child_env()
    env["TERM"] = "xterm-256color"
    env.pop("TMUX", None)  # ensure the client isn't treated as nested

    session, window = _split_target(target)
    suffix = f"{os.getpid()}_{secrets.token_hex(2)}"
    group, err = await asyncio.to_thread(_setup_group, env, session, window, suffix)
    if not group:
        await ws.send_text(json.dumps({"type": "fatal", "msg": err or "tmux setup failed"}))
        await ws.close()
        return

    # fork a PTY running `tmux attach` to the grouped session
    pid, fd = pty.fork()
    if pid == 0:  # child
        try:
            os.execvpe("tmux", ["tmux", "attach-session", "-t", group], env)
        except Exception:
            os._exit(1)

    loop = asyncio.get_event_loop()

    async def pump_out():
        try:
            while True:
                data = await loop.run_in_executor(None, os.read, fd, 65536)
                if not data:
                    break
                await ws.send_bytes(data)
        except Exception:
            pass
        # The tmux client exited (EOF on the PTY) - e.g. the grouped session was
        # killed out from under us. Close the socket so the frontend's auto-
        # reconnect gets a fresh attach instead of showing a dead "[exited]".
        with contextlib.suppress(Exception):
            await ws.close()

    out_task = asyncio.create_task(pump_out())
    try:
        while True:
            msg = await ws.receive()
            if msg.get("type") == "websocket.disconnect":
                break
            b = msg.get("bytes")
            if b is not None:
                os.write(fd, b)               # keystrokes
                continue
            t = msg.get("text")
            if t:
                try:
                    ctrl = json.loads(t)
                    if ctrl.get("type") == "resize":
                        _set_winsize(fd, int(ctrl["rows"]), int(ctrl["cols"]))
                except (ValueError, KeyError, TypeError):
                    os.write(fd, t.encode())  # fallback: treat as input
    except WebSocketDisconnect:
        pass
    except Exception:
        pass
    finally:
        out_task.cancel()
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
        try:
            os.close(fd)
        except Exception:
            pass
        await asyncio.to_thread(_teardown_group, env, group)
