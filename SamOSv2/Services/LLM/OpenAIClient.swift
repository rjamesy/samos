import Foundation

/// HTTP client for OpenAI Chat Completions API with streaming and native function calling.
final class OpenAIClient: LLMClient, @unchecked Sendable {
    private let settings: any SettingsStoreProtocol
    private let session: URLSession

    init(settings: any SettingsStoreProtocol, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    // MARK: - Blocking Completion

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard let apiKey = settings.string(forKey: SettingsKey.openaiAPIKey), !apiKey.isEmpty else {
            throw LLMError.apiKeyMissing
        }

        let model = request.model ?? settings.string(forKey: SettingsKey.openaiModel) ?? AppConfig.defaultModel
        let start = Date()

        var body = buildBody(request, model: model, stream: false)

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let hasImages = bodyHasImages(body)

        var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = jsonData
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = hasImages ? 45 : AppConfig.llmTimeoutSeconds

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("Not an HTTP response")
        }

        if httpResponse.statusCode == 429 {
            throw LLMError.rateLimited
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.invalidResponse("HTTP \(httpResponse.statusCode): \(body.prefix(200))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMError.invalidResponse("Cannot parse response JSON")
        }

        let content = message["content"] as? String ?? ""
        let usage = json["usage"] as? [String: Any]
        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

        // Parse native tool_calls if present
        var toolCalls: [ToolCall]?
        if let rawToolCalls = message["tool_calls"] as? [[String: Any]] {
            toolCalls = rawToolCalls.compactMap { tc -> ToolCall? in
                guard let id = tc["id"] as? String,
                      let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String else { return nil }
                let argsStr = function["arguments"] as? String ?? "{}"
                let args = parseToolArguments(argsStr)
                return ToolCall(id: id, name: name, arguments: args)
            }
        }

        return LLMResponse(
            text: content,
            model: model,
            latencyMs: latencyMs,
            promptTokens: usage?["prompt_tokens"] as? Int,
            completionTokens: usage?["completion_tokens"] as? Int,
            toolCalls: toolCalls
        )
    }

    // MARK: - SSE Streaming

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let apiKey = settings.string(forKey: SettingsKey.openaiAPIKey), !apiKey.isEmpty else {
                        continuation.finish(throwing: LLMError.apiKeyMissing)
                        return
                    }

                    let model = request.model ?? settings.string(forKey: SettingsKey.openaiModel) ?? AppConfig.defaultModel
                    let body = buildBody(request, model: model, stream: true)
                    let jsonData = try JSONSerialization.data(withJSONObject: body)

                    var urlRequest = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
                    urlRequest.httpMethod = "POST"
                    urlRequest.httpBody = jsonData
                    urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.timeoutInterval = AppConfig.llmTimeoutSeconds

                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        continuation.finish(throwing: LLMError.invalidResponse("HTTP \(statusCode)"))
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else {
                            continue
                        }

                        continuation.yield(content)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Shared Helpers

    private func buildBody(_ request: LLMRequest, model: String, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_completion_tokens": request.maxTokens ?? AppConfig.maxCompletionTokens,
        ]

        if stream {
            body["stream"] = true
        }

        if let temp = request.temperature {
            body["temperature"] = temp
        } else {
            body["temperature"] = AppConfig.defaultTemperature
        }

        // Response format
        if let format = request.responseFormat {
            switch format {
            case .jsonObject:
                body["response_format"] = ["type": "json_object"]
            case .jsonSchema(let name, let schema):
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": [
                        "name": name,
                        "schema": schema
                    ]
                ] as [String: Any]
            case .text:
                break
            }
        }

        // Messages
        var messages: [[String: Any]] = []
        if let system = request.system {
            messages.append(["role": "system", "content": system])
        }
        for msg in request.messages {
            switch msg.content {
            case .text(let s):
                messages.append(["role": msg.role, "content": s])
            case .multipart(let parts):
                var contentArray: [[String: Any]] = []
                for part in parts {
                    switch part {
                    case .text(let t):
                        contentArray.append(["type": "text", "text": t])
                    case .imageURL(let url):
                        contentArray.append(["type": "image_url", "image_url": ["url": url]])
                    }
                }
                messages.append(["role": msg.role, "content": contentArray])
            }
        }
        body["messages"] = messages

        // Native function calling (Phase 5)
        if let tools = request.tools, !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters.isEmpty ? [
                            "type": "object",
                            "properties": [:] as [String: Any]
                        ] as [String: Any] : tool.parameters
                    ] as [String: Any]
                ] as [String: Any]
            }

            if let toolChoice = request.toolChoice {
                body["tool_choice"] = toolChoice
            }
        }

        return body
    }

    private func bodyHasImages(_ body: [String: Any]) -> Bool {
        guard let messages = body["messages"] as? [[String: Any]] else { return false }
        return messages.contains { msg in
            if let content = msg["content"] as? [[String: Any]] {
                return content.contains { $0["type"] as? String == "image_url" }
            }
            return false
        }
    }

    private func parseToolArguments(_ argsString: String) -> [String: String] {
        guard let data = argsString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in json {
            result[key] = "\(value)"
        }
        return result
    }
}
