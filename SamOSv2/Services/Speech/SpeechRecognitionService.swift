import Foundation
import Speech
import AVFoundation

/// Unified speech recognition using Apple SFSpeechRecognizer.
/// Handles wake word detection ("Hey Sam") and continuous transcription.
@MainActor
final class SpeechRecognitionService: NSObject {
    private let settings: any SettingsStoreProtocol
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()

    private(set) var isListening = false
    private var isCapturingCommand = false
    private var silenceTimer: Task<Void, Never>?
    private var lastTranscription = ""

    /// Called when wake word is detected.
    var onWakeWordDetected: (() -> Void)?
    /// Called when a full command is transcribed after wake word.
    var onCommandRecognized: ((String) -> Void)?
    /// Called with status updates for debug.
    var onStatusUpdate: ((String) -> Void)?

    init(settings: any SettingsStoreProtocol) {
        self.settings = settings
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// Start listening for wake word ("Hey Sam") then capture command.
    func startListening() {
        startRecognition(commandOnly: false)
    }

    /// Start capturing a command directly (wake word already detected by Porcupine).
    func startCommandCapture() {
        startRecognition(commandOnly: true)
    }

    private func startRecognition(commandOnly: Bool) {
        guard !isListening else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .authorized:
                    self.beginRecognition(commandOnly: commandOnly)
                case .denied, .restricted:
                    self.onStatusUpdate?("[Voice] Speech recognition not authorized")
                case .notDetermined:
                    self.onStatusUpdate?("[Voice] Speech recognition authorization pending")
                @unknown default:
                    break
                }
            }
        }
    }

    func stopListening() {
        guard isListening else { return }
        endRecognition()
        onStatusUpdate?("[Voice] Stopped listening")
    }

    // MARK: - Recognition

    private func beginRecognition(commandOnly: Bool = false) {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            onStatusUpdate?("[Voice] Speech recognizer not available")
            return
        }

        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        do {
            try audioEngine.start()
            isListening = true
            isCapturingCommand = commandOnly
            hasDelivered = false
            lastTranscription = ""
            if commandOnly {
                onStatusUpdate?("[Voice] Capturing command...")
                resetSilenceTimer() // Start silence timer immediately for command mode
            } else {
                onStatusUpdate?("[Voice] Listening for 'Hey Sam'...")
            }
        } catch {
            onStatusUpdate?("[Voice] Audio engine failed: \(error.localizedDescription)")
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    self.handleTranscription(text, isFinal: result.isFinal)
                }

                if error != nil || (result?.isFinal ?? false) {
                    // Recognition ended — restart if still supposed to be listening
                    if self.isListening && !self.isCapturingCommand {
                        self.restartForWakeWord()
                    }
                }
            }
        }
    }

    private func handleTranscription(_ text: String, isFinal: Bool) {
        let lower = text.lowercased()

        if !isCapturingCommand {
            // Look for wake word
            if lower.contains("hey sam") || lower.contains("hey, sam") || lower.contains("hey sham") {
                isCapturingCommand = true
                onWakeWordDetected?()
                onStatusUpdate?("[Voice] Wake word detected! Listening for command...")

                // Extract anything after "hey sam"
                if let range = lower.range(of: "hey sam") ?? lower.range(of: "hey, sam") ?? lower.range(of: "hey sham") {
                    let afterWake = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !afterWake.isEmpty {
                        lastTranscription = afterWake
                        resetSilenceTimer()
                    }
                }
            }
        } else {
            // Capturing command — use full text in command-only mode, strip wake word otherwise
            if let range = lower.range(of: "hey sam") ?? lower.range(of: "hey, sam") ?? lower.range(of: "hey sham") {
                lastTranscription = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                lastTranscription = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            resetSilenceTimer()

            if isFinal && !lastTranscription.isEmpty {
                deliverCommand(lastTranscription)
            }
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s silence = end of command
            if !Task.isCancelled {
                await MainActor.run {
                    if self.isCapturingCommand && !self.lastTranscription.isEmpty {
                        self.deliverCommand(self.lastTranscription)
                    }
                }
            }
        }
    }

    private var hasDelivered = false

    private func deliverCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Guard against duplicate delivery (silence timer + isFinal race)
        guard !hasDelivered else { return }
        hasDelivered = true

        onStatusUpdate?("[Voice] Command: \"\(trimmed)\"")
        onCommandRecognized?(trimmed)

        // Reset for next wake word
        isCapturingCommand = false
        lastTranscription = ""
        silenceTimer?.cancel()

        // Stop recognition — the voice pipeline will restart us when ready
        endRecognition()
    }

    /// Restart recognition for wake word listening (called externally after turn completes).
    func restartForWakeWord() {
        endRecognition()
        hasDelivered = false
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.beginRecognition()
        }
    }

    private func endRecognition() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }
}
