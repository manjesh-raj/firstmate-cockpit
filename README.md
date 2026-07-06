# firstmate-cockpit

A macOS cockpit to **observe and lightly control** a [firstmate](https://github.com/kunchenguid/firstmate) fleet.

You keep talking to your first mate as usual (in tmux); this gives you a live window onto the whole crew - who's working, what needs a decision, PRs ready to merge - plus a chat box that types to the first mate for you.

- **Brains:** Python / FastAPI (this repo). Reads the firstmate home's files and shells out to its `bin/` scripts.
- **Shell (planned, Phase 3):** Tauri wraps the FastAPI app into a real `Firstmate.app` with a dock icon and native notifications.
- **firstmate is never modified.** The cockpit only reads it and calls its own guarded helpers (`fm-send.sh`, `fm-pr-merge.sh`).

## Status

- [x] **Phase 1 - backend core.** File/state parsing, script wrappers, FastAPI + WebSocket, a live dashboard page.
- [x] **Phase 2 - dashboard UI.** Custom light/dark themes, captain identity, stat tiles, fleet board, First Mate Console (Raw pane + Conversation), empty states.
- [x] **Phase 3 - native app** → `Firstmate.app` (pywebview + py2app; no Rust).

## Build Firstmate.app

```sh
./build_app.sh            # standalone build → dist/Firstmate.app
./build_app.sh --alias    # fast dev build (runs from source, not distributable)
open dist/Firstmate.app
```

The app runs the FastAPI server on a local port in a background thread and hosts
it in a native WKWebView window. It auto-detects the firstmate home (or honors
`FM_HOME`). To enable the console/chat, launch it with `FIRSTMATE_TARGET` set, or
configure it in-app later.

### py2app notes (gotchas already handled)
- `build_app.sh` hides `pyproject.toml` during the build - py2app 0.28 aborts if the
  distribution has `install_requires` (which `[project].dependencies` populates).
- Needs `setuptools<80` (py2app 0.28 uses APIs removed in newer setuptools).
- `anyio._backends._asyncio` is force-included - anyio loads it dynamically, so
  static analysis misses it and sync endpoints would 500 at runtime.

## Run (development)

```sh
cd ~/manjesh/firstmate-cockpit
python3.12 -m venv .venv
.venv/bin/pip install -e .          # or: pip install fastapi 'uvicorn[standard]' websockets
.venv/bin/python -m uvicorn backend.app:app --host 127.0.0.1 --port 8765
```

Then open http://127.0.0.1:8765/

## Configuration (environment variables)

| Var | Default | Purpose |
|-----|---------|---------|
| `FM_HOME` | auto-detected (`~/manjesh/firstmate`) | The firstmate home to observe. |
| `FIRSTMATE_TARGET` | *(unset)* | tmux target of your first-mate pane, e.g. `firstmate:0`. Required for the chat box to send. Find it with `tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}'`. |
| `FM_POLL_INTERVAL` | `3` | Live-update cadence (seconds). |
| `FM_COCKPIT_HOST` / `FM_COCKPIT_PORT` | `127.0.0.1` / `8765` | Where the app binds. |
| `FM_SCRIPT_TIMEOUT` | `20` | Per-script timeout (seconds). |

## Connecting to your first mate

The chat/console needs a first mate running **inside tmux** (that's the only channel
firstmate's `fm-send.sh` can type into - a plain terminal or IDE session can't be reached).

1. Start it once:
   ```sh
   tmux new -s firstmate
   cd ~/manjesh/firstmate && claude
   ```
2. In the app, click the ⚙ gear → **Detect** → pick the pane flagged "✓ firstmate home"
   → **Save**. (Or set `FIRSTMATE_TARGET`, e.g. `firstmate:1.1`.) The choice persists to
   `~/Library/Application Support/firstmate-cockpit/config.json`.

Note: tmux window indexes depend on your `base-index` - it may be `firstmate:0` or
`firstmate:1.1`. Detect finds the real one, so you don't have to guess.

## How control works

There is one first mate: a live agent session in tmux. The cockpit does **not** contain an LLM. When you type in the chat box, it calls `fm-send.sh <FIRSTMATE_TARGET> "<your text>"`, which types into that same pane - exactly as if you'd typed in the terminal. You can use the terminal and the app interchangeably; they drive the same conversation. Sending is best-effort (`fm-send.sh` reports a swallowed Enter), and the UI surfaces failures instead of assuming success.

## API

| Endpoint | Type | Backed by |
|----------|------|-----------|
| `GET /api/health` | read | - |
| `GET /api/fleet` | read | files + `fm-crew-state.sh` |
| `GET /api/peek/{target}` | read | `fm-peek.sh` |
| `GET /api/firstmate/console` | read | `fm-peek.sh` on `FIRSTMATE_TARGET` (raw pane + best-effort parsed messages) |
| `GET /api/report/{id}` | read | `data/<id>/report.md` |
| `WS /ws/live` | read | poll loop |
| `WS /ws/terminal` | **interactive** | embeds the tmux session as a real terminal (xterm.js ↔ PTY `tmux attach`) |
| `GET /api/firstmate/console` | read | cleaned pane + stitched transcript |
| `POST /api/firstmate/key` | control | send a key to menus/prompts (`fm-send --key`) |
| `GET`/`POST` `/api/settings` · `GET /api/firstmate/detect` | read/control | first-mate target config + tmux auto-detect |
| `POST /api/send` | control | `fm-send.sh` |
| `POST /api/send-task/{id}` | control | `fm-send.sh fm-<id>` |
| `POST /api/merge` | control | `fm-pr-merge.sh` |

## Layout

```
backend/
  app.py        FastAPI endpoints + WebSocket
  fleet.py      parse data/ + state/ into the fleet model (read-only)
  scripts.py    safe, sandboxed wrappers for fm-* scripts
  config.py     home discovery + settings
  static/       the dashboard page
src-tauri/      (Phase 3) native shell
```
