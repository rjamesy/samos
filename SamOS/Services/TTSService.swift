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

    private init() {}

    /// Speaks the given text using ElevenLabs TTS.
    /// - Parameters:
    ///   - text: Text to speak.
    ///   - mode: Controls prosody (confirm = snappier, answer = normal).
    ///   - interrupt: If true (default), stops any current speech first.
    func speak(_ text: String, mode: SpeechMode = .answer, interrupt: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Respect mute and empty text
        guard !ElevenLabsSettings.isMuted, !trimmed.isEmpty else { return }
        guard ElevenLabsSettings.isConfigured else {
            print("[TTSService] Not configured — skipping speech")
            return
        }

        if interrupt {
            stopSpeaking()
        }

        speakTask = Task { [weak self] in
            do {
                if ElevenLabsSettings.useStreaming {
                    // Streaming: download via streaming endpoint, then play
                    let fileURL = try await ElevenLabsClient.streamSynthesizeToFile(trimmed, mode: mode)
                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: fileURL)
                        return
                    }
                    await self?.playAudioFile(fileURL)
                } else {
                    // Non-streaming: download complete MP3 data, write to temp file, then play
                    let audioData = try await ElevenLabsClient.synthesize(trimmed, mode: mode)
                    guard !Task.isCancelled else { return }
                    await self?.playAudio(audioData)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if ElevenLabsSettings.useStreaming {
                    // Fallback: retry with non-streaming
                    print("[TTSService] Streaming failed, falling back: \(error.localizedDescription)")
                    do {
                        let audioData = try await ElevenLabsClient.synthesize(trimmed, mode: mode)
                        guard !Task.isCancelled else { return }
                        await self?.playAudio(audioData)
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

    /// Immediately stops any current speech playback.
    func stopSpeaking() {
        speakTask?.cancel()
        speakTask = nil
        player?.stop()
        player = nil
        isSpeaking = false
        cleanupTempFile()
    }

    // MARK: - Private

    private var tempFileURL: URL?

    /// Plays audio from raw MP3 data (non-streaming path).
    private func playAudio(_ data: Data) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("samos_tts_\(UUID().uuidString).mp3")
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
                    self?.isSpeaking = false
                    self?.cleanupTempFile()
                }
            }
            audioPlayer.prepareToPlay()
            audioPlayer.play()
            player = audioPlayer
            isSpeaking = true
        } catch {
            print("[TTSService] Failed to play audio: \(error)")
            cleanupTempFile()
        }
    }

    private func cleanupTempFile() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
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
