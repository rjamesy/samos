import Foundation
import AVFoundation

/// Queue-based TTS playback with LRU audio cache.
/// Falls back from ElevenLabs → OpenAI TTS when ElevenLabs key is missing.
@MainActor
final class TTSService: NSObject, TTSServiceProtocol, AVAudioPlayerDelegate {
    private let client: ElevenLabsClient
    private let openAIClient: OpenAITTSClient
    private let settings: any SettingsStoreProtocol

    private var player: AVAudioPlayer?
    private var queue: [(text: String, mode: TTSMode)] = []
    private var isProcessing = false
    private var cache: [String: URL] = [:] // text -> audio file URL
    private var cacheOrder: [String] = []

    private(set) var isSpeaking = false

    // Streaming TTS state
    private var streamingQueue: [URL] = []
    private var isStreamPlaying = false

    nonisolated init(client: ElevenLabsClient, openAIClient: OpenAITTSClient, settings: any SettingsStoreProtocol) {
        self.client = client
        self.openAIClient = openAIClient
        self.settings = settings
        super.init()
    }

    func speak(text: String, mode: TTSMode) async {
        guard !settings.bool(forKey: SettingsKey.elevenlabsMuted) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        switch mode {
        case .interrupt:
            stop()
            queue.removeAll()
            queue.append((text, mode))
        case .queue:
            queue.append((text, mode))
        case .normal:
            queue.append((text, mode))
        }

        if !isProcessing {
            await processQueue()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isSpeaking = false
        isProcessing = false
        streamingQueue.removeAll()
        isStreamPlaying = false
    }

    // MARK: - Streaming TTS (Phase 4)

    /// Speak from a streaming LLM source — accumulates tokens, synthesizes per sentence.
    func speakStreaming(llmStream: AsyncThrowingStream<String, Error>) async {
        guard !settings.bool(forKey: SettingsKey.elevenlabsMuted) else { return }

        var buffer = ""
        let sentenceEnders: Set<Character> = [".", "!", "?", "\n"]

        do {
            for try await token in llmStream {
                buffer += token

                // Check if we have a complete sentence
                if let lastChar = buffer.last, sentenceEnders.contains(lastChar) {
                    let sentence = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer = ""

                    if !sentence.isEmpty {
                        // Synthesize and queue for playback
                        if let url = await synthesizeWithFallback(sentence) {
                            streamingQueue.append(url)
                            if !isStreamPlaying {
                                await playStreamQueue()
                            }
                        }
                    }
                }
            }

            // Flush remaining buffer
            let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                if let url = await synthesizeWithFallback(remaining) {
                    streamingQueue.append(url)
                    if !isStreamPlaying {
                        await playStreamQueue()
                    }
                }
            }
        } catch {
            print("[TTS] Streaming error: \(error.localizedDescription)")
        }
    }

    private func playStreamQueue() async {
        isStreamPlaying = true
        isSpeaking = true

        while !streamingQueue.isEmpty {
            let url = streamingQueue.removeFirst()
            await playAudioFile(url)
        }

        isStreamPlaying = false
        isSpeaking = false
    }

    // MARK: - Queue Processing

    private func processQueue() async {
        guard !isProcessing else { return }
        isProcessing = true

        while !queue.isEmpty {
            let item = queue.removeFirst()
            await playText(item.text)
        }

        isProcessing = false
    }

    private func playText(_ text: String) async {
        // Check cache
        if let cachedURL = cache[text] {
            await playAudioFile(cachedURL)
            return
        }

        // Synthesize with fallback
        if let url = await synthesizeWithFallback(text) {
            addToCache(text: text, url: url)
            await playAudioFile(url)
        }
    }

    /// Try ElevenLabs first, fall back to OpenAI TTS.
    private func synthesizeWithFallback(_ text: String) async -> URL? {
        // Try ElevenLabs
        do {
            let url = try await client.synthesizeToFile(text: text)
            return url
        } catch {
            let isKeyMissing: Bool
            if case TTSError.apiKeyMissing = error {
                isKeyMissing = true
            } else {
                isKeyMissing = error.localizedDescription.contains("API key")
            }
            if isKeyMissing {
                print("[TTS] ElevenLabs key missing, falling back to OpenAI TTS")
            } else {
                print("[TTS] ElevenLabs error: \(error.localizedDescription), trying OpenAI TTS")
            }
        }

        // Fallback to OpenAI TTS
        do {
            let url = try await openAIClient.synthesizeToFile(text: text)
            return url
        } catch {
            print("[TTS] OpenAI TTS also failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func playAudioFile(_ url: URL) async {
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            player = p
            isSpeaking = true
            p.play()

            // Wait for playback to finish
            while p.isPlaying {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            isSpeaking = false
        } catch {
            print("[TTS] Playback error: \(error.localizedDescription)")
            isSpeaking = false
        }
    }

    // MARK: - LRU Cache

    private func addToCache(text: String, url: URL) {
        if cache.count >= AppConfig.ttsCacheSize {
            if let oldest = cacheOrder.first {
                cacheOrder.removeFirst()
                if let oldURL = cache.removeValue(forKey: oldest) {
                    try? FileManager.default.removeItem(at: oldURL)
                }
            }
        }
        cache[text] = url
        cacheOrder.append(text)
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}
