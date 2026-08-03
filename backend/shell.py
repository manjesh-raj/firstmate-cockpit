"""A real PTY shell over a WebSocket, streamed to the cockpit's xterm.js.

This is the sibling of ``backend/terminal.py``. The terminal bridge attaches a
tmux *mirror* of the first mate's session - great for watching the agent, but a
mirror repaints only the visible region, so xterm's scrollback stays empty and
the captain cannot scroll up. This bridge instead forks a genuine login shell
in a PTY and streams its bytes straight to xterm, so lines that scroll off the
top land in xterm's scrollback and stay there (real WezTerm-style scroll-up for
primary-screen content).

The byte pump, keystroke write, and ``TIOCSWINSZ`` resize handling are the same
pattern as ``terminal.py``; the only difference is what we exec (a shell, not
``tmux attach-session``) and that there is no grouped-session setup/teardown.

Note on image paste: because this and the mirror both forward the browser
paste as bytes to a PTY on the *same machine* as the running agent, an agent
run in this shell reads the shared macOS system clipboard for a pasted
screenshot exactly as it does in the mirror. Nothing extra is wired here.
"""

from __future__ import annotations

import asyncio
import contextlib
import fcntl
import json
import os
import pty
import signal
import struct
import termios
from pathlib import Path

from fastapi import WebSocket, WebSocketDisconnect

from .config import config
from .scripts import _child_env


def _set_winsize(fd: int, rows: int, cols: int):
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except Exception:
        pass


def _shell_argv() -> list[str]:
    """The operator's login shell (``$SHELL -l``), falling back to ``bash -i``."""
    shell = os.environ.get("SHELL")
    if shell and Path(shell).exists():
        return [shell, "-l"]
    return ["bash", "-i"]


def _shell_cwd() -> str:
    """Where the shell opens. FM_SHELL_CWD wins, else the firstmate home, else $HOME."""
    override = os.environ.get("FM_SHELL_CWD")
    if override:
        p = Path(override).expanduser()
        if p.is_dir():
            return str(p)
    if config.fm_home.is_dir():
        return str(config.fm_home)
    return str(Path.home())


async def shell_bridge(ws: WebSocket):
    await ws.accept()

    env = _child_env()
    env["TERM"] = "xterm-256color"
    env.pop("TMUX", None)  # a fresh shell, not nested under any tmux client

    argv = _shell_argv()
    cwd = _shell_cwd()

    pid, fd = pty.fork()
    if pid == 0:  # child
        try:
            os.chdir(cwd)
        except Exception:
            pass
        try:
            os.execvpe(argv[0], argv, env)
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
        # The shell exited (EOF on the PTY) - close the socket so the frontend's
        # auto-reconnect gets a fresh shell instead of a dead, silent terminal.
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
                os.write(fd, b)               # keystrokes / pasted text
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
