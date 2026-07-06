"""Native macOS launcher for the firstmate cockpit.

Runs the FastAPI app on a local port in a background thread, then opens it in a
native WKWebView window via pywebview. Packaged into Firstmate.app by py2app
(see setup.py). Set FM_COCKPIT_NO_WINDOW=1 to start only the server (used to
verify the launch path headlessly).
"""

from __future__ import annotations

import os
import socket
import threading
import time

import uvicorn

from backend.app import app
from backend.config import config


class _Server(uvicorn.Server):
    """uvicorn Server that skips signal handlers so it can run off-main-thread."""

    def install_signal_handlers(self) -> None:  # noqa: D401
        pass


def _free_port(preferred: int) -> int:
    """Return the preferred port if free, else an OS-assigned free port."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", preferred))
        port = preferred
    except OSError:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    finally:
        s.close()
    return port


def _start_server(port: int) -> _Server:
    # Pin pure-Python loop/protocol so the packaged app doesn't depend on the
    # optional compiled extras (uvloop / httptools) being bundled correctly.
    cfg = uvicorn.Config(
        app, host="127.0.0.1", port=port, log_level="warning",
        loop="asyncio", http="h11", ws="websockets",
    )
    server = _Server(cfg)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    # wait until it's actually accepting connections
    for _ in range(200):
        if server.started:
            break
        time.sleep(0.05)
    return server


def main() -> None:
    port = _free_port(config.port)
    server = _start_server(port)
    url = f"http://127.0.0.1:{port}/"

    if os.environ.get("FM_COCKPIT_NO_WINDOW") == "1":
        # headless verification: prove the server is up, then exit cleanly.
        print(f"server up at {url} (started={server.started})")
        return

    import webview

    webview.create_window(
        "Firstmate Cockpit",
        url,
        width=1440,
        height=900,
        min_size=(920, 620),
        maximized=True,   # start maximized so the terminal has full space
    )
    webview.start()  # blocks until the window closes
    server.should_exit = True


if __name__ == "__main__":
    main()
