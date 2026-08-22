// Manjesh Grand Line - native macOS app.
//
// GL-02 / GL-03 / GL-04 / GL-15 / GL-26 (production-readiness review). This is
// the app's one subprocess runner. Before it existed there were ~25 hand-rolled
// `Process` call sites across 21 files, seven copies of `resolveExecutable`,
// ten result structs, four identical git-auth blocks and five `claude -p`
// runners - and, more to the point, three distinct *classes* of live deadlock
// spread across them:
//
//  - **Wait-before-drain.** `proc.waitUntilExit()` before reading either pipe.
//    A child emitting more than one pipe buffer (~64KB) blocks forever, and so
//    does the thread waiting on it. `FleetDataSource.mergePR` had exactly this,
//    which is why a chatty merge script left the Merge button disabled for the
//    rest of the session. (Phase 1 hand-fixed that one site and `SSHKeyGenerator`.)
//  - **The half-fix: stdout to EOF, *then* stderr, then wait.** ~12 helpers
//    had this, and their own comments show the deadlock was understood - the
//    fix just only covered the stdout half. A child that fills the 64KB
//    *stderr* pipe while stdout is still open deadlocks identically, which is
//    entirely realistic for `npm -g`, `brew upgrade`, git advice output, or
//    `av`/`gh` failure spew. **This is the case `SubprocessSelfTest`'s
//    stderr-flood child pins**, because it is the one that reads as already
//    fixed.
//  - **Never-read stderr pipes.** A `Pipe()` attached to `standardError` and
//    never read is a 64KB fuse on the child. (Phase 1 converted five of these
//    in `FleetData` to `nullDevice`.)
//
// ## What this runner guarantees
//
//  1. **Both streams are drained concurrently, always.** Not "stdout first" -
//     concurrently, via `readabilityHandler` into a locked buffer, so neither
//     pipe can fill while the other is being read. A stream the caller does
//     not want is `FileHandle.nullDevice`, never an unread `Pipe`.
//  2. **Every run is bounded.** There is a default timeout, and on expiry the
//     child gets SIGTERM, then SIGKILL after a short grace. A run that times
//     out returns partial output with `timedOut == true` rather than blocking
//     its caller forever. This is what makes GL-03's poller watchdog a
//     backstop rather than the only defence.
//  3. **No thread is left blocked on a pipe.** `readDataToEndOfFile()` does
//     not return until *every* writer closes, which includes a grandchild that
//     inherited the pipe (`brew` spawning background work). Handler-based
//     reads can be torn down on the way out; a blocked `read(2)` cannot.
//  4. **One place for environment and token injection.** `childEnvironmentDict()`
//     is the base for every run (PATH fix-up for a Finder-launched GUI app,
//     `TMUX`/`HERDR_*` stripping), and secrets travel as environment variables
//     - never argv - so they never appear in `ps`. `gitAuthEnvironment` is the
//     single copy of the GitHub Basic-auth `http.extraheader` block that four
//     files each carried.
//  5. **One logging choke point** (GL-11): every non-zero exit, launch failure
//     and timeout is logged with the executable, the exit status and a bounded
//     slice of stderr. Arguments are logged only for the executable's own
//     name plus argv count, because argv can carry a prompt or a path the
//     review's redaction rules cover.
//
// ## What it deliberately does not do
//
// It does not wrap interactive/PTY work. `LocalProcessTerminalView` (every
// terminal tab, including the one-shot Console command tabs) forks its child
// in-process through SwiftTerm and has nothing to do with `Process`; a real
// `sudo` password prompt still needs a real terminal, which is why Bootstrap
// and Settings route through a Console tab rather than through this file.
//
// It is also synchronous by design. Callers that must not block - the pollers,
// the AI one-shots - already own a background queue or a completion handler;
// hiding that behind an async facade here would make the main-thread rule
// harder to see, not easier. `Subprocess.runAsync` exists for the narrow case
// of "I am on the main thread and need this off it" and is a thin wrapper.

import Foundation
import os

// MARK: - Result

struct SubprocessResult {

    enum Outcome: Equatable {
        /// The child ran to completion (successfully or not) - `status` is its
        /// real exit code.
        case exited
        /// The child did not finish within the timeout and was killed.
        /// `stdout`/`stderr` hold whatever it had produced by then.
        case timedOut
        /// The child could not be started at all (missing executable, bad
        /// working directory, fork failure). `stderr` holds the reason.
        case launchFailed
    }

    let outcome: Outcome
    /// The child's real exit status, or a sentinel for the two non-exit
    /// outcomes. `-1` for a launch failure is deliberate: it is the value the
    /// ~10 hand-rolled result structs this type replaces all used, so a call
    /// site that branches on `status == -1` keeps working unchanged.
    let status: Int32
    let stdoutData: Data
    let stderrData: Data
    /// Wall-clock duration, for the Health surface and for logging.
    let duration: TimeInterval

    /// Trimmed UTF-8, matching what every replaced helper returned. Callers
    /// that need the raw bytes (a downloaded blob, a `git show` of a binary)
    /// use `stdoutData`.
    var stdout: String { Self.text(stdoutData) }
    var stderr: String { Self.text(stderrData) }

    var timedOut: Bool { outcome == .timedOut }
    var launchFailed: Bool { outcome == .launchFailed }

    /// Ran, and the child itself reported success.
    var ok: Bool { outcome == .exited && status == 0 }

    /// The shape this app shows the captain when an action fails - see
    /// `CheckOutcome.log`'s own doc comment on why every action's real tool
    /// output is surfaced rather than a bare green checkmark.
    var combinedLog: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A one-line reason suitable for a status label, in the caller's own
    /// failure text. `nil` when the run succeeded.
    var failureSummary: String? {
        switch outcome {
        case .exited:
            if status == 0 { return nil }
            let detail = stderr.isEmpty ? stdout : stderr
            let firstLine = detail.split(separator: "\n").first.map(String.init) ?? ""
            return firstLine.isEmpty ? "exited with status \(status)" : firstLine
        case .timedOut:
            return "timed out"
        case .launchFailed:
            return stderr.isEmpty ? "could not start" : stderr
        }
    }

    private static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func launchFailure(_ message: String) -> SubprocessResult {
        SubprocessResult(outcome: .launchFailed, status: -1,
                         stdoutData: Data(), stderrData: Data(message.utf8), duration: 0)
    }
}

// MARK: - Early cancellation

/// A handle a caller can use to stop a run it started, without this file
/// handing out the underlying `Process`. Needed by exactly one shape of caller
/// today - SRE Lead tears down an in-flight `claude` turn when its pane closes
/// - and kept deliberately minimal so it does not become a general-purpose
/// process registry.
///
/// Cancelling before the child has launched is honoured: `run` checks the flag
/// after `Process.run()` and terminates immediately, so a cancel that races
/// the launch cannot leave an orphan.
final class SubprocessCancellation {

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init() {}

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    /// Returns false when the caller has already cancelled, so `run` can kill
    /// the just-launched child instead of letting it run to completion.
    fileprivate func adopt(_ process: Process) -> Bool {
        lock.lock()
        self.process = process
        let alreadyCancelled = cancelled
        lock.unlock()
        return !alreadyCancelled
    }

    fileprivate func release() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

// MARK: - Runner

enum Subprocess {

    /// Sentinel status for a killed-on-timeout run. Distinct from `-1` (launch
    /// failure) so a caller can tell "never started" from "started and hung"
    /// without inspecting `outcome`.
    static let timedOutStatus: Int32 = -2

    /// The default bound for a run whose caller did not pick one. Chosen to be
    /// generous enough for the slowest routine thing this app shells out to
    /// (`brew` resolving a cask, `git fetch` over a slow link) while still
    /// being a bound - the point of GL-02's fix is that *no* run is unbounded,
    /// not that every run is fast. Long operations pass their own value:
    /// `brew upgrade` and `git clone` legitimately take minutes.
    static let defaultTimeout: TimeInterval = 60

    /// How long a child gets between SIGTERM and SIGKILL. Long enough for git
    /// to release `.git/index.lock` on its way out, short enough that a
    /// caller's own timeout budget is not meaningfully overrun.
    private static let terminationGrace: TimeInterval = 2

    /// Where a stream's bytes should go.
    enum StreamPolicy {
        /// Capture into the result. Drained concurrently with the other stream.
        case capture
        /// `FileHandle.nullDevice` - the child writes to /dev/null. Use this
        /// (never an unread `Pipe`) when the caller genuinely does not want
        /// the output.
        case discard
        /// Merge into stdout, so a single combined log preserves interleaving.
        /// Only meaningful for stderr.
        case mergeIntoStdout
    }

    // MARK: Executable resolution

    /// The one copy of what was seven identical private `resolveExecutable`
    /// functions. A Finder- or `open`-launched GUI app inherits a bare minimal
    /// PATH with no Homebrew in it, so PATH alone is not enough - the fallback
    /// list is the same one every copy carried.
    ///
    /// An absolute path is returned as-is when it is executable, so a caller
    /// holding a configured path (a test seam, a captain-set tool location)
    /// can pass it straight through.
    static func resolveExecutable(_ name: String, extraCandidates: [String] = []) -> String? {
        let fm = FileManager.default
        if name.hasPrefix("/") {
            return fm.isExecutableFile(atPath: name) ? name : nil
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                let candidate = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        let fallbacks = extraCandidates + [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        for candidate in fallbacks where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    // MARK: The run

    /// Run `executable` and return once it has exited, been killed on timeout,
    /// or failed to start. Never blocks indefinitely; never deadlocks on a
    /// full pipe.
    ///
    /// - Parameters:
    ///   - env: the child's complete environment. Defaults to
    ///     `childEnvironmentDict()`, which is what every replaced helper used.
    ///     Pass a value only to replace that base wholesale; to *add* to it,
    ///     use `extraEnv`.
    ///   - extraEnv: merged over the base. This is the channel for secrets
    ///     (git tokens, the app-lock password candidate): environment
    ///     variables are not visible in `ps`, argv is.
    ///   - stdin: written to the child and then closed. `nil` means the child
    ///     gets `/dev/null`, so an interactive tool that would otherwise wait
    ///     on a terminal fails fast instead of hanging.
    ///   - label: what the log line calls this run. Defaults to the
    ///     executable's last path component.
    @discardableResult
    static func run(
        executable: String,
        arguments: [String] = [],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        extraEnv: [String: String] = [:],
        stdin: Data? = nil,
        timeout: TimeInterval? = defaultTimeout,
        stdout stdoutPolicy: StreamPolicy = .capture,
        stderr stderrPolicy: StreamPolicy = .capture,
        log: os.Logger = AppLog.subprocess,
        label: String? = nil,
        cancellation: SubprocessCancellation? = nil
    ) -> SubprocessResult {
        _ = ignoreSIGPIPE
        let name = label ?? (executable as NSString).lastPathComponent
        let started = Date()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let cwd { proc.currentDirectoryURL = cwd }

        var environment = env ?? childEnvironmentDict()
        for (key, value) in extraEnv { environment[key] = value }
        proc.environment = environment

        // stdin: a real pipe only when there is something to write. Anything
        // else gets /dev/null rather than this process's own stdin, so a child
        // that decides to prompt cannot hang on a terminal read - which is the
        // failure `av save`'s own `/dev/tty` requirement taught this codebase
        // the hard way (see VaultData's header).
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        proc.standardInput = inPipe ?? FileHandle.nullDevice

        let outPipe: Pipe? = stdoutPolicy == .capture ? Pipe() : nil
        proc.standardOutput = outPipe ?? FileHandle.nullDevice

        let errPipe: Pipe?
        switch stderrPolicy {
        case .capture:
            errPipe = Pipe()
            proc.standardError = errPipe
        case .discard:
            errPipe = nil
            proc.standardError = FileHandle.nullDevice
        case .mergeIntoStdout:
            errPipe = nil
            // Sharing one handle needs no second reader, so it cannot fill a
            // second buffer - safe by construction.
            proc.standardError = outPipe ?? FileHandle.nullDevice
        }

        let group = DispatchGroup()
        let outCollector = StreamCollector()
        let errCollector = StreamCollector()

        if let outPipe { outCollector.attach(to: outPipe.fileHandleForReading, group: group) }
        if let errPipe { errCollector.attach(to: errPipe.fileHandleForReading, group: group) }

        do {
            try proc.run()
        } catch {
            outCollector.detach()
            errCollector.detach()
            cancellation?.release()
            log.error("\(name, privacy: .public) failed to launch: \(error.localizedDescription, privacy: .public)")
            return .launchFailure(error.localizedDescription)
        }
        if let cancellation, !cancellation.adopt(proc) {
            // Cancelled while launching - kill it now rather than letting a
            // process the caller has already abandoned run to completion.
            proc.terminate()
        }

        // The writer runs on its own queue: a child that never reads stdin
        // would otherwise block this thread on the write, which is the same
        // class of bug in the other direction.
        if let inPipe, let stdin {
            group.enter()
            writeQueue.async {
                defer { group.leave() }
                let handle = inPipe.fileHandleForWriting
                // A child that exits before reading its input closes the read
                // end, and the write then raises SIGPIPE/EPIPE. `write(_:)`
                // traps on error, so go through the throwing variant.
                try? handle.write(contentsOf: stdin)
                try? handle.close()
            }
        }

        var outcome = SubprocessResult.Outcome.exited
        let deadline: DispatchTime? = timeout.map { .now() + $0 }

        // Waiting on the drain group also waits for the process: both pipes
        // reach EOF when the child (and anything holding its pipe ends) exits.
        if let deadline, group.wait(timeout: deadline) == .timedOut {
            outcome = .timedOut
            log.error("\(name, privacy: .public) exceeded its \(timeout ?? 0, format: .fixed(precision: 1))s timeout - terminating")
            if proc.isRunning { proc.terminate() }
            if group.wait(timeout: .now() + terminationGrace) == .timedOut {
                // SIGTERM was ignored, or a grandchild is still holding the
                // pipe open. Kill the child, then stop reading regardless -
                // the handler teardown in `detach()` is what keeps this from
                // leaking a permanently blocked reader.
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                _ = group.wait(timeout: .now() + terminationGrace)
            }
            outCollector.detach()
            errCollector.detach()
        } else if deadline == nil {
            group.wait()
        }

        // Safe now: either both pipes hit EOF (so the child has exited), or we
        // killed it above and reaped it here.
        if outcome != .timedOut {
            proc.waitUntilExit()
        } else if proc.isRunning {
            // Give the reap one bounded chance rather than blocking forever on
            // a process that somehow survived SIGKILL (unkillable D-state).
            let reaped = DispatchSemaphore(value: 0)
            proc.terminationHandler = { _ in reaped.signal() }
            _ = reaped.wait(timeout: .now() + terminationGrace)
            proc.terminationHandler = nil
        }

        cancellation?.release()

        let status = outcome == .timedOut ? timedOutStatus : proc.terminationStatus
        let result = SubprocessResult(
            outcome: outcome,
            status: status,
            stdoutData: outCollector.snapshot(),
            stderrData: errCollector.snapshot(),
            duration: Date().timeIntervalSince(started)
        )

        logCompletion(result, name: name, argc: arguments.count, log: log)
        return result
    }

    /// Convenience for the common "resolve on PATH, then run" pair. Returns a
    /// launch failure whose `stderr` names the missing tool, which is what
    /// every replaced helper reported.
    static func run(
        tool: String,
        arguments: [String] = [],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        extraEnv: [String: String] = [:],
        stdin: Data? = nil,
        timeout: TimeInterval? = defaultTimeout,
        stdout stdoutPolicy: StreamPolicy = .capture,
        stderr stderrPolicy: StreamPolicy = .capture,
        log: os.Logger = AppLog.subprocess,
        extraCandidates: [String] = []
    ) -> SubprocessResult {
        guard let executable = resolveExecutable(tool, extraCandidates: extraCandidates) else {
            log.error("\(tool, privacy: .public) not found on PATH")
            return .launchFailure("'\(tool)' not found on PATH")
        }
        return run(executable: executable, arguments: arguments, cwd: cwd, env: env,
                   extraEnv: extraEnv, stdin: stdin, timeout: timeout,
                   stdout: stdoutPolicy, stderr: stderrPolicy, log: log, label: tool)
    }

    /// Run off the main thread and hand the result back on `completion`'s
    /// queue (main by default). A thin wrapper - the point is that a caller on
    /// the main thread has one obvious way to not block it (GL-04).
    static func runAsync(
        executable: String,
        arguments: [String] = [],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        extraEnv: [String: String] = [:],
        timeout: TimeInterval? = defaultTimeout,
        stdout stdoutPolicy: StreamPolicy = .capture,
        stderr stderrPolicy: StreamPolicy = .capture,
        log: os.Logger = AppLog.subprocess,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completeOn completionQueue: DispatchQueue = .main,
        completion: @escaping (SubprocessResult) -> Void
    ) {
        DispatchQueue.global(qos: qos).async {
            let result = run(executable: executable, arguments: arguments, cwd: cwd, env: env,
                             extraEnv: extraEnv, timeout: timeout,
                             stdout: stdoutPolicy, stderr: stderrPolicy, log: log)
            completionQueue.async { completion(result) }
        }
    }

    // MARK: Git

    /// The single copy of the GitHub token injection that `ShiftGitSync`,
    /// `DocsRunbookGitSync`, `VaultRecipeGit` and `GitHubSyncData` each carried
    /// verbatim. GitHub's own documented shape for token-based git-over-HTTPS
    /// (the same `x-access-token` Basic-auth convention Actions' built-in token
    /// uses), delivered through `GIT_CONFIG_*` environment variables rather
    /// than a `-c` argument so the token is never in `ps`'s argv listing.
    ///
    /// Returns an empty dictionary - not an error - when there is no token or
    /// the remote is not `https://`. A local path or `file://` remote (every
    /// disposable-bare-repo self-test in this project) has no host to
    /// authenticate against, and offline must still be able to work locally.
    static func gitAuthEnvironment(remoteURL: String) -> [String: String] {
        guard remoteURL.hasPrefix("https://"), let token = DocsSyncSource.ghAuthToken() else { return [:] }
        let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
        return [
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.extraheader",
            "GIT_CONFIG_VALUE_0": "Authorization: Basic \(basic)",
            // A git that decides to prompt for credentials in a GUI-launched
            // process would otherwise hang until the timeout; failing fast is
            // strictly better feedback.
            "GIT_TERMINAL_PROMPT": "0",
        ]
    }

    /// `/usr/bin/git` is the one executable this app hardcodes rather than
    /// resolving: it ships with the Command Line Tools this project already
    /// requires, and picking up a PATH `git` would mean a captain's own shell
    /// configuration could change what the app's sync does.
    static let gitExecutable = "/usr/bin/git"

    /// Run git. `authenticateFor` supplies a remote URL when the operation
    /// talks to that remote (`clone`/`fetch`/`push`); a purely local operation
    /// (`status`, `show`, `commit`) passes `nil` and gets no token.
    static func git(
        _ arguments: [String],
        cwd: URL?,
        authenticateFor remoteURL: String? = nil,
        timeout: TimeInterval? = defaultTimeout,
        log: os.Logger = AppLog.gitSync
    ) -> SubprocessResult {
        var extra: [String: String] = ["GIT_TERMINAL_PROMPT": "0"]
        if let remoteURL {
            for (key, value) in gitAuthEnvironment(remoteURL: remoteURL) { extra[key] = value }
        }
        return run(executable: gitExecutable, arguments: arguments, cwd: cwd,
                   extraEnv: extra, timeout: timeout, log: log,
                   label: "git \(arguments.first ?? "")")
    }

    // MARK: Internals

    private static let writeQueue = DispatchQueue(label: "com.firstmate.cockpit.subprocess.stdin",
                                                  qos: .utility)

    /// Writing to a pipe whose reader has gone away raises SIGPIPE, whose
    /// default disposition is to kill the process. That is a real, reachable
    /// crash here rather than a theoretical one: any child that exits without
    /// reading all of its stdin (a `claude` that rejects its flags, a `git
    /// credential` helper with no helper configured) leaves the writer holding
    /// a broken pipe. Ignoring the signal turns it into the `EPIPE` the
    /// throwing `FileHandle.write(contentsOf:)` already handles.
    ///
    /// Process-wide and one-shot, which is the standard disposition for any
    /// program that talks to pipes at all - and correct for a GUI app, which
    /// has no shell-pipeline semantics to preserve. Installed lazily from the
    /// first run rather than from `main.swift` so a self-test that never
    /// touches this file's runner is unaffected.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private static func logCompletion(_ result: SubprocessResult, name: String, argc: Int, log: os.Logger) {
        switch result.outcome {
        case .exited where result.status == 0:
            log.debug("\(name, privacy: .public) ok in \(result.duration, format: .fixed(precision: 2))s (\(argc) args)")
        case .exited:
            // Bounded slice: a failing `brew`/`npm` can emit megabytes, and a
            // log line is a breadcrumb, not a transcript. The full text is
            // already surfaced to the captain through the caller's own log
            // field.
            log.error("""
                \(name, privacy: .public) exited \(result.status) after \
                \(result.duration, format: .fixed(precision: 2))s: \
                \(Self.excerpt(result.failureSummary ?? ""), privacy: .public)
                """)
        case .timedOut:
            log.error("\(name, privacy: .public) timed out after \(result.duration, format: .fixed(precision: 2))s and was killed")
        case .launchFailed:
            log.error("\(name, privacy: .public) failed to launch: \(Self.excerpt(result.stderr), privacy: .public)")
        }
    }

    private static func excerpt(_ text: String, limit: Int = 400) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

// MARK: - Concurrent stream drain

/// Reads one pipe end into a locked buffer via `readabilityHandler`, so both
/// of a child's streams can be drained at the same time from one thread's
/// point of view - which is the whole fix for GL-02.
///
/// Deliberately *not* `readDataToEndOfFile()` on a background thread. That
/// call does not return until every writer closes the pipe, which includes a
/// grandchild that inherited it (`brew` and `npm` both spawn such children),
/// so a timeout could kill the child and still leave a thread blocked on the
/// pipe forever. A handler can be torn down; a blocked `read(2)` cannot.
private final class StreamCollector {

    private let lock = NSLock()
    private var buffer = Data()
    private var handle: FileHandle?
    private var group: DispatchGroup?
    private var finished = false

    func attach(to handle: FileHandle, group: DispatchGroup) {
        lock.lock()
        self.handle = handle
        self.group = group
        lock.unlock()
        group.enter()
        handle.readabilityHandler = { [weak self] h in
            guard let self else { return }
            // `availableData` returns empty at EOF. It can throw an ObjC
            // exception on a closed descriptor, which is exactly what
            // `detach()` guards against by clearing the handler first.
            let chunk = h.availableData
            if chunk.isEmpty {
                self.finish()
            } else {
                self.lock.lock()
                self.buffer.append(chunk)
                self.lock.unlock()
            }
        }
    }

    /// Stop reading and release the group, whether or not EOF was reached.
    /// Called on the timeout path.
    func detach() {
        finish()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    private func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let h = handle
        let g = group
        handle = nil
        group = nil
        lock.unlock()
        h?.readabilityHandler = nil
        g?.leave()
    }
}
