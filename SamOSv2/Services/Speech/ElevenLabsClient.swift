import Foundation
import AVFoundation

/// HTTP client for ElevenLabs text-to-speech API.
final class ElevenLabsClient: @unchecked Sendable {
    private let settings: any SettingsStoreProtocol
    private let session: URLSession

    init(settings: any SettingsStoreProtocol, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    /// Synthesize speech from text and return audio data.
    func synthesize(text: String) async throws -> Data {
        guard let apiKey = settings.string(forKey: SettingsKey.elevenlabsAPIKey), !apiKey.isEmpty else {
            throw TTSError.apiKeyMissing
        }

        let voiceId = settings.string(forKey: SettingsKey.elevenlabsVoiceID) ?? ""
        let modelId = settings.string(forKey: SettingsKey.elevenlabsModelID) ?? AppConfig.defaultTTSModel

        guard !voiceId.isEmpty else {
            throw TTSError.synthesisError("Voice ID not configured")
        }

        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw TTSError.synthesisError("HTTP \(statusCode)")
        }

        return data
    }

    /// Synthesize and save to a temporary file, returning the URL.
    func synthesizeToFile(text: String) async throws -> URL {
        let data = try await synthesize(text: text)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try data.write(to: tempURL)
        return tempURL
    }
}
