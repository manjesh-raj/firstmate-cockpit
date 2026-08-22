// Manjesh Grand Line - native macOS app.
//
// `swift build && FM_RUN_PHASE1_HARDENING_TESTS=1 .build/debug/FirstmateCockpit`
//
// Permanent regression coverage for the two phase-1 findings whose fix is a
// single easily-deleted line, and whose absence is invisible until the day it
// matters:
//
//  - **GL-08**: `ssh`'s argv must be option-terminated with `--` before the
//    destination, and a leading `-` must be rejected at every entry point.
//    A regression here is a local code-execution vector reachable from a
//    restored `.glbackup`, and nothing about the app looks or behaves
//    differently until someone exploits it. Note what is asserted: not "the
//    address is escaped" (it is not, and should not be - ssh takes it
//    verbatim) but "`--` sits immediately before the destination", which is
//    the property that makes a leading dash harmless.
//  - **GL-05**: the single-instance lock actually excludes a second holder.
//    This is tested through the `flock` layer only - the
//    `NSRunningApplication` layer needs two real bundled processes, and the
//    Info.plist layer is Launch Services' job. `FM_INSTANCE_LOCK_FILE` keeps
//    the test off the captain's real lock file, so running this while the app
//    is open is safe.

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum Phase1HardeningSelfTest {

    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            failures.append(label)
        }
    }

    static func run() -> Bool {
        print("== Phase 1 hardening self-test (GL-05 / GL-08) ==")
        failures = []

        sshArgvIsOptionTerminated()
        quickConnectRejectsLeadingDash()
        hostUnsafeFieldDetection()
        backupImportRefusesUnsafeHosts()
        instanceLockExcludesASecondHolder()

        print(failures.isEmpty
            ? "== PASS (phase 1 hardening) =="
            : "== FAIL (phase 1 hardening): \(failures.count) case(s) ==")
        return failures.isEmpty
    }

    // MARK: - GL-08

    private static func sshArgvIsOptionTerminated() {
        print("- Host.sshArguments: `--` immediately precedes the destination")

        let plain = Host(label: "Prod", address: "bastion.example.com", username: "manjesh")
        let args = plain.sshArguments()
        check(args.last == "manjesh@bastion.example.com", "the destination is still the last argument")
        check(args.count >= 2 && args[args.count - 2] == "--", "`--` is the argument immediately before it")

        // With every optional flag present, so a future change that appends
        // something after the destination is caught rather than silently
        // moving `--` away from it.
        let loaded = Host(
            label: "Loaded", address: "10.0.0.5", port: 2222, username: "root",
            agentForward: true,
            portForwards: [PortForwardRule(kind: .local, listenPort: 8080, destHost: "127.0.0.1", destPort: 80)]
        )
        let loadedArgs = loaded.sshArguments()
        check(loadedArgs.last == "root@10.0.0.5", "flags do not displace the destination")
        check(loadedArgs.count >= 2 && loadedArgs[loadedArgs.count - 2] == "--",
              "`--` still sits directly before the destination with -A/-L/-p present")
        check(loadedArgs.contains("-A") && loadedArgs.contains("-p"), "the flags themselves are still emitted")

        // The attack payload itself: even if such a host somehow existed, the
        // terminator means ssh reads it as a (bogus) hostname, never an option.
        let hostile = Host(label: "x", address: "-oProxyCommand=/usr/bin/touch /tmp/pwned")
        let hostileArgs = hostile.sshArguments()
        guard let dashDash = hostileArgs.firstIndex(of: "--") else {
            check(false, "a dash-leading address is still option-terminated")
            return
        }
        check(dashDash == hostileArgs.count - 2,
              "a dash-leading address sits after `--`, so ssh cannot parse it as -o")
    }

    private static func quickConnectRejectsLeadingDash() {
        print("- HostCatalog.parseQuickConnect: refuses a dash-leading destination")
        check(HostCatalog.parseQuickConnect("-oProxyCommand=id") == nil, "a bare `-o...` is refused")
        check(HostCatalog.parseQuickConnect("ssh -oProxyCommand=id") == nil, "the `ssh `-prefixed form is refused")
        check(HostCatalog.parseQuickConnect("root@-evil") == nil, "a dash-leading host after `user@` is refused")
        check(HostCatalog.parseQuickConnect("-bad@host") == nil, "a dash-leading username is refused")

        // ...and still parses everything it used to. A validation change that
        // broke ordinary quick-connect would be a worse regression than the
        // bug it guards against.
        guard let ok = HostCatalog.parseQuickConnect("manjesh@bastion.example.com:2222") else {
            check(false, "an ordinary user@host:port still parses")
            return
        }
        check(ok.args.last == "manjesh@bastion.example.com", "the ordinary destination is unchanged")
        check(ok.args.contains("--"), "the ordinary form is option-terminated too")
        check(ok.args.contains("2222"), "an explicit port survives")
        check(HostCatalog.parseQuickConnect("[::1]") != nil, "a bracketed IPv6 literal still parses")
        check(HostCatalog.parseQuickConnect("2001:db8::1") != nil, "a bare IPv6 literal still parses")
    }

    private static func hostUnsafeFieldDetection() {
        print("- Host.unsafeFieldNames: names exactly the offending fields")
        check(Host(label: "a", address: "ok.example.com").unsafeFieldNames.isEmpty, "a clean host reports nothing")
        check(Host(label: "a", address: "-x").unsafeFieldNames == ["Address"], "a bad address is named")
        check(Host(label: "a", address: "ok", username: "-x").unsafeFieldNames == ["Username"], "a bad username is named")
        check(Host(label: "a", address: "ok", jumpVia: "-x").unsafeFieldNames == ["Jump host"], "a bad jump host is named")
        // Leading whitespace must not smuggle one past the check.
        check(Host(label: "a", address: "  -oProxyCommand=id").unsafeFieldNames == ["Address"],
              "leading whitespace does not hide a leading dash")
    }

    private static func backupImportRefusesUnsafeHosts() {
        print("- BackupImport: a tampered bundle's unsafe host never reaches the store")
        let good = Host(label: "Good", address: "bastion.example.com", username: "manjesh")
        let evil = Host(label: "Evil", address: "-oProxyCommand=/usr/bin/touch /tmp/pwned")
        let bundle = GrandLineBackup(hosts: [good, evil], snippets: [], keys: [], settings: BackupSettings())

        let preview = BackupImport.diff(bundle: bundle, existingHosts: [], existingSnippets: [], existingKeys: [])
        check(preview.hostRows.count == 1, "only the safe host produced a diff row")
        check(preview.hostRows.first?.label == "Good", "and it is the safe one")
        check(preview.rejectedHostWarnings.count == 1, "the refusal is reported to the captain")
        check(preview.rejectedHostWarnings.first?.contains("Evil") == true, "the warning names the refused host")
        check(preview.rejectedHostWarnings.first?.contains("Address") == true, "and names the offending field")

        // `apply` works off `hostRows`, so the refused host is structurally
        // unreachable - assert that rather than trusting the comment.
        let applied = Set(preview.hostRows.map { $0.bundleHost.address })
        check(!applied.contains(evil.address), "the unsafe address is absent from everything apply() can write")
    }

    // MARK: - GL-05

    private static func instanceLockExcludesASecondHolder() {
        print("- SingleInstanceGuard: the flock excludes a second holder")
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-instance-lock-\(UUID().uuidString)")
        setenv("FM_INSTANCE_LOCK_FILE", scratch.path, 1)
        defer {
            unsetenv("FM_INSTANCE_LOCK_FILE")
            try? FileManager.default.removeItem(at: scratch)
        }

        check(SingleInstanceGuard.lockFileURL().path == scratch.path, "the override points at the scratch lock file")

        // `activateExisting: false` - never bring a real running app forward
        // from a headless test.
        switch SingleInstanceGuard.acquire(activateExisting: false) {
        case .acquired:
            check(true, "the first acquire succeeds")
        case .alreadyRunning:
            check(false, "the first acquire succeeds")
            return
        }

        let contents = (try? String(contentsOf: scratch, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        check(contents == "\(ProcessInfo.processInfo.processIdentifier)", "the lock file records this process's pid")

        // A second holder has to be a genuinely different process - `flock` is
        // per-open-file-description, so re-acquiring from *this* process would
        // succeed and prove nothing. Spawning `/usr/bin/flock`-style helpers
        // isn't portable on macOS, so use a tiny `python3` child that takes the
        // same advisory lock non-blockingly and reports whether it got it.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["python3", "-c", """
import fcntl, sys
f = open(sys.argv[1], 'a+')
try:
    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(7)
sys.exit(0)
""", scratch.path]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            check(probe.terminationStatus == 7, "a separate process cannot take the lock while we hold it")
        } catch {
            print("  ! could not spawn the python3 lock probe (\(error.localizedDescription)) - skipping the "
                + "cross-process half; the same-process half above still ran")
        }

        SingleInstanceGuard.releaseForTests()

        // Once released, the same probe must succeed - otherwise this test
        // would pass even if the lock were never actually released, e.g. if
        // the probe were failing for an unrelated reason.
        let after = Process()
        after.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        after.arguments = probe.arguments
        after.standardOutput = FileHandle.nullDevice
        after.standardError = FileHandle.nullDevice
        do {
            try after.run()
            after.waitUntilExit()
            check(after.terminationStatus == 0, "the lock is genuinely released afterwards (so the check above means something)")
        } catch {
            print("  ! could not spawn the release probe - skipped")
        }
    }
}

#endif
