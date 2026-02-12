import Foundation

/// Serializes competing audio work so TTS has priority over STT/capture.
actor AudioCoordinator {
    static let shared = AudioCoordinator()

    enum WorkKind: String, Sendable {
        case tts
        case stt
        case capture

        var priority: Int {
            switch self {
            case .tts: return 3
            case .stt: return 2
            case .capture: return 1
            }
        }

        var category: String {
            switch self {
            case .tts: return "playback"
            case .stt, .capture: return "record"
            }
        }

        var mode: String {
            switch self {
            case .tts: return "default"
            case .stt: return "measurement"
            case .capture: return "voice_capture"
            }
        }
    }

    struct Lease: Sendable {
        fileprivate let id: UUID
        let kind: WorkKind
        let owner: String
    }

    private struct Waiter {
        let id: UUID
        let kind: WorkKind
        let owner: String
        let enqueuedAt: Date
        let continuation: CheckedContinuation<Lease, Never>
    }

    private var activeLease: Lease?
    private var waiters: [Waiter] = []
    private var captureOwner: String?
    private var sttOwner: String?
    private var ttsOwner: String?
    private var pendingTTSOwner: String?

    func setTTSPending(owner: String) {
        pendingTTSOwner = owner
        #if DEBUG
        print("[AUDIO_GATE] pending_tts owner=\(owner)")
        #endif
    }

    func clearTTSPending(owner: String?) {
        guard let owner else {
            pendingTTSOwner = nil
            return
        }
        if pendingTTSOwner == owner {
            pendingTTSOwner = nil
        }
    }

    func acquire(for kind: WorkKind, owner: String = "unknown") async -> Lease {
        let blockedByPendingTTS = (pendingTTSOwner != nil && kind != .tts)
        if activeLease == nil, waiters.isEmpty, !blockedByPendingTTS {
            let lease = Lease(id: UUID(), kind: kind, owner: owner)
            activeLease = lease
            assignOwner(owner, for: kind)
            logAudioSession(event: "acquire", kind: kind, owner: owner, activation: "active")
            #if DEBUG
            print("[AUDIO_GATE] acquire kind=\(kind.rawValue) owner=\(owner)")
            #endif
            if kind == .tts, pendingTTSOwner == owner {
                pendingTTSOwner = nil
            }
            return lease
        }

        return await withCheckedContinuation { continuation in
            let waiter = Waiter(id: UUID(), kind: kind, owner: owner, enqueuedAt: Date(), continuation: continuation)
            waiters.append(waiter)
            resumeNextIfPossible()
        }
    }

    func release(_ lease: Lease) {
        guard let activeLease, activeLease.id == lease.id else { return }
        clearOwner(for: lease.kind, owner: lease.owner)
        logAudioSession(event: "release", kind: lease.kind, owner: lease.owner, activation: "inactive")
        #if DEBUG
        print("[AUDIO_GATE] release kind=\(lease.kind.rawValue) owner=\(lease.owner)")
        #endif
        self.activeLease = nil
        resumeNextIfPossible()
    }

    func reactivateForTTS(owner: String = "unknown") {
        logAudioSession(event: "reactivate_tts", kind: .tts, owner: owner, activation: "reactivating")
    }

    private func resumeNextIfPossible() {
        guard activeLease == nil, !waiters.isEmpty else { return }

        let sortedIndices = waiters.indices.sorted { lhs, rhs in
            let left = waiters[lhs]
            let right = waiters[rhs]
            if left.kind.priority == right.kind.priority {
                return left.enqueuedAt < right.enqueuedAt
            }
            return left.kind.priority > right.kind.priority
        }
        let selectableIndex: Int? = {
            guard let first = sortedIndices.first else { return nil }
            guard pendingTTSOwner != nil else { return first }
            let ttsIndex = sortedIndices.first(where: { waiters[$0].kind == .tts })
            // Block capture/STT promotion while TTS is pending.
            return ttsIndex
        }()
        guard let idx = selectableIndex else { return }
        let waiter = waiters.remove(at: idx)
        let lease = Lease(id: waiter.id, kind: waiter.kind, owner: waiter.owner)
        activeLease = lease
        assignOwner(lease.owner, for: lease.kind)
        logAudioSession(event: "acquire", kind: lease.kind, owner: lease.owner, activation: "active")
        #if DEBUG
        print("[AUDIO_GATE] acquire kind=\(lease.kind.rawValue) owner=\(lease.owner)")
        #endif
        if lease.kind == .tts, pendingTTSOwner == lease.owner {
            pendingTTSOwner = nil
        }
        waiter.continuation.resume(returning: lease)
    }

    private func assignOwner(_ owner: String, for kind: WorkKind) {
        switch kind {
        case .capture:
            captureOwner = owner
        case .stt:
            sttOwner = owner
        case .tts:
            ttsOwner = owner
        }
    }

    private func clearOwner(for kind: WorkKind, owner: String) {
        switch kind {
        case .capture:
            if captureOwner == owner { captureOwner = nil }
        case .stt:
            if sttOwner == owner { sttOwner = nil }
        case .tts:
            if ttsOwner == owner { ttsOwner = nil }
        }
    }

    private func logAudioSession(event: String, kind: WorkKind, owner: String, activation: String) {
        #if DEBUG
        print("[AUDIO_SESSION] event=\(event) category=\(kind.category) mode=\(kind.mode) activation=\(activation) owner=\(owner) capture_owner=\(captureOwner ?? "none") stt_owner=\(sttOwner ?? "none") tts_owner=\(ttsOwner ?? "none")")
        #endif
    }
}

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
    func suspendForTTS()
    func resumeAfterTTSIfNeeded()
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
    private var captureLease: AudioCoordinator.Lease?
    private var sttLease: AudioCoordinator.Lease?
    private var audioOwnerSequence = 0
    private var lastTTSSuspendCompletedAt: Date?
    private let postTTSSuspendDebounceMs: Int

    init(postTTSSuspendDebounceMs: Int = 80) {
        self.postTTSSuspendDebounceMs = max(0, postTTSSuspendDebounceMs)
    }

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
        releaseSTTLease()
        noSpeechTimeoutTask?.cancel()
        noSpeechTimeoutTask = nil
        followUpSpeechDetected = false

        // Stop capture (discard partial audio)
        capture.stopCapture(discard: true)
        capture.stopEngineHard() // belt + suspenders
        releaseCaptureLease()

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

        startCaptureWithLease(noSpeechTimeoutMs: noSpeechTimeoutMs)
    }

    /// Cancels an in-progress follow-up capture and resumes wake word listening.
    func cancelFollowUpCapture() {
        guard status == .capturingAudio else { return }
        noSpeechTimeoutTask?.cancel()
        noSpeechTimeoutTask = nil
        capture.stopCapture(discard: true)
        capture.stopEngineHard()
        releaseCaptureLease()
        followUpSpeechDetected = false
        resumeWakeWord()
    }

    // MARK: - Pipeline Steps

    private func handleWakeWord() {
        guard listeningEnabled else { return }

        // Barge-in: stop any TTS playback immediately
        TTSService.shared.stopSpeaking(reason: .userInterrupt)

        // Stop Porcupine's audio engine before we start capture
        wakeWord.stop()

        setStatus(.capturingAudio)
        SoundCuePlayer.shared.playCaptureBeep()
        followUpSpeechDetected = false

        startCaptureWithLease(noSpeechTimeoutMs: nil)
    }

    private func handleCaptureComplete(wavURL: URL) {
        guard listeningEnabled else { return }
        noSpeechTimeoutTask?.cancel()
        noSpeechTimeoutTask = nil
        followUpSpeechDetected = false

        // Ensure audio engine is fully stopped (belt + suspenders — AudioCaptureService
        // already stops in finishCapture, but we enforce it here too)
        capture.stopEngineHard()
        releaseCaptureLease()

        setStatus(.transcribing)

        sttTask = Task(priority: .userInitiated) { [weak self] in
            let owner = await MainActor.run { self?.nextAudioOwner(prefix: "stt") ?? "stt_unknown" }
            let lease = await AudioCoordinator.shared.acquire(for: .stt, owner: owner)
            await MainActor.run {
                self?.sttLease = lease
            }
            defer {
                self?.sttTask = nil
                Task {
                    await AudioCoordinator.shared.release(lease)
                }
                Task { @MainActor [weak self] in
                    self?.sttLease = nil
                }
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
        releaseCaptureLease()
        releaseSTTLease()
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
        releaseCaptureLease()
        releaseSTTLease()
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

    func suspendForTTS() {
        #if DEBUG
        print("[AUDIO_SESSION] event=tts_suspend_requested category=record mode=measurement activation=deactivating")
        #endif
        if status == .capturingAudio {
            noSpeechTimeoutTask?.cancel()
            noSpeechTimeoutTask = nil
            capture.stopCapture(discard: true)
            capture.stopEngineHard()
            followUpSpeechDetected = false
            releaseCaptureLease()
        }
        if status == .transcribing {
            sttTask?.cancel()
            sttTask = nil
            releaseSTTLease()
        }
        wakeWord.stop()
        if listeningEnabled {
            setStatus(.listeningForWakeWord)
        }
        lastTTSSuspendCompletedAt = Date()
        #if DEBUG
        print("[AUDIO_SESSION] event=tts_suspend_complete category=record mode=measurement activation=inactive")
        #endif
    }

    func resumeAfterTTSIfNeeded() {
        guard listeningEnabled else { return }
        guard status == .listeningForWakeWord else { return }
        resumeWakeWord()
    }

    private func startCaptureWithLease(noSpeechTimeoutMs: Int?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let lastTTSSuspendCompletedAt, self.postTTSSuspendDebounceMs > 0 {
                let elapsedMs = Int(Date().timeIntervalSince(lastTTSSuspendCompletedAt) * 1000)
                let remainingMs = self.postTTSSuspendDebounceMs - elapsedMs
                if remainingMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingMs) * 1_000_000)
                }
            }
            let owner = self.nextAudioOwner(prefix: "capture")
            let lease = await AudioCoordinator.shared.acquire(for: .capture, owner: owner)
            guard self.status == .capturingAudio else {
                await AudioCoordinator.shared.release(lease)
                return
            }
            self.captureLease = lease
            do {
                try self.capture.startCapture()
                self.scheduleNoSpeechTimeoutIfNeeded(noSpeechTimeoutMs)
            } catch {
                self.releaseCaptureLease()
                self.handleError(error)
            }
        }
    }

    private func releaseCaptureLease() {
        guard let lease = captureLease else { return }
        captureLease = nil
        Task {
            await AudioCoordinator.shared.release(lease)
        }
    }

    private func releaseSTTLease() {
        guard let lease = sttLease else { return }
        sttLease = nil
        Task {
            await AudioCoordinator.shared.release(lease)
        }
    }

    private func nextAudioOwner(prefix: String) -> String {
        audioOwnerSequence += 1
        return "\(prefix)_\(audioOwnerSequence)"
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
