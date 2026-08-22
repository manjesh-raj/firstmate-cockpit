// Manjesh Grand Line - native macOS app.
//
// Dictation's optional local Whisper engine (fm/grandline-dictation-whisper-
// engine) - downloads and locates the large-v3-turbo ggml model, on demand,
// into local app storage. The model is never bundled into the app (it's
// ~547MB) - this is the one piece of Dictation that needs a network fetch
// the first time the local-engine toggle is turned on, mirroring how
// `DocsSyncSource`/`UpdatesSource` already fetch real external content into
// `~/Library/Application Support/FirstmateCockpit/...` on demand rather than
// shipping it in the bundle.

import Foundation

/// A plain-message error - `String` itself can't conform to `Error` directly.
struct WhisperModelValidationError: Error {
    let message: String
}

/// One model file's download/availability state - `WhisperModelManager`'s
/// one source of truth, mirroring `DictationStatus`'s own "real state, never
/// fabricated" shape.
enum WhisperModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case ready
    case failed(String)
}

/// Downloads, validates, and locates the quantized large-v3-turbo ggml model
/// (per the captain-approved plan's phase-1 model choice - not a smaller/
/// faster size, and not a model-picker UI, both explicitly out of scope for
/// this pass). One instance for the app's whole lifetime, owned by the app
/// delegate alongside `DictationStore`/`DictationEngine`.
final class WhisperModelManager: NSObject {
    static let shared = WhisperModelManager()

    /// The file name whisper.cpp itself uses for this exact model (matches
    /// upstream's own `models/download-ggml-model.sh` naming convention) -
    /// also what `WhisperCppEngine.init(modelPath:)` is handed.
    static let modelFileName = "ggml-large-v3-turbo-q5_0.bin"

    /// Real, live-verified URL (HTTP 302 -> a real ~547MB file, confirmed via
    /// a direct HEAD request against this exact path before wiring this up -
    /// not guessed or fabricated) - the same host and path convention
    /// upstream whisper.cpp's own `models/download-ggml-model.sh` uses
    /// (`src="https://huggingface.co/ggerganov/whisper.cpp"`, this file's own
    /// name). Quantized to q5_0 rather than the full-precision or q8_0
    /// variant - the smaller download the plan's "still fully offline, real
    /// accuracy win" framing calls for, without the picker UI a choice of
    /// quantization level would otherwise imply.
    static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelFileName)")!

    /// `~/Library/Application Support/FirstmateCockpit/whisper/`, overridable
    /// via `FM_WHISPER_MODEL_DIR` - the same `FM_*_DIR` convention
    /// `DictationStore`/`HostStore`/etc. already established, so tests can
    /// point this at a scratch directory without touching a captain's real
    /// (large, slow-to-redownload) model file.
    static func directoryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_WHISPER_MODEL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("whisper", isDirectory: true)
    }

    var modelPathOnDisk: String {
        Self.directoryURL().appendingPathComponent(Self.modelFileName).path
    }

    private(set) var state: WhisperModelState = .notDownloaded

    /// Mirrors `DictationStore.observe`'s "list of closures" shape - both the
    /// Dictation page (progress bar) and anything else that cares (none yet)
    /// can subscribe independently.
    private var observers: [(WhisperModelState) -> Void] = []
    func observe(_ handler: @escaping (WhisperModelState) -> Void) {
        observers.append(handler)
        handler(state)
    }

    private var session: URLSession?
    private var activeTask: URLSessionDownloadTask?

    override init() {
        super.init()
        refreshState()
    }

    /// Re-reads real on-disk state - called on init and whenever the
    /// Dictation page appears, matching every other "no polling, refresh on
    /// appear" store in this app (`DictationPermissions`, `VaultSource`).
    /// Deliberately does NOT re-validate the file's contents on every call
    /// (that would mean re-reading a 547MB file just to render a status) -
    /// the one real validation pass happens once, right after a download
    /// completes, in `didFinishDownloadingTo` below. A file that somehow got
    /// corrupted on disk after that point (manual tampering, disk failure)
    /// is still caught downstream: `WhisperCppEngine.init?` fails to load it,
    /// and `DictationEngine` falls back to Apple Speech rather than trusting
    /// this state blindly.
    func refreshState() {
        if FileManager.default.fileExists(atPath: modelPathOnDisk) {
            state = .ready
        } else if case .downloading = state {
            // Leave an in-flight download's progress alone.
        } else {
            state = .notDownloaded
        }
        notify()
    }

    var isReady: Bool { state == .ready }

    func startDownload() {
        if case .ready = state { return }
        if case .downloading = state { return }
        try? FileManager.default.createDirectory(at: Self.directoryURL(), withIntermediateDirectories: true)
        state = .downloading(progress: 0)
        notify()
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: Self.modelURL)
        activeTask = task
        task.resume()
    }

    /// Cancels an in-flight download and reports `.notDownloaded` - `URLSession`
    /// itself owns the temp file it was writing to and cleans it up once the
    /// task is cancelled (this class never sees or manages that temp path
    /// directly), so there is no partial file left anywhere a later
    /// `refreshState()` could mistake for a valid model.
    func cancelDownload() {
        activeTask?.cancel()
        activeTask = nil
        session?.invalidateAndCancel()
        session = nil
        state = .notDownloaded
        notify()
    }

    /// GL-35: delete the downloaded model.
    ///
    /// The review's finding was blunt - 547MB with no way to get it back
    /// except finding the directory by hand. A captain who tried the local
    /// engine and went back to Apple Speech has no reason to keep it, and the
    /// app that manages every other tool's disk footprint should not be the
    /// one thing that strands half a gigabyte.
    ///
    /// Cancels an in-flight download first, so "delete" means the same thing
    /// in every state. Returns whether anything was actually removed.
    @discardableResult
    func deleteDownloadedModel() -> Bool {
        if case .downloading = state { cancelDownload() }
        let path = modelPathOnDisk
        guard FileManager.default.fileExists(atPath: path) else {
            refreshState()
            return false
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            AppLog.store.info("deleted the local Whisper model")
        } catch {
            AppLog.store.error("could not delete the local Whisper model: \(error.localizedDescription, privacy: .public)")
            state = .failed("Could not delete the model: \(error.localizedDescription)")
            notify()
            return false
        }
        refreshState()
        return true
    }

    /// The model file's size on disk, for a UI that wants to say what deleting
    /// it would actually reclaim. `nil` when it is not downloaded.
    var downloadedByteCount: Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: modelPathOnDisk)
        return (attrs?[.size] as? NSNumber)?.int64Value
    }

    /// The real, cheap validation this class applies to a just-downloaded
    /// file before it's ever treated as a usable model - separated out so a
    /// test can exercise it directly against a crafted fixture without a
    /// real 547MB network transfer. Two checks, not a cryptographic
    /// checksum: upstream (`ggml-org/whisper.cpp`'s own
    /// `models/download-ggml-model.sh`) publishes no checksum manifest for
    /// these files to verify against (checked directly, not assumed) -
    /// (1) the file is at least plausibly large (catches a near-empty/
    /// aborted transfer), and (2) it starts with `GGML_FILE_MAGIC`
    /// (`whisper.cpp`'s own model-loader magic-number check, `0x67676d6c` -
    /// see `Vendor/whisper.cpp/Sources/CWhisper/whisper-src/whisper.cpp`'s
    /// `"invalid model data (bad magic)"` check). A file that passes both but
    /// is still truncated mid-tensor-data is caught one layer up:
    /// `WhisperCppEngine.init?` fails to load it, and `DictationEngine` falls
    /// back to Apple Speech rather than trusting this validation alone.
    static func validate(fileAt url: URL) -> Result<Void, WhisperModelValidationError> {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 10_000_000 else {
            return .failure(WhisperModelValidationError(message: "Downloaded file is too small to be a real model - the download likely failed partway through."))
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(WhisperModelValidationError(message: "Downloaded file could not be read back."))
        }
        defer { try? handle.close() }
        guard let magicData = try? handle.read(upToCount: 4), magicData.count == 4 else {
            return .failure(WhisperModelValidationError(message: "Downloaded file could not be read back."))
        }
        let magic = magicData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard magic == 0x67676d6c else {
            return .failure(WhisperModelValidationError(message: "Downloaded file failed validation (unexpected format) - it will not be used."))
        }
        return .success(())
    }

    private func notify() {
        let current = state
        DispatchQueue.main.async { [weak self] in
            self?.observers.forEach { $0(current) }
        }
    }
}

extension WhisperModelManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            guard let self, case .downloading = self.state else { return }
            self.state = .downloading(progress: progress)
            self.notify()
        }
    }

    /// `URLSession` hands this delegate a temp file that is deleted the
    /// moment this method returns - validation and the move into place both
    /// have to happen synchronously, right here, before that happens. A file
    /// that fails validation is never moved anywhere real - it stays exactly
    /// where `URLSession`'s own temp-file lifecycle discards it, so a failed
    /// download can never be mistaken for a valid model later.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        switch Self.validate(fileAt: location) {
        case .failure(let validationError):
            DispatchQueue.main.async { [weak self] in
                self?.state = .failed(validationError.message)
                self?.notify()
            }
        case .success:
            do {
                let dest = URL(fileURLWithPath: modelPathOnDisk)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                DispatchQueue.main.async { [weak self] in
                    self?.state = .ready
                    self?.notify()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.state = .failed("Could not save the downloaded model: \(error.localizedDescription)")
                    self?.notify()
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        DispatchQueue.main.async { [weak self] in
            self?.state = .failed(error.localizedDescription)
            self?.notify()
        }
    }
}
