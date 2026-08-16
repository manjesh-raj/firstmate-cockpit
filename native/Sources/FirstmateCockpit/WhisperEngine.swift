// Manjesh Grand Line - native macOS app.
//
// Dictation's optional local Whisper engine (fm/grandline-dictation-whisper-
// engine) - a thin Swift wrapper around vendored whisper.cpp's plain C API
// (`Vendor/whisper.cpp`, see that directory's README.md for what was vendored
// and why). This is the low-level "run inference on a buffer of samples"
// piece; `WhisperModel.swift` owns downloading/locating the model file, and
// `DictationEngine.swift` decides when to use this instead of (or alongside)
// the Apple Speech framework path.
//
// `whisper_full` is not thread-safe for the same context (see whisper.h's own
// doc comment on it) - this wrapper does not add its own locking, since
// `DictationEngine` only ever calls it from one recording at a time (the
// hold-to-record gesture is inherently serial - the hotkey can't be "held"
// twice concurrently).

import AVFoundation
import CWhisper
import Foundation

/// Loads one whisper.cpp model file and runs inference against a buffer of
/// 16kHz mono Float32 PCM samples. One instance per loaded model - `nil`
/// init means the model failed to load (missing file, corrupt/truncated
/// data, wrong format), which `DictationEngine` treats as "fall back to
/// Apple Speech," never as a crash.
final class WhisperCppEngine {
    private let context: OpaquePointer

    /// Fails (returns `nil`) rather than crashing when the model can't be
    /// loaded - a truncated download, a wrong/corrupt file, or a model this
    /// build of whisper.cpp can't parse all report as a load failure here
    /// rather than propagating a fatal error, since a broken local model
    /// must never mean dictation stops working entirely (task requirement).
    init?(modelPath: String) {
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
        var cparams = whisper_context_default_params()
        // No Metal/CUDA/etc backend is compiled into the vendored CWhisper
        // target (CPU-only, see Vendor/whisper.cpp/README.md) - `use_gpu`
        // would be a no-op either way, but setting it `false` explicitly
        // documents that this is a deliberate CPU-only build, not a GPU path
        // that silently isn't wired up.
        cparams.use_gpu = false
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            return nil
        }
        context = ctx
    }

    deinit {
        whisper_free(context)
    }

    /// Runs inference on `samples` (16kHz mono Float32 PCM, already resampled
    /// by the caller - see `DictationAudioResampler`) and returns the
    /// concatenated segment text, or `nil` if `whisper_full` itself reports
    /// failure or every segment came back empty.
    ///
    /// `initialPrompt`, when non-empty, is passed through to whisper.cpp's
    /// real "initial prompt" biasing mechanism (`whisper_full_params.
    /// initial_prompt`) - the closest whisper.cpp equivalent to
    /// `SFSpeechRecognitionRequest.contextualStrings`, since whisper.cpp has
    /// no per-word vocabulary-biasing API. This is a real, if less precise,
    /// mechanism: it conditions the decoder the way a few words of preceding
    /// context would, rather than guaranteeing any specific word gets
    /// recognized. See `DictationEngine`'s vocabulary wiring for how the
    /// captain's personal vocabulary list is turned into this string.
    func transcribe(samples: [Float], initialPrompt: String?, language: String = "en") -> String? {
        guard !samples.isEmpty else { return nil }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_context = true
        params.single_segment = false
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))

        // `whisper_full_params` holds `initial_prompt`/`language` as raw
        // `const char *` - the C strings backing them must stay alive for the
        // duration of the `whisper_full` call below, so they're built here
        // (not passed in from the caller as Swift `String`s that could be
        // deallocated first) and explicitly freed afterward.
        var promptCString: UnsafeMutablePointer<CChar>?
        if let initialPrompt, !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptCString = strdup(initialPrompt)
            params.initial_prompt = UnsafePointer(promptCString)
        }
        let languageCString = strdup(language)
        params.language = UnsafePointer(languageCString)
        defer {
            free(promptCString)
            free(languageCString)
        }

        let result = samples.withUnsafeBufferPointer { buffer -> Int32 in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
        guard result == 0 else { return nil }

        let segmentCount = whisper_full_n_segments(context)
        guard segmentCount > 0 else { return nil }
        var text = ""
        for i in 0..<segmentCount {
            if let segment = whisper_full_get_segment_text(context, i) {
                text += String(cString: segment)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Resamples live-captured audio buffers to the 16kHz mono Float32 PCM
/// whisper.cpp requires, accumulating the result across an entire recording.
/// `AVAudioEngine`'s input node runs at whatever the system's native sample
/// rate is (44.1kHz/48kHz typically) - `SFSpeechAudioBufferRecognitionRequest`
/// handles that resampling internally, but whisper.cpp expects the caller to
/// hand it 16kHz samples directly, so this exists purely for the local-engine
/// path. Kept as its own type (not folded into `DictationEngine`) so it can
/// be unit-tested independently of any live microphone.
final class DictationAudioResampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private(set) var samples: [Float] = []

    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    func reset() {
        converter = nil
        inputFormat = nil
        samples = []
    }

    /// Appends one tapped buffer's audio, resampled to 16kHz mono, onto the
    /// accumulated sample array. Safe to call from the same audio-tap
    /// callback that also feeds `SFSpeechAudioBufferRecognitionRequest`.
    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
        }
        guard let converter else { return }

        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channelData = outBuffer.floatChannelData else { return }
        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0 else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }
}
