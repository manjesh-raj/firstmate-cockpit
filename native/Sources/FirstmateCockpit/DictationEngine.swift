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
    case didNotCatchThat

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .needsMicrophone: return "Needs Microphone access"
        case .needsSpeechRecognition: return "Needs Speech Recognition access"
        case .needsAccessibility: return "Needs Accessibility access"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .didNotCatchThat: return "Didn't catch that"
        }
    }

    /// `shortcutDisplay` is the captain's *current* shortcut's display string
    /// (phase 2, fm/grandline-dictation-phase2 - the combo is no longer
    /// fixed at "Right ⌥ Option", so this text can no longer be a static
    /// per-case literal).
    func detail(shortcutDisplay: String) -> String {
        switch self {
        case .ready: return "Hold \(shortcutDisplay) anywhere to dictate."
        case .needsMicrophone: return "Grand Line needs permission to use your microphone before it can dictate."
        case .needsSpeechRecognition: return "Grand Line needs permission to use on-device Speech Recognition before it can dictate."
        case .needsAccessibility: return "Grand Line needs Accessibility access so the \(shortcutDisplay) shortcut works from any app, and so it can paste the result at your cursor."
        case .recording: return "Listening - release \(shortcutDisplay) to transcribe."
        case .transcribing: return "Turning your speech into text…"
        case .didNotCatchThat: return "No speech was recognized that time - hold \(shortcutDisplay) and try again."
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
        case .didNotCatchThat: return "questionmark.circle.fill"
        }
    }

    var tint: HelmTint {
        switch self {
        case .ready: return .good
        case .needsMicrophone, .needsSpeechRecognition, .needsAccessibility, .didNotCatchThat: return .warn
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

    /// The most recent non-empty transcript seen from *any* result while a
    /// recognition is in flight - partial or final. Needed because a real,
    /// live-reproduced `SFSpeechRecognizer` quirk (confirmed on-device, with
    /// `shouldReportPartialResults = true` below) can deliver a non-final
    /// result carrying the correct, complete transcript, then a *final*
    /// result whose `bestTranscription.formattedString` is empty - most
    /// reliably reproduced by holding the hotkey through a few seconds of
    /// trailing silence after speech ends, a completely ordinary real usage
    /// pattern. `finish(text:)` falls back to this instead of the (possibly
    /// empty) final text so that a correctly recognized utterance is never
    /// silently discarded. Reset at the start of every `beginCapture`.
    private var bestTranscriptSeen = ""

    /// Guards against waiting forever for a final result that may never
    /// arrive - scheduled right after `endAudio()` in `stopRecording()`,
    /// cancelled the moment `finish(text:)` actually runs (whether triggered
    /// by a real final result, a real error, or this timeout itself).
    private var finishTimeoutWorkItem: DispatchWorkItem?

    /// Bounded wait, after the hotkey is released and `endAudio()` is called,
    /// for a final result to arrive before finalizing with whatever transcript
    /// (if any) has been seen so far. Chosen generously above the ~4-5s
    /// trailing-silence gap that reliably reproduced the empty-final-result
    /// quirk above, while still being far short of "the captain gives up and
    /// assumes the app is broken."
    private static let finishTimeout: TimeInterval = 8

    /// Fired on every state transition (recording start/stop, back to ready,
    /// a permission gap discovered at record time) - `DictationController`
    /// subscribes while visible so the page never shows a stale status.
    var onStatusChanged: ((DictationStatus) -> Void)?

    /// Fired with the final recognized text and real recording duration right
    /// after a successful paste (phase 2, fm/grandline-dictation-phase2) -
    /// this is exactly the "real, pasted text" moment the task brief's
    /// history acceptance criteria describes, so `AppDelegate` wires this
    /// straight into `DictationStore.recordHistory`. Never fired for an
    /// empty/"didn't catch that" result.
    var onTranscript: ((String, TimeInterval) -> Void)?

    /// Supplies the captain's personal vocabulary (phase 2) at the moment a
    /// new recording begins - read fresh every time rather than cached, so
    /// an edit made on the Dictation page takes effect on the very next
    /// recording with no restart needed. `nil`/empty is a normal, harmless
    /// state (no bias applied).
    var vocabularyProvider: (() -> [String])?

    /// Wall-clock time the current capture actually started (audio engine
    /// running) - `finish(text:)` uses this to compute the real duration
    /// recorded into history. `nil` outside of an active capture.
    private var recordingStartedAt: Date?

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
        // Partial results are required, not optional: see `bestTranscriptSeen`
        // above for the real, live-reproduced failure mode this fixes (a
        // final result can arrive with an empty transcript even though an
        // immediately-prior partial result had the real, correct one).
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        // Phase 2: bias recognition toward the captain's own personal
        // vocabulary - a real, documented API for exactly this purpose
        // (`SFSpeechRecognitionRequest.contextualStrings`), not a cosmetic
        // list. Read fresh on every recording, never cached.
        let vocabulary = vocabularyProvider?() ?? []
        if !vocabulary.isEmpty {
            request.contextualStrings = vocabulary
        }
        recognitionRequest = request
        isFinishing = false
        bestTranscriptSeen = ""
        finishTimeoutWorkItem?.cancel()
        finishTimeoutWorkItem = nil

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
        recordingStartedAt = Date()
        onStatusChanged?(.recording)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.bestTranscriptSeen = text
                }
                if result.isFinal {
                    self.finish(text: text)
                }
            } else if error != nil {
                // A real error still might trail a good partial result (e.g.
                // a transient no-speech-detected error after real words were
                // already recognized) - `finish` falls back to
                // `bestTranscriptSeen` rather than discarding it outright.
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

        // A final result can be delayed indefinitely (or, per the quirk
        // `bestTranscriptSeen` exists for, arrive but carry no usable text) -
        // this timeout is what turns "wait forever" into "finalize with
        // whatever was actually heard, or say so honestly."
        let workItem = DispatchWorkItem { [weak self] in self?.finish(text: nil) }
        finishTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishTimeout, execute: workItem)
    }

    private func finish(text: String?) {
        guard !isFinishing else { return }
        isFinishing = true
        finishTimeoutWorkItem?.cancel()
        finishTimeoutWorkItem = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalText = !trimmed.isEmpty ? text! : (bestTranscriptSeen.isEmpty ? nil : bestTranscriptSeen)
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        if let finalText {
            Self.pasteAtCursor(finalText)
            onTranscript?(finalText, duration)
            onStatusChanged?(DictationPermissions.currentStatus())
        } else {
            onStatusChanged?(.didNotCatchThat)
        }
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
