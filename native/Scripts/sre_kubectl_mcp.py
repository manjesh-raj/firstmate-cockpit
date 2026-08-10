#!/usr/bin/env python3
"""SRE Lead's one MCP tool: run a read-only kubectl command on the connected
bastion over SSH.

Minimal MCP stdio JSON-RPC server (`initialize`, `notifications/initialized`,
`tools/list`, `tools/call` - the whole surface one tool needs), standard
library only, no pip install. Spawned as a subprocess of the local `claude`
CLI (see `SRELead.swift`), configured via `--mcp-config` pointing at a small
generated JSON file whose `env` block sets `SRE_LEAD_HOST_CONFIG` to a second
generated JSON file (written by the Swift side per-session) holding the
resolved `ssh` argv for the bastion the captain is already connected to
(`Host.sshArguments(allHosts:)` plus a materialized `-i <key>` when the host
uses a saved key - see `SRELead.swift`'s `buildSSHArgv`).

Read-only enforcement lives HERE, not in the persona prompt: `_ALLOWED_VERBS`
is the only set of kubectl subcommands this tool will ever exec, and
`_validate_args` rejects anything that isn't a plain, individually-safe
argument - no shell metacharacters, so there is no local or remote shell
for a flag-smuggled `--dry-run=client -o yaml | kubectl apply -f -` (or any
other `;`/`&&`/`` ` ``/`$()`-based trick) to run inside. The command runs on
the bastion via a *second* SSH connection reusing the exact same argv this
app's own terminal tab already trusts (`sshArguments`), never a local
kubeconfig - so this script never talks to a Kubernetes API server directly,
and multiple clusters "just work" because whichever bastion is connected
already has its own authenticated `kubectl`.
"""

import json
import os
import shlex
import subprocess
import sys

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
# metacharacters ever reach this set, so there is nothing for a remote shell
# to interpret even though `ssh` sends the joined command line through the
# bastion's login shell.
_SAFE_CHARS = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    "-_./:=,@*{}[]'\" "
)

_TIMEOUT_SECONDS = 30


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


def _load_host_config():
    path = os.environ.get("SRE_LEAD_HOST_CONFIG")
    if not path:
        raise RuntimeError("SRE_LEAD_HOST_CONFIG is not set - this script must be spawned by SRELead.swift")
    with open(path) as f:
        cfg = json.load(f)
    argv = cfg.get("ssh_argv")
    if not isinstance(argv, list) or not argv:
        raise RuntimeError(f"{path} has no usable 'ssh_argv'")
    return cfg.get("ssh_executable", "/usr/bin/ssh"), argv


def _run_kubectl(subcommand, args, namespace):
    error = _validate_args(subcommand, args)
    if error:
        return {"ok": False, "error": error}

    ssh_exe, ssh_argv = _load_host_config()
    remote = ["kubectl", subcommand]
    if namespace:
        if set(namespace) - _SAFE_CHARS:
            return {"ok": False, "error": f"namespace {namespace!r} contains disallowed characters"}
        remote += ["-n", namespace]
    remote += args

    # `ssh <same argv the interactive tab already uses> -- bash -lc '<kubectl ...>'`:
    # a second, independent connection to the same bastion. Forced through a
    # login shell (`bash -lc`) so it sources the same profile
    # (`.bash_profile`/`.profile`) the interactive tab already benefits from -
    # a bare non-interactive `ssh ... -- kubectl ...` exec only sources
    # `.bashrc`, and only for an interactive shell, so a `kubectl` that's only
    # on PATH via a profile file is "command not found" for this tool even
    # though the interactive tab finds it fine. `shlex.quote` per token is
    # defense in depth on top of `_validate_args`'s character-set check
    # above, not a replacement for it - every token was already validated
    # before it reaches here.
    remote_cmd = " ".join(shlex.quote(tok) for tok in remote)
    full = [ssh_exe] + ssh_argv + ["--", "bash", "-lc", remote_cmd]
    try:
        proc = subprocess.run(
            full, capture_output=True, text=True, timeout=_TIMEOUT_SECONDS
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"kubectl {subcommand} timed out after {_TIMEOUT_SECONDS}s"}
    except OSError as e:
        return {"ok": False, "error": f"failed to run ssh: {e}"}

    return {
        "ok": proc.returncode == 0,
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-20000:],
        "stderr": proc.stderr[-4000:],
    }


def _tool_schema():
    return {
        "name": TOOL_NAME,
        "description": (
            "Run a READ-ONLY kubectl command (get, describe, logs, top, or events) "
            "against the Kubernetes cluster the currently connected bastion is already "
            "authenticated to. Runs on the bastion over SSH, not locally. Any other "
            "verb (apply, delete, patch, exec, ...) is refused."
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
                "serverInfo": {"name": "sre-kubectl", "version": "1.0.0"},
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
