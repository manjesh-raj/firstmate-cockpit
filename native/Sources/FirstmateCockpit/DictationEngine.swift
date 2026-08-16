// Manjesh Grand Line - native macOS app.
//
// Dictation, phase 1 (fm/grandline-dictation-mvp): a first-party, in-process
// dictation pipeline - not an integration with the third-party
// "OpenSuperWhisper" app, which a captain-approved Lavish plan discussion
// explicitly rejected as impractical (different build system, a Rust-based
// engine incompatible with this app's plain-`swift build`-only, no-Xcode
// convention - see this project's own `native/README.md`/`CLAUDE.md`
// conventions).
//
// The pipeline is entirely Apple frameworks, no vendored engine:
//   - `AVAudioEngine` captures microphone audio while Right ⌥ Option is held.
//   - `SFSpeechRecognizer` (Apple's built-in Speech framework) transcribes it,
//     requesting on-device recognition (`requiresOnDeviceRecognition = true`)
//     whenever the recognizer reports it supports that for the current
//     locale/OS - falling back to Apple's server-backed recognition
//     otherwise, since not every locale/OS combination supports on-device.
//   - The final recognized text is pasted at the current cursor position via
//     `NSPasteboard` + a synthetic Cmd+V (`CGEvent`), not the Accessibility
//     `AXUIElement` API - see `DictationEngine.pasteAtCursor` below for why
//     that was the more reliable choice in practice.
//
// Vendoring `whisper.cpp` was explicitly ruled out of this phase (only ever a
// later upgrade path if Apple's Speech framework proves insufficient in real
// use) - see this file's own header and `CLAUDE.md`'s "Dictation" section for
// the full phase 1/2/3 split.
//
// Permission state (`DictationPermissions`) is read fresh every time via the
// real system APIs, never cached/assumed - `DictationController` polls it on
// every `viewWillAppear` and `DictationEngine.startRecording()` re-checks it
// before ever opening the microphone, so a permission revoked in System
// Settings after this app launched is caught immediately rather than only at
// next relaunch.

import AVFoundation
import AppKit
import ApplicationServices
import Speech

/// A single permission's tri-state, mirroring the shape every other
/// permission check in this app already uses (see `SudoTouchIDData.swift`,
/// `VaultSource.checkAppPasswordConfigured`) - real state read from the OS,
/// never fabricated.
enum DictationPermissionState: Equatable {
    case notDetermined
    case granted
    case denied
}

/// The Dictation page's one real status value - exactly the four states the
/// task brief calls for, plus a `recording` state so the page (and, later,
/// any status-pill UI) can reflect an in-flight dictation truthfully rather
/// than freezing on whatever permission state was last read.
enum DictationStatus: Equatable {
    case ready
    case needsMicrophone
    case needsSpeechRecognition
    case needsAccessibility
    case recording
    case transcribing

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .needsMicrophone: return "Needs Microphone access"
        case .needsSpeechRecognition: return "Needs Speech Recognition access"
        case .needsAccessibility: return "Needs Accessibility access"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        }
    }

    var detail: String {
        switch self {
        case .ready: return "Hold Right ⌥ Option anywhere to dictate."
        case .needsMicrophone: return "Grand Line needs permission to use your microphone before it can dictate."
        case .needsSpeechRecognition: return "Grand Line needs permission to use on-device Speech Recognition before it can dictate."
        case .needsAccessibility: return "Grand Line needs Accessibility access so the Right ⌥ Option shortcut works from any app, and so it can paste the result at your cursor."
        case .recording: return "Listening - release Right ⌥ Option to transcribe."
        case .transcribing: return "Turning your speech into text…"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .needsMicrophone: return "mic.slash.fill"
        case .needsSpeechRecognition: return "exclamationmark.bubble.fill"
        case .needsAccessibility: return "hand.raised.slash.fill"
        case .recording: return "waveform"
        case .transcribing: return "ellipsis.circle.fill"
        }
    }

    var tint: HelmTint {
        switch self {
        case .ready: return .good
        case .needsMicrophone, .needsSpeechRecognition, .needsAccessibility: return .warn
        case .recording, .transcribing: return .accent
        }
    }
}

/// Reads and requests the three real system permissions Dictation depends on.
/// Pure statics - no instance state - so both `DictationController` (for
/// display) and `DictationEngine` (before actually opening the microphone)
/// can consult the exact same source of truth.
enum DictationPermissions {
    static var microphone: DictationPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static var speechRecognition: DictationPermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the real system microphone-access prompt the first time it's
    /// genuinely needed - a no-op (immediate `completion(true)`, no dialog)
    /// once already granted, matching `SFSpeechRecognizer.requestAuthorization`
    /// and `ShiftGlobalHotkey.requestPermissionIfNeeded()`'s own "safe to call
    /// every time" convention.
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func requestSpeechRecognition(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    /// Shows the real system "Accessibility" permission prompt if not already
    /// granted - the exact same `AXIsProcessTrustedWithOptions` call
    /// `ShiftGlobalHotkey.requestPermissionIfNeeded()` already uses for
    /// Shift's own global hotkey, since this is the identical system
    /// permission (one process-wide Accessibility trust grant covers both
    /// features - there is no separate "Dictation" entry in System Settings).
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The one place that turns the three permission reads above into a
    /// single `DictationStatus` - checked in the same order the task brief
    /// lists them (Microphone, then Speech Recognition, then Accessibility),
    /// so a captain missing more than one sees the first one to resolve.
    static func currentStatus(isRecording: Bool = false, isTranscribing: Bool = false) -> DictationStatus {
        if isRecording { return .recording }
        if isTranscribing { return .transcribing }
        if microphone != .granted { return .needsMicrophone }
        if speechRecognition != .granted { return .needsSpeechRecognition }
        if !isAccessibilityTrusted { return .needsAccessibility }
        return .ready
    }
}

/// Owns the actual hold-to-record -> transcribe -> paste pipeline. One
/// instance for the app's whole lifetime (built by the app delegate, exactly
/// like `ShiftNotificationScheduler`/`ShiftGlobalHotkey`), driven by
/// `DictationHotkey`'s onDown/onUp callbacks.
final class DictationEngine {
    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private(set) var isRecording = false
    private var isFinishing = false

    /// Fired on every state transition (recording start/stop, back to ready,
    /// a permission gap discovered at record time) - `DictationController`
    /// subscribes while visible so the page never shows a stale status.
    var onStatusChanged: ((DictationStatus) -> Void)?

    /// Fired with the final recognized text right before it's pasted -
    /// mostly useful for tests/manual verification; the paste itself doesn't
    /// depend on anyone observing this.
    var onTranscript: ((String) -> Void)?

    init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    /// Tracks "the captain still wants to record" across an async permission
    /// request - the hold-to-record gesture that triggered `startRecording()`
    /// can easily release before a system permission dialog resolves (the
    /// captain's very first, brief tap of Right ⌥ Option is the common case
    /// this exists for). `stopRecording()` clears it so a permission grant
    /// that lands *after* the key was already released doesn't start
    /// recording anyway.
    private var wantsToRecord = false

    /// Called by `DictationHotkey`'s onDown. A no-op if already recording.
    /// Drives the real system permission prompts inline the first time
    /// Microphone/Speech Recognition access is genuinely needed - the actual
    /// "hold Right ⌥ Option" usage flow the task brief describes, not just
    /// the Dictation page's own manual "Request access" buttons.
    func startRecording() {
        guard !isRecording else { return }
        wantsToRecord = true
        beginIfPermissionsReady()
    }

    private func beginIfPermissionsReady() {
        guard wantsToRecord else { return }
        if DictationPermissions.microphone == .notDetermined {
            DictationPermissions.requestMicrophone { [weak self] _ in self?.beginIfPermissionsReady() }
            return
        }
        if DictationPermissions.speechRecognition == .notDetermined {
            DictationPermissions.requestSpeechRecognition { [weak self] _ in self?.beginIfPermissionsReady() }
            return
        }
        guard DictationPermissions.microphone == .granted,
              DictationPermissions.speechRecognition == .granted,
              let recognizer, recognizer.isAvailable else {
            onStatusChanged?(DictationPermissions.currentStatus())
            return
        }
        beginCapture(recognizer: recognizer)
    }

    private func beginCapture(recognizer: SFSpeechRecognizer) {
        guard wantsToRecord, !isRecording else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request
        isFinishing = false

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            onStatusChanged?(DictationPermissions.currentStatus())
            return
        }

        isRecording = true
        onStatusChanged?(.recording)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result, result.isFinal {
                self.finish(text: result.bestTranscription.formattedString)
            } else if error != nil {
                self.finish(text: nil)
            }
        }
    }

    /// Called by `DictationHotkey`'s onUp. Stops capturing audio immediately
    /// and signals end-of-audio to the recognizer; the recognizer's own
    /// completion (above) is what actually finishes the pipeline and pastes,
    /// since a final result can arrive slightly after `endAudio()`.
    func stopRecording() {
        wantsToRecord = false
        guard isRecording else { return }
        isRecording = false
        onStatusChanged?(.transcribing)
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()
    }

    private func finish(text: String?) {
        guard !isFinishing else { return }
        isFinishing = true
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Self.pasteAtCursor(text)
            onTranscript?(text)
        }
        onStatusChanged?(DictationPermissions.currentStatus())
    }

    /// Pastes `text` at the current cursor position in whichever app
    /// currently has focus.
    ///
    /// Chose `NSPasteboard` + a synthetic Cmd+V (`CGEvent`) over the
    /// Accessibility `AXUIElement` API (e.g. `kAXSelectedTextAttribute`)
    /// deliberately: `AXUIElement` text-insertion only works against apps
    /// that expose a conforming Accessibility text role for their focused
    /// element, which excludes most terminal emulators (including this app's
    /// own SwiftTerm-based Console tabs) and many Electron/web-based editors
    /// - a synthetic Cmd+V lands in any app that accepts a real paste
    /// keystroke, which is a strictly larger and more predictable set. Both
    /// approaches need the same Accessibility trust already required for the
    /// global hotkey (`DictationHotkey`), so there's no permission-cost
    /// difference between them - only a reliability one.
    static func pasteAtCursor(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard isAccessibilityTrustedForPaste() else { return }
        // Virtual keycode 9 = 'v' (kVK_ANSI_V).
        let vKeyCode: CGKeyCode = 9
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Split out from `pasteAtCursor` so a test can stub it - posting a
    /// synthetic keystroke without Accessibility trust would either silently
    /// no-op or, on some macOS versions, do nothing observable at all, so
    /// gating it explicitly here keeps the pasteboard write (still useful
    /// on its own - a captain can always paste manually) separate from the
    /// synthetic-keystroke half that truly needs the permission.
    static func isAccessibilityTrustedForPaste() -> Bool { AXIsProcessTrusted() }
}
