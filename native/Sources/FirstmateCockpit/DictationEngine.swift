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
    case cleaningUp
    case didNotCatchThat
    /// macOS's own system-level Dictation setting (System Settings ->
    /// Keyboard -> Dictation) is off - a real, captain-hit gap where every
    /// dictation attempt used to surface as the exact same generic
    /// "Didn't catch that" message a genuine no-speech miss shows, giving no
    /// clue that a system setting, not a real speech problem, was the cause.
    /// Distinguished by its own real, different `recognitionTask` error - see
    /// `DictationEngine`'s `systemDictationDisabledErrorDomain`/`Code` for the
    /// exact live-confirmed shape - never inferred from silence/timing.
    case systemDictationDisabled

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .needsMicrophone: return "Needs Microphone access"
        case .needsSpeechRecognition: return "Needs Speech Recognition access"
        case .needsAccessibility: return "Needs Accessibility access"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .cleaningUp: return "Cleaning up…"
        case .didNotCatchThat: return "Didn't catch that"
        case .systemDictationDisabled: return "System Dictation is disabled"
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
        case .cleaningUp: return "Rewriting your transcript into a clean sentence…"
        case .didNotCatchThat: return "No speech was recognized that time - hold \(shortcutDisplay) and try again."
        case .systemDictationDisabled: return "macOS's own Dictation setting is off, so Grand Line can't transcribe speech. Turn it on in System Settings > Keyboard > Dictation, then try again."
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
        case .cleaningUp: return "sparkles"
        case .didNotCatchThat: return "questionmark.circle.fill"
        case .systemDictationDisabled: return "gear.badge.xmark"
        }
    }

    var tint: HelmTint {
        switch self {
        case .ready: return .good
        case .needsMicrophone, .needsSpeechRecognition, .needsAccessibility, .didNotCatchThat, .systemDictationDisabled: return .warn
        case .recording, .transcribing, .cleaningUp: return .accent
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

    /// Defense-in-depth ceiling on top of `finishTimeout` above (see
    /// `hardCeilingWorkItem`'s doc comment) - deliberately independent of
    /// this engine's own internal state, so it stays a real safety net even
    /// against a class of bug this task's own fix didn't anticipate.
    ///
    /// fm/grandline-dictation-long-utterance-status-race: this used to be a
    /// single fixed constant (`finishTimeout + 5` = 13s) regardless of how
    /// much audio was actually captured - live-reproduced (real mic, real
    /// `say`-produced ~49s utterance, local Whisper engine enabled) that a
    /// genuinely long recording can legitimately need more than 13s total
    /// (Apple's own finalization wait plus, once the local Whisper engine is
    /// enabled, `whisper_full`'s own processing - both scale with audio
    /// length, not just a fixed cost). When that happens, this ceiling used
    /// to fire *before* the real `finish(text:)` completion, forcing the
    /// display to "Didn't catch that" even though the real pipeline went on
    /// to succeed moments later (a correct transcript pasted and recorded to
    /// history) - exactly the captain's reported symptom: history and the
    /// visible status disagreeing, only for long utterances. Confirmed live
    /// with Metal disabled (`FM_WHISPER_METAL_RESOURCES_OVERRIDE` pointed at
    /// an empty directory, simulating slower-than-this-machine's-own
    /// Metal-accelerated transcription): the ceiling fired at exactly 13s
    /// while the real transcription was still running.
    ///
    /// `hardCeilingDuration(forCapturedAudioSeconds:)` below now scales this
    /// ceiling with the recording's own captured duration instead of a fixed
    /// number, so a longer recording gets a proportionally longer allowance
    /// before it's considered "stuck" - see that method's own doc comment for
    /// the reasoning and its limits. This is deliberately *not* the whole
    /// fix: see `report(_:isCeilingTimeout:)`'s doc comment for the other
    /// half - a late-but-real completion must still be able to correct an
    /// already-shown ceiling-forced display, since no fixed (or even
    /// duration-scaled) ceiling can rule out every legitimately-slow case
    /// (a cold model load, thermal throttling, genuinely slower hardware).
    private static func hardCeilingDuration(forCapturedAudioSeconds capturedAudioSeconds: TimeInterval) -> TimeInterval {
        let baseline = finishTimeout + 5 // 13s - unchanged, so a short utterance's behavior is untouched.
        // Live-measured on real Apple Silicon with Metal: a ~49s utterance's
        // whole pipeline (Apple finalization + whisper transcription)
        // completed in ~5-6s - so allowing the recording's own duration again,
        // on top of the fixed baseline, is a generous multiple of that real
        // measurement, comfortably covering realistic variance (slower
        // hardware, thermal throttling, a cold model load) without waiting
        // anywhere near what a full CPU-only Metal fallback would need (a
        // distinct, much bigger performance problem - see this file's
        // "Whisper engine" section in `CLAUDE.md` for the ~20x-realtime
        // CPU-only cost that motivated adding Metal acceleration in the
        // first place; no ceiling sized for interactive use should try to
        // wait that out).
        return baseline + max(0, capturedAudioSeconds)
    }

    /// The exact `NSError` shape `SFSpeechRecognizer`'s `recognitionTask(with:)`
    /// completion reports when macOS's own system-level Dictation setting
    /// (System Settings > Keyboard > Dictation) is off - confirmed live on a
    /// real Mac (fm/grandline-dictation-system-disabled-message) by toggling
    /// that setting off and running this exact completion closure:
    /// `domain == "kLSRErrorDomain"`, `code == 201`,
    /// `localizedDescription == "Siri and Dictation are disabled"`. This is a
    /// distinct, identifiable failure - live-confirmed separately (same real
    /// Mac, setting back on) that a genuine no-speech miss instead reports
    /// `domain == "kAFAssistantErrorDomain"`, `code == 1110`,
    /// `"No speech detected"`, which must keep resolving to
    /// `.didNotCatchThat` completely unchanged.
    private static let systemDictationDisabledErrorDomain = "kLSRErrorDomain"
    private static let systemDictationDisabledErrorCode = 201

    /// The most recent status this engine actually told `onStatusChanged`
    /// about - tracked purely so `hardCeilingWorkItem` can check "are we
    /// still showing Transcribing…" without touching `isFinishing`/
    /// `isRecording` at all (see that property's own doc comment for why
    /// that separation matters).
    private var lastReportedStatus: DictationStatus = .ready

    /// Absolute wall-clock watchdog, scheduled every time `.transcribing` is
    /// reported and cancelled the moment any other status is reported -
    /// fires `Self.hardTranscribingCeiling` after `.transcribing` regardless
    /// of `isFinishing`/`isRecording`'s internal state. This is deliberately
    /// NOT the same mechanism as `finishTimeoutWorkItem` (which the real bug
    /// fixed by this task lived in - see `finish(text:)`'s doc comment for
    /// the exact race): that timeout calls back into `finish(text:)`, which
    /// can itself be silently swallowed by `isFinishing`'s own guard if
    /// something has gone wrong internally. This watchdog bypasses all of
    /// that and forces the *displayed* status back to something actionable
    /// on its own, so "stuck on Transcribing… forever" stays categorically
    /// impossible even against a future bug this task's own fix didn't
    /// anticipate, not just against the specific race found and fixed here.
    private var hardCeilingWorkItem: DispatchWorkItem?

    /// The one place `onStatusChanged` is ever invoked from - tracks
    /// `lastReportedStatus` and arms/disarms `hardCeilingWorkItem` so every
    /// status transition (not just the ones this task happened to touch)
    /// keeps that watchdog correctly in sync.
    ///
    /// fm/grandline-dictation-long-utterance-status-race: `onStatusChanged`
    /// now carries a second `isCeilingTimeout` flag, `true` only for the one
    /// call the hard ceiling itself makes when it gives up waiting. This is
    /// the "supersede/correct" half of that task's fix (the other half is
    /// `hardCeilingDuration(forCapturedAudioSeconds:)`'s duration-aware
    /// scaling above): the ceiling firing does not mean the real pipeline
    /// stopped - `finish(text:)`/`deliver(_:duration:)` keep running in the
    /// background regardless and will call `report(_:)` again with the real
    /// outcome once they complete, exactly like they already did before this
    /// fix. What consumers need is a way to tell "this is a tentative
    /// give-up, a real result may still follow" apart from "this is the real,
    /// final outcome" - `DictationHUDController.handle(_:isCeilingTimeout:)`
    /// is the one consumer that needed this distinction (it gates on
    /// `wasActive` to tell a real completion apart from an unrelated
    /// permission-button click - see that file's header - and used to clear
    /// that flag on the ceiling's forced failure too, silently discarding any
    /// later, real, successful completion). `DictationController`'s own
    /// status card has no such gating and already showed the eventual real
    /// correction unconditionally.
    private func report(_ status: DictationStatus, isCeilingTimeout: Bool = false) {
        lastReportedStatus = status
        if status == .transcribing {
            hardCeilingWorkItem?.cancel()
            let capturedAudioSeconds = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            let ceiling = Self.hardCeilingDuration(forCapturedAudioSeconds: capturedAudioSeconds)
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.lastReportedStatus == .transcribing else { return }
                self.lastReportedStatus = .didNotCatchThat
                self.onStatusChanged?(.didNotCatchThat, true)
            }
            hardCeilingWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + ceiling, execute: workItem)
        } else {
            hardCeilingWorkItem?.cancel()
            hardCeilingWorkItem = nil
        }
        onStatusChanged?(status, isCeilingTimeout)
    }

    /// Fired on every state transition (recording start/stop, back to ready,
    /// a permission gap discovered at record time) - `DictationController`
    /// subscribes while visible so the page never shows a stale status.
    ///
    /// The second parameter, `isCeilingTimeout`, is `true` only for the one
    /// call `report(_:isCeilingTimeout:)`'s hard-ceiling watchdog itself
    /// makes (see that method's doc comment) - every other call passes
    /// `false`, including the real, final correction that always follows a
    /// ceiling-forced display once the actual pipeline completes.
    var onStatusChanged: ((DictationStatus, Bool) -> Void)?

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

    /// Reports whether the "Clean up my sentences" toggle (phase 3) is on -
    /// read fresh at the moment a dictation finishes, not cached, so a toggle
    /// flipped mid-recording takes effect on that very dictation's result.
    /// `nil`/`false` means "paste the raw transcript," matching every other
    /// provider closure's own "absent means off/empty" convention above.
    var cleanupEnabledProvider: (() -> Bool)?

    /// Reports whether the "Use local Whisper engine" toggle is on
    /// (fm/grandline-dictation-whisper-engine) - read fresh at the start of
    /// every recording, matching every other provider closure's convention.
    var localWhisperEnabledProvider: (() -> Bool)?

    /// Resamples the live tap audio to 16kHz mono Float32 for the local
    /// Whisper engine, accumulating across the whole recording - only ever
    /// actually used when `localWhisperEnabledProvider` is true, so the
    /// default (toggle off) path pays no extra CPU for this at all beyond
    /// the one `providerProviders?() ?? false` check.
    private let whisperResampler = DictationAudioResampler()

    /// Lazily loaded and cached for the app's whole lifetime once a load
    /// succeeds - `WhisperCppEngine.init?` re-reading and re-parsing a
    /// ~547MB model file on every single recording would be a real,
    /// noticeable delay before the local engine could ever start
    /// transcribing. `nil` after a failed load attempt means "don't retry
    /// every load automatically" as of a recording; whether the model exists
    /// at all is still re-checked from `beginCapture` since a captain could
    /// delete/redownload it between recordings.
    private var cachedWhisperEngine: WhisperCppEngine?
    private var cachedWhisperEngineModelPath: String?

    /// Whether *this specific recording* is using the local Whisper engine -
    /// decided once at `beginCapture` time (toggle + model ready + engine
    /// loads), not re-checked mid-recording, so a toggle flip while already
    /// recording can't switch engines mid-flight.
    private var usingLocalWhisperThisRecording = false

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
            report(DictationPermissions.currentStatus())
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

        // Decided once, here, not re-checked mid-recording - see
        // `usingLocalWhisperThisRecording`'s doc comment. Still runs the
        // Apple Speech pipeline below unconditionally either way: this is
        // deliberate, not wasted work. Running both in parallel means a
        // local-Whisper transcription failure (model fails to load, produces
        // no usable text) has an already-computed Apple transcript to fall
        // back to immediately in `finish(text:)`, with no extra latency and
        // no separate "try Apple after Whisper already failed" code path
        // that would itself need its own timeout/fallback handling.
        usingLocalWhisperThisRecording = localWhisperEnabledProvider?() ?? false
        if usingLocalWhisperThisRecording {
            whisperResampler.reset()
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            if self.usingLocalWhisperThisRecording {
                self.whisperResampler.append(buffer)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            report(DictationPermissions.currentStatus())
            return
        }

        isRecording = true
        recordingStartedAt = Date()
        report(.recording)

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
            } else if let error {
                let nsError = error as NSError
                if nsError.domain == Self.systemDictationDisabledErrorDomain,
                   nsError.code == Self.systemDictationDisabledErrorCode {
                    // Live-confirmed on a real Mac (System Settings > Keyboard
                    // > Dictation toggled off, a real recognitionTask run):
                    // this exact domain/code, with no usable transcript ever
                    // possible in this state - report the specific,
                    // actionable status directly rather than falling into the
                    // generic "Didn't catch that" bucket below. See
                    // `DictationStatus.systemDictationDisabled`'s doc comment.
                    self.finish(text: nil, systemDictationDisabled: true)
                    return
                }
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
    ///
    /// Guards on `isRecording`, which `finish(text:)` now also clears the
    /// moment recognition actually ends (see that method's doc comment) -
    /// so if recognition already completed before the hotkey was released,
    /// this call correctly no-ops instead of re-triggering the stuck-forever
    /// race a captain hit with Right ⌘ Command configured (reproduced live
    /// and just as reproducible with the default Right ⌥ Option - it's a
    /// pure timing race, not specific to either key; see this file's header
    /// and `CLAUDE.md`'s Dictation section for the full writeup).
    func stopRecording() {
        wantsToRecord = false
        guard isRecording else { return }
        isRecording = false
        report(.transcribing)
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

    private func finish(text: String?, systemDictationDisabled: Bool = false) {
        guard !isFinishing else { return }
        isFinishing = true
        finishTimeoutWorkItem?.cancel()
        finishTimeoutWorkItem = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        // The real root cause of the stuck-forever bug this method's header
        // now documents: recognition can complete (a real final result, OR -
        // as live-reproduced here - a fast error like "Siri and Dictation
        // are disabled") *before* the hotkey is ever released. `isRecording`
        // used to stay `true` in that case (only `stopRecording()` ever
        // cleared it), so the *later* `stopRecording()` call on release
        // would still pass its own `guard isRecording`, overwrite the status
        // this method is about to set back to `.transcribing`, and schedule
        // a second `finishTimeoutWorkItem` - whose eventual `finish(text:)`
        // call then hit the `guard !isFinishing` above and returned with no
        // status update at all. Stuck on "Transcribing…" forever, with no
        // error and no revert. Tearing capture down right here, the moment
        // recognition actually ends, closes that race: by the time
        // `stopRecording()` runs later, `isRecording` is already `false` and
        // it correctly no-ops instead of stomping this method's own result.
        if isRecording {
            isRecording = false
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        // No usable transcript is ever possible in this state (recognition
        // never really ran) - report the specific status directly rather
        // than falling through the generic empty-text handling below, which
        // would otherwise indistinguishably report `.didNotCatchThat`.
        if systemDictationDisabled {
            report(.systemDictationDisabled)
            return
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appleText = !trimmed.isEmpty ? text! : (bestTranscriptSeen.isEmpty ? nil : bestTranscriptSeen)
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        // The local Whisper engine (fm/grandline-dictation-whisper-engine) is
        // attempted only when this specific recording opted into it (decided
        // once at `beginCapture`, see `usingLocalWhisperThisRecording`'s doc
        // comment) - the default (toggle off) path skips this block
        // entirely and goes straight to the Apple-computed `appleText`,
        // exactly matching this method's pre-existing behavior byte for
        // byte. `whisper_full` runs on a background queue since it can take
        // a real, noticeable amount of time on CPU; the already-computed
        // `appleText` is what a failed/empty local transcription falls back
        // to, with no extra latency for that fallback path.
        guard usingLocalWhisperThisRecording else {
            finishWithFinalText(appleText, duration: duration)
            return
        }

        let samples = whisperResampler.samples
        let vocabulary = vocabularyProvider?() ?? []
        let initialPrompt = vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", ")
        let modelReady = WhisperModelManager.shared.isReady
        let modelPath = WhisperModelManager.shared.modelPathOnDisk
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var whisperText: String?
            if modelReady {
                whisperText = self?.loadWhisperEngine(modelPath: modelPath)?.transcribe(samples: samples, initialPrompt: initialPrompt)
            }
            DispatchQueue.main.async {
                // A missing model, a load failure, or an empty/failed
                // transcription all fall back to the Apple Speech result
                // computed in parallel above - a broken local engine must
                // never mean dictation stops working entirely.
                self?.finishWithFinalText(whisperText ?? appleText, duration: duration)
            }
        }
    }

    /// Loads (or reuses the cached) local Whisper engine for `modelPath` -
    /// called only from the background queue in `finish(text:)` above, never
    /// concurrently with itself (a second recording can't begin until this
    /// one has fully finished, since `isRecording`/`isFinishing` gate that).
    /// Caching across recordings avoids re-parsing the ~547MB model file on
    /// every single dictation, which would otherwise be a real, noticeable
    /// delay before the local engine could start transcribing at all.
    private func loadWhisperEngine(modelPath: String) -> WhisperCppEngine? {
        if let cachedWhisperEngine, cachedWhisperEngineModelPath == modelPath {
            return cachedWhisperEngine
        }
        guard let engine = WhisperCppEngine(modelPath: modelPath) else { return nil }
        cachedWhisperEngine = engine
        cachedWhisperEngineModelPath = modelPath
        return engine
    }

    /// The one place both the Apple-only path and the local-Whisper path
    /// converge once a final transcript (or `nil`) has been decided - runs
    /// the optional "Clean up my sentences" rewrite and pastes/records the
    /// result, exactly like this method did before the local-engine option
    /// existed.
    private func finishWithFinalText(_ finalText: String?, duration: TimeInterval) {
        guard let finalText else {
            report(.didNotCatchThat)
            return
        }

        guard cleanupEnabledProvider?() == true else {
            deliver(finalText, duration: duration)
            return
        }

        report(.cleaningUp)
        DictationCleanup.rewrite(finalText) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let cleaned):
                self.deliver(cleaned, duration: duration)
            case .failure:
                // A cleanup failure (no network, not authenticated, claude
                // missing, a timeout, a garbled response) must never lose or
                // block the dictation - fall back to the raw transcript
                // rather than silently dropping the paste. See this file's
                // header for the full pipeline contract.
                self.deliver(finalText, duration: duration)
            }
        }
    }

    /// Pastes and records the final text (raw or, when the "Clean up my
    /// sentences" toggle is on and the rewrite succeeded, cleaned) - the one
    /// place both paths above converge, so paste and history always agree on
    /// which text was actually used.
    private func deliver(_ text: String, duration: TimeInterval) {
        Self.pasteAtCursor(text)
        onTranscript?(text, duration)
        report(DictationPermissions.currentStatus())
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
    /// GL-29's most important seam. Set, `pasteAtCursor` routes here instead
    /// of touching the pasteboard or posting a synthetic ⌘V - so a self-test
    /// can drive the whole finish/deliver path without typing the captain's
    /// test fixtures into whatever app happens to be frontmost, and without
    /// clobbering their clipboard. Never set in the shipping app.
    static var pasteSinkForTests: ((String) -> Void)?

    static func pasteAtCursor(_ text: String) {
        if let sink = pasteSinkForTests {
            sink(text)
            return
        }
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

    // MARK: Probe / self-test surface (GL-29)

    /// The finish/race/timeout state machine is the part of this file with
    /// three real shipped bugs in its history (the delayed-empty-final-result
    /// hang, the `.transcribing` stomp when recognition beats the key release,
    /// and the hard ceiling permanently winning over a slow-but-real result) -
    /// and all three were verified only by probes that were then reverted,
    /// which is exactly why the review called this the highest-risk untested
    /// subsystem. These shims are the permanent version of those probes.
    ///
    /// They drive the *real* methods; nothing here reimplements a decision.

    /// Stand in for a real capture having started, so `finish`/`stopRecording`
    /// see the state they would see mid-dictation.
    func debugBeginCaptureForTests(startedAt: Date = Date()) {
        isRecording = true
        isFinishing = false
        bestTranscriptSeen = ""
        recordingStartedAt = startedAt
        usingLocalWhisperThisRecording = false
        report(.recording)
    }

    /// Feed a partial/final recognition result exactly as the real
    /// `recognitionTask` callback does, so the `bestTranscriptSeen` fallback
    /// is exercised rather than described.
    func debugNoteTranscriptForTests(_ text: String) {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bestTranscriptSeen = text
        }
    }

    func debugFinishForTests(text: String?, systemDictationDisabled: Bool = false) {
        finish(text: text, systemDictationDisabled: systemDictationDisabled)
    }

    func debugStopRecordingForTests() { stopRecording() }

    var debugIsRecordingForTests: Bool { isRecording }
    var debugIsFinishingForTests: Bool { isFinishing }
    var debugBestTranscriptForTests: String { bestTranscriptSeen }

    static func debugHardCeilingDurationForTests(capturedAudioSeconds: TimeInterval) -> TimeInterval {
        hardCeilingDuration(forCapturedAudioSeconds: capturedAudioSeconds)
    }

    /// Split out from `pasteAtCursor` so a test can stub it - posting a
    /// synthetic keystroke without Accessibility trust would either silently
    /// no-op or, on some macOS versions, do nothing observable at all, so
    /// gating it explicitly here keeps the pasteboard write (still useful
    /// on its own - a captain can always paste manually) separate from the
    /// synthetic-keystroke half that truly needs the permission.
    static func isAccessibilityTrustedForPaste() -> Bool { AXIsProcessTrusted() }
}
