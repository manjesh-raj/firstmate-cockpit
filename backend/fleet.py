"""Parse a firstmate home's files + state into a single fleet model.

Everything here is read-only. The source of truth is firstmate's own on-disk
state; we never cache authoritative data or write back. Current task state comes
from ``fm-crew-state.sh`` (not a tail of the append-only status log, which can be
stale - see the script's own header).
"""

from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from . import scripts
from .config import config


# --- small file helpers ------------------------------------------------------

def _read(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except (FileNotFoundError, IsADirectoryError, OSError):
        return None


# --- projects ----------------------------------------------------------------

_PROJECT_RE = re.compile(
    r"^-\s+(?P<name>\S+)\s+\[(?P<mode>[^\]]+)\]\s+-\s+(?P<desc>.*?)(?:\s+\(added\s+(?P<added>[^)]+)\))?\s*$"
)


def parse_projects() -> List[Dict[str, Any]]:
    text = _read(config.data / "projects.md")
    if not text:
        return []
    out: List[Dict[str, Any]] = []
    for line in text.splitlines():
        m = _PROJECT_RE.match(line.strip())
        if not m:
            continue
        mode = m.group("mode")
        yolo = "+yolo" in mode
        out.append(
            {
                "name": m.group("name"),
                "mode": mode.replace("+yolo", "").strip(),
                "yolo": yolo,
                "desc": m.group("desc").strip(),
                "added": (m.group("added") or "").strip(),
            }
        )
    return out


# --- backlog -----------------------------------------------------------------

_SECTION_RE = re.compile(r"^##\s+(.*?)\s*$")
_ITEM_RE = re.compile(r"^-\s+\[(?P<check>[ xX])\]\s+(?P<body>.*)$")
_URL_RE = re.compile(r"https?://\S+")
_PAREN_RE = re.compile(r"\((\w+):\s*([^)]*)\)")


def parse_backlog() -> Dict[str, List[Dict[str, Any]]]:
    text = _read(config.data / "backlog.md")
    result: Dict[str, List[Dict[str, Any]]] = {"in_flight": [], "queued": [], "done": []}
    if not text:
        return result

    section_key = None
    for line in text.splitlines():
        sm = _SECTION_RE.match(line)
        if sm:
            title = sm.group(1).lower()
            if "flight" in title:
                section_key = "in_flight"
            elif "queue" in title:
                section_key = "queued"
            elif "done" in title:
                section_key = "done"
            else:
                section_key = None
            continue

        im = _ITEM_RE.match(line.strip())
        if not im or section_key is None:
            continue

        body = im.group("body")
        url_m = _URL_RE.search(body)
        tags = {k.lower(): v.strip() for k, v in _PAREN_RE.findall(body)}
        # The id is the first whitespace token; desc is up to the url / first tag.
        first_tok = body.split(" ", 1)[0]
        desc = body
        if url_m:
            desc = body[: url_m.start()].strip()
        else:
            paren = body.find(" (")
            if paren != -1:
                desc = body[:paren].strip()
        # Strip a leading "id - " off the description if present.
        if desc.startswith(first_tok):
            desc = desc[len(first_tok):].lstrip(" -")

        result[section_key].append(
            {
                "id": first_tok,
                "checked": im.group("check").lower() == "x",
                "desc": desc.strip(),
                "url": url_m.group(0) if url_m else None,
                "repo": tags.get("repo"),
                "kind": tags.get("kind"),
            }
        )
    return result


# --- tasks (from state/*.meta + live crew-state) -----------------------------

def _parse_meta(path: Path) -> Dict[str, str]:
    meta: Dict[str, str] = {}
    text = _read(path)
    if not text:
        return meta
    for line in text.splitlines():
        if "=" in line and not line.startswith("#"):
            k, _, v = line.partition("=")
            meta[k.strip()] = v.strip()
    return meta


def _classify(state: str) -> str:
    """Map a crew-state verb to a coarse status bucket for the UI."""
    return {
        "working": "working",
        "parked": "needs_decision",
        "done": "done",
        "blocked": "blocked",
        "failed": "failed",
    }.get(state, "unknown")


def parse_tasks(live: bool = True) -> List[Dict[str, Any]]:
    """Enumerate tasks from state/*.meta. When ``live`` also read current state."""
    tasks: List[Dict[str, Any]] = []
    state_dir = config.state
    if not state_dir.is_dir():
        return tasks

    for meta_path in sorted(state_dir.glob("*.meta")):
        task_id = meta_path.stem
        meta = _parse_meta(meta_path)
        task: Dict[str, Any] = {
            "id": task_id,
            "kind": meta.get("kind", "ship"),
            "repo": meta.get("repo"),
            "worktree": meta.get("worktree"),
            "window": meta.get("window"),
            "backend": meta.get("backend", "tmux"),
            "harness": meta.get("harness"),
            "pr": meta.get("pr"),
            "state": "unknown",
            "source": "none",
            "detail": "",
            "status": "unknown",
        }
        if live:
            res = scripts.crew_state(task_id)
            parsed = _parse_crew_state_line(res.stdout.strip())
            task.update(parsed)
            task["status"] = _classify(task["state"])
        tasks.append(task)
    return tasks


_CREW_LINE_RE = re.compile(
    r"state:\s*(?P<state>\S+)\s*·\s*source:\s*(?P<source>\S+)(?:\s*·\s*(?P<detail>.*))?"
)


def _parse_crew_state_line(line: str) -> Dict[str, str]:
    m = _CREW_LINE_RE.search(line)
    if not m:
        return {"state": "unknown", "source": "none", "detail": line}
    return {
        "state": m.group("state"),
        "source": m.group("source"),
        "detail": (m.group("detail") or "").strip(),
    }


# --- context docs + watcher health ------------------------------------------

def parse_context() -> Dict[str, Any]:
    def doc(name: str) -> Dict[str, Any]:
        text = _read(config.data / name)
        return {"present": text is not None, "content": text or ""}

    return {
        "captain": doc("captain.md"),
        "learnings": doc("learnings.md"),
        "secondmates": doc("secondmates.md"),
    }


def watcher_health() -> Dict[str, Any]:
    """Best-effort read of watcher liveness and the session lock."""
    state_dir = config.state
    lock = state_dir / ".watch.lock"
    beat = state_dir / ".last-watcher-beat"
    session_lock = state_dir / ".lock"

    lock_present = lock.exists() or lock.is_symlink()
    last_beat_age: Optional[float] = None
    if beat.exists():
        last_beat_age = round(time.time() - beat.stat().st_mtime, 1)

    # The lock file lingers after a watcher dies, so lock presence alone is not
    # liveness. A watcher is "healthy" only if its heartbeat is recent; a present
    # lock with a stale/absent beat is "stale" (likely dead), and no lock is
    # "off". Threshold is generous relative to the watcher's own poll cadence.
    fresh_secs = 180.0
    if lock_present and last_beat_age is not None and last_beat_age <= fresh_secs:
        status = "healthy"
    elif lock_present:
        status = "stale"
    else:
        status = "off"

    return {
        "status": status,
        "watcher_present": lock_present,
        "last_beat_age_secs": last_beat_age,
        "session_lock_present": session_lock.exists(),
    }


def scout_report(task_id: str) -> Optional[str]:
    return _read(config.data / task_id / "report.md")


# --- first-mate console parsing (best-effort) --------------------------------

# A prompt caret marks a captain input line.
_COMPOSER_RE = re.compile(r"^\s*(>|❯|›)\s?")
# Pure border / rule lines (box drawing, separators).
_BORDER_RE = re.compile(r"^[\s│─╭╮╰╯┃━┏┓┗┛▔▁▐▛▜▙▟█▘▝·•╌╍]+$")
# The assistant response marker Claude's TUI puts before a reply.
_REPLY_MARKER_RE = re.compile(r"^\s*⏺\s?")

# Substrings that mark a line as TUI chrome, not conversation. Matched
# case-insensitively. Best-effort: tuned to Claude Code's TUI.
_CHROME_SUBSTR = (
    "for shortcuts", "for agents", "to interrupt", "ctrl+", "tab to amend",
    "to explain", "esc to", "image in clipboard",
    "mcp server", "run /mcp", "claude code v", "opus 4", "haiku 4", "sonnet 4",
    "fable 5", "usage limit", "draws down", "learn more", "· claude team",
    "cooked for", "worked for", "crunched for", "spelunking", "thinking with",
    "esc to interrupt", "do you want to proceed", "requires approval",
    "yes, and don",
    # Claude Code's periodic session-feedback survey.
    "how is claude doing", "how's claude doing", "0: dismiss", "1: bad",
)
# Lines starting with these are spinners / tool-output / art → drop.
_CHROME_PREFIX = ("✻", "✳", "⎿", "⏵", "$", "⚠", "▎")


def _is_chrome(s: str) -> bool:
    if _BORDER_RE.match(s):
        return True
    if s[:1] in _CHROME_PREFIX:
        return True
    low = s.lower()
    return any(sub in low for sub in _CHROME_SUBSTR)


def clean_pane(raw: str) -> str:
    """A readable scrollback: the raw pane with UI chrome removed, line structure
    kept. Drops banners, spinners, tool output, the feedback survey, box borders,
    the empty composer box, and footer hints - but keeps prompts and replies with
    their original line breaks and indentation. Collapses runs of blank lines.
    """
    if not raw:
        return ""
    out: List[str] = []
    for line in raw.splitlines():
        s = line.rstrip()
        st = s.strip()
        if not st:
            if out and out[-1] == "":
                continue
            out.append("")
            continue
        if _is_chrome(st):
            continue
        # drop the empty composer caret line (the live input box)
        if _COMPOSER_RE.match(st) and not _COMPOSER_RE.sub("", st).strip():
            continue
        out.append(s)
    while out and out[0] == "":
        out.pop(0)
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out)


# --- transcript accumulation (works around the alternate-screen limit) --------
#
# Claude Code's TUI runs in the terminal alternate screen, so tmux keeps NO
# scrollback - each capture is only the current screen (~35 lines). To give the
# cockpit real, scrollable history we stitch successive screen snapshots: each
# poll overlaps the previous one, so we find the overlap and append only the new
# tail. Caret/selection markers are ignored when matching so a moving menu
# highlight doesn't duplicate a block.


def _norm_line(s: str) -> str:
    return re.sub(r"^\s*[>❯›]\s?", "", s).strip()


class _PaneTranscript:
    def __init__(self) -> None:
        self.lines: List[str] = []

    def update(self, new_lines: List[str]) -> None:
        if not new_lines:
            return
        if not self.lines:
            self.lines = list(new_lines)
            return
        a = [_norm_line(x) for x in self.lines]
        b = [_norm_line(x) for x in new_lines]
        max_k = min(len(a), len(b))
        best = 0
        for k in range(max_k, 0, -1):
            if a[-k:] == b[:k]:
                best = k
                break
        if best > 0:
            self.lines.extend(new_lines[best:])
        elif b != a[-len(b):]:
            # window jumped with no overlap and isn't already our tail: append.
            if self.lines and self.lines[-1] != "":
                self.lines.append("")
            self.lines.extend(new_lines)
        if len(self.lines) > 4000:
            self.lines = self.lines[-4000:]

    def text(self) -> str:
        out = self.lines[:]
        while out and out[0] == "":
            out.pop(0)
        while out and out[-1] == "":
            out.pop()
        return "\n".join(out)


_accumulators: Dict[str, _PaneTranscript] = {}


def accumulate(target: str, cleaned: str) -> str:
    """Merge a cleaned screen snapshot into the running transcript for a target."""
    acc = _accumulators.get(target)
    if acc is None:
        acc = _PaneTranscript()
        _accumulators[target] = acc
    acc.update(cleaned.splitlines())
    return acc.text()


def reset_transcript(target: str) -> None:
    _accumulators.pop(target, None)


def parse_console(raw: str) -> List[Dict[str, str]]:
    """Turn a captured first-mate pane into rough speaker turns (best-effort).

    A real Claude/codex TUI pane is noisy - banners, spinners, tool output, box
    drawing, and a live composer box - so the faithful view is always the raw
    pane. Here we: drop TUI chrome, drop the *live composer draft* (the last
    prompt line, which is unsent text still being typed), treat prompt lines as
    captain turns and everything else as first-mate output, and merge
    consecutive same-speaker lines.
    """
    if not raw:
        return []

    # 1. keep only conversation-bearing lines
    cleaned: List[str] = []
    for line in raw.splitlines():
        s = line.strip()
        if not s or _is_chrome(s):
            continue
        cleaned.append(s)

    # 2. drop the live composer draft: the LAST prompt line is unsent text in
    #    the input box, not a message the captain actually sent.
    last_prompt = -1
    for i, s in enumerate(cleaned):
        if _COMPOSER_RE.match(s):
            last_prompt = i
    if last_prompt != -1:
        cleaned.pop(last_prompt)

    # 3. build speaker turns
    messages: List[Dict[str, str]] = []

    def push(who: str, parts: List[str]) -> None:
        text = " ".join(parts).strip()
        if text:
            messages.append({"who": who, "text": text})

    cur_who = "mate"
    buf: List[str] = []
    for s in cleaned:
        if _COMPOSER_RE.match(s):
            push(cur_who, buf)
            buf = [_COMPOSER_RE.sub("", s)]
            cur_who = "captain"
            continue
        if cur_who == "captain":
            push(cur_who, buf)
            buf = []
            cur_who = "mate"
        buf.append(_REPLY_MARKER_RE.sub("", s))
    push(cur_who, buf)
    return messages


# --- top-level snapshot ------------------------------------------------------

def snapshot(live: bool = True) -> Dict[str, Any]:
    projects = parse_projects()
    backlog = parse_backlog()
    tasks = parse_tasks(live=live)
    active = [t for t in tasks if t["status"] in ("working", "needs_decision", "blocked")]
    needs_you = [t for t in tasks if t["status"] in ("needs_decision", "blocked")]
    return {
        "home": str(config.fm_home),
        "home_ok": config.home_ok(),
        "captain": config.captain,
        "firstmate_target": config.firstmate_target or None,
        "generated_at": round(time.time(), 1),
        "projects": projects,
        "backlog": backlog,
        "tasks": tasks,
        "counts": {
            "projects": len(projects),
            "tasks": len(tasks),
            "active": len(active),
            "needs_you": len(needs_you),
            "pr_ready": len([t for t in tasks if t.get("pr")]),
            "queued": len(backlog["queued"]),
            "done": len(backlog["done"]),
        },
        "context": parse_context(),
        "watcher": watcher_health(),
    }
