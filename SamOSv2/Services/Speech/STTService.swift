import Foundation

/// OpenAI Whisper API speech-to-text service.
final class STTService: STTServiceProtocol, @unchecked Sendable {
    private let settings: any SettingsStoreProtocol

    init(settings: any SettingsStoreProtocol) {
        self.settings = settings
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let apiKey = settings.string(forKey: SettingsKey.openaiAPIKey), !apiKey.isEmpty else {
            throw STTError.apiKeyMissing
        }

        let audioData = try Data(contentsOf: audioURL)
        let boundary = UUID().uuidString

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()

        // Model field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("whisper-1\r\n")

        // Audio file
        let filename = audioURL.lastPathComponent
        let mimeType = filename.hasSuffix(".wav") ? "audio/wav" : "audio/mpeg"
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")

        // Close boundary
        body.append("--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.transcriptionFailed("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw STTError.transcriptionFailed("HTTP \(httpResponse.statusCode): \(errorText.prefix(200))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw STTError.transcriptionFailed("Could not parse response")
        }

        return text
    }
}

enum STTError: Error, LocalizedError {
    case apiKeyMissing
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing: return "OpenAI API key not configured for STT"
        case .transcriptionFailed(let detail): return "Transcription failed: \(detail)"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
