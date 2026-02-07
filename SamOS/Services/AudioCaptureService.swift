import AVFoundation
import Foundation

/// Captures microphone audio with a lightweight tap (no conversion or file I/O in the callback).
/// After silence-based endpoint detection, converts accumulated samples to a 16 kHz mono PCM16 WAV offline.
final class AudioCaptureService {

    // MARK: - Callbacks

    var onSessionComplete: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - State

    private(set) var isCapturing = false

    // MARK: - Private

    private var engine: AVAudioEngine?
    private var hardwareFormat: AVAudioFormat?

    /// Raw Float32 samples from channel 0 at hardware sample rate.
    /// Only written by the tap callback; only read after the engine is stopped.
    private var capturedSamples: [Float] = []

    /// Whether we have detected speech (RMS above threshold) at least once.
    private var speechDetected = false
    /// Timestamp of the last buffer that was above the silence threshold.
    private var lastSpeechTime: Date?
    /// Guards against duplicate finishCapture calls from the tap.
    private var finishDispatched = false

    // MARK: - Errors

    enum CaptureError: Error, LocalizedError {
        case engineSetupFailed(String)
        case alreadyCapturing
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .engineSetupFailed(let msg): return "Audio engine setup failed: \(msg)"
            case .alreadyCapturing: return "Already capturing audio"
            case .conversionFailed: return "Failed to convert captured audio to WAV"
            }
        }
    }

    // MARK: - Public API

    func startCapture() throws {
        guard !isCapturing else { throw CaptureError.alreadyCapturing }

        // Safety net: ensure TTS is stopped before capture starts (dispatches to MainActor)
        Task { @MainActor in TTSService.shared.stopSpeaking() }

        speechDetected = false
        lastSpeechTime = nil
        finishDispatched = false
        capturedSamples = []

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0 else {
            throw CaptureError.engineSetupFailed("No audio input available")
        }
        self.hardwareFormat = hwFormat

        // Pre-allocate for ~30 seconds at hardware rate (avoids reallocations in the tap)
        capturedSamples.reserveCapacity(Int(hwFormat.sampleRate) * 30)

        let thresholdDB = M2Settings.silenceThresholdDB
        let silenceDurationMs = M2Settings.silenceDurationMs

        // Ultra-lightweight tap: only copies samples + computes RMS. No conversion, no file I/O.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.processTap(buffer, thresholdDB: thresholdDB, silenceDurationMs: silenceDurationMs)
        }

        try engine.start()
        isCapturing = true
    }

    /// Idempotent hard stop — removes tap, stops engine, releases resources.
    func stopEngineHard() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Stops capture. If `discard` is true, drops all captured audio.
    func stopCapture(discard: Bool = false) {
        guard isCapturing else { return }
        stopEngineHard()
        isCapturing = false
        speechDetected = false
        lastSpeechTime = nil
        finishDispatched = false
        if discard {
            capturedSamples = []
            hardwareFormat = nil
        }
    }

    // MARK: - Tap Callback (KEEP LIGHTWEIGHT — no allocations, no conversion, no file I/O, no logging)

    private func processTap(
        _ buffer: AVAudioPCMBuffer,
        thresholdDB: Float,
        silenceDurationMs: Int
    ) {
        guard let floatData = buffer.floatChannelData, buffer.frameLength > 0 else { return }

        let count = Int(buffer.frameLength)
        let samples = floatData[0]

        // Accumulate raw samples (channel 0 only)
        capturedSamples.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))

        // Fast RMS in dB
        var sumSquares: Float = 0
        for i in 0..<count {
            let s = samples[i]
            sumSquares += s * s
        }
        let rms = sqrtf(sumSquares / Float(count))
        let rmsDB: Float = rms > 0 ? 20 * log10f(rms) : -100

        if rmsDB > thresholdDB {
            speechDetected = true
            lastSpeechTime = Date()
        }

        // After speech detected, check for silence timeout
        if speechDetected, let lastSpeech = lastSpeechTime {
            let elapsed = Date().timeIntervalSince(lastSpeech) * 1000
            if elapsed >= Double(silenceDurationMs) && !finishDispatched {
                finishDispatched = true
                DispatchQueue.main.async { [weak self] in
                    self?.finishCapture()
                }
            }
        }
    }

    // MARK: - Finish Capture (main thread → offline conversion)

    private func finishCapture() {
        guard isCapturing else { return }

        // Stop engine first — guarantees no more tap callbacks after this returns
        stopCapture(discard: false)

        // Convert accumulated samples to WAV on a background thread
        let samples = capturedSamples
        let hwFormat = hardwareFormat
        capturedSamples = []

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try AudioCaptureService.writeWAVOffline(samples: samples, hardwareFormat: hwFormat)
                await MainActor.run {
                    self?.onSessionComplete?(url)
                }
            } catch {
                await MainActor.run {
                    self?.onError?(error)
                }
            }
        }
    }

    // MARK: - Offline WAV Conversion

    /// Converts hardware-rate Float32 samples to a 16 kHz mono PCM16 WAV file.
    /// Runs on a background thread — no audio engine required.
    static func writeWAVOffline(samples: [Float], hardwareFormat: AVAudioFormat?) throws -> URL {
        guard let hwFormat = hardwareFormat, !samples.isEmpty else {
            throw CaptureError.conversionFailed
        }

        // Source: mono Float32 at hardware sample rate
        let monoHWFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hwFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: monoHWFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        samples.withUnsafeBufferPointer { src in
            sourceBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)

        // Target: 16 kHz mono PCM16
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!

        guard let converter = AVAudioConverter(from: monoHWFormat, to: targetFormat) else {
            throw CaptureError.conversionFailed
        }

        let ratio = 16000.0 / hwFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(ceil(Double(samples.count) * ratio))
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount)!

        var inputProvided = false
        var convError: NSError?
        converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputProvided = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard convError == nil else { throw CaptureError.conversionFailed }

        // Write to temp WAV file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("samos_capture_\(UUID().uuidString).wav")
        let file = try AVAudioFile(
            forWriting: tempURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: outputBuffer)

        return tempURL
    }
}
