// Manjesh Grand Line - native macOS app.
//
// GL-05: refuse to run two copies of this app at once.
//
// Why this is a real problem and not hygiene: every JSON store in this app is
// load-once-then-last-writer-wins (`HostStore`, `SSHKeyStore`, `SnippetStore`,
// `DictationStore`), so instance A's stale `persist()` silently discards
// everything B saved since A launched - with no error and, crucially, no
// corrupt-file backup either, because the file it overwrites decodes perfectly
// well. Worse, two processes share one Shift git working tree with a
// *per-process* serial queue, so they collide on `.git/index.lock` (which
// `ShiftGitSync`'s own comments name), and first-run `ensureWorkingTreeNow()`
// does a `removeItem` + `moveItem` swap - a second instance arriving mid-swap
// deletes the clone the first one just installed.
//
// AGENTS.md already documents that every build of this app shares one bundle
// identity and that accidental second instances are a real, recurring event on
// this machine. So this file has to cover two shapes:
//
//  1. **A second bundled `.app` launch.** `LSMultipleInstancesProhibited` in
//     the Info.plist (see `build_native_app.sh`) makes Launch Services
//     activate the running copy instead of starting a new process, so in the
//     normal double-click case this code never even runs. The
//     `NSRunningApplication` check below is the belt-and-braces version for
//     the paths that bypass Launch Services (`open -n`, running the binary
//     inside the bundle directly).
//  2. **An unbundled `swift run` / `.build/debug` binary**, which has no
//     bundle identifier at all, so neither of the above applies. That is
//     exactly the case AGENTS.md warns about (a worktree build colliding with
//     the captain's real running instance), and it is covered by the advisory
//     `flock` on a lock file in Application Support - which also catches a
//     bundled copy vs. an unbundled one, since both take the same lock.
//
// Deliberately *not* covered: the self-test binaries. Every `FM_RUN_*_TESTS=1`
// invocation runs headless and exits before touching `NSApplication`, and
// several of them legitimately run while the captain's real app is open, so
// `acquire()` is called from `applicationDidFinishLaunching`'s path only - not
// from `main.swift`'s top level.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum SingleInstanceGuard {

    enum Outcome {
        /// This process is the only instance - carry on.
        case acquired
        /// Another instance already holds the lock. It has been activated
        /// (when we could find it); this process should exit without touching
        /// any store.
        case alreadyRunning(pid: pid_t?)
    }

    /// Set once `acquire()` succeeds. Held for the process's lifetime - the
    /// `flock` is released by the kernel on exit (including a crash), so there
    /// is no stale-lock-file cleanup problem to get wrong.
    private static var lockDescriptor: Int32?

    /// `~/Library/Application Support/FirstmateCockpit/instance.lock`.
    /// Overridable via `FM_INSTANCE_LOCK_FILE` so a self-test can take a
    /// scratch lock instead of contending with the captain's real instance.
    static func lockFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_INSTANCE_LOCK_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("instance.lock")
    }

    /// Try to become the one instance.
    ///
    /// - Parameter activateExisting: whether to bring the already-running copy
    ///   forward when one is found (the right behaviour for a real launch;
    ///   a self-test passes `false`).
    static func acquire(activateExisting: Bool = true) -> Outcome {
        #if canImport(AppKit)
        if let other = otherRunningInstance() {
            if activateExisting { other.activate(options: [.activateIgnoringOtherApps]) }
            return .alreadyRunning(pid: other.processIdentifier)
        }
        #endif
        return acquireLockFile()
    }

    #if canImport(AppKit)
    /// Another process with our exact bundle identifier. `nil` for an
    /// unbundled binary (no identifier to match on) - that case falls through
    /// to the lock file, which is the whole reason the lock file exists.
    private static func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != me }
    }
    #endif

    /// An advisory whole-file `flock(LOCK_EX | LOCK_NB)`. The descriptor is
    /// intentionally leaked for the process's lifetime; the kernel drops the
    /// lock when the process dies, however it dies, so a crashed instance
    /// never leaves the app permanently unlaunchable.
    private static func acquireLockFile() -> Outcome {
        let url = lockFileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // Cannot create/open the lock file at all (a read-only container,
            // a permissions problem). Failing *open* here is deliberate: a
            // guard that cannot run must not block the app from starting.
            NSLog("[cockpit] single-instance: could not open \(url.path) - proceeding unguarded")
            return .acquired
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let heldBy = pidInLockFile(fd: fd)
            close(fd)
            return .alreadyRunning(pid: heldBy)
        }
        // Record our pid for diagnostics (and so the loser can name the
        // winner). Truncate first - a previous, longer pid would otherwise
        // leave trailing bytes.
        ftruncate(fd, 0)
        let line = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        lockDescriptor = fd
        return .acquired
    }

    private static func pidInLockFile(fd: Int32) -> pid_t? {
        var buf = [CChar](repeating: 0, count: 32)
        let n = pread(fd, &buf, 31, 0)
        guard n > 0 else { return nil }
        let text = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(text)
    }

    /// Releases the lock. Only needed by self-tests - a real instance holds it
    /// until it exits.
    static func releaseForTests() {
        guard let fd = lockDescriptor else { return }
        flock(fd, LOCK_UN)
        close(fd)
        lockDescriptor = nil
    }
}
