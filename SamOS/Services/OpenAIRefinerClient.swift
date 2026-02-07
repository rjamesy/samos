import Foundation

/// HTTP client for OpenAI chat completions, used by SkillForge to refine skill specs.
final class OpenAIRefinerClient {

    enum RefinerError: Error, LocalizedError {
        case notConfigured
        case requestFailed(String)
        case badResponse(Int)
        case parseFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OpenAI API key not configured"
            case .requestFailed(let msg): return "OpenAI request failed: \(msg)"
            case .badResponse(let code): return "OpenAI returned HTTP \(code)"
            case .parseFailed(let msg): return "Failed to parse skill spec: \(msg)"
            }
        }
    }

    /// Asks OpenAI to refine a draft skill spec into valid JSON.
    func refineSkillSpec(goal: String, draft: SkillSpec, toolList: [String]) async throws -> SkillSpec {
        guard OpenAISettings.isConfigured else { throw RefinerError.notConfigured }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let draftJSON = (try? encoder.encode(draft)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let tools = toolList.joined(separator: ", ")

        let systemMessage = """
        You are a skill specification generator for SamOS, a macOS voice assistant.
        Your job is to refine a draft skill spec into a valid, complete SkillSpec JSON.

        Available tools that can be used in steps: \(tools)

        The spec must include: id, name, version, triggerPhrases, slots, steps, and optionally onTrigger.
        Slot types: "date", "string", "number".
        Step actions: tool names (e.g. "schedule_task", "show_text") or "talk".
        Step args support {{slotName}} interpolation.

        Return ONLY the JSON object. No explanation, no markdown, no code fences.
        """

        let userMessage = """
        Goal: \(goal)

        Draft spec:
        \(draftJSON)

        Please refine this into a complete, valid skill spec.
        """

        let requestBody: [String: Any] = [
            "model": OpenAISettings.model,
            "messages": [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.3
        ]

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw RefinerError.requestFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw RefinerError.requestFailed("Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw RefinerError.badResponse(http.statusCode)
        }

        // Parse OpenAI response envelope
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw RefinerError.parseFailed("Could not extract content from OpenAI response")
        }

        // Extract JSON from content
        let jsonString = extractJSON(from: content)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw RefinerError.parseFailed("Invalid UTF-8 in response")
        }

        do {
            return try JSONDecoder().decode(SkillSpec.self, from: jsonData)
        } catch {
            throw RefinerError.parseFailed(error.localizedDescription)
        }
    }

    private func extractJSON(from text: String) -> String {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}")
        else { return text }
        return String(text[start...end])
    }
}
