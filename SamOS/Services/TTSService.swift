import AVFoundation

/// Text-to-speech service using ElevenLabs.
/// Safe to call from @MainActor; network and audio work runs off-main.
@MainActor
final class TTSService {
    struct TimingSnapshot: Sendable {
        let queueWaitMs: Int?
        let synthesisMs: Int?
        let playbackStartMs: Int?
    }

    enum SpeechDropReason: String {
        case userInterrupt = "user_interrupt"
        case ttsEngineError = "tts_engine_error"
        case audioSessionDenied = "audio_session_denied"
        case explicitCancel = "explicit_cancel"
        case supersededByNewTurn = "superseded_by_new_turn"
        case ttsStartDeadline = "tts_start_deadline"
        case audioGateTimeout = "audio_gate_timeout"
    }

    static let shared = TTSService()

    /// Whether audio is currently playing.
    @Published private(set) var isSpeaking = false
    @Published private(set) var lastDropReason: SpeechDropReason?

    private var player: AVAudioPlayer?
    private var speakTask: Task<Void, Never>?
    private var speechQueue: [(text: String, mode: SpeechMode)] = []
    private var audioCache: [String: Data] = [:]
    private var audioCacheOrder: [String] = []
    private let maxAudioCacheEntries = 40
    private var ttsLease: AudioCoordinator.Lease?
    private var activeCorrelationID: String = "unknown"
    private var enqueueAtByCorrelationID: [String: Date] = [:]
    private var synthesisStartAtByCorrelationID: [String: Date] = [:]
    private var playbackStartAtByCorrelationID: [String: Date] = [:]

    private init() {}

    /// Warms DNS + TLS connection pool to ElevenLabs so first speech has lower latency.
    func prewarm() {
        guard ElevenLabsSettings.isConfigured else { return }
        Task.detached(priority: .utility) {
            guard let url = URL(string: "https://api.elevenlabs.io") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: request)
            #if DEBUG
            await MainActor.run { print("[TTS_PREWARM] ElevenLabs connection pool warmed") }
            #endif
        }
    }

    /// Enqueues multiple lines for sequential playback.
    /// Reuses current playback when the same correlation ID is active.
    /// Cancels in-progress speech only for explicit turn replacement.
    func enqueue(_ lines: [String], mode: SpeechMode = .answer, correlationID: String? = nil) {
        guard !lines.isEmpty else { return }
        let trimmedCorrelationID = correlationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCorrelationID = (trimmedCorrelationID?.isEmpty == false) ? trimmedCorrelationID : nil

        let hasActiveSpeech = isSpeaking || !speechQueue.isEmpty || speakTask != nil
        let shouldReplaceActiveSpeech: Bool
        if let normalizedCorrelationID {
            shouldReplaceActiveSpeech = hasActiveSpeech && activeCorrelationID != normalizedCorrelationID
            activeCorrelationID = normalizedCorrelationID
            if enqueueAtByCorrelationID[normalizedCorrelationID] == nil {
                enqueueAtByCorrelationID[normalizedCorrelationID] = Date()
            }
        } else {
            shouldReplaceActiveSpeech = hasActiveSpeech
        }

        if shouldReplaceActiveSpeech {
            stopSpeaking(reason: .supersededByNewTurn)
        }

        if lastDropReason == .explicitCancel {
            lastDropReason = nil
        }

        speechQueue.append(contentsOf: lines.map { (text: $0, mode: mode) })
        if !isSpeaking {
            drainQueue()
        }
    }

    /// Speaks the given text using ElevenLabs TTS.
    /// - Parameters:
    ///   - text: Text to speak.
    ///   - mode: Controls prosody (confirm = snappier, answer = normal).
    ///   - interrupt: If true (default), stops any current speech first.
    func speak(_ text: String, mode: SpeechMode = .answer, interrupt: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pacing = ResponsePolish.ttsPacing(for: trimmed, mode: mode)
        let ttsText = pacing.ttsText
        let cacheKey = makeAudioCacheKey(text: ttsText, mode: mode)

        // Respect mute and empty text
        guard !ElevenLabsSettings.isMuted, !ttsText.isEmpty else { return }
        guard ElevenLabsSettings.isConfigured else {
            print("[TTSService] ElevenLabs not configured — skipping speech")
            let owner = activeCorrelationID
            Task {
                await AudioCoordinator.shared.clearTTSPending(owner: owner)
            }
            if !speechQueue.isEmpty {
                drainQueue()
            }
            return
        }

        if interrupt {
            stopSpeaking(reason: .explicitCancel)
        }

        speakTask = Task { [weak self] in
            do {
                if let self, self.synthesisStartAtByCorrelationID[self.activeCorrelationID] == nil {
                    self.synthesisStartAtByCorrelationID[self.activeCorrelationID] = Date()
                }
                if pacing.preSpeakDelayNs > 0 {
                    try await Task.sleep(nanoseconds: pacing.preSpeakDelayNs)
                    guard !Task.isCancelled else { return }
                }

                if let cachedAudio = self?.cachedAudio(forKey: cacheKey) {
                    guard !Task.isCancelled else { return }
                    await self?.acquireTTSLeaseIfNeeded(owner: self?.activeCorrelationID ?? "unknown")
                    self?.playAudio(cachedAudio)
                    return
                }

                if ElevenLabsSettings.useStreaming {
                    // Streaming: download via streaming endpoint, then play
                    let fileURL = try await ElevenLabsClient.streamSynthesizeToFile(ttsText, mode: mode)
                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: fileURL)
                        return
                    }
                    if let data = try? Data(contentsOf: fileURL) {
                        self?.storeAudioInCache(data, forKey: cacheKey)
                    }
                    await self?.acquireTTSLeaseIfNeeded(owner: self?.activeCorrelationID ?? "unknown")
                    self?.playAudioFile(fileURL)
                } else {
                    // Non-streaming: download complete MP3 data, write to temp file, then play
                    let audioData = try await ElevenLabsClient.synthesize(ttsText, mode: mode)
                    guard !Task.isCancelled else { return }
                    self?.storeAudioInCache(audioData, forKey: cacheKey)
                    await self?.acquireTTSLeaseIfNeeded(owner: self?.activeCorrelationID ?? "unknown")
                    self?.playAudio(audioData)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if ElevenLabsSettings.useStreaming {
                    // Fallback: retry with non-streaming
                    print("[TTSService] Streaming failed, falling back: \(error.localizedDescription)")
                    do {
                        let audioData = try await ElevenLabsClient.synthesize(ttsText, mode: mode)
                        guard !Task.isCancelled else { return }
                        self?.storeAudioInCache(audioData, forKey: cacheKey)
                        await self?.acquireTTSLeaseIfNeeded(owner: self?.activeCorrelationID ?? "unknown")
                        self?.playAudio(audioData)
                    } catch {
                        guard !Task.isCancelled else { return }
                        print("[TTSService] Fallback also failed: \(error.localizedDescription)")
                        self?.logSpeechDrop(reason: .ttsEngineError)
                        self?.releaseTTSLease()
                    }
                } else {
                    print("[TTSService] Error: \(error.localizedDescription)")
                    self?.logSpeechDrop(reason: .ttsEngineError)
                    self?.releaseTTSLease()
                }
            }
        }
    }

    /// Immediately stops any current speech playback and clears the queue.
    func stopSpeaking(reason: SpeechDropReason = .explicitCancel) {
        if isSpeaking || !speechQueue.isEmpty {
            logSpeechDrop(reason: reason)
        }
        speechQueue.removeAll()
        speakTask?.cancel()
        speakTask = nil
        player?.stop()
        player = nil
        isSpeaking = false
        releaseTTSLease()
        let correlationID = activeCorrelationID
        Task {
            await AudioCoordinator.shared.clearTTSPending(owner: correlationID)
        }
        cleanupTempFile()
    }

    func stopSpeaking() {
        stopSpeaking(reason: .explicitCancel)
    }

    func clearLastDropReason() {
        lastDropReason = nil
    }

    // MARK: - Private

    private var tempFileURL: URL?

    /// Plays audio from raw audio data (MP3/WAV) by inferring a suitable temp file extension.
    private func playAudio(_ data: Data) {
        let fileExtension = Self.inferredAudioFileExtension(for: data)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("samos_tts_\(UUID().uuidString).\(fileExtension)")
        do {
            try data.write(to: tempURL)
        } catch {
            print("[TTSService] Failed to write temp audio: \(error)")
            return
        }

        playAudioFile(tempURL)
    }

    /// Plays audio from a file URL (used by both streaming and non-streaming).
    private func playAudioFile(_ fileURL: URL) {
        cleanupTempFile()
        tempFileURL = fileURL

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            audioPlayer.delegate = PlaybackDelegate.shared
            PlaybackDelegate.shared.onFinish = { [weak self] in
                Task { @MainActor in
                    self?.cleanupTempFile()
                    self?.drainQueue()
                }
            }
            PlaybackDelegate.shared.onDecodeError = { [weak self] _ in
                Task { @MainActor in
                    self?.logSpeechDrop(reason: .ttsEngineError)
                }
            }
            audioPlayer.prepareToPlay()
            playbackStartAtByCorrelationID[activeCorrelationID] = Date()
            audioPlayer.play()
            player = audioPlayer
            isSpeaking = true
        } catch {
            print("[TTSService] Failed to play audio: \(error)")
            logSpeechDrop(reason: .ttsEngineError)
            releaseTTSLease()
            cleanupTempFile()
            drainQueue()
        }
    }

    private func cleanupTempFile() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    private func makeAudioCacheKey(text: String, mode: SpeechMode) -> String {
        let modeKey: String
        switch mode {
        case .confirm: modeKey = "confirm"
        case .answer: modeKey = "answer"
        }
        return "elevenlabs|\(modeKey)|\(text)"
    }

    static func inferredAudioFileExtension(for data: Data) -> String {
        guard data.count >= 12 else { return "mp3" }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { // "RIFF"
            return "wav"
        }
        if data.starts(with: [0x49, 0x44, 0x33]) { // "ID3"
            return "mp3"
        }
        if data[0] == 0xFF, (data[1] & 0xE0) == 0xE0 { // MPEG frame sync
            return "mp3"
        }
        return "mp3"
    }

    private func cachedAudio(forKey key: String) -> Data? {
        audioCache[key]
    }

    private func storeAudioInCache(_ data: Data, forKey key: String) {
        guard !key.isEmpty, !data.isEmpty else { return }

        if let existingIndex = audioCacheOrder.firstIndex(of: key) {
            audioCacheOrder.remove(at: existingIndex)
        }
        audioCacheOrder.append(key)
        audioCache[key] = data

        while audioCacheOrder.count > maxAudioCacheEntries {
            let evicted = audioCacheOrder.removeFirst()
            audioCache.removeValue(forKey: evicted)
        }
    }

    /// Speaks the next item in the queue, or marks speech as finished.
    private func drainQueue() {
        guard !speechQueue.isEmpty else {
            isSpeaking = false
            releaseTTSLease()
            return
        }
        let next = speechQueue.removeFirst()
        speak(next.text, mode: next.mode, interrupt: false)
    }

    private func acquireTTSLeaseIfNeeded(owner: String) async {
        guard ttsLease == nil else { return }
        let lease = await acquireAudioCoordinatorLeaseWithTimeout(owner: owner, timeoutMs: 1800)
        guard let lease else {
            logSpeechDrop(reason: .audioGateTimeout)
            await AudioCoordinator.shared.clearTTSPending(owner: owner)
            return
        }
        ttsLease = lease
    }

    private func releaseTTSLease() {
        guard let lease = ttsLease else { return }
        ttsLease = nil
        Task {
            await AudioCoordinator.shared.release(lease)
            await AudioCoordinator.shared.clearTTSPending(owner: lease.owner)
        }
    }

    private func acquireAudioCoordinatorLeaseWithTimeout(owner: String, timeoutMs: Int) async -> AudioCoordinator.Lease? {
        await withTaskGroup(of: AudioCoordinator.Lease?.self) { group in
            group.addTask {
                await AudioCoordinator.shared.acquire(for: .tts, owner: owner)
            }
            group.addTask {
                let delayNs = UInt64(max(1, timeoutMs)) * 1_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func logSpeechDrop(reason: SpeechDropReason) {
        lastDropReason = reason
        #if DEBUG
        print("[SPEECH_DROP_REASON] correlation_id=\(activeCorrelationID) reason=\(reason.rawValue)")
        #endif
    }

    var lastDropReasonRawValue: String? {
        lastDropReason?.rawValue
    }

    var currentCorrelationID: String {
        activeCorrelationID
    }

    func timingSnapshot(for correlationID: String) -> TimingSnapshot? {
        guard let enqueueAt = enqueueAtByCorrelationID[correlationID] else { return nil }
        let synthesisStart = synthesisStartAtByCorrelationID[correlationID]
        let playbackStart = playbackStartAtByCorrelationID[correlationID]

        let queueWaitMs: Int?
        if let synthesisStart {
            queueWaitMs = max(0, Int(synthesisStart.timeIntervalSince(enqueueAt) * 1000))
        } else {
            queueWaitMs = nil
        }

        let synthesisMs: Int?
        if let synthesisStart, let playbackStart {
            synthesisMs = max(0, Int(playbackStart.timeIntervalSince(synthesisStart) * 1000))
        } else {
            synthesisMs = nil
        }

        let playbackStartMs: Int?
        if let playbackStart {
            playbackStartMs = max(0, Int(playbackStart.timeIntervalSince(enqueueAt) * 1000))
        } else {
            playbackStartMs = nil
        }

        return TimingSnapshot(queueWaitMs: queueWaitMs, synthesisMs: synthesisMs, playbackStartMs: playbackStartMs)
    }
}

// MARK: - Playback Delegate

/// Bridges AVAudioPlayerDelegate to the @MainActor TTSService.
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    static let shared = PlaybackDelegate()
    var onFinish: (() -> Void)?
    var onDecodeError: ((Error?) -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("[TTSService] Decode error: \(error?.localizedDescription ?? "unknown")")
        onDecodeError?(error)
        onFinish?()
    }
}
