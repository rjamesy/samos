import SwiftUI

/// System status for the voice/processing pipeline.
enum SystemStatus: String, Sendable {
    case idle
    case listening
    case capturing
    case thinking
    case speaking
}

/// Central observable state for the entire app.
@MainActor
@Observable
final class AppState {
    // MARK: - Chat

    var chatMessages: [ChatMessage] = []
    var outputItems: [OutputItem] = []

    // MARK: - System Status

    var status: SystemStatus = .idle
    var isMuted: Bool = false
    var showSettings: Bool = false
    var isListeningEnabled: Bool = false {
        didSet { handleListeningToggle() }
    }
    var lastError: String?

    // MARK: - Session

    let sessionId: String = UUID().uuidString

    // MARK: - Feature State

    var isCameraEnabled: Bool = false
    var isThinkingIndicatorVisible: Bool = false
    var activeSkillForgeJob: SkillForgeJob?

    // MARK: - Latency

    var lastLatencyMs: Int?

    // MARK: - Debug

    var debugLog: [String] = []
    var toolLog: [String] = []
    var engineLog: [String] = []
    var memoryStats: String = ""

    // MARK: - Container Reference

    var container: AppContainer?

    // MARK: - Chat Actions

    func send(_ text: String, attachments: [ChatAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var userMessage = ChatMessage(role: .user, text: trimmed)
        userMessage.attachments = attachments
        chatMessages.append(userMessage)

        guard let container else {
            appendAssistant("I'm not fully initialized yet. Please wait a moment.")
            return
        }

        status = .thinking
        isThinkingIndicatorVisible = true
        addDebug("[Turn] Processing: \"\(trimmed.prefix(80))\"")

        Task {
            do {
                // Get LLM response + execute plan
                let result = try await container.orchestrator.processTurn(
                    text: trimmed,
                    history: chatMessages,
                    sessionId: sessionId,
                    attachments: attachments
                )

                // Show chat bubble IMMEDIATELY — before TTS starts
                self.isThinkingIndicatorVisible = false

                if !result.sayText.isEmpty {
                    self.appendAssistant(result.sayText, latencyMs: result.latencyMs, usedMemory: result.usedMemory)
                }

                self.outputItems.append(contentsOf: result.outputItems)
                self.lastLatencyMs = result.latencyMs
                self.addDebug("[Turn] Complete: \(result.latencyMs)ms, tools: \(result.toolCalls)")

                for tool in result.toolCalls {
                    self.toolLog.append("[\(self.timestamp)] \(tool)")
                }

                if !result.engineSummary.isEmpty {
                    self.engineLog.append("[\(self.timestamp)] \(result.engineSummary)")
                    self.addDebug("[Engines] \(result.engineSummary)")
                    if self.engineLog.count > 50 {
                        self.engineLog.removeFirst(self.engineLog.count - 50)
                    }
                }

                // THEN speak via TTS (non-blocking — runs in background)
                let askedQuestion = result.sayText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
                if !result.sayText.isEmpty && !self.isMuted {
                    self.status = .speaking
                    container.speechRecognition.stopListening()
                    Task {
                        await container.ttsService.speak(text: result.sayText, mode: .normal)
                        await MainActor.run {
                            if self.status == .speaking {
                                if askedQuestion && self.isListeningEnabled {
                                    self.startFollowUpCapture()
                                } else {
                                    self.restartListeningAfterTurn()
                                }
                            }
                        }
                    }
                } else {
                    if askedQuestion && self.isListeningEnabled {
                        self.startFollowUpCapture()
                    } else {
                        self.restartListeningAfterTurn()
                    }
                }
            } catch {
                self.isThinkingIndicatorVisible = false
                self.lastError = error.localizedDescription
                self.addDebug("[Error] \(error.localizedDescription)")
                self.appendAssistant("Sorry, something went wrong. Please try again.")
                self.restartListeningAfterTurn()
            }
        }
    }

    // MARK: - Voice Pipeline Integration

    func setupVoiceCallbacks() {
        guard let container else { return }

        // Wire Porcupine wake word → SpeechRecognition for command capture
        container.wakeWordService.onWakeWordDetected = { [weak self] in
            Task { @MainActor in
                self?.status = .capturing
                self?.addDebug("[Voice] Hey Sam detected (Porcupine)")
                // After wake word, use SpeechRecognition to capture command
                self?.startCommandCapture()
            }
        }

        // Wire SpeechRecognition callbacks
        container.speechRecognition.onWakeWordDetected = { [weak self] in
            self?.status = .capturing
            self?.addDebug("[Voice] Wake word detected (SFSpeech)")
        }

        container.speechRecognition.onCommandRecognized = { [weak self] command in
            self?.addDebug("[Voice] Command: \"\(command)\"")
            self?.send(command)
        }

        container.speechRecognition.onStatusUpdate = { [weak self] msg in
            self?.addDebug(msg)
        }
    }

    private func startCommandCapture() {
        guard let speech = container?.speechRecognition else { return }
        // Stop Porcupine temporarily, use SpeechRecognition for the command
        container?.wakeWordService.stop()
        speech.startCommandCapture()
    }

    private func handleListeningToggle() {
        guard let container else { return }
        if isListeningEnabled {
            setupVoiceCallbacks()
            // Try Porcupine first, fall back to SpeechRecognition
            do {
                try container.wakeWordService.start()
                status = .listening
                addDebug("[Voice] Porcupine wake word active")
            } catch {
                addDebug("[Voice] Porcupine failed: \(error.localizedDescription)")
                addDebug("[Voice] Falling back to SFSpeechRecognizer")
                container.speechRecognition.startListening()
                status = .listening
            }
        } else {
            container.wakeWordService.stop()
            container.speechRecognition.stopListening()
            if status == .listening {
                status = .idle
            }
            addDebug("[Voice] Mic disabled")
        }
    }

    // MARK: - Follow-Up Capture

    /// Sam asked a question — go straight into command capture mode (no wake word needed).
    private func startFollowUpCapture() {
        guard let container else {
            status = .listening
            return
        }
        status = .capturing
        addDebug("[Voice] Follow-up capture (Sam asked a question)")
        container.speechRecognition.startCommandCapture()
    }

    // MARK: - Voice Restart

    /// After a turn (with or without TTS), restart the appropriate wake word service.
    private func restartListeningAfterTurn() {
        guard isListeningEnabled, let container else {
            status = isListeningEnabled ? .listening : .idle
            return
        }

        // Try Porcupine first, fall back to SFSpeech
        do {
            try container.wakeWordService.start()
            status = .listening
            addDebug("[Voice] Porcupine restarted after turn")
        } catch {
            addDebug("[Voice] Porcupine restart failed, using SFSpeech")
            container.speechRecognition.restartForWakeWord()
            status = .listening
        }
    }

    // MARK: - Debug

    func addDebug(_ message: String) {
        let entry = "[\(timestamp)] \(message)"
        debugLog.append(entry)
        // Keep last 200 entries
        if debugLog.count > 200 {
            debugLog.removeFirst(debugLog.count - 200)
        }
    }

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - Private

    private func appendAssistant(_ text: String, latencyMs: Int? = nil, usedMemory: Bool = false) {
        let msg = ChatMessage(
            role: .assistant,
            text: text,
            latencyMs: latencyMs,
            provider: "openai",
            usedMemory: usedMemory
        )
        chatMessages.append(msg)
    }
}
