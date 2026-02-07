import Foundation

/// HTTP client for the ElevenLabs Text-to-Speech API.
/// Returns raw audio data (mp3) for playback.
enum ElevenLabsClient {

    enum TTSError: Error, LocalizedError {
        case notConfigured
        case requestFailed(String)
        case badResponse(Int)
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "ElevenLabs API key not configured"
            case .requestFailed(let msg): return "TTS request failed: \(msg)"
            case .badResponse(let code): return "ElevenLabs returned HTTP \(code)"
            case .emptyAudio: return "ElevenLabs returned empty audio"
            }
        }
    }

    /// Synthesizes speech from text and returns MP3 audio data.
    /// - Parameters:
    ///   - text: The text to speak.
    ///   - mode: Controls voice_settings (confirm = snappier, answer = normal).
    static func synthesize(_ text: String, mode: SpeechMode = .answer) async throws -> Data {
        let apiKey = ElevenLabsSettings.apiKey
        let voiceId = ElevenLabsSettings.voiceId
        let modelId = ElevenLabsSettings.modelId

        guard !apiKey.isEmpty, !voiceId.isEmpty else {
            throw TTSError.notConfigured
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)") else {
            throw TTSError.requestFailed("Invalid URL")
        }

        let body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": mode.voiceSettings,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TTSError.requestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TTSError.requestFailed("Not an HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data.prefix(200), encoding: .utf8) ?? ""
            print("[ElevenLabsClient] HTTP \(http.statusCode): \(errorBody)")
            throw TTSError.badResponse(http.statusCode)
        }

        guard !data.isEmpty else {
            throw TTSError.emptyAudio
        }

        return data
    }

    // MARK: - Streaming

    /// Streams TTS audio to a temp file via ElevenLabs streaming endpoint.
    /// Returns the file URL as soon as enough data is written to start playback.
    /// - Parameters:
    ///   - text: The text to speak.
    ///   - mode: Controls voice_settings.
    /// - Returns: URL to the MP3 file being streamed into.
    static func streamSynthesizeToFile(_ text: String, mode: SpeechMode = .answer) async throws -> URL {
        let apiKey = ElevenLabsSettings.apiKey
        let voiceId = ElevenLabsSettings.voiceId
        let modelId = ElevenLabsSettings.modelId

        guard !apiKey.isEmpty, !voiceId.isEmpty else {
            throw TTSError.notConfigured
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream") else {
            throw TTSError.requestFailed("Invalid streaming URL")
        }

        let body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": mode.voiceSettings,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TTSError.requestFailed("Not an HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            print("[ElevenLabsClient] Streaming HTTP \(http.statusCode)")
            throw TTSError.badResponse(http.statusCode)
        }

        // Buffer all streamed chunks into Data, then write once
        var audioData = Data()
        audioData.reserveCapacity(64 * 1024) // 64KB typical for short speech
        for try await byte in bytes {
            audioData.append(byte)
        }

        guard !audioData.isEmpty else {
            throw TTSError.emptyAudio
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("samos_tts_stream_\(UUID().uuidString).mp3")
        try audioData.write(to: tempURL)

        return tempURL
    }
}
