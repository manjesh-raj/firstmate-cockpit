"""Discover every OPEN, not-yet-merged PR across the operator's project clones.

The dashboard's "Ready for your review" used to reflect only PRs tied to a
currently-tracked in-flight task, so a still-open PR vanished from the board the
moment its worker was cleaned up. This module fills that gap: it walks the
project clones under ``$FM_HOME/projects/*``, reads each clone's ``origin``
remote to learn its forge + owner/repo, and asks the forge for open PRs.

Everything here is read-only against the forges:

- GitHub uses the operator's already-authenticated ``gh`` CLI.
- Bitbucket uses the cached git credential for ``bitbucket.org`` (the same
  credential a ``git push`` authenticates with), read via ``git credential
  fill``. If no usable credential exists, that repo is skipped gracefully.

The aggregated result is cached for ~60s because the dashboard polls often; a
single repo that errors or has no usable remote is skipped, never failing the
whole endpoint. Each forge call is bounded by a short timeout.
"""

from __future__ import annotations

import base64
import json
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from . import scripts
from .config import config

# --- tunables ----------------------------------------------------------------

_TTL = 60.0            # cache lifetime for the aggregated result, seconds
_GH_TIMEOUT = 12.0     # per-repo `gh pr list` budget, seconds
_BB_TIMEOUT = 10.0     # per-repo Bitbucket API budget, seconds
_GIT_TIMEOUT = 6.0     # small git plumbing calls, seconds


# --- remote parsing ----------------------------------------------------------

# scp-like SSH form: git@github.com:owner/repo(.git)
_SCP_RE = re.compile(r"^[\w.+-]+@([\w.-]+):(.+)$")
# URL form: scheme://[user@]host[:port]/owner/repo(.git)
_URL_RE = re.compile(r"^\w+://(?:[^@/]+@)?([\w.-]+)(?::\d+)?/(.+)$")


def _parse_remote(url: str) -> Optional[Tuple[str, str, str]]:
    """Return ``(forge, owner, repo)`` for a github.com / bitbucket.org remote.

    Handles https (with or without a ``user@`` prefix) and both SSH forms.
    Returns ``None`` for anything else so unknown forges are skipped.
    """
    u = (url or "").strip()
    if not u:
        return None
    m = _SCP_RE.match(u)
    if m:
        host, path = m.group(1), m.group(2)
    else:
        m = _URL_RE.match(u)
        if not m:
            return None
        host, path = m.group(1), m.group(2)
    path = path.strip("/")
    if path.endswith(".git"):
        path = path[:-4]
    parts = [p for p in path.split("/") if p]
    if len(parts) < 2:
        return None
    owner, repo = parts[0], parts[1]
    host = host.lower()
    if host == "github.com" or host.endswith(".github.com"):
        forge = "github"
    elif host == "bitbucket.org" or host.endswith(".bitbucket.org"):
        forge = "bitbucket"
    else:
        return None
    return forge, owner, repo


# --- git plumbing ------------------------------------------------------------

def _git(*args: str, input_text: Optional[str] = None, timeout: float = _GIT_TIMEOUT):
    """Run a git command with the cockpit's child env. Returns the CompletedProcess
    or None on failure/timeout."""
    try:
        return subprocess.run(
            ["git", *args],
            input=input_text,
            env=scripts._child_env(),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None


def _origin_url(clone: Path) -> Optional[str]:
    proc = _git("-C", str(clone), "remote", "get-url", "origin")
    if proc is None or proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def _git_email() -> Optional[str]:
    proc = _git("config", "--global", "user.email")
    if proc is None or proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


# --- GitHub ------------------------------------------------------------------

_GH_FAIL = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE", "ERROR"}
_GH_OK = {"SUCCESS", "NEUTRAL", "SKIPPED"}


def _map_github_checks(rollup: Optional[List[Dict[str, Any]]]) -> str:
    """Collapse gh's ``statusCheckRollup`` to green | red | pending | none.

    The rollup mixes CheckRun entries (``status`` + ``conclusion``) and legacy
    StatusContext entries (``state``). Any failure wins, then any pending, then
    any success; an empty rollup means no checks are configured.
    """
    if not rollup:
        return "none"
    saw_fail = saw_pending = saw_success = False
    for c in rollup:
        status = (c.get("status") or "").upper()
        concl = (c.get("conclusion") or "").upper()
        state = (c.get("state") or "").upper()
        if state in _GH_FAIL or concl in _GH_FAIL:
            saw_fail = True
        elif state in ("PENDING", "EXPECTED") or (status and status != "COMPLETED"):
            saw_pending = True
        elif state == "SUCCESS" or concl in _GH_OK:
            saw_success = True
        else:
            # Unknown / in-between shape: treat conservatively as still running.
            saw_pending = True
    if saw_fail:
        return "red"
    if saw_pending:
        return "pending"
    if saw_success:
        return "green"
    return "none"


def _github_open_prs(owner: str, repo: str, repo_label: str) -> List[Dict[str, Any]]:
    try:
        proc = subprocess.run(
            [
                "gh", "pr", "list", "--repo", f"{owner}/{repo}",
                "--state", "open", "--limit", "50",
                "--json", "number,title,url,statusCheckRollup,createdAt",
            ],
            env=scripts._child_env(),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=_GH_TIMEOUT,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return []
    if proc.returncode != 0:
        return []
    try:
        rows = json.loads(proc.stdout or "[]")
    except ValueError:
        return []
    out: List[Dict[str, Any]] = []
    for r in rows:
        out.append(
            {
                "repo": repo_label,
                "number": r.get("number"),
                "title": r.get("title") or "",
                "url": r.get("url") or "",
                "forge": "github",
                "checks": _map_github_checks(r.get("statusCheckRollup")),
                "createdAt": r.get("createdAt") or "",
            }
        )
    return out


# --- Bitbucket ---------------------------------------------------------------

# Resolved once per process: the (user, token) basic-auth identity that the
# Bitbucket REST API actually accepts. The cached git credential's username
# (a bare bitbucket handle) is often rejected because the stored password is an
# Atlassian API token that must be paired with the account email, so we keep a
# small candidate list and remember the first that works.
_bb_lock = threading.Lock()
_bb_identity: Optional[Tuple[str, str]] = None   # working (user, token)
_bb_resolved = False                              # have we tried yet this process?


def _bb_candidates() -> List[Tuple[str, str]]:
    """Basic-auth identities to try for bitbucket.org, best guess first."""
    proc = _git("credential", "fill", input_text="protocol=https\nhost=bitbucket.org\n\n")
    if proc is None or proc.returncode != 0:
        return []
    user = token = None
    for line in proc.stdout.splitlines():
        if line.startswith("username="):
            user = line[len("username="):]
        elif line.startswith("password="):
            token = line[len("password="):]
    if not token:
        return []
    cands: List[Tuple[str, str]] = []
    if user:
        cands.append((user, token))
    email = _git_email()
    if email and (email, token) not in cands:
        cands.append((email, token))
    return cands


def _bb_get(url: str, user: str, token: str) -> Optional[Any]:
    """GET a Bitbucket API URL with basic auth. Returns parsed JSON or None.

    Raises nothing on HTTP 401/403 (returns None) so the caller can try the next
    candidate identity.
    """
    req = urllib.request.Request(url)
    cred = base64.b64encode(f"{user}:{token}".encode("utf-8")).decode("ascii")
    req.add_header("Authorization", "Basic " + cred)
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=_BB_TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8", errors="replace"))
    except (urllib.error.URLError, ValueError, OSError):
        return None


def _bitbucket_open_prs(workspace: str, repo: str, repo_label: str) -> List[Dict[str, Any]]:
    global _bb_identity, _bb_resolved
    with _bb_lock:
        if not _bb_resolved:
            _bb_resolved = True
            _bb_identity = None
            # Defer picking the identity until the first real request below so we
            # validate against an actual repo the operator can see.
            _bb_candidates_cache["list"] = _bb_candidates()

    url = (
        f"https://api.bitbucket.org/2.0/repositories/{workspace}/{repo}"
        "/pullrequests?state=OPEN&pagelen=50"
    )

    # Reuse the already-proven identity when we have one.
    with _bb_lock:
        identity = _bb_identity
        candidates = list(_bb_candidates_cache.get("list") or [])

    data = None
    if identity is not None:
        data = _bb_get(url, identity[0], identity[1])

    if data is None:
        for user, token in candidates:
            probe = _bb_get(url, user, token)
            if probe is not None and isinstance(probe, dict) and "values" in probe:
                with _bb_lock:
                    _bb_identity = (user, token)
                data = probe
                break

    if not isinstance(data, dict) or "values" not in data:
        return []

    out: List[Dict[str, Any]] = []
    for pr in data.get("values", []):
        href = (((pr.get("links") or {}).get("html") or {}).get("href")) or ""
        out.append(
            {
                "repo": repo_label,
                "number": pr.get("id"),
                "title": pr.get("title") or "",
                "url": href,
                "forge": "bitbucket",
                # Bitbucket build/check state needs an extra call per PR; the
                # task allows leaving it as "none" when not readily available.
                "checks": "none",
                "createdAt": pr.get("created_on") or "",
            }
        )
    return out


# Small process-level holder for the resolved candidate list (guarded by _bb_lock).
_bb_candidates_cache: Dict[str, Any] = {}


# --- aggregation + cache -----------------------------------------------------

_cache_lock = threading.Lock()
_cache: Dict[str, Any] = {"ts": 0.0, "data": []}


def _aggregate() -> List[Dict[str, Any]]:
    projects_dir = config.fm_home / "projects"
    if not projects_dir.is_dir():
        return []
    results: List[Dict[str, Any]] = []
    for clone in sorted(projects_dir.iterdir()):
        try:
            if not clone.is_dir():
                continue
            remote = _origin_url(clone)
            if not remote:
                continue
            parsed = _parse_remote(remote)
            if not parsed:
                continue
            forge, owner, repo = parsed
            repo_label = clone.name
            if forge == "github":
                results.extend(_github_open_prs(owner, repo, repo_label))
            elif forge == "bitbucket":
                results.extend(_bitbucket_open_prs(owner, repo, repo_label))
        except Exception:
            # One bad clone must never sink the whole endpoint.
            continue
    return results


def open_prs() -> List[Dict[str, Any]]:
    """Aggregated open PRs across all project clones, cached for ~60s."""
    now = time.time()
    with _cache_lock:
        if _cache["ts"] > 0 and (now - _cache["ts"]) < _TTL:
            return _cache["data"]
    data = _aggregate()
    with _cache_lock:
        _cache["data"] = data
        _cache["ts"] = time.time()
    return data
