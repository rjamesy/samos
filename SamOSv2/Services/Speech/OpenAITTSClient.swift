import Foundation

/// OpenAI text-to-speech API client. Fallback when ElevenLabs is not configured.
final class OpenAITTSClient: @unchecked Sendable {
    private let settings: any SettingsStoreProtocol

    init(settings: any SettingsStoreProtocol) {
        self.settings = settings
    }

    /// Synthesize speech and return raw MP3 data.
    func synthesize(text: String, voice: String = "nova") async throws -> Data {
        guard let apiKey = settings.string(forKey: SettingsKey.openaiAPIKey), !apiKey.isEmpty else {
            throw TTSError.apiKeyMissing
        }

        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "tts-1",
            "input": text,
            "voice": voice,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TTSError.synthesisError("OpenAI TTS HTTP \(statusCode)")
        }

        return data
    }

    /// Synthesize and save to a temporary file, returning the URL.
    func synthesizeToFile(text: String, voice: String = "nova") async throws -> URL {
        let data = try await synthesize(text: text, voice: voice)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try data.write(to: tempURL)
        return tempURL
    }
}
