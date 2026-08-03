"""FastAPI app: the brains of firstmate-cockpit.

Read endpoints expose the fleet model; a WebSocket pushes live snapshots; control
endpoints drive firstmate's own guarded helpers to type to the first mate, merge
a PR, or answer a parked task. The firstmate home is never modified here.
"""

from __future__ import annotations

import asyncio
import contextlib
from pathlib import Path

from fastapi import FastAPI, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import auth, fleet, openprs, scripts
from .config import config
from .shell import shell_bridge
from .terminal import terminal_bridge

app = FastAPI(title="firstmate-cockpit", version="0.1.0")

_STATIC = Path(__file__).parent / "static"


# --- authentication gate -----------------------------------------------------
#
# Everything under /api (bar login/logout/status/health) requires a valid signed
# session cookie, so the auth is genuine rather than a frontend-only screen. The
# index page and static assets stay open - the page itself shows the login
# screen until /api/auth/status reports a session. Unauthenticated API calls get
# a 401, which the UI treats as "show the login screen".

_PUBLIC_PATHS = {
    "/",
    "/index.html",
    "/favicon.ico",
    "/api/login",
    "/api/logout",
    "/api/auth/status",
    "/api/health",
}


def _is_public(path: str) -> bool:
    if path in _PUBLIC_PATHS:
        return True
    return path.startswith("/static/")


@app.middleware("http")
async def require_session(request: Request, call_next):
    path = request.url.path
    if _is_public(path) or not path.startswith("/api/"):
        return await call_next(request)
    if not auth.is_authenticated(request.cookies):
        return JSONResponse({"ok": False, "error": "unauthenticated"}, status_code=401)
    return await call_next(request)


# --- auth endpoints ----------------------------------------------------------

class LoginBody(BaseModel):
    username: str
    password: str


@app.post("/api/login")
def post_login(body: LoginBody, response: Response):
    if not auth.validate(body.username, body.password):
        return JSONResponse(
            {"ok": False, "error": "That username or password doesn't match the credentials file."},
            status_code=401,
        )
    token = auth.make_token(body.username)
    response.set_cookie(
        auth.SESSION_COOKIE, token,
        max_age=auth.SESSION_TTL, httponly=True, samesite="lax", path="/",
    )
    return {"ok": True, "username": body.username}


@app.post("/api/logout")
def post_logout(response: Response):
    response.delete_cookie(auth.SESSION_COOKIE, path="/")
    return {"ok": True}


@app.get("/api/auth/status")
def auth_status(request: Request):
    token = request.cookies.get(auth.SESSION_COOKIE)
    username = auth.verify_token(token)
    creds = auth.load_credentials()
    return {
        "authenticated": username is not None,
        "username": username,
        "credentials_file": str(config.cred_file),
        "default_username": creds.get("username"),
    }


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


@app.get("/api/open-prs")
def get_open_prs():
    """Every OPEN, not-yet-merged PR across the operator's project clones.

    Returns a list of ``{repo, number, title, url, forge, checks, createdAt}``.
    Discovers repos by reading each ``$FM_HOME/projects/*`` clone's origin
    remote, then asks GitHub (via ``gh``) or Bitbucket (via the cached git
    credential). Aggregated result is cached ~60s; a repo that errors or has no
    usable remote/credential is skipped, never failing the whole call.
    """
    return openprs.open_prs()


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


def _scan_candidates():
    """Scan tmux panes, tag first-mate home panes, and rank home panes first.

    Returns (candidates, error). ``error`` is set (candidates empty) when no
    tmux server is reachable. A candidate carries: target, session, window,
    pane, command (runtime), path (cwd), and is_home.
    """
    panes = scripts.tmux_panes()
    if panes is None:
        return [], "No tmux server running - start your first mate in tmux first."
    home = str(config.fm_home)
    cands = []
    for p in panes:
        # Skip the internal mirror sessions the terminal bridge spins up
        # (see terminal._group_name); they are not real first-mate targets.
        if str(p.get("session", "")).startswith("cockpit_"):
            continue
        path = p.get("path", "")
        is_home = path == home or path.startswith(home + "/")
        cands.append({**p, "is_home": is_home})
    cands.sort(key=lambda c: (not c["is_home"], c["target"]))
    return cands, None


@app.get("/api/firstmate/detect")
def detect_firstmate():
    """Scan tmux panes and rank first-mate candidates (home panes first)."""
    cands, err = _scan_candidates()
    if err:
        return {"ok": False, "error": err, "candidates": []}
    return {"ok": True, "candidates": cands}


@app.get("/api/targets")
def get_targets():
    """List candidate first-mate sessions (tmux panes) for the target selector.

    Mirrors the "Detect" data in Settings → Connection: each candidate has a
    target id, its runtime/command, its cwd/path, and whether that path is a
    firstmate home. Also echoes the currently active target.
    """
    cands, err = _scan_candidates()
    if err:
        return {"ok": False, "error": err, "targets": [], "active": config.firstmate_target or None}
    return {"ok": True, "targets": cands, "active": config.firstmate_target or None}


# --- live websocket ----------------------------------------------------------

@app.websocket("/ws/terminal")
async def ws_terminal(ws: WebSocket):
    # Gate the live terminal behind the session so auth is genuine.
    if not auth.is_authenticated(ws.cookies):
        await ws.close(code=1008)  # policy violation
        return
    await terminal_bridge(ws)


@app.websocket("/ws/shell")
async def ws_shell(ws: WebSocket):
    # A real PTY shell (with true scrollback), behind the same session gate as
    # the mirror. Coexists with /ws/terminal; it does not replace it.
    if not auth.is_authenticated(ws.cookies):
        await ws.close(code=1008)  # policy violation
        return
    await shell_bridge(ws)


@app.websocket("/ws/live")
async def ws_live(ws: WebSocket):
    if not auth.is_authenticated(ws.cookies):
        await ws.close(code=1008)
        return
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
