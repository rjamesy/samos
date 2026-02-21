import Foundation

/// Limits concurrent intelligence engine API calls to avoid rate-limiting and resource contention.
actor EngineScheduler {
    static let shared = EngineScheduler()

    private let maxConcurrent = 3
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        running -= 1
        if !waiters.isEmpty {
            running += 1
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    /// Run a block with concurrency limiting.
    func run<T>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { Task { await release() } }
        return try await work()
    }
}

/// Lightweight LLM client shared by all intelligence engines.
/// Ollama for fast/cheap operations, GPT-5.2 for deep reasoning.
enum IntelligenceLLMClient {

    enum LLMError: Error {
        case unavailable
        case requestFailed(String)
        case invalidResponse
    }

    // MARK: - Ollama (fast, local)

    static func ollamaJSON(systemPrompt: String,
                           userPrompt: String,
                           maxTokens: Int = 512) async throws -> String {
        guard M2Settings.useOllama else { throw LLMError.unavailable }
        let transport = RealOllamaTransport()
        return try await transport.chat(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            model: M2Settings.ollamaModel,
            maxOutputTokens: maxTokens
        )
    }

    // MARK: - GPT-5.2 (deep reasoning)

    static func openAIJSON(systemPrompt: String,
                           userPrompt: String,
                           maxTokens: Int = 1200,
                           temperature: Double = 0.0) async throws -> String {
        guard OpenAISettings.apiKeyStatus == .ready else {
            throw LLMError.unavailable
        }
        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        let model = OpenAISettings.generalModel.isEmpty
            ? OpenAISettings.defaultPreferredModel
            : OpenAISettings.generalModel
        let tokenKey = RealOpenAITransport.completionTokenParameter(for: model)

        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": temperature,
            "response_format": ["type": "json_object"]
        ]
        payload[tokenKey] = maxTokens

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.requestFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }
        return content
    }

    // MARK: - Engine (gpt-4.1-mini for background intelligence engines)

    static func engineJSON(systemPrompt: String,
                           userPrompt: String,
                           maxTokens: Int = 600) async throws -> String {
        guard OpenAISettings.apiKeyStatus == .ready else {
            throw LLMError.unavailable
        }
        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        let model = "gpt-4.1-mini"

        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.0,
            "response_format": ["type": "json_object"]
        ]
        payload["max_output_tokens"] = maxTokens

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LLMError.requestFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse
        }
        return content
    }

    // MARK: - Hybrid (Ollama fast → GPT fallback)

    static func hybridJSON(systemPrompt: String,
                           userPrompt: String,
                           ollamaMaxTokens: Int = 512,
                           openAIMaxTokens: Int = 1200) async throws -> String {
        if M2Settings.useOllama {
            do {
                return try await ollamaJSON(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    maxTokens: ollamaMaxTokens
                )
            } catch {
                // Fall through to GPT
            }
        }
        return try await openAIJSON(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: openAIMaxTokens
        )
    }

    // MARK: - Parse JSON

    static func parseJSON(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func parseJSONArray(_ raw: String) -> [[String: Any]]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return arr
    }
}
