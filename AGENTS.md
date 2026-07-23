# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Runtime

- Needs Python 3.11+ (see `pyproject.toml`). The system `python3` on this Mac is 3.9, which cannot evaluate the `str | None` annotations in the pydantic models and fails at import. Build the venv with `python3.12`: `python3.12 -m venv .venv`.
- Dev server: `.venv/bin/python -m uvicorn backend.app:app --host 127.0.0.1 --port 8766`. Native app: `desktop.py` (pywebview); `FM_COCKPIT_NO_WINDOW=1` starts the server only, prints readiness, then exits.

## Auth

- Sign-in is file-based (`backend/auth.py`): a plaintext `~/.firstmate-cockpit/credentials` (path overridable via `FM_CREDENTIALS_FILE`), created with defaults on first run. Sessions are signed with a persistent key using stdlib `hmac` only - deliberately no `itsdangerous`/JWT dep so the py2app bundle stays simple.
- All `/api/*` (except login/logout/auth-status/health) and both websockets are gated by a signed cookie. `/` and `/static/*` stay public so the page can serve the login screen and handle 401s itself.

## Terminal (xterm.js over tmux)

- The live terminal attaches to a per-connection *grouped* tmux mirror (`backend/terminal.py`). The group name carries a per-connection suffix (`cockpit_<session>_<pid>_<hex>`) so two cockpit instances don't fight over one shared mirror and kill each other's attach (that showed up as a dead `[exited]` frame). When the inner tmux client exits, the bridge closes the socket so the frontend auto-reconnects.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
