import Foundation

/// Escalates complex visual queries to GPT-4 Vision for analysis.
final class GPTVisionClient: @unchecked Sendable {
    private let settings: SettingsStoreProtocol

    init(settings: SettingsStoreProtocol) {
        self.settings = settings
    }

    /// Analyze an image with GPT Vision.
    func analyze(imageBase64: String, prompt: String) async throws -> String {
        let apiKey = settings.string(forKey: SettingsKey.openaiAPIKey) ?? ""
        guard !apiKey.isEmpty else {
            throw LLMError.apiKeyMissing
        }

        let model = settings.string(forKey: SettingsKey.openaiModel) ?? "gpt-4o"
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_completion_tokens": 500,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": prompt
                        ],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(imageBase64)"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.invalidResponse("HTTP \(httpResponse.statusCode): \(errorText)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse("Could not parse GPT Vision response")
        }

        return content
    }
}
