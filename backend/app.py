"""FastAPI app: the brains of firstmate-cockpit.

Read endpoints expose the fleet model; a WebSocket pushes live snapshots; control
endpoints drive firstmate's own guarded helpers to type to the first mate, merge
a PR, or answer a parked task. The firstmate home is never modified here.
"""

from __future__ import annotations

import asyncio
import contextlib
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import fleet, scripts
from .config import config
from .terminal import terminal_bridge

app = FastAPI(title="firstmate-cockpit", version="0.1.0")

_STATIC = Path(__file__).parent / "static"


# --- read endpoints ----------------------------------------------------------

@app.get("/api/health")
def health():
    return {
        "ok": config.home_ok(),
        "home": str(config.fm_home),
        "firstmate_target_configured": bool(config.firstmate_target),
    }


@app.get("/api/fleet")
def get_fleet():
    return fleet.snapshot(live=True)


@app.get("/api/peek/{target}")
def get_peek(target: str, lines: int = 40):
    res = scripts.peek(target, lines=lines)
    return {"ok": res.ok, "output": res.stdout, "error": res.stderr}


@app.get("/api/firstmate/console")
def firstmate_console(lines: int = 80):
    """Read the first mate's pane and return it raw + best-effort parsed.

    The raw view is a faithful mirror of the tmux pane; the parsed
    ``messages`` are a heuristic rendering that still needs tuning against a
    real first-mate harness (see fleet.parse_console).
    """
    target = config.firstmate_target
    if not target:
        return {"ok": False, "configured": False, "error": "FIRSTMATE_TARGET not set"}
    res = scripts.peek(target, lines=lines)
    if not res.ok:
        return {"ok": False, "configured": True, "raw": res.stdout, "messages": [], "error": res.stderr}
    cleaned = fleet.clean_pane(res.stdout)          # current screen, chrome stripped
    history = fleet.accumulate(target, cleaned)     # stitched growing transcript
    return {
        "ok": True, "configured": True,
        "raw": history,                               # full scrollable history
        "screen": cleaned,                            # just the current screen
        "messages": fleet.parse_console(history),     # parsed over full history
    }


class KeyBody(BaseModel):
    key: str


# Keys the UI may send to the first mate's interactive menus / prompts.
_ALLOWED_KEYS = {
    "Up", "Down", "Left", "Right", "Enter", "Escape", "Space", "Tab",
    "BSpace", "y", "n",
    *[str(d) for d in range(10)],
}


@app.post("/api/firstmate/key")
def post_firstmate_key(body: KeyBody):
    """Send one key to the first mate (for menus / permission prompts)."""
    target = config.firstmate_target
    if not target:
        return JSONResponse({"ok": False, "error": "No first-mate target configured."}, status_code=409)
    key = (body.key or "").strip()
    if key not in _ALLOWED_KEYS:
        return JSONResponse({"ok": False, "error": f"key not allowed: {key}"}, status_code=400)
    res = scripts.send_key(target, key)
    return {"ok": res.ok, "error": res.stderr if not res.ok else None}


@app.get("/api/report/{task_id}")
def get_report(task_id: str):
    report = fleet.scout_report(task_id)
    if report is None:
        return JSONResponse({"ok": False, "error": "no report"}, status_code=404)
    return {"ok": True, "report": report}


# --- control endpoints -------------------------------------------------------

class SendBody(BaseModel):
    text: str
    # Optional explicit target; defaults to the configured first mate.
    target: str | None = None


class MergeBody(BaseModel):
    url: str


def _require_firstmate_target(target: str | None) -> str | None:
    resolved = target or config.firstmate_target
    return resolved or None


@app.post("/api/send")
def post_send(body: SendBody):
    """Type a line to the first mate (or an explicit target)."""
    target = _require_firstmate_target(body.target)
    if not target:
        return JSONResponse(
            {
                "ok": False,
                "error": (
                    "No first-mate target configured. Set FIRSTMATE_TARGET to the "
                    "tmux target of your first mate pane (e.g. 'firstmate:0')."
                ),
            },
            status_code=409,
        )
    text = body.text.strip()
    if not text:
        return JSONResponse({"ok": False, "error": "empty text"}, status_code=400)
    res = scripts.send(target, text)
    return {"ok": res.ok, "error": res.stderr if not res.ok else None}


@app.post("/api/send-task/{task_id}")
def post_send_task(task_id: str, body: SendBody):
    """Type a line to a specific crew task (fm-<id>)."""
    res = scripts.send(f"fm-{task_id}", body.text.strip())
    return {"ok": res.ok, "error": res.stderr if not res.ok else None}


@app.post("/api/merge")
def post_merge(body: MergeBody):
    res = scripts.merge_pr(body.url)
    return {"ok": res.ok, "output": res.stdout, "error": res.stderr if not res.ok else None}


# --- settings + first-mate detection -----------------------------------------

class SettingsBody(BaseModel):
    firstmate_target: str | None = None


@app.get("/api/settings")
def get_settings():
    return {
        "firstmate_target": config.firstmate_target,
        "captain": config.captain,
        "home": str(config.fm_home),
        "poll_interval": config.poll_interval,
    }


@app.post("/api/settings")
def save_settings(body: SettingsBody):
    config.set_firstmate_target(body.firstmate_target or "")
    return {"ok": True, "firstmate_target": config.firstmate_target}


@app.get("/api/firstmate/detect")
def detect_firstmate():
    """Scan tmux panes and rank first-mate candidates (home panes first)."""
    panes = scripts.tmux_panes()
    if panes is None:
        return {"ok": False, "error": "No tmux server running - start your first mate in tmux first.", "candidates": []}
    home = str(config.fm_home)
    cands = []
    for p in panes:
        path = p.get("path", "")
        is_home = path == home or path.startswith(home + "/")
        cands.append({**p, "is_home": is_home})
    # home panes first, then by target
    cands.sort(key=lambda c: (not c["is_home"], c["target"]))
    return {"ok": True, "candidates": cands}


# --- live websocket ----------------------------------------------------------

@app.websocket("/ws/terminal")
async def ws_terminal(ws: WebSocket):
    await terminal_bridge(ws)


@app.websocket("/ws/live")
async def ws_live(ws: WebSocket):
    await ws.accept()
    try:
        while True:
            # snapshot() shells out to fm-crew-state; run it off the event loop.
            snap = await asyncio.to_thread(fleet.snapshot, True)
            await ws.send_json(snap)
            await asyncio.sleep(config.poll_interval)
    except WebSocketDisconnect:
        return
    except Exception:
        with contextlib.suppress(Exception):
            await ws.close()


# --- static dashboard --------------------------------------------------------

@app.get("/")
def index():
    return FileResponse(str(_STATIC / "index.html"))


if _STATIC.is_dir():
    app.mount("/static", StaticFiles(directory=str(_STATIC)), name="static")
