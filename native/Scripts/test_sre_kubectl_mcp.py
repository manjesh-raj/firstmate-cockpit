#!/usr/bin/env python3
"""Tests for sre_kubectl_mcp.py's shared-terminal bridge protocol
(`fm/cockpit-sre-lead-shared-terminal`).

Run with: python3 -m unittest test_sre_kubectl_mcp -v
(from `native/Scripts/`, or `python3 -m unittest native.Scripts.test_sre_kubectl_mcp -v`
from the repo root).

No third-party test runner is set up for this standalone stdlib script, so
this file is plain `unittest` and can run with only a system Python 3.

This script no longer builds or runs any `ssh`/`subprocess` command itself -
that whole model (a second SSH connection, `become_user`/`startup_snippet`
escalation) was removed. All it does now is write a `request-<id>.json` file
and poll for a `response-<id>.json` file - the Swift-side half of that
protocol (`SRELeadBridge.swift`) has its own tests
(`SRELeadBridgeSelfTest.swift`, run via `FM_RUN_SRE_LEAD_BRIDGE_TESTS=1`).
This file covers, on the Python side:
  - write-verb refusal and character-allowlist validation, unaffected by the
    execution-model change
  - the request file is written atomically (via a `.tmp` + `os.rename`) and
    contains exactly the validated, shell-quoted kubectl command line
  - polling behavior: a response that appears after a short delay is picked
    up and returned verbatim; a response that never appears within the
    timeout produces a clear timeout error and cleans up the stale request
    file

`fm/grandline-sre-lead-runbook-execution` added `RunbookExecutionTests`
below, covering the second MCP tool, `run_runbook`: finding a runbook by
title, refusing a runbook by name the moment any one step fails the exact
same `_validate_args` check `kubectl_readonly` uses (asserting nothing is
ever written to the bridge directory in that case), and running every step
of an all-compliant runbook sequentially through the bridge.
"""

import json
import os
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sre_kubectl_mcp as mcp  # noqa: E402


class ValidationTests(unittest.TestCase):
    """Unaffected by the execution-model change - re-run to prove it stayed that way."""

    def test_rejects_non_readonly_verb(self):
        err = mcp._validate_args("delete", ["pod/foo"])
        self.assertIsNotNone(err)
        self.assertIn("delete", err)

    def test_rejects_smuggled_write_verb_in_arg(self):
        err = mcp._validate_args("get", ["pods;", "kubectl apply -f x.yaml"])
        self.assertIsNotNone(err)

    def test_rejects_disallowed_characters(self):
        err = mcp._validate_args("get", ["pods`whoami`"])
        self.assertIsNotNone(err)
        self.assertIn("disallowed", err)

    def test_accepts_plain_readonly_args(self):
        err = mcp._validate_args("get", ["pods", "-n", "raas-preprod", "-o", "wide"])
        self.assertIsNone(err)


class BridgeRequestTests(unittest.TestCase):
    """Assert the request file's exact shape and that validation runs before
    any file is ever written."""

    def setUp(self):
        import tempfile
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self.bridge_dir = self._tmpdir_ctx.name
        self._old_env = os.environ.get("SRE_LEAD_BRIDGE_DIR")
        os.environ["SRE_LEAD_BRIDGE_DIR"] = self.bridge_dir

    def tearDown(self):
        if self._old_env is None:
            os.environ.pop("SRE_LEAD_BRIDGE_DIR", None)
        else:
            os.environ["SRE_LEAD_BRIDGE_DIR"] = self._old_env
        self._tmpdir_ctx.cleanup()

    def _requests(self):
        return [f for f in os.listdir(self.bridge_dir) if f.startswith("request-") and f.endswith(".json")]

    def test_invalid_command_never_writes_a_request_file(self):
        outcome = mcp._run_kubectl("delete", ["pod/foo"], None)
        self.assertFalse(outcome["ok"])
        self.assertIn("delete", outcome["error"])
        self.assertEqual(self._requests(), [])

    def test_writes_exactly_one_request_file_with_the_quoted_command(self):
        # Answer the request from a background thread so `_run_kubectl`'s
        # poll loop (which runs on this thread) doesn't block forever.
        def respond():
            deadline = time.time() + 5
            while time.time() < deadline:
                reqs = self._requests()
                if reqs:
                    request_id = reqs[0][len("request-"):-len(".json")]
                    with open(os.path.join(self.bridge_dir, reqs[0])) as f:
                        payload = json.load(f)
                    assert payload["command"] == "kubectl get pods -n raas-preprod", payload
                    # Mimics `SRELeadBridge.nextPendingRequest` claiming
                    # (deleting) the request file as soon as it's read.
                    os.remove(os.path.join(self.bridge_dir, reqs[0]))
                    with open(os.path.join(self.bridge_dir, f"response-{request_id}.json"), "w") as f:
                        json.dump({"ok": True, "output": "pod/api-1   1/1   Running"}, f)
                    return
                time.sleep(0.05)
            raise AssertionError("no request file appeared")

        t = threading.Thread(target=respond)
        t.start()
        outcome = mcp._run_kubectl("get", ["pods", "-n", "raas-preprod"], None)
        t.join(timeout=5)

        self.assertTrue(outcome["ok"], outcome)
        self.assertEqual(outcome["output"], "pod/api-1   1/1   Running")
        # The request file is removed once the response is read.
        self.assertEqual(self._requests(), [])

    def test_namespace_flag_is_folded_into_the_command_string(self):
        captured = {}

        def respond():
            deadline = time.time() + 5
            while time.time() < deadline:
                reqs = self._requests()
                if reqs:
                    request_id = reqs[0][len("request-"):-len(".json")]
                    with open(os.path.join(self.bridge_dir, reqs[0])) as f:
                        captured["command"] = json.load(f)["command"]
                    with open(os.path.join(self.bridge_dir, f"response-{request_id}.json"), "w") as f:
                        json.dump({"ok": True, "output": ""}, f)
                    return
                time.sleep(0.05)

        t = threading.Thread(target=respond)
        t.start()
        mcp._run_kubectl("logs", ["pod/api-7f9", "--previous"], "prod")
        t.join(timeout=5)

        self.assertEqual(captured.get("command"), "kubectl logs -n prod pod/api-7f9 --previous")

    def test_rejects_disallowed_characters_in_namespace(self):
        outcome = mcp._run_kubectl("get", ["pods"], "prod;rm -rf")
        self.assertFalse(outcome["ok"])
        self.assertIn("disallowed", outcome["error"])
        self.assertEqual(self._requests(), [])

    def test_missing_bridge_dir_env_var_fails_cleanly(self):
        del os.environ["SRE_LEAD_BRIDGE_DIR"]
        outcome = mcp._run_kubectl("get", ["pods"], None)
        self.assertFalse(outcome["ok"])
        self.assertIn("SRE_LEAD_BRIDGE_DIR", outcome["error"])


class BridgeTimeoutTests(unittest.TestCase):
    """A response that never appears must time out cleanly, not hang, and
    must not leave a stale request file behind."""

    def setUp(self):
        import tempfile
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self.bridge_dir = self._tmpdir_ctx.name
        self._old_env = os.environ.get("SRE_LEAD_BRIDGE_DIR")
        os.environ["SRE_LEAD_BRIDGE_DIR"] = self.bridge_dir

    def tearDown(self):
        if self._old_env is None:
            os.environ.pop("SRE_LEAD_BRIDGE_DIR", None)
        else:
            os.environ["SRE_LEAD_BRIDGE_DIR"] = self._old_env
        self._tmpdir_ctx.cleanup()

    def test_times_out_and_cleans_up_the_request_file(self):
        from unittest import mock
        with mock.patch.object(mcp, "_TIMEOUT_SECONDS", 0.3), \
                mock.patch.object(mcp, "_POLL_INTERVAL_SECONDS", 0.05):
            outcome = mcp._run_kubectl("get", ["pods"], None)

        self.assertFalse(outcome["ok"])
        self.assertIn("timed out", outcome["error"])
        remaining = [f for f in os.listdir(self.bridge_dir) if f.startswith("request-")]
        self.assertEqual(remaining, [])

    def test_response_arriving_just_before_timeout_is_still_picked_up(self):
        from unittest import mock

        def respond_late():
            time.sleep(0.15)
            reqs = [f for f in os.listdir(self.bridge_dir) if f.startswith("request-")]
            if not reqs:
                return
            request_id = reqs[0][len("request-"):-len(".json")]
            with open(os.path.join(self.bridge_dir, f"response-{request_id}.json"), "w") as f:
                json.dump({"ok": True, "output": "node-1   Ready"}, f)

        t = threading.Thread(target=respond_late)
        t.start()
        with mock.patch.object(mcp, "_TIMEOUT_SECONDS", 5), \
                mock.patch.object(mcp, "_POLL_INTERVAL_SECONDS", 0.05):
            outcome = mcp._run_kubectl("get", ["nodes"], None)
        t.join(timeout=5)

        self.assertTrue(outcome["ok"], outcome)
        self.assertEqual(outcome["output"], "node-1   Ready")


class RunbookExecutionTests(unittest.TestCase):
    """`run_runbook`: lookup by title, validate-everything-before-running-
    anything, and sequential execution through the same bridge."""

    def setUp(self):
        import tempfile
        self._runbooks_ctx = tempfile.TemporaryDirectory()
        self.runbooks_dir = self._runbooks_ctx.name
        self._bridge_ctx = tempfile.TemporaryDirectory()
        self.bridge_dir = self._bridge_ctx.name
        self._old_runbooks_env = os.environ.get("SRE_LEAD_RUNBOOKS_DIR")
        self._old_bridge_env = os.environ.get("SRE_LEAD_BRIDGE_DIR")
        os.environ["SRE_LEAD_RUNBOOKS_DIR"] = self.runbooks_dir
        os.environ["SRE_LEAD_BRIDGE_DIR"] = self.bridge_dir

    def tearDown(self):
        for key, old in (("SRE_LEAD_RUNBOOKS_DIR", self._old_runbooks_env),
                          ("SRE_LEAD_BRIDGE_DIR", self._old_bridge_env)):
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old
        self._runbooks_ctx.cleanup()
        self._bridge_ctx.cleanup()

    def _write_runbook(self, filename, content):
        with open(os.path.join(self.runbooks_dir, filename), "w") as f:
            f.write(content)

    def _requests(self):
        return [f for f in os.listdir(self.bridge_dir) if f.startswith("request-") and f.endswith(".json")]

    def _respond_to_n_requests(self, n, output_for=lambda i: f"output-{i}"):
        """Background thread: answers up to `n` requests in order, each with
        `{"ok": true, "output": output_for(i)}`."""
        def worker():
            answered = 0
            deadline = time.time() + 5
            while time.time() < deadline and answered < n:
                reqs = sorted(self._requests())
                if reqs:
                    request_id = reqs[0][len("request-"):-len(".json")]
                    os.remove(os.path.join(self.bridge_dir, reqs[0]))
                    with open(os.path.join(self.bridge_dir, f"response-{request_id}.json"), "w") as f:
                        json.dump({"ok": True, "output": output_for(answered)}, f)
                    answered += 1
                time.sleep(0.05)

        t = threading.Thread(target=worker)
        t.start()
        return t

    def test_no_runbooks_dir_env_fails_cleanly(self):
        del os.environ["SRE_LEAD_RUNBOOKS_DIR"]
        outcome = mcp._run_runbook("anything")
        self.assertFalse(outcome["ok"])
        self.assertIn("SRE_LEAD_RUNBOOKS_DIR", outcome["error"])

    def test_no_matching_runbook(self):
        self._write_runbook("unrelated.md", "# Something else\n\n```\nkubectl get pods\n```\n")
        outcome = mcp._run_runbook("API latency spike")
        self.assertFalse(outcome["ok"])
        self.assertIn("no runbook found", outcome["error"])

    def test_ambiguous_runbook_name_is_refused(self):
        self._write_runbook("a.md", "# Database Incident - primary\n\n```\nkubectl get pods\n```\n")
        self._write_runbook("b.md", "# Database Incident - replica\n\n```\nkubectl get pods\n```\n")
        outcome = mcp._run_runbook("database incident")
        self.assertFalse(outcome["ok"])
        self.assertIn("multiple runbooks", outcome["error"])
        self.assertEqual(self._requests(), [])

    def test_runbook_with_one_disallowed_step_is_refused_by_name_with_no_steps_run(self):
        self._write_runbook("restart-api.md", (
            "# Restart the API\n\n"
            "```\n"
            "kubectl get pods -n prod\n"
            "kubectl rollout restart deployment/api -n prod\n"
            "kubectl get pods -n prod\n"
            "```\n"
        ))
        outcome = mcp._run_runbook("Restart the API")
        self.assertFalse(outcome["ok"])
        self.assertTrue(outcome.get("refused"))
        self.assertEqual(outcome["runbook"], "Restart the API")
        self.assertEqual(outcome["failed_step"], 2)
        self.assertIn("rollout", outcome["error"])
        self.assertIn("No steps were run", outcome["error"])
        # Not one step was ever sent to the shared terminal - including the
        # earlier, individually-valid `kubectl get pods` step before it.
        self.assertEqual(self._requests(), [])

    def test_runbook_with_a_non_kubectl_line_is_refused(self):
        self._write_runbook("mixed.md", (
            "# Mixed Steps\n\n"
            "```\n"
            "kubectl get pods -n prod\n"
            "rm -rf /\n"
            "```\n"
        ))
        outcome = mcp._run_runbook("Mixed Steps")
        self.assertFalse(outcome["ok"])
        self.assertTrue(outcome.get("refused"))
        self.assertIn("not a kubectl command", outcome["error"])
        self.assertEqual(self._requests(), [])

    def test_fully_compliant_runbook_runs_every_step_in_order(self):
        self._write_runbook("api-latency-spike.md", (
            "# API latency spike\n\n"
            "Investigate elevated p99 latency.\n\n"
            "```\n"
            "kubectl get pods -n prod\n"
            "$ kubectl describe pod api-1 -n prod\n"
            "kubectl logs pod/api-1 -n prod --previous\n"
            "```\n"
        ))
        t = self._respond_to_n_requests(3)
        outcome = mcp._run_runbook("api latency spike")
        t.join(timeout=5)

        self.assertTrue(outcome["ok"], outcome)
        self.assertEqual(outcome["runbook"], "API latency spike")
        self.assertEqual(len(outcome["steps"]), 3)
        self.assertEqual(outcome["steps"][0]["command"], "kubectl get pods -n prod")
        self.assertEqual(outcome["steps"][1]["command"], "kubectl describe pod api-1 -n prod")
        self.assertEqual(outcome["steps"][2]["command"], "kubectl logs pod/api-1 -n prod --previous")
        for i, step in enumerate(outcome["steps"]):
            self.assertTrue(step["ok"], step)
            self.assertEqual(step["output"], f"output-{i}")

    def test_matches_runbook_by_title_not_filename(self):
        self._write_runbook("some-internal-slug-123.md", "# Restart the API\n\n```\nkubectl get pods\n```\n")
        found, error = mcp._find_runbook("restart the api")
        self.assertIsNone(error)
        self.assertEqual(found[0], "Restart the API")

    def test_extract_command_lines_ignores_prose_and_comments_outside_fences(self):
        content = (
            "# Some Runbook\n\n"
            "kubectl get pods\n"  # outside a fence - prose, not a step
            "```\n"
            "# a comment, not a command\n"
            "\n"
            "kubectl get pods -n prod\n"
            "```\n"
            "kubectl get nodes\n"  # outside a fence again
        )
        self.assertEqual(mcp._extract_command_lines(content), ["kubectl get pods -n prod"])

    def test_execution_stops_at_first_bridge_failure(self):
        self._write_runbook("two-steps.md", (
            "# Two Steps\n\n"
            "```\n"
            "kubectl get pods -n prod\n"
            "kubectl get nodes\n"
            "```\n"
        ))

        def worker():
            deadline = time.time() + 5
            while time.time() < deadline:
                reqs = sorted(self._requests())
                if reqs:
                    request_id = reqs[0][len("request-"):-len(".json")]
                    os.remove(os.path.join(self.bridge_dir, reqs[0]))
                    with open(os.path.join(self.bridge_dir, f"response-{request_id}.json"), "w") as f:
                        json.dump({"ok": False, "error": "busy"}, f)
                    return
                time.sleep(0.05)

        t = threading.Thread(target=worker)
        t.start()
        outcome = mcp._run_runbook("Two Steps")
        t.join(timeout=5)

        self.assertFalse(outcome["ok"])
        self.assertEqual(len(outcome["steps"]), 1)
        self.assertFalse(outcome["steps"][0]["ok"])


if __name__ == "__main__":
    unittest.main()
