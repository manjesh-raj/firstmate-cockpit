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

When the host config's `become_user` is set (`Host.becomeUser`, optional,
per-host), the already-validated kubectl command is piped into
`sudo su - <become_user>`'s stdin, rather than passed as a `-c` argument -
see `_run_kubectl`. Unset (the default), behavior is unchanged.

When the host config's `startup_snippet` is set (`Host.startupSnippetID`,
resolved to command text by `SRELead.swift` before this script ever sees it),
it is sent first, before the escalation and kubectl command, over the same
persistent shell - see `_run_via_sequential_shell`. This exists because of a
root cause the first three `become_user` attempts (PRs #70/#71/#72, all
described above) missed entirely: on the captain's real "EKS Preprod Bastion"
host, `Host.sshArguments` connects only as far as a jump/gateway box
(`centos@ec2-...`), never the real target where `kubectl`/`devops_k8s_preprod`
live - reaching it needs an *additional* hop the interactive tab already
fires automatically via `Host.startupSnippetID` (a saved snippet, e.g. `mpp`,
presumably a shell alias/function defined server-side in that jump box's own
profile) roughly 1.5s after connecting. Every prior escalation attempt ran
`sudo su - <user>` on the jump box itself, a machine that almost certainly
doesn't have that user or the same sudoers setup as the real target - which
is why three different `su`/stdin argument shapes all failed identically.
Unset (the default, every host that has never used a startup snippet),
behavior is completely unchanged from before this feature existed.

**`su -c` was tried twice and failed on the captain's real bastion - do not
reintroduce it.** `fm/cockpit-sre-lead-become-user` (PR #70) used
`sudo su - <user> -c '<kubectl ...>'`; `fm/cockpit-sre-lead-su-syntax-fix`
(PR #71) "fixed" the ordering to `sudo su -c '<kubectl ...>' - <user>` based
on a correct reading of util-linux's `su` option-parsing order. Both were
guesses validated only by static reasoning about `su`'s argv parser, and the
captain then tested PR #71's fixed ordering directly on the real bastion:
**`-c` was silently ignored entirely** - it dropped the captain into a live
interactive shell as `<user>` instead of running the command. So this
bastion's `su` does not honor `-c` reliably in that shape at all, regardless
of argument order; the argv-flag approach is a dead end on this machine.
What the captain confirmed *does* work, live: `echo '<kubectl ...>' | sudo su
- <user>` - piping the command into the target shell's stdin. That is what
`_run_kubectl` does now, via `subprocess.run`'s own `input=` parameter (not
a shell-level `echo | ...` string, which would reintroduce the nested-quoting
fragility this whole escalation path has been trying to avoid) - see
`fm/cockpit-sre-lead-su-stdin-pipe`.

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
import time

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

# Best-effort delay between sequential stdin writes when a startup snippet is
# involved (see `_run_via_sequential_shell`) - mirrors the existing ~1.5s
# fixed-delay precedent `ConsoleController.runStartupSnippet` already uses
# for the interactive tab, since there is no reliable "shell/nested-hop is
# ready for more input" signal to hook here either.
_SNIPPET_STEP_DELAY_SECONDS = 1.5


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
    return (
        cfg.get("ssh_executable", "/usr/bin/ssh"),
        argv,
        cfg.get("become_user"),
        cfg.get("startup_snippet"),
    )


def _run_kubectl(subcommand, args, namespace):
    error = _validate_args(subcommand, args)
    if error:
        return {"ok": False, "error": error}

    ssh_exe, ssh_argv, become_user, startup_snippet = _load_host_config()
    remote = ["kubectl", subcommand]
    if namespace:
        if set(namespace) - _SAFE_CHARS:
            return {"ok": False, "error": f"namespace {namespace!r} contains disallowed characters"}
        remote += ["-n", namespace]
    remote += args

    # `shlex.quote` per token is defense in depth on top of
    # `_validate_args`'s character-set check above, not a replacement for it -
    # every token was already validated before it reaches here.
    remote_cmd = " ".join(shlex.quote(tok) for tok in remote)

    if startup_snippet:
        return _run_via_sequential_shell(
            ssh_exe, ssh_argv, startup_snippet, become_user, remote_cmd, subcommand
        )

    # `ssh <same argv the interactive tab already uses> -- bash -lc '<...>'`:
    # a second, independent connection to the same bastion. Forced through a
    # login shell (`bash -lc`) so it sources the same profile
    # (`.bash_profile`/`.profile`) the interactive tab already benefits from -
    # a bare non-interactive `ssh ... -- kubectl ...` exec only sources
    # `.bashrc`, and only for an interactive shell, so a `kubectl` that's only
    # on PATH via a profile file is "command not found" for this tool even
    # though the interactive tab finds it fine.
    #
    # `become_user` (`Host.becomeUser`, `fm/cockpit-sre-lead-become-user`):
    # on some bastions the login user this host connects as cannot run
    # `kubectl` at all - only a dedicated service user reached via
    # `sudo su - <user>` can. Two prior attempts to deliver the kubectl
    # command via `su -c '<kubectl ...>'` (in either argument order) both
    # failed on the captain's real bastion - see the module docstring for
    # the full evidence. What the captain confirmed works is piping the
    # command into the target shell's stdin, so that's what happens here:
    # the SSH command is just `bash -lc 'sudo su - <user>'` (no kubectl
    # command embedded in argv at all), and the already-validated kubectl
    # command string is handed to `subprocess.run` via `input=`, with a
    # trailing newline so the remote shell actually executes it once read -
    # matching the captain's own `echo '<cmd>' | sudo su - <user>` test. This
    # single-shot path is unaffected by `startup_snippet` - no host that lacks
    # one reaches any of the code below this comment.
    stdin_input = None
    if become_user:
        shell_cmd = f"sudo su - {shlex.quote(become_user)}"
        stdin_input = remote_cmd + "\n"
    else:
        shell_cmd = remote_cmd

    full = [ssh_exe] + ssh_argv + ["--", "bash", "-lc", shell_cmd]
    try:
        proc = subprocess.run(
            full, capture_output=True, text=True, timeout=_TIMEOUT_SECONDS,
            input=stdin_input,
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


def _run_via_sequential_shell(ssh_exe, ssh_argv, startup_snippet, become_user, remote_cmd, subcommand):
    """A host with `startup_snippet` set needs an extra hop run first, over
    the *same* shell session, before the escalation and kubectl commands -
    `Host.sshArguments` alone only reaches a jump/gateway box on this class
    of host, not the real target (see the module docstring for the captain's
    "EKS Preprod Bastion" case this was root-caused against). The snippet is
    typically itself a further nested `ssh` (a server-side alias like `mpp`,
    opaque to this script by design), so a fresh, separate `ssh` invocation
    from this script could not replicate it - it depends on config that only
    exists inside the first hop's own shell.

    Unlike the single-shot `subprocess.run(..., input=...)` path above, the
    commands here cannot be handed over as one blob: the interactive tab's
    own `runStartupSnippet` documents that there is no reliable "the remote
    shell is ready" signal, and firing the escalation/kubectl commands
    immediately risks them racing ahead of the snippet's own nested-hop
    handshake and landing nowhere useful (or in the wrong shell entirely).
    So this opens a persistent login shell and writes each command to its
    stdin one at a time, with a delay after each, closing stdin once the
    kubectl command is sent so the whole chain unwinds on EOF exactly like
    the single-shot path's `su` session already does.
    """
    full = [ssh_exe] + ssh_argv + ["--", "bash", "-l"]
    try:
        proc = subprocess.Popen(
            full, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
        )
    except OSError as e:
        return {"ok": False, "error": f"failed to run ssh: {e}"}

    try:
        proc.stdin.write(startup_snippet + "\n")
        proc.stdin.flush()
        time.sleep(_SNIPPET_STEP_DELAY_SECONDS)

        if become_user:
            proc.stdin.write(f"sudo su - {shlex.quote(become_user)}\n")
            proc.stdin.flush()
            time.sleep(_SNIPPET_STEP_DELAY_SECONDS)

        proc.stdin.write(remote_cmd + "\n")
        proc.stdin.flush()

        # `communicate()`, not a manual `proc.stdin.close()` beforehand: it
        # closes stdin itself (since no `input=` is passed here - every
        # command was already written above) as part of its own internal
        # read loop, which is what lets the remote's `bash -l` (and, if
        # `become_user` opened one, its nested `su -` shell) see EOF and
        # unwind - a `close()` call of our own first would make this second,
        # redundant close raise on an already-closed file.
        stdout, stderr = proc.communicate(timeout=_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        return {"ok": False, "error": f"kubectl {subcommand} timed out after {_TIMEOUT_SECONDS}s"}
    except OSError as e:
        return {"ok": False, "error": f"failed to run ssh: {e}"}

    return {
        "ok": proc.returncode == 0,
        "exit_code": proc.returncode,
        "stdout": stdout[-20000:],
        "stderr": stderr[-4000:],
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
