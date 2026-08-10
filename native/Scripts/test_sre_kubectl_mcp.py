#!/usr/bin/env python3
"""Tests for sre_kubectl_mcp.py's become_user escalation fix.

Run with: python3 -m unittest native/Scripts/test_sre_kubectl_mcp.py -v
(from the repo root, or `cd native/Scripts && python3 -m unittest
test_sre_kubectl_mcp -v`).

No third-party test runner is set up for this standalone stdlib script, so
this file is plain `unittest` and can run with only a system Python 3.

Covers, per fm/cockpit-sre-lead-su-stdin-pipe's acceptance criteria:
  - the exact subprocess.run() argv + input= construction, both with and
    without become_user set (asserted directly via a monkeypatched
    subprocess.run, not "looks right by inspection")
  - a local end-to-end shim reproducing the captain's two real-bastion
    findings: a fake `su` that ignores `-c` (matching the real bastion) but
    honors piped stdin - the new construction must succeed against it
  - write-verb refusal and character-allowlist validation, unaffected by
    the become_user change
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sre_kubectl_mcp as mcp  # noqa: E402


def _write_executable(path, contents):
    with open(path, "w") as f:
        f.write(contents)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def _write_host_config(tmpdir, ssh_executable, ssh_argv, become_user=None, startup_snippet=None):
    path = os.path.join(tmpdir, "host_config.json")
    cfg = {"ssh_executable": ssh_executable, "ssh_argv": ssh_argv}
    if become_user is not None:
        cfg["become_user"] = become_user
    if startup_snippet is not None:
        cfg["startup_snippet"] = startup_snippet
    with open(path, "w") as f:
        json.dump(cfg, f)
    return path


class ValidationTests(unittest.TestCase):
    """Unaffected by this fix - re-run to prove the change didn't touch validation."""

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


class RunKubectlConstructionTests(unittest.TestCase):
    """Assert the exact argv + input= subprocess.run() call, not just behavior."""

    def setUp(self):
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self.tmpdir = self._tmpdir_ctx.name
        self._old_env = os.environ.get("SRE_LEAD_HOST_CONFIG")

    def tearDown(self):
        self._tmpdir_ctx.cleanup()
        if self._old_env is None:
            os.environ.pop("SRE_LEAD_HOST_CONFIG", None)
        else:
            os.environ["SRE_LEAD_HOST_CONFIG"] = self._old_env

    def _fake_run(self, returncode=0, stdout="", stderr=""):
        result = mock.Mock()
        result.returncode = returncode
        result.stdout = stdout
        result.stderr = stderr
        return result

    def test_become_user_pipes_command_via_stdin_not_argv(self):
        cfg_path = _write_host_config(
            self.tmpdir,
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes", "bastion.example.com"],
            become_user="devops_k8s_preprod",
        )
        os.environ["SRE_LEAD_HOST_CONFIG"] = cfg_path

        with mock.patch.object(mcp.subprocess, "run", return_value=self._fake_run()) as run_mock:
            mcp._run_kubectl("get", ["pods", "-n", "raas-preprod"], None)

        run_mock.assert_called_once()
        args, kwargs = run_mock.call_args
        argv = args[0]

        self.assertEqual(
            argv,
            [
                "/usr/bin/ssh",
                "-o",
                "BatchMode=yes",
                "bastion.example.com",
                "--",
                "bash",
                "-lc",
                "sudo su - devops_k8s_preprod",
            ],
        )
        # No `-c`, and no kubectl command embedded in argv anywhere.
        self.assertNotIn("-c", argv)
        self.assertFalse(any("kubectl" in tok for tok in argv))

        self.assertEqual(kwargs["input"], "kubectl get pods -n raas-preprod\n")

    def test_become_user_with_namespace_and_extra_args_in_stdin(self):
        cfg_path = _write_host_config(
            self.tmpdir,
            "/usr/bin/ssh",
            ["prod-bastion"],
            become_user="svc_k8s",
        )
        os.environ["SRE_LEAD_HOST_CONFIG"] = cfg_path

        with mock.patch.object(mcp.subprocess, "run", return_value=self._fake_run()) as run_mock:
            mcp._run_kubectl("logs", ["pod/api-7f9", "--previous"], "prod")

        _, kwargs = run_mock.call_args
        self.assertEqual(kwargs["input"], "kubectl logs -n prod pod/api-7f9 --previous\n")

    def test_no_become_user_is_byte_identical_to_before(self):
        cfg_path = _write_host_config(
            self.tmpdir,
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes", "bastion.example.com"],
        )
        os.environ["SRE_LEAD_HOST_CONFIG"] = cfg_path

        with mock.patch.object(mcp.subprocess, "run", return_value=self._fake_run()) as run_mock:
            mcp._run_kubectl("get", ["pods", "-n", "raas-preprod"], None)

        args, kwargs = run_mock.call_args
        argv = args[0]

        self.assertEqual(
            argv,
            [
                "/usr/bin/ssh",
                "-o",
                "BatchMode=yes",
                "bastion.example.com",
                "--",
                "bash",
                "-lc",
                "kubectl get pods -n raas-preprod",
            ],
        )
        # No stdin plumbing at all when become_user is unset - not even "".
        self.assertIsNone(kwargs["input"])

    def _fake_popen(self):
        written = []
        proc = mock.Mock()
        proc.stdin = mock.Mock()
        proc.stdin.write.side_effect = lambda s: written.append(s)
        proc.communicate.return_value = ("", "")
        proc.returncode = 0
        return proc, written

    def test_startup_snippet_and_become_user_write_sequentially_with_delay(self):
        cfg_path = _write_host_config(
            self.tmpdir,
            "/usr/bin/ssh",
            ["bastion.example.com"],
            become_user="devops_k8s_preprod",
            startup_snippet="mpp",
        )
        os.environ["SRE_LEAD_HOST_CONFIG"] = cfg_path

        fake_proc, written = self._fake_popen()
        with mock.patch.object(mcp.subprocess, "Popen", return_value=fake_proc) as popen_mock, \
                mock.patch.object(mcp.time, "sleep") as sleep_mock:
            outcome = mcp._run_kubectl("get", ["pods", "-n", "raas-preprod"], None)

        popen_mock.assert_called_once()
        argv = popen_mock.call_args[0][0]
        self.assertEqual(argv, ["/usr/bin/ssh", "bastion.example.com", "--", "bash", "-l"])
        # No `-c`, and every command sent as a separate stdin write, in order.
        self.assertNotIn("-c", argv)
        self.assertEqual(
            written,
            ["mpp\n", "sudo su - devops_k8s_preprod\n", "kubectl get pods -n raas-preprod\n"],
        )
        self.assertEqual(sleep_mock.call_count, 2)
        # Closing stdin is left to `communicate()` itself (see the production
        # code's comment) - not asserted here since the mock doesn't model
        # `communicate()`'s real internal behavior.
        self.assertTrue(outcome["ok"], outcome)

    def test_startup_snippet_without_become_user_skips_escalation_step(self):
        cfg_path = _write_host_config(
            self.tmpdir, "/usr/bin/ssh", ["bastion.example.com"], startup_snippet="mpp",
        )
        os.environ["SRE_LEAD_HOST_CONFIG"] = cfg_path

        fake_proc, written = self._fake_popen()
        with mock.patch.object(mcp.subprocess, "Popen", return_value=fake_proc), \
                mock.patch.object(mcp.time, "sleep") as sleep_mock:
            mcp._run_kubectl("get", ["pods"], None)

        self.assertEqual(written, ["mpp\n", "kubectl get pods\n"])
        self.assertEqual(sleep_mock.call_count, 1)


class RealBastionShimTests(unittest.TestCase):
    """Reproduces the captain's two real-bastion results with a local fake `su`/`ssh`.

    fake_su mimics the confirmed real behavior: silently ignores `-c` (never
    runs the command, just would drop into an interactive shell - here it
    exits with a distinct marker instead so the test can detect it), but
    reads and runs a command piped via stdin correctly.

    fake_ssh mimics the ssh hop: it discards everything before `--` (the
    connection args) and simply execs the remaining `bash -lc '<cmd>'`
    locally, so the whole chain (ssh -> bash -lc 'sudo su - user' <- stdin)
    runs for real, end to end, on this machine.
    """

    def setUp(self):
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self.tmpdir = self._tmpdir_ctx.name
        self.bin_dir = os.path.join(self.tmpdir, "bin")
        os.makedirs(self.bin_dir)

        _write_executable(
            os.path.join(self.bin_dir, "sudo"),
            "#!/bin/bash\nexec \"$@\"\n",
        )

        # Mimics the real bastion: `-c` is silently swallowed/ignored (here,
        # surfaced as a distinct failure marker rather than actually hanging
        # in an interactive shell, since the test has no TTY to hang on);
        # `su - <user>` with no `-c` reads one line from stdin and runs it.
        _write_executable(
            os.path.join(self.bin_dir, "su"),
            textwrap.dedent(
                """\
                #!/bin/bash
                for arg in "$@"; do
                    if [[ "$arg" == "-c" ]]; then
                        echo "SU_IGNORED_DASH_C_MARKER" >&2
                        exit 17
                    fi
                done
                user="${@: -1}"
                read -r cmdline
                echo "RAN_AS:${user}:${cmdline}"
                """
            ),
        )

        _write_executable(
            os.path.join(self.bin_dir, "fake_ssh"),
            textwrap.dedent(
                """\
                #!/bin/bash
                while [[ "$1" != "--" && $# -gt 0 ]]; do shift; done
                shift
                exec "$@"
                """
            ),
        )

        # `bash -lc` (what production code and this shim both use) is a
        # *login* shell on macOS, which sources /etc/profile ->
        # /usr/libexec/path_helper, which rebuilds PATH from /etc/paths(.d)
        # and puts real system directories (/usr/bin, containing the real
        # `su`) ahead of anything merely prepended to the parent's PATH
        # beforehand - confirmed live, a plain PATH prepend is not enough to
        # shadow the real `su`/`sudo`. A fake, isolated HOME with its own
        # `.bash_profile` that re-prepends the fake bin dir runs *after*
        # path_helper, so it wins.
        self.fake_home = os.path.join(self.tmpdir, "home")
        os.makedirs(self.fake_home)
        with open(os.path.join(self.fake_home, ".bash_profile"), "w") as f:
            f.write(f'export PATH="{self.bin_dir}:$PATH"\n')

        self._old_home = os.environ.get("HOME")
        os.environ["HOME"] = self.fake_home
        self._old_env = os.environ.get("SRE_LEAD_HOST_CONFIG")

    def tearDown(self):
        if self._old_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self._old_home
        if self._old_env is None:
            os.environ.pop("SRE_LEAD_HOST_CONFIG", None)
        else:
            os.environ["SRE_LEAD_HOST_CONFIG"] = self._old_env
        self._tmpdir_ctx.cleanup()

    def test_new_stdin_construction_succeeds_against_dash_c_ignoring_su(self):
        cfg_path = _write_host_config(
            self.tmpdir,
            os.path.join(self.bin_dir, "fake_ssh"),
            ["irrelevant-host-arg"],
            become_user="devops_k8s_preprod",
        )
        os.environ["SRE_LEAD_HOST_CONFIG"] = cfg_path

        outcome = mcp._run_kubectl("get", ["pods", "-n", "raas-preprod"], None)

        self.assertTrue(outcome["ok"], outcome)
        self.assertIn("RAN_AS:devops_k8s_preprod:kubectl get pods -n raas-preprod", outcome["stdout"])
        self.assertNotIn("SU_IGNORED_DASH_C_MARKER", outcome["stderr"])

    def test_old_dash_c_shape_would_have_failed_on_this_shim(self):
        """Sanity check that the shim really does reproduce the old failure."""
        old_style_cmd = "sudo su -c 'kubectl get pods -n raas-preprod' - devops_k8s_preprod"
        import subprocess

        proc = subprocess.run(
            [os.path.join(self.bin_dir, "fake_ssh"), "irrelevant", "--", "bash", "-lc", old_style_cmd],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(proc.returncode, 17)
        self.assertIn("SU_IGNORED_DASH_C_MARKER", proc.stderr)


class RealMultiHopShimTests(unittest.TestCase):
    """Reproduces the timing race a startup snippet introduces, per
    `fm/cockpit-sre-lead-startup-snippet`'s acceptance criteria: a fake
    "remote" simulates a nested-ssh handshake delay right after the snippet
    command arrives, discarding anything that shows up while it's still
    "connecting" - mimicking a real nested `ssh` hop's own handshake. The old
    single-`input=`-blob approach (what a naive extension of the pre-fix code
    would have done) sends every command immediately and loses the kubectl
    command to that window; the new sequential-write-with-delay approach in
    `_run_via_sequential_shell` waits it out and succeeds.
    """

    def setUp(self):
        self._tmpdir_ctx = tempfile.TemporaryDirectory()
        self.tmpdir = self._tmpdir_ctx.name

        # A stdlib-only fake "remote shell": echoes each line it processes as
        # "RAN:<line>". After the line that matches the snippet trigger, it
        # simulates a nested-hop handshake by discarding (not processing) any
        # further input that arrives during BUSY_WINDOW - a real interactive
        # shell mid-handshake wouldn't hand typed-ahead input to the right
        # place either.
        self.fake_remote = os.path.join(self.tmpdir, "fake_remote.py")
        with open(self.fake_remote, "w") as f:
            f.write(textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import sys, select, time
                BUSY_WINDOW = 0.5

                def main():
                    first = sys.stdin.readline()
                    if not first:
                        return
                    first = first.rstrip("\\n")
                    sys.stdout.write("RAN:" + first + "\\n")
                    sys.stdout.flush()
                    if first == "run-mpp-snippet":
                        deadline = time.time() + BUSY_WINDOW
                        while time.time() < deadline:
                            remaining = deadline - time.time()
                            ready, _, _ = select.select([sys.stdin], [], [], max(remaining, 0))
                            if not ready:
                                break
                            sys.stdin.readline()  # discard - simulates a lost keystroke
                    for line in sys.stdin:
                        line = line.rstrip("\\n")
                        if not line:
                            continue
                        sys.stdout.write("RAN:" + line + "\\n")
                        sys.stdout.flush()

                if __name__ == "__main__":
                    main()
                """
            ))
        os.chmod(self.fake_remote, os.stat(self.fake_remote).st_mode | stat.S_IEXEC)

        self.fake_ssh = os.path.join(self.tmpdir, "fake_ssh")
        _write_executable(self.fake_ssh, f"#!/bin/bash\nexec {sys.executable} {self.fake_remote}\n")

        self._old_env = os.environ.get("SRE_LEAD_HOST_CONFIG")

    def tearDown(self):
        if self._old_env is None:
            os.environ.pop("SRE_LEAD_HOST_CONFIG", None)
        else:
            os.environ["SRE_LEAD_HOST_CONFIG"] = self._old_env
        self._tmpdir_ctx.cleanup()

    def test_old_single_blob_loses_kubectl_command_to_the_race(self):
        # What a naive extension of the pre-fix code would have done: hand
        # the snippet + kubectl command to subprocess.run's input= as one
        # blob, with no delay for the snippet's simulated nested hop.
        blob = "run-mpp-snippet\nkubectl get pods\n"
        proc = subprocess.run([self.fake_ssh], input=blob, capture_output=True, text=True, timeout=5)
        self.assertIn("RAN:run-mpp-snippet", proc.stdout)
        self.assertNotIn("RAN:kubectl get pods", proc.stdout)

    def test_sequential_write_with_delay_survives_the_same_race(self):
        cfg_path = _write_host_config(
            self.tmpdir, self.fake_ssh, ["irrelevant"], startup_snippet="run-mpp-snippet",
        )
        os.environ["SRE_LEAD_HOST_CONFIG"] = cfg_path

        # 2.0s, comfortably longer than the shim's 0.5s simulated busy window
        # plus any real child-process startup jitter (observed up to ~0.3s
        # spawning python through a bash wrapper) - the margin matters here:
        # too tight a gap made this test itself flaky, since the fake
        # remote's busy window starts counting from when *it* reads the
        # first line, not from when the parent wrote it.
        with mock.patch.object(mcp, "_SNIPPET_STEP_DELAY_SECONDS", 2.0):
            outcome = mcp._run_kubectl("get", ["pods"], None)

        self.assertTrue(outcome["ok"], outcome)
        self.assertIn("RAN:run-mpp-snippet", outcome["stdout"])
        self.assertIn("RAN:kubectl get pods", outcome["stdout"])


if __name__ == "__main__":
    unittest.main()
