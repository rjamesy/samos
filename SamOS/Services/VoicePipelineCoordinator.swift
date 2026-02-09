import Foundation

/// Pipeline status exposed to the UI layer.
enum VoicePipelineStatus: Equatable {
    case off
    case listeningForWakeWord
    case capturingAudio
    case transcribing
}

@MainActor
protocol VoicePipelineCoordinating: AnyObject {
    var onStatusChange: ((VoicePipelineStatus) -> Void)? { get set }
    var onTranscript: ((String) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func startListening() throws
    func stopListening()
    func startFollowUpCapture(noSpeechTimeoutMs: Int?)
    func cancelFollowUpCapture()
}

/// Orchestrates WakeWordService → AudioCaptureService → STTService in a linear state machine.
///
/// Hard rule: when state == `.transcribing`, NO AVAudioEngine and NO Porcupine should be active.
@MainActor
final class VoicePipelineCoordinator {

    // MARK: - Callbacks (set by AppState)

    var onStatusChange: ((VoicePipelineStatus) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - State

    private(set) var status: VoicePipelineStatus = .off

    /// Whether the user wants the pipeline active. Guards against accidental resumes after errors.
    private var listeningEnabled = false

    // MARK: - Services

    private let wakeWord = WakeWordService()
    private let capture = AudioCaptureService()
    private let stt = STTService()

    private var sttTask: Task<Void, Never>?
    private var noSpeechTimeoutTask: Task<Void, Never>?
    private var followUpSpeechDetected = false

    // MARK: - Start / Stop

    func startListening() throws {
        guard status == .off else { return }
        listeningEnabled = true

        // Preload Whisper when classic STT is active.
        // Realtime mode can still opt into classic STT for lower latency.
        let useRealtimeSTT = OpenAISettings.realtimeModeEnabled && !OpenAISettings.realtimeUseClassicSTT
        if !useRealtimeSTT {
            try stt.loadModel()
        }

        // Wire callbacks
        wakeWord.onWakeWordDetected = { [weak self] in
            self?.handleWakeWord()
        }

        capture.onSessionComplete = { [weak self] url in
            Task { @MainActor in
                self?.handleCaptureComplete(wavURL: url)
            }
        }

        capture.onSpeechDetected = { [weak self] in
            self?.followUpSpeechDetected = true
        }

        capture.onError = { [weak self] error in
            Task { @MainActor in
                self?.handleError(error)
            }
        }

        try wakeWord.start()
        setStatus(.listeningForWakeWord)
    }

    /// Immediate, idempotent stop. Cancels all in-flight work.
    func stopListening() {
        listeningEnabled = false

        // Cancel any in-flight STT
        sttTask?.cancel()
        sttTask = nil
        noSpeechTimeoutTask?.cancel()
        noSpeechTimeoutTask = nil
        followUpSpeechDetected = false

        // Stop capture (discard partial audio)
        capture.stopCapture(discard: true)
        capture.stopEngineHard() // belt + suspenders

        // Stop wake word
        wakeWord.stop()

        setStatus(.off)
    }

    // MARK: - Follow-Up Capture

    /// Starts a follow-up capture without requiring wake word.
    /// Used when Sam asks a question and we expect a spoken reply.
    func startFollowUpCapture(noSpeechTimeoutMs: Int? = nil) {
        guard listeningEnabled, status == .listeningForWakeWord else { return }

        // Stop wake word's audio engine before starting capture
        wakeWord.stop()

        followUpSpeechDetected = false
        setStatus(.capturingAudio)
        SoundCuePlayer.shared.playCaptureBeep()

        do {
            try capture.startCapture()
            scheduleNoSpeechTimeoutIfNeeded(noSpeechTimeoutMs)
        } catch {
            handleError(error)
        }
    }

    /// Cancels an in-progress follow-up capture and resumes wake word listening.
    func cancelFollowUpCapture() {
        guard status == .capturingAudio else { return }
        noSpeechTimeoutTask?.cancel()
        noSpeechTimeoutTask = nil
        capture.stopCapture(discard: true)
        capture.stopEngineHard()
        followUpSpeechDetected = false
        resumeWakeWord()
    }

    // MARK: - Pipeline Steps

    private func handleWakeWord() {
        guard listeningEnabled else { return }

        // Barge-in: stop any TTS playback immediately
        TTSService.shared.stopSpeaking()

        // Stop Porcupine's audio engine before we start capture
        wakeWord.stop()

        setStatus(.capturingAudio)
        SoundCuePlayer.shared.playCaptureBeep()
        followUpSpeechDetected = false

        do {
            try capture.startCapture()
        } catch {
            handleError(error)
        }
    }

    private func handleCaptureComplete(wavURL: URL) {
        guard listeningEnabled else { return }
        noSpeechTimeoutTask?.cancel()
        noSpeechTimeoutTask = nil
        followUpSpeechDetected = false

        // Ensure audio engine is fully stopped (belt + suspenders — AudioCaptureService
        // already stops in finishCapture, but we enforce it here too)
        capture.stopEngineHard()

        setStatus(.transcribing)

        sttTask = Task(priority: .userInitiated) { [weak self] in
            defer {
                self?.sttTask = nil
            }
            guard !Task.isCancelled else { return }
            do {
                let text = try await self?.stt.transcribe(wavURL: wavURL) ?? ""
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if !text.isEmpty {
                        self?.onTranscript?(text)
                    }
                    self?.resumeWakeWord()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.handleError(error)
                }
            }
        }
    }

    private func resumeWakeWord() {
        noSpeechTimeoutTask?.cancel()
        noSpeechTimeoutTask = nil
        followUpSpeechDetected = false
        guard listeningEnabled else {
            setStatus(.off)
            return
        }
        do {
            try wakeWord.start()
            setStatus(.listeningForWakeWord)
        } catch {
            handleError(error)
        }
    }

    private func handleError(_ error: Error) {
        // Ensure everything is stopped
        noSpeechTimeoutTask?.cancel()
        noSpeechTimeoutTask = nil
        followUpSpeechDetected = false
        capture.stopCapture(discard: true)
        capture.stopEngineHard()
        wakeWord.stop()

        onError?(error)

        guard listeningEnabled else {
            setStatus(.off)
            return
        }

        // Attempt to resume after a short delay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            guard let self, self.listeningEnabled else { return }
            self.resumeWakeWord()
        }
    }

    private func setStatus(_ newStatus: VoicePipelineStatus) {
        status = newStatus
        onStatusChange?(newStatus)
    }

    private func scheduleNoSpeechTimeoutIfNeeded(_ noSpeechTimeoutMs: Int?) {
        noSpeechTimeoutTask?.cancel()
        noSpeechTimeoutTask = nil

        guard let timeoutMs = noSpeechTimeoutMs, timeoutMs > 0 else { return }
        noSpeechTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.status == .capturingAudio, !self.followUpSpeechDetected else { return }
            self.cancelFollowUpCapture()
        }
    }
}

extension VoicePipelineCoordinator: VoicePipelineCoordinating {}
