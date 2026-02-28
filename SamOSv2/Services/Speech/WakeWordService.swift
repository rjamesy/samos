import AVFoundation
import Foundation
import PorcupineC

/// Wraps Picovoice Porcupine C library for always-on wake word detection ("Hey Sam").
/// Uses AVAudioEngine to capture mic audio and feeds 16kHz Int16 frames to the Porcupine C API.
final class WakeWordService {

    // MARK: - Callbacks

    var onWakeWordDetected: (() -> Void)?
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - Errors

    enum WakeWordError: Error, LocalizedError {
        case missingAccessKey
        case missingKeywordFile
        case missingModelFile
        case porcupineError(String)
        case audioSetupFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingAccessKey: return "Porcupine AccessKey not configured"
            case .missingKeywordFile: return "Porcupine keyword (.ppn) file not found"
            case .missingModelFile: return "Porcupine model (.pv) file not found"
            case .porcupineError(let msg): return "Porcupine error: \(msg)"
            case .audioSetupFailed(let msg): return "Audio setup failed: \(msg)"
            }
        }
    }

    // MARK: - State

    private(set) var isRunning = false
    private var porcupine: OpaquePointer?
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let settings: any SettingsStoreProtocol

    /// Porcupine requires exactly this many Int16 samples per process() call.
    private var frameLength: Int32 = 0
    /// Buffer to accumulate converted Int16 samples.
    private var sampleBuffer: [Int16] = []

    init(settings: any SettingsStoreProtocol) {
        self.settings = settings
    }

    // MARK: - Public API

    func start() throws {
        guard !isRunning else { return }

        let accessKey = settings.string(forKey: SettingsKey.porcupineAccessKey) ?? ""
        guard !accessKey.isEmpty else { throw WakeWordError.missingAccessKey }

        // Look for keyword file in bundle
        guard let keywordPath = Bundle.main.path(forResource: "Hey-Sam_en_mac_v4_0_0", ofType: "ppn") else {
            throw WakeWordError.missingKeywordFile
        }

        // Model params file bundled in app resources
        guard let modelPath = Bundle.main.path(forResource: "porcupine_params", ofType: "pv") else {
            throw WakeWordError.missingModelFile
        }

        let sensitivity = settings.double(forKey: SettingsKey.porcupineSensitivity)
        let effectiveSensitivity = sensitivity > 0 ? Float(sensitivity) : Float(AppConfig.defaultWakeWordSensitivity)

        // Initialize Porcupine C engine
        var handle: OpaquePointer?
        var sensitivityC = effectiveSensitivity

        let status = keywordPath.withCString { kwPtr -> pv_status_t in
            modelPath.withCString { modelPtr -> pv_status_t in
                accessKey.withCString { akPtr -> pv_status_t in
                    var kwOptional: UnsafePointer<CChar>? = kwPtr
                    return withUnsafePointer(to: &kwOptional) { kwArrayPtr in
                        withUnsafePointer(to: &sensitivityC) { sensPtr in
                            pv_porcupine_init(akPtr, modelPtr, "cpu", 1, kwArrayPtr, sensPtr, &handle)
                        }
                    }
                }
            }
        }

        guard status == PV_STATUS_SUCCESS, let handle else {
            let msg = String(cString: pv_status_to_string(status))
            throw WakeWordError.porcupineError(msg)
        }

        self.porcupine = handle
        self.frameLength = pv_porcupine_frame_length()
        self.sampleBuffer = []

        // Set up AVAudioEngine for mic capture
        try setupAudioEngine()
        isRunning = true
        print("[WakeWord] Started with Porcupine, frame length: \(frameLength)")
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        sampleBuffer = []

        if let porcupine {
            pv_porcupine_delete(porcupine)
        }
        porcupine = nil
        isRunning = false
        print("[WakeWord] Stopped")
    }

    // MARK: - Audio Engine

    private func setupAudioEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw WakeWordError.audioSetupFailed("No audio input available")
        }

        // Porcupine needs 16kHz mono Int16
        let sampleRate = Double(pv_sample_rate())
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw WakeWordError.audioSetupFailed("Cannot create target audio format")
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw WakeWordError.audioSetupFailed("Cannot create audio converter")
        }
        self.converter = converter

        let frameLen = self.frameLength

        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(frameLen), format: hwFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, targetFormat: targetFormat, frameLength: frameLen)
        }

        try engine.start()
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat, frameLength: Int32) {
        onAudioBuffer?(buffer)

        // Convert to 16kHz Int16
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrameCapacity > 0,
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity)
        else { return }

        var error: NSError?
        let status = converter?.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData, error == nil else { return }

        // Extract Int16 samples
        guard let int16Data = convertedBuffer.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: int16Data[0], count: Int(convertedBuffer.frameLength)))
        sampleBuffer.append(contentsOf: samples)

        // Process complete frames
        let fl = Int(frameLength)
        while sampleBuffer.count >= fl {
            let frame = Array(sampleBuffer.prefix(fl))
            sampleBuffer.removeFirst(fl)

            var keywordIndex: Int32 = -1
            let result = frame.withUnsafeBufferPointer { ptr in
                pv_porcupine_process(porcupine, ptr.baseAddress, &keywordIndex)
            }

            if result == PV_STATUS_SUCCESS && keywordIndex >= 0 {
                Task { @MainActor [weak self] in
                    self?.onWakeWordDetected?()
                }
            }
        }
    }

    deinit {
        if let porcupine {
            pv_porcupine_delete(porcupine)
        }
    }
}
