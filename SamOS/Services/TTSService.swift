import AVFoundation

/// Text-to-speech service using ElevenLabs.
/// Safe to call from @MainActor; network and audio work runs off-main.
@MainActor
final class TTSService {

    static let shared = TTSService()

    /// Whether audio is currently playing.
    @Published private(set) var isSpeaking = false

    private var player: AVAudioPlayer?
    private var speakTask: Task<Void, Never>?
    private var speechQueue: [(text: String, mode: SpeechMode)] = []
    private var audioCache: [String: Data] = [:]
    private var audioCacheOrder: [String] = []
    private let maxAudioCacheEntries = 40

    private init() {}

    /// Enqueues multiple lines for sequential playback.
    /// Cancels any in-progress speech first, then plays each line in order.
    func enqueue(_ lines: [String], mode: SpeechMode = .answer) {
        guard !lines.isEmpty else { return }
        stopSpeaking()
        speechQueue = lines.map { (text: $0, mode: mode) }
        drainQueue()
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
            return
        }

        if interrupt {
            stopSpeaking()
        }

        speakTask = Task { [weak self] in
            do {
                if pacing.preSpeakDelayNs > 0 {
                    try await Task.sleep(nanoseconds: pacing.preSpeakDelayNs)
                    guard !Task.isCancelled else { return }
                }

                if let cachedAudio = self?.cachedAudio(forKey: cacheKey) {
                    guard !Task.isCancelled else { return }
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
                    self?.playAudioFile(fileURL)
                } else {
                    // Non-streaming: download complete MP3 data, write to temp file, then play
                    let audioData = try await ElevenLabsClient.synthesize(ttsText, mode: mode)
                    guard !Task.isCancelled else { return }
                    self?.storeAudioInCache(audioData, forKey: cacheKey)
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
                        self?.playAudio(audioData)
                    } catch {
                        guard !Task.isCancelled else { return }
                        print("[TTSService] Fallback also failed: \(error.localizedDescription)")
                    }
                } else {
                    print("[TTSService] Error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Immediately stops any current speech playback and clears the queue.
    func stopSpeaking() {
        speechQueue.removeAll()
        speakTask?.cancel()
        speakTask = nil
        player?.stop()
        player = nil
        isSpeaking = false
        cleanupTempFile()
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
            audioPlayer.prepareToPlay()
            audioPlayer.play()
            player = audioPlayer
            isSpeaking = true
        } catch {
            print("[TTSService] Failed to play audio: \(error)")
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
            return
        }
        let next = speechQueue.removeFirst()
        speak(next.text, mode: next.mode, interrupt: false)
    }
}

// MARK: - Playback Delegate

/// Bridges AVAudioPlayerDelegate to the @MainActor TTSService.
private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    static let shared = PlaybackDelegate()
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("[TTSService] Decode error: \(error?.localizedDescription ?? "unknown")")
        onFinish?()
    }
}
