// Manjesh Grand Line - native macOS app.
//
// GL-29: permanent coverage for `DictationEngine`'s finish/race/timeout state
// machine - the review's own top-ranked untested subsystem, and for good
// reason: three real, captain-reported production bugs have shipped from this
// one method, and each was verified only by a temporary probe that was then
// reverted. Those probes are now these cases.
//
//   1. `fm/grandline-dictation-transcribe-hang-fix` - a *final* recognition
//      result whose text is empty (a real, reproduced `SFSpeechRecognizer`
//      quirk after trailing silence) meant the correct transcript, already
//      seen in a partial result, was thrown away and nothing was pasted.
//   2. `fm/grandline-dictation-stuck-transcribing-fix` - recognition finishing
//      *before* the hotkey is released left `isRecording` true, so the later
//      `stopRecording()` stomped the already-final status back to
//      "Transcribing…" forever.
//   3. `fm/grandline-dictation-long-utterance-status-race` - a fixed 13s hard
//      ceiling forced "Didn't catch that" on screen while a long utterance was
//      still genuinely being transcribed, and the real result that arrived
//      afterwards had to be able to supersede it.
//
// Run: `FM_RUN_DICTATION_ENGINE_TESTS=1 .build/debug/FirstmateCockpit`
//
// Nothing here touches a microphone, the speech framework, the network, the
// pasteboard, or the frontmost app: `DictationEngine.pasteSinkForTests`
// intercepts delivery (see its doc comment - without it a run would type these
// fixtures into whatever window happened to be in front), and the state
// machine is driven through the same `finish`/`stopRecording` the real
// recognition callbacks call.

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

enum DictationEngineSelfTest {

    static func run() -> Bool {
        // Guard rail: if this is ever set by shipping code, every case below
        // would pass while pasting nowhere. Assert the shape of the world
        // before trusting the results.
        guard DictationEngine.pasteSinkForTests == nil else {
            print("FAIL pasteSinkForTests was already set before the suite ran")
            return false
        }

        let cases: [(String, () -> String?)] = [
            ("emptyFinalResultFallsBackToTheBestPartialSeen", test_emptyFinalResultFallsBackToBestPartial),
            ("finishBeforeKeyReleaseIsNotStompedByStopRecording", test_finishBeforeKeyReleaseIsNotStomped),
            ("noTranscriptAtAllReportsDidNotCatchThat", test_noTranscriptReportsDidNotCatchThat),
            ("systemDictationDisabledIsItsOwnStatus", test_systemDictationDisabledIsDistinct),
            ("hardCeilingScalesWithCapturedAudio", test_hardCeilingScalesWithCapturedAudio),
            ("doubleFinishDeliversOnce", test_doubleFinishDeliversOnce),
        ]

        var failures = 0
        for (name, testCase) in cases {
            var delivered: [String] = []
            DictationEngine.pasteSinkForTests = { delivered.append($0) }
            defer { DictationEngine.pasteSinkForTests = nil }
            _ = delivered
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
            DictationEngine.pasteSinkForTests = nil
        }

        if failures == 0 {
            print("DictationEngineSelfTest: all \(cases.count) cases passed")
            return true
        }
        print("DictationEngineSelfTest: \(failures) of \(cases.count) cases FAILED")
        return false
    }

    // MARK: Harness

    /// A live engine plus everything a case needs to observe it. `pasted` is
    /// what actually reached the captain's cursor; `statuses` is every status
    /// the UI (page card and floating HUD) would have shown, in order.
    private final class Harness {
        let engine = DictationEngine()
        var pasted: [String] = []
        var recorded: [(text: String, duration: TimeInterval)] = []
        var statuses: [(status: DictationStatus, isCeilingTimeout: Bool)] = []

        init(cleanupEnabled: Bool = false) {
            DictationEngine.pasteSinkForTests = { [weak self] in self?.pasted.append($0) }
            engine.onTranscript = { [weak self] text, duration in
                self?.recorded.append((text, duration))
            }
            engine.onStatusChanged = { [weak self] status, isCeiling in
                self?.statuses.append((status, isCeiling))
            }
            engine.cleanupEnabledProvider = { cleanupEnabled }
            engine.localWhisperEnabledProvider = { false }
            engine.vocabularyProvider = { [] }
        }

        deinit { DictationEngine.pasteSinkForTests = nil }

        var lastStatus: DictationStatus? { statuses.last?.status }
    }

    // MARK: Cases

    /// Bug 1. The final result is empty; the correct text was only ever seen
    /// in a partial. Reverting `finish`'s `bestTranscriptSeen` fallback makes
    /// this fail with nothing delivered - which is precisely the shipped bug
    /// (the captain saw "Transcribing…" and then silence, with no paste).
    private static func test_emptyFinalResultFallsBackToBestPartial() -> String? {
        let h = Harness()
        h.engine.debugBeginCaptureForTests()
        h.engine.debugNoteTranscriptForTests("restart the api deployment")
        h.engine.debugFinishForTests(text: "")

        guard h.pasted == ["restart the api deployment"] else {
            return "expected the partial transcript to be delivered, got \(h.pasted)"
        }
        guard h.recorded.count == 1, h.recorded[0].text == "restart the api deployment" else {
            return "history and paste disagree: \(h.recorded)"
        }
        guard h.lastStatus != .didNotCatchThat else {
            return "reported didNotCatchThat despite having a real transcript"
        }
        return nil
    }

    /// Bug 2. Recognition completes first, the hotkey is released after. The
    /// release must not reopen the transcribing state or re-arm a timeout.
    private static func test_finishBeforeKeyReleaseIsNotStomped() -> String? {
        let h = Harness()
        h.engine.debugBeginCaptureForTests()
        h.engine.debugNoteTranscriptForTests("scale the deployment")
        // Recognition finishes while the key is still held.
        h.engine.debugFinishForTests(text: "scale the deployment")
        guard !h.engine.debugIsRecordingForTests else {
            return "finish() left isRecording true - stopRecording() will stomp the final status"
        }
        let statusAfterFinish = h.lastStatus

        // Now the captain lets go.
        h.engine.debugStopRecordingForTests()
        guard h.lastStatus == statusAfterFinish else {
            return "the key release changed the reported status to \(String(describing: h.lastStatus)) - the stuck-on-Transcribing bug"
        }
        guard h.lastStatus != .transcribing else {
            return "ended on .transcribing, which is the stuck state itself"
        }
        guard h.pasted == ["scale the deployment"] else { return "unexpected delivery: \(h.pasted)" }
        return nil
    }

    /// Genuine silence: nothing partial, nothing final. This is the one case
    /// that *should* say so, and it must not be reachable by the two above.
    private static func test_noTranscriptReportsDidNotCatchThat() -> String? {
        let h = Harness()
        h.engine.debugBeginCaptureForTests()
        h.engine.debugFinishForTests(text: nil)
        guard h.pasted.isEmpty else { return "pasted \(h.pasted) for a silent recording" }
        guard h.lastStatus == .didNotCatchThat else {
            return "expected .didNotCatchThat, got \(String(describing: h.lastStatus))"
        }
        return nil
    }

    /// `fm/grandline-dictation-system-disabled-message`: the system setting
    /// being off is a different message from "didn't catch that", because the
    /// fix for it is different. Reverting that branch collapses the two.
    private static func test_systemDictationDisabledIsDistinct() -> String? {
        let h = Harness()
        h.engine.debugBeginCaptureForTests()
        h.engine.debugNoteTranscriptForTests("this should not be delivered")
        h.engine.debugFinishForTests(text: nil, systemDictationDisabled: true)
        guard h.lastStatus == .systemDictationDisabled else {
            return "expected .systemDictationDisabled, got \(String(describing: h.lastStatus))"
        }
        guard h.pasted.isEmpty else {
            return "delivered \(h.pasted) even though recognition never really ran"
        }
        return nil
    }

    /// Bug 3's first half: the ceiling has to grow with how much audio was
    /// captured, or a long utterance is declared failed while it is still
    /// being transcribed. Restoring the old fixed constant makes the long
    /// case fail here.
    private static func test_hardCeilingScalesWithCapturedAudio() -> String? {
        let short = DictationEngine.debugHardCeilingDurationForTests(capturedAudioSeconds: 2)
        let long = DictationEngine.debugHardCeilingDurationForTests(capturedAudioSeconds: 49)
        guard short >= 13 else { return "short-utterance ceiling regressed to \(short)s (floor is 13s)" }
        guard long > short else {
            return "ceiling did not grow with captured audio (\(short)s for 2s of audio, \(long)s for 49s)"
        }
        guard long >= short + 40 else {
            return "ceiling grew by only \(long - short)s for 47s more audio - not enough to cover a real long utterance"
        }
        return nil
    }

    /// Belt and braces on `isFinishing`: two finishes (the real timeout firing
    /// alongside a real result, which is exactly how bug 2 was reached) must
    /// deliver once, not twice.
    private static func test_doubleFinishDeliversOnce() -> String? {
        let h = Harness()
        h.engine.debugBeginCaptureForTests()
        h.engine.debugFinishForTests(text: "only once please")
        h.engine.debugFinishForTests(text: "only once please")
        guard h.pasted.count == 1 else { return "delivered \(h.pasted.count) times: \(h.pasted)" }
        guard h.recorded.count == 1 else { return "recorded \(h.recorded.count) history entries" }
        return nil
    }
}

#endif
