import Foundation
import AVFoundation

/// Voice Activity Detection + microphone capture.
/// Captures audio after wake word until silence is detected.
@MainActor
final class AudioCaptureService {
    private let settings: any SettingsStoreProtocol
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private(set) var isCapturing = false

    var onCaptureComplete: ((URL) -> Void)?

    init(settings: any SettingsStoreProtocol) {
        self.settings = settings
    }

    func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        do {
            audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        } catch {
            print("[AudioCapture] Failed to create audio file: \(error)")
            isCapturing = false
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.audioFile else { return }
            do {
                try file.write(from: buffer)
            } catch {
                print("[AudioCapture] Write error: \(error)")
            }
            // TODO: VAD — detect silence and auto-stop
        }

        do {
            try engine.start()
            self.audioEngine = engine
            print("[AudioCapture] Started capturing")
        } catch {
            print("[AudioCapture] Failed to start engine: \(error)")
            isCapturing = false
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isCapturing = false

        if let file = audioFile {
            let url = file.url
            audioFile = nil
            onCaptureComplete?(url)
        }
        print("[AudioCapture] Stopped capturing")
    }
}
