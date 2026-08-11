#!/usr/bin/env python3
"""SRE Lead's one MCP tool: run a read-only kubectl command in the captain's
own already-connected terminal tab for this host.

Minimal MCP stdio JSON-RPC server (`initialize`, `notifications/initialized`,
`tools/list`, `tools/call` - the whole surface one tool needs), standard
library only, no pip install. Spawned as a subprocess of the local `claude`
CLI (see `SRELead.swift`).

**`fm/cockpit-sre-lead-shared-terminal` replaced this tool's whole execution
model - read this before touching anything below.** Every earlier version
(five attempts: PRs #70/#71/#72/#73, plus an abandoned PTY investigation) ran
kubectl over a *second*, independent SSH connection to the same bastion,
built from `Host.sshArguments(allHosts:)` plus (depending on the attempt) a
`become_user`/`startup_snippet` escalation. The captain then confirmed a hard
constraint that makes the entire second-connection approach a dead end on the
real "EKS Preprod Bastion" host: its EKS Bastion hop is username/password-
gated *by policy* - no SSH key auth is possible there. A second, independent,
fully-automated SSH connection can never complete that login chain, because
nothing can supply a password that isn't stored anywhere, by design - no
argument-shape fix, stdin-piping trick, or extra hop could ever have worked,
because the premise (a second automated connection can finish the login) was
false from the start. **Do not resurrect a second-connection approach for
this or any other password-gated host** - if a future host needs kubectl
access and also has a password-gated hop, it needs this same shared-terminal
approach, not a variant of the old one.

The fix: never open a second connection at all. Run the kubectl command in
the *same*, already-authenticated interactive terminal tab the captain used
to log all the way into the host by hand - the same idea `Snippet`'s "Run"
action already uses (`TerminalView.send(txt:)`), just machine-initiated. This
script and the Swift app are different processes with no shared memory, so
`SRELeadBridge.swift` (Swift, in the app) and this script talk over a small
file-based request/response protocol in a per-session directory
(`SRE_LEAD_BRIDGE_DIR`, set by `SRELead.setUp`):

  1. This script writes `request-<id>.json` (`{"command": "<kubectl ...>"}`)
     into that directory, atomically (write to a `.tmp` path, then `os.rename`
     into place, so the Swift side never reads a half-written file).
  2. `SRELeadBridge` notices the file, injects `<command>` into the host
     page's one primary interactive tab wrapped with two fresh random
     markers (`echo <start marker>; <command>; echo <end marker>`), polls
     that tab's own terminal buffer for the end marker to appear, extracts
     everything between the two markers as the real output, and writes
     `response-<id>.json` back (`{"ok": true, "output": "..."}` or
     `{"ok": false, "error": "..."}` - e.g. if the tab looked busy, if the
     captain typed into it while the command was running, or on timeout).
  3. This script polls for that response file to appear, reads it, and
     returns it as this tool's result.

Read-only enforcement lives HERE, not in the persona prompt and not in
`SRELeadBridge.swift`: `_ALLOWED_VERBS` is the only set of kubectl subcommands
this tool will ever run, and `_validate_args` rejects anything that isn't a
plain, individually-safe argument - no shell metacharacters, so there is no
way for a flag-smuggled `--dry-run=client -o yaml | kubectl apply -f -` (or
any other `;`/`&&`/`` ` ``/`$()`-based trick) to do anything unexpected once
it's typed into the shared, real interactive shell. This validation runs
before the command is even written into a request file, exactly like it ran
before the old `ssh` argv was built - moving the execution path did not
change this guarantee.
"""

import json
import os
import shlex
import sys
import time
import uuid

PROTOCOL_VERSION = "2024-11-05"
TOOL_NAME = "kubectl_readonly"

# The entire read-only surface. Anything else - patch, apply, delete, edit,
# replace, scale, cordon, drain, exec, cp, attach, port-forward, proxy, run,
# create, annotate, label, rollout (restart/undo/etc is a write; `rollout
# status`/`rollout history` are read-only but not worth the extra surface
# area for a v1 read-only tool) - is refused outright.
_ALLOWED_VERBS = {"get", "describe", "logs", "top", "events"}

# Conservative allowlist for every individual argv token after the verb:
# letters, digits, and a small set of punctuation kubectl args legitimately
# use (namespace/label selectors, resource/name, jsonpath, flags). No shell
# metacharacters ever reach this set, so there is nothing for the shared
# interactive shell to interpret beyond running kubectl with plain arguments.
_SAFE_CHARS = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    "-_./:=,@*{}[]'\" "
)

# How long to wait for `SRELeadBridge` to write a response file. Comfortably
# above `SRELeadBridge.commandTimeout` (25s) so a bridge-side timeout always
# produces a real response file before this script's own poll gives up.
_TIMEOUT_SECONDS = 30
_POLL_INTERVAL_SECONDS = 0.2


def _validate_args(subcommand, args):
    if subcommand not in _ALLOWED_VERBS:
        return f"'{subcommand}' is not a read-only kubectl verb. Allowed: {sorted(_ALLOWED_VERBS)}"
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        return "args must be a list of strings"
    for arg in args:
        if not arg:
            continue
        bad = set(arg) - _SAFE_CHARS
        if bad:
            return f"argument {arg!r} contains disallowed character(s): {''.join(sorted(bad))!r}"
        low = arg.lower()
        # Flag-smuggling guard: a shell metachar can't survive `_SAFE_CHARS`
        # above, but a *second* kubectl verb hiding in an otherwise
        # innocuous-looking argument (e.g. someone relying on a future,
        # laxer character set) is worth refusing explicitly too.
        for verb in ("apply", "delete", "patch", "edit", "replace", "scale",
                     "cordon", "drain", "exec", "attach", "port-forward",
                     "proxy", "create", "annotate", "label", "restart"):
            if verb in low:
                return f"argument {arg!r} references the write verb '{verb}', which is never allowed"
    return None


def _bridge_dir():
    path = os.environ.get("SRE_LEAD_BRIDGE_DIR")
    if not path:
        raise RuntimeError("SRE_LEAD_BRIDGE_DIR is not set - this script must be spawned by SRELead.swift")
    return path


def _run_kubectl(subcommand, args, namespace):
    error = _validate_args(subcommand, args)
    if error:
        return {"ok": False, "error": error}

    remote = ["kubectl", subcommand]
    if namespace:
        if set(namespace) - _SAFE_CHARS:
            return {"ok": False, "error": f"namespace {namespace!r} contains disallowed characters"}
        remote += ["-n", namespace]
    remote += args

    # `shlex.quote` per token is defense in depth on top of
    # `_validate_args`'s character-set check above, not a replacement for it:
    # this string is typed directly into the shared interactive shell, so it
    # still goes through real shell parsing once there.
    remote_cmd = " ".join(shlex.quote(tok) for tok in remote)

    try:
        bridge_dir = _bridge_dir()
    except RuntimeError as e:
        return {"ok": False, "error": str(e)}

    request_id = uuid.uuid4().hex
    request_path = os.path.join(bridge_dir, f"request-{request_id}.json")
    response_path = os.path.join(bridge_dir, f"response-{request_id}.json")
    tmp_path = request_path + ".tmp"

    try:
        with open(tmp_path, "w") as f:
            json.dump({"command": remote_cmd}, f)
        os.rename(tmp_path, request_path)
    except OSError as e:
        return {"ok": False, "error": f"could not write the bridge request: {e}"}

    deadline = time.time() + _TIMEOUT_SECONDS
    while time.time() < deadline:
        if os.path.exists(response_path):
            try:
                with open(response_path) as f:
                    outcome = json.load(f)
            except (OSError, json.JSONDecodeError) as e:
                outcome = {"ok": False, "error": f"could not read the bridge response: {e}"}
            finally:
                try:
                    os.remove(response_path)
                except OSError:
                    pass
            return outcome
        time.sleep(_POLL_INTERVAL_SECONDS)

    # Timed out waiting on the Swift side - clean up a still-pending request
    # file so it isn't picked up and acted on later, after this call has
    # already given up on it.
    try:
        os.remove(request_path)
    except OSError:
        pass
    return {"ok": False, "error": f"timed out after {_TIMEOUT_SECONDS}s waiting for the shared-terminal bridge to respond"}


def _tool_schema():
    return {
        "name": TOOL_NAME,
        "description": (
            "Run a READ-ONLY kubectl command (get, describe, logs, top, or events) "
            "in the captain's own already-connected terminal tab for this host, using "
            "whatever cluster access that tab already has. Any other verb (apply, "
            "delete, patch, exec, ...) is refused. Can occasionally fail with a "
            "'busy' error if that tab is actively being used - wait a moment and retry."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "subcommand": {
                    "type": "string",
                    "enum": sorted(_ALLOWED_VERBS),
                    "description": "The kubectl verb to run.",
                },
                "args": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": (
                        "Remaining kubectl arguments as separate tokens, e.g. "
                        "[\"pods\", \"-o\", \"wide\"] or [\"pod/api-7f9\", \"--previous\"]. "
                        "Do not include the namespace flag here; use the 'namespace' field."
                    ),
                },
                "namespace": {
                    "type": "string",
                    "description": "Optional namespace (-n). Omit for --all-namespaces or cluster-scoped resources.",
                },
            },
            "required": ["subcommand", "args"],
        },
    }


def _reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = req.get("method")
        id_ = req.get("id")

        if method == "initialize":
            _reply(id_, result={
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "sre-kubectl", "version": "2.0.0"},
            })
        elif method == "notifications/initialized":
            pass  # no response expected for a notification
        elif method == "tools/list":
            _reply(id_, result={"tools": [_tool_schema()]})
        elif method == "tools/call":
            params = req.get("params", {})
            if params.get("name") != TOOL_NAME:
                _reply(id_, error={"code": -32602, "message": f"unknown tool {params.get('name')!r}"})
                continue
            args_in = params.get("arguments", {})
            outcome = _run_kubectl(
                args_in.get("subcommand", ""), args_in.get("args", []), args_in.get("namespace")
            )
            text = json.dumps(outcome, indent=2)
            _reply(id_, result={
                "content": [{"type": "text", "text": text}],
                "isError": not outcome.get("ok", False),
            })
        elif id_ is not None:
            _reply(id_, error={"code": -32601, "message": f"method not found: {method}"})


if __name__ == "__main__":
    main()
