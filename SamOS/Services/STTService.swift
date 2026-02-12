import AVFoundation
import Foundation
import whisper

/// In-process speech-to-text using whisper.cpp via vendored static library.
final class STTService {

    // MARK: - Errors

    enum STTError: Error, LocalizedError {
        case modelNotConfigured
        case modelFileNotFound(String)
        case modelLoadFailed
        case transcriptionFailed(String)
        case noAudioFile

        var errorDescription: String? {
            switch self {
            case .modelNotConfigured: return "Whisper model path not configured"
            case .modelFileNotFound(let p): return "Whisper model file not found: \(p)"
            case .modelLoadFailed: return "Failed to load Whisper model"
            case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
            case .noAudioFile: return "Audio file not found or unreadable"
            }
        }
    }

    // MARK: - State

    private var ctx: OpaquePointer?
    /// URL whose security-scoped access is active while model is loaded.
    private var modelAccessURL: URL?

    var isModelLoaded: Bool { ctx != nil }

    // MARK: - Model Lifecycle

    func loadModel() throws {
        // Skip if already loaded — reuse context across transcriptions
        if ctx != nil {
            STTDiagnosticsStore.shared.recordPrewarm(success: true, error: nil)
            return
        }

        // 1. Try bundled model first (always works in sandbox)
        // 2. Fall back to security-scoped bookmark (user-selected file)
        let path: String
        var scopedURL: URL?

        if let bundled = Bundle.main.path(forResource: "ggml-base.en", ofType: "bin") {
            let bundledLargeExists = Bundle.main.path(forResource: "ggml-large", ofType: "bin") != nil
            if !bundledLargeExists {
                STTDiagnosticsStore.shared.recordBundleFallbackOnce(
                    "Model size 'large' not found in bundle, falling back to 'base'."
                )
            }
            path = bundled
            STTDiagnosticsStore.shared.recordModelFound(true)
        } else if let resolved = M2Settings.resolveWhisperModelURL() {
            path = resolved.path
            scopedURL = resolved
            STTDiagnosticsStore.shared.recordModelFound(true)
        } else if !M2Settings.whisperModelDisplayPath.isEmpty {
            STTDiagnosticsStore.shared.recordModelFound(false)
            throw STTError.modelFileNotFound(M2Settings.whisperModelDisplayPath)
        } else {
            STTDiagnosticsStore.shared.recordModelFound(false)
            throw STTError.modelNotConfigured
        }

        if let prev = modelAccessURL {
            prev.stopAccessingSecurityScopedResource()
            modelAccessURL = nil
        }

        var params = whisper_context_default_params()
        // Disable GPU — logs show "no GPU found" on macOS; these flags cause extra backend init work
        params.use_gpu = false
        params.flash_attn = false
        guard let newCtx = whisper_init_from_file_with_params(path, params) else {
            scopedURL?.stopAccessingSecurityScopedResource()
            STTDiagnosticsStore.shared.recordPrewarm(success: false, error: STTError.modelLoadFailed.localizedDescription)
            throw STTError.modelLoadFailed
        }
        self.ctx = newCtx
        modelAccessURL = scopedURL
        STTDiagnosticsStore.shared.recordPrewarm(success: true, error: nil)
    }

    func unloadModel() {
        if let ctx = ctx {
            whisper_free(ctx)
        }
        self.ctx = nil
        if let url = modelAccessURL {
            url.stopAccessingSecurityScopedResource()
            modelAccessURL = nil
        }
    }

    // MARK: - Transcription

    /// Transcribes a 16 kHz mono WAV file and returns the text. Deletes the WAV file after processing.
    func transcribe(wavURL: URL) async throws -> String {
        let useRealtimeSTT = OpenAISettings.realtimeModeEnabled && !OpenAISettings.realtimeUseClassicSTT
        STTDiagnosticsStore.shared.recordEngineSelection(
            realtimeModeEnabled: OpenAISettings.realtimeModeEnabled,
            useClassicSTT: OpenAISettings.realtimeUseClassicSTT
        )
        if useRealtimeSTT {
            STTDiagnosticsStore.shared.recordModelFound(true)
            defer { try? FileManager.default.removeItem(at: wavURL) }
            do {
                return try await OpenAIRealtimeSocket.transcribeWav(wavURL)
            } catch OpenAIRealtimeSocket.RealtimeError.missingTranscript {
                return ""
            } catch OpenAIRealtimeSocket.RealtimeError.requestFailed(let message) {
                if message.lowercased().contains("audio buffer empty") {
                    return ""
                }
                STTDiagnosticsStore.shared.recordError(message)
                throw OpenAIRealtimeSocket.RealtimeError.requestFailed(message)
            }
        }

        guard let ctx = ctx else { throw STTError.modelLoadFailed }
        let capturedCtx = ctx
        let capturedWavURL = wavURL

        let text: String = try await Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: capturedWavURL) }
            let capturedSamples = try Self.loadWAVSamples(url: capturedWavURL)

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = Self.optimalThreadCount()
            params.print_special = false
            params.print_progress = false
            params.print_realtime = false
            params.print_timestamps = false
            params.single_segment = false

            let langStr = strdup("en")
            params.language = UnsafePointer(langStr)

            let result = capturedSamples.withUnsafeBufferPointer { bufferPtr -> Int32 in
                whisper_full(capturedCtx, params, bufferPtr.baseAddress, Int32(capturedSamples.count))
            }

            free(langStr)

            guard result == 0 else {
                STTDiagnosticsStore.shared.recordError("whisper_full returned \(result)")
                throw STTError.transcriptionFailed("whisper_full returned \(result)")
            }

            let nSegments = whisper_full_n_segments(capturedCtx)
            var output = ""
            for i in 0..<nSegments {
                if let segmentText = whisper_full_get_segment_text(capturedCtx, i) {
                    output += String(cString: segmentText)
                }
            }

            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value

        STTDiagnosticsStore.shared.recordPrewarm(success: true, error: nil)
        return text
    }

    private static func optimalThreadCount() -> Int32 {
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        // Keep one core free for UI/audio and cap to avoid diminishing returns.
        let tuned = max(2, min(coreCount - 1, 8))
        return Int32(tuned)
    }

    // MARK: - WAV Loading

    private static func loadWAVSamples(url: URL) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw STTError.noAudioFile
        }

        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw STTError.noAudioFile
        }

        try file.read(into: buffer)

        guard let floatData = buffer.floatChannelData else {
            throw STTError.noAudioFile
        }

        return Array(UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength)))
    }

    deinit {
        unloadModel()
    }
}
