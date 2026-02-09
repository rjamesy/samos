import Foundation

// MARK: - OpenAI Transport Protocol

final class OpenAIAPILogStore {
    static let shared = OpenAIAPILogStore()

    private struct LogEvent: Encodable {
        let sessionID: String
        let loggedAt: Date
        let phase: String
        let requestID: String
        let service: String
        let endpoint: String?
        let method: String?
        let model: String?
        let statusCode: Int?
        let latencyMs: Int?
        let error: String?
        let payload: String?
    }

    private let queue = DispatchQueue(label: "com.samos.openai.api.log")
    private let encoder: JSONEncoder
    private let sessionID = UUID().uuidString
    private let logFileURL: URL?

    private init() {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        self.encoder = jsonEncoder

        do {
            let fileManager = FileManager.default
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let logsDir = appSupport
                .appendingPathComponent("SamOS", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
            try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let fileURL = logsDir.appendingPathComponent("openai_api_events.jsonl", isDirectory: false)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            self.logFileURL = fileURL
            #if DEBUG
            print("[OpenAIAPILogStore] path=\(fileURL.path)")
            #endif
        } catch {
            #if DEBUG
            print("[OpenAIAPILogStore] init failed: \(error.localizedDescription)")
            #endif
            self.logFileURL = nil
        }
    }

    var logPath: String? {
        logFileURL?.path
    }

    @discardableResult
    func logHTTPRequest(service: String,
                        endpoint: String,
                        method: String,
                        model: String?,
                        timeoutSeconds: TimeInterval,
                        payload: Any?) -> String {
        let requestID = UUID().uuidString
        let payloadEnvelope: [String: Any] = [
            "timeout_seconds": timeoutSeconds,
            "request": payload ?? [:]
        ]
        log(
            phase: "request",
            requestID: requestID,
            service: service,
            endpoint: endpoint,
            method: method,
            model: model,
            statusCode: nil,
            latencyMs: nil,
            error: nil,
            payload: payloadEnvelope
        )
        return requestID
    }

    func logHTTPResponse(requestID: String,
                         service: String,
                         endpoint: String,
                         method: String,
                         model: String?,
                         statusCode: Int,
                         latencyMs: Int,
                         responseData: Data?) {
        log(
            phase: "response",
            requestID: requestID,
            service: service,
            endpoint: endpoint,
            method: method,
            model: model,
            statusCode: statusCode,
            latencyMs: latencyMs,
            error: nil,
            payload: parsedPayload(from: responseData)
        )
    }

    func logHTTPError(requestID: String,
                      service: String,
                      endpoint: String,
                      method: String,
                      model: String?,
                      statusCode: Int?,
                      latencyMs: Int?,
                      error: String,
                      responseData: Data?) {
        log(
            phase: "error",
            requestID: requestID,
            service: service,
            endpoint: endpoint,
            method: method,
            model: model,
            statusCode: statusCode,
            latencyMs: latencyMs,
            error: error,
            payload: parsedPayload(from: responseData)
        )
    }

    func logRealtimeEvent(requestID: String,
                          service: String,
                          direction: String,
                          payload: [String: Any]) {
        log(
            phase: direction,
            requestID: requestID,
            service: service,
            endpoint: "wss://api.openai.com/v1/realtime",
            method: "WS",
            model: OpenAISettings.realtimeModel,
            statusCode: nil,
            latencyMs: nil,
            error: nil,
            payload: payload
        )
    }

    func logRealtimeSummary(requestID: String,
                            service: String,
                            latencyMs: Int,
                            note: String) {
        log(
            phase: "summary",
            requestID: requestID,
            service: service,
            endpoint: "wss://api.openai.com/v1/realtime",
            method: "WS",
            model: OpenAISettings.realtimeModel,
            statusCode: nil,
            latencyMs: latencyMs,
            error: nil,
            payload: ["note": note]
        )
    }

    @discardableResult
    func logBlockedRequest(service: String,
                           endpoint: String?,
                           method: String?,
                           model: String?,
                           reason: String,
                           payload: Any? = nil) -> String {
        let requestID = UUID().uuidString
        log(
            phase: "blocked",
            requestID: requestID,
            service: service,
            endpoint: endpoint,
            method: method,
            model: model,
            statusCode: nil,
            latencyMs: 0,
            error: reason,
            payload: payload
        )
        return requestID
    }

    private func log(phase: String,
                     requestID: String,
                     service: String,
                     endpoint: String?,
                     method: String?,
                     model: String?,
                     statusCode: Int?,
                     latencyMs: Int?,
                     error: String?,
                     payload: Any?) {
        guard let logFileURL else { return }

        let payloadString: String?
        if let payload {
            let sanitized = sanitize(payload)
            payloadString = stringifyJSON(sanitized)
        } else {
            payloadString = nil
        }

        let event = LogEvent(
            sessionID: sessionID,
            loggedAt: Date(),
            phase: phase,
            requestID: requestID,
            service: service,
            endpoint: endpoint,
            method: method,
            model: model,
            statusCode: statusCode,
            latencyMs: latencyMs,
            error: error,
            payload: payloadString
        )

        queue.async { [encoder] in
            guard let encoded = try? encoder.encode(event) else { return }
            var line = encoded
            line.append(0x0A)
            self.appendLine(line, to: logFileURL)
        }
    }

    private func parsedPayload(from data: Data?) -> Any? {
        guard let data else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        if let text = String(data: data, encoding: .utf8) {
            return truncate(text)
        }
        return "binary_data_bytes=\(data.count)"
    }

    private func sanitize(_ value: Any, keyHint: String? = nil) -> Any {
        if let dict = value as? [String: Any] {
            var sanitized: [String: Any] = [:]
            for (key, nested) in dict {
                let keyLower = key.lowercased()
                if Self.redactedKeys.contains(keyLower) {
                    sanitized[key] = "[REDACTED]"
                    continue
                }
                sanitized[key] = sanitize(nested, keyHint: key)
            }
            return sanitized
        }

        if let array = value as? [Any] {
            return array.map { sanitize($0, keyHint: keyHint) }
        }

        if let string = value as? String {
            let keyLower = keyHint?.lowercased() ?? ""
            if (keyLower == "audio" || keyLower == "delta"), string.count > 96 {
                return "base64(len=\(string.count), preview=\(String(string.prefix(64)))...)"
            }
            return truncate(string)
        }

        return value
    }

    private func stringifyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text
    }

    private func truncate(_ value: String, maxChars: Int = 16_000) -> String {
        guard value.count > maxChars else { return value }
        let keep = max(0, maxChars - 64)
        let prefix = String(value.prefix(keep))
        return "\(prefix)\n...[truncated \(value.count - keep) chars]"
    }

    private func appendLine(_ line: Data, to url: URL) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try? line.write(to: url, options: .atomic)
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(line)
        } catch {
            #if DEBUG
            print("[OpenAIAPILogStore] append failed: \(error.localizedDescription)")
            #endif
        }
    }

    private static let redactedKeys: Set<String> = [
        "authorization", "api_key", "apikey", "x-api-key", "token", "xi-api-key"
    ]
}

/// Abstraction over the OpenAI HTTP API so tests can inject a fake.
protocol OpenAITransport {
    func chat(messages: [[String: String]], model: String) async throws -> String
}

/// Real transport that hits the OpenAI /v1/chat/completions endpoint.
struct RealOpenAITransport: OpenAITransport {

    private static var didLogStartup = false

    /// JSON Schema for structured outputs — constrains action enum + step types.
    /// strict: false because args is free-form and not all fields appear on every action.
    private static let responseFormat: [String: Any] = {
        let stepSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "step": ["type": "string", "enum": ["talk", "tool", "ask", "delegate"]] as [String: Any],
                "say": ["type": "string"],
                "name": ["type": "string"],
                "args": ["type": "object"],
                "slot": ["type": "string"],
                "prompt": ["type": "string"],
                "task": ["type": "string"],
                "context": ["type": "string"]
            ] as [String: Any],
            "required": ["step"]
        ]

        return [
            "type": "json_schema",
            "json_schema": [
                "name": "sam_action",
                "strict": false,
                "schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["TALK", "TOOL", "PLAN", "DELEGATE_OPENAI", "CAPABILITY_GAP"]] as [String: Any],
                        "say": ["type": "string"],
                        "name": ["type": "string"],
                        "args": ["type": "object"],
                        "steps": ["type": "array", "items": stepSchema] as [String: Any],
                        "goal": ["type": "string"],
                        "missing": ["type": "string"],
                        "task": ["type": "string"],
                        "context": ["type": "string"]
                    ] as [String: Any],
                    "required": ["action"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }()

    func chat(messages: [[String: String]], model: String) async throws -> String {
        guard OpenAISettings.isConfigured else {
            OpenAIAPILogStore.shared.logBlockedRequest(
                service: "OpenAIRouter.chat",
                endpoint: "https://api.openai.com/v1/chat/completions",
                method: "POST",
                model: model,
                reason: "OpenAI API key not configured",
                payload: ["message_count": messages.count]
            )
            throw OpenAIRouter.OpenAIError.notConfigured
        }

        #if DEBUG
        if !Self.didLogStartup {
            Self.didLogStartup = true
            print("[OpenAI] model=\(model)")
        }
        #endif

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw OpenAIRouter.OpenAIError.requestFailed("Invalid URL")
        }

        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.4,
            "max_tokens": 768,
            "response_format": Self.responseFormat
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let requestID = OpenAIAPILogStore.shared.logHTTPRequest(
            service: "OpenAIRouter.chat",
            endpoint: url.absoluteString,
            method: "POST",
            model: model,
            timeoutSeconds: request.timeoutInterval,
            payload: requestBody
        )

        let data: Data
        let startedAt = Date()
        var loggedTerminal = false
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                OpenAIAPILogStore.shared.logHTTPError(
                    requestID: requestID,
                    service: "OpenAIRouter.chat",
                    endpoint: url.absoluteString,
                    method: "POST",
                    model: model,
                    statusCode: nil,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                    error: "Invalid response object",
                    responseData: responseData
                )
                loggedTerminal = true
                throw OpenAIRouter.OpenAIError.requestFailed("Invalid response")
            }
            guard (200...299).contains(http.statusCode) else {
                OpenAIAPILogStore.shared.logHTTPError(
                    requestID: requestID,
                    service: "OpenAIRouter.chat",
                    endpoint: url.absoluteString,
                    method: "POST",
                    model: model,
                    statusCode: http.statusCode,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                    error: "HTTP \(http.statusCode)",
                    responseData: responseData
                )
                loggedTerminal = true
                throw OpenAIRouter.OpenAIError.badResponse(http.statusCode)
            }
            OpenAIAPILogStore.shared.logHTTPResponse(
                requestID: requestID,
                service: "OpenAIRouter.chat",
                endpoint: url.absoluteString,
                method: "POST",
                model: model,
                statusCode: http.statusCode,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                responseData: responseData
            )
            loggedTerminal = true
            data = responseData
        } catch let error as OpenAIRouter.OpenAIError {
            if !loggedTerminal {
                OpenAIAPILogStore.shared.logHTTPError(
                    requestID: requestID,
                    service: "OpenAIRouter.chat",
                    endpoint: url.absoluteString,
                    method: "POST",
                    model: model,
                    statusCode: nil,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                    error: error.localizedDescription,
                    responseData: nil
                )
            }
            throw error
        } catch {
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRouter.chat",
                endpoint: url.absoluteString,
                method: "POST",
                model: model,
                statusCode: nil,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: error.localizedDescription,
                responseData: nil
            )
            throw OpenAIRouter.OpenAIError.requestFailed(error.localizedDescription)
        }

        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRouter.chat",
                endpoint: url.absoluteString,
                method: "POST",
                model: model,
                statusCode: nil,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: "Could not extract content from response",
                responseData: data
            )
            throw OpenAIRouter.OpenAIError.requestFailed("Could not extract content from response")
        }

        return content
    }
}

// MARK: - OpenAI Router

/// Routes user input through OpenAI to produce PLAN JSON.
/// Reuses OllamaRouter's message-building and parsing infrastructure.
final class OpenAIRouter {

    enum OpenAIError: Error, LocalizedError {
        case notConfigured
        case requestFailed(String)
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OpenAI API key not configured"
            case .requestFailed(let msg): return "OpenAI request failed: \(msg)"
            case .badResponse(let code): return "OpenAI returned HTTP \(code)"
            }
        }
    }

    private let transport: OpenAITransport
    private let parser: OllamaRouter

    init(parser: OllamaRouter, transport: OpenAITransport = RealOpenAITransport()) {
        self.parser = parser
        self.transport = transport
    }

    // MARK: - Route Plan

    func routePlan(_ input: String, history: [ChatMessage] = [],
                   pendingSlot: PendingSlot? = nil,
                   repairReasons: [String]? = nil,
                   repairRawSnippet: String? = nil,
                   alarmContext: AlarmContext? = nil) async throws -> Plan {
        guard OpenAISettings.isConfigured else {
            OpenAIAPILogStore.shared.logBlockedRequest(
                service: "OpenAIRouter.routePlan",
                endpoint: "https://api.openai.com/v1/chat/completions",
                method: "POST",
                model: OpenAISettings.model,
                reason: "OpenAI API key not configured",
                payload: ["input_preview": String(input.prefix(160))]
            )
            throw OpenAIError.notConfigured
        }

        let systemPrompt = buildLightSystemPrompt(forInput: input)
        var messages = parser.buildMessages(input: input, history: history,
                                            systemPrompt: systemPrompt,
                                            pendingSlot: pendingSlot,
                                            alarmContext: alarmContext)
        parser.appendRepairBlock(to: &messages, repairReasons: repairReasons, rawSnippet: repairRawSnippet)

        let responseText = try await transport.chat(messages: messages, model: OpenAISettings.model)

        #if DEBUG
        print("[OpenAIRouter] Raw response: \(responseText)")
        #endif

        // Parse — if it fails, try salvage stages before falling back to TALK
        do {
            let plan = try parser.parsePlanOrAction(from: responseText)
            let guarded = enforcePostParseGuardrails(plan, userInput: input)
            if shouldRepairUnexpectedCapabilityEscalation(guarded, userInput: input) {
                if repairReasons == nil {
                    let reasons = [
                        "You returned CAPABILITY_GAP/start_skillforge for a normal user task.",
                        "Only use CAPABILITY_GAP/start_skillforge when the user explicitly asks Sam to build/learn a new capability.",
                        "For this request, return PLAN/TALK using existing tools only."
                    ]
                    return try await routePlan(
                        input,
                        history: history,
                        pendingSlot: pendingSlot,
                        repairReasons: reasons,
                        repairRawSnippet: responseText,
                        alarmContext: alarmContext
                    )
                }
                return fallbackPlanForUnexpectedCapabilityEscalation(userInput: input)
            }
            return guarded
        } catch {
            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw OpenAIError.requestFailed("Empty response from OpenAI")
            }

            // Stage 1: normalize args (string→object) and retry decode (existing)
            if let data = trimmed.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let normalized = parser.normalizeActionJSON(dict)
                if let normalizedData = try? JSONSerialization.data(withJSONObject: normalized),
                   let action = try? JSONDecoder().decode(Action.self, from: normalizedData) {
                    #if DEBUG
                    print("[OpenAIRouter] Salvaged via normalizeActionJSON")
                    #endif
                    return enforcePostParseGuardrails(Plan.fromAction(action), userInput: input)
                }
            }

            // Stage 2: show_text / markdown extraction
            if trimmed.contains("\"show_text\"") || trimmed.contains("\"markdown\"") {
                if let markdown = extractMarkdownContent(trimmed) {
                    #if DEBUG
                    print("[OpenAIRouter] Salvaged as show_text")
                    #endif
                let salvaged = Plan(steps: [.tool(
                    name: "show_text",
                    args: ["markdown": .string(markdown)],
                    say: "Here you go."
                )])
                return enforcePostParseGuardrails(salvaged, userInput: input)
                }
            }

            // Stage 2b: raw markdown (starts with # heading)
            if trimmed.hasPrefix("#") {
                #if DEBUG
                print("[OpenAIRouter] Salvaged raw markdown as show_text")
                #endif
                let salvaged = Plan(steps: [.tool(
                    name: "show_text",
                    args: ["markdown": .string(trimmed)],
                    say: "Here you go."
                )])
                return enforcePostParseGuardrails(salvaged, userInput: input)
            }

            // Stage 3: show_image / image URL extraction
            if trimmed.contains("\"show_image\"") || trimmed.contains("\"urls\"") || trimmed.contains("\"url\"") {
                if let imageData = extractImageURLs(trimmed) {
                    #if DEBUG
                    print("[OpenAIRouter] Salvaged as show_image")
                    #endif
                    let salvaged = Plan(steps: [.tool(
                        name: "show_image",
                        args: [
                            "urls": .string(imageData.urls.joined(separator: "|")),
                            "alt": .string(imageData.alt)
                        ],
                        say: "Here you go."
                    )])
                    return enforcePostParseGuardrails(salvaged, userInput: input)
                }
            }

            // Stage 4: JSON-looking garbage → friendly error (never leak raw JSON)
            if looksLikeJSON(trimmed) {
                #if DEBUG
                print("[OpenAIRouter] JSON-looking response could not be parsed, returning friendly error")
                #endif
                return Plan(steps: [.talk(say: "Sorry, I had trouble processing that. Could you try again?")])
            }

            // Stage 5: plain text → capped TALK (existing behaviour)
            #if DEBUG
            print("[OpenAIRouter] Parse failed (\(error)), wrapped as TALK")
            #endif
            let capped = String(trimmed.prefix(240))
            return Plan(steps: [.talk(say: capped)])
        }
    }

    // MARK: - Light System Prompt

    /// Shorter system prompt for OpenAI.
    private func buildLightSystemPrompt(forInput input: String) -> String {
        let tools = ToolRegistry.shared.allTools
        var toolDescriptions = ""
        for tool in tools where tool.name != "capability_gap_to_claude_prompt" {
            toolDescriptions += "- \(tool.name): \(tool.description)\n"
        }

        let installedSkills = SkillStore.shared.loadInstalled()
        var skillBlock = ""
        if !installedSkills.isEmpty {
            skillBlock += "\n## Installed Skills (NOT tool names)\n"
            skillBlock += "- These are matched automatically from user text.\n"
            skillBlock += "- Never call an installed skill name in TOOL steps.\n"
            skillBlock += "- Use TOOL steps only for names in Available Tools.\n"
            for skill in installedSkills {
                let triggers = skill.triggerPhrases.joined(separator: ", ")
                skillBlock += "- \(skill.name): triggers on \"\(triggers)\"\n"
            }
        }

        let memoryHints = MemoryStore.shared.memoryContext(query: input, maxItems: 3, maxChars: 300)
        let memoryHintField: String
        if memoryHints.isEmpty {
            memoryHintField = "memory_hint: []"
        } else {
            let snippets = memoryHints.map { memory in
                "\"[\(memory.type.rawValue)] \(memory.content.replacingOccurrences(of: "\"", with: "'"))\""
            }
            memoryHintField = "memory_hint: [\(snippets.joined(separator: ", "))]"
        }

        let selfLessons = SelfLearningStore.shared.relevantLessonTexts(query: input, maxItems: 3, maxChars: 260)
        let selfLearningField: String
        if selfLessons.isEmpty {
            selfLearningField = "self_learning: []"
        } else {
            let snippets = selfLessons.map { lesson in
                "\"\(lesson.replacingOccurrences(of: "\"", with: "'"))\""
            }
            selfLearningField = "self_learning: [\(snippets.joined(separator: ", "))]"
        }

        let websiteHints = WebsiteLearningStore.shared.relevantContext(query: input, maxItems: 10, maxChars: 1200)
        let websiteLearningField: String
        if websiteHints.isEmpty {
            websiteLearningField = "website_learning: []"
        } else {
            let snippets = websiteHints.map { note in
                "\"\(note.replacingOccurrences(of: "\"", with: "'"))\""
            }
            websiteLearningField = "website_learning: [\(snippets.joined(separator: ", "))]"
        }

        return """
        You are Sam, a friendly voice assistant inside a macOS app called SamOS.
        You receive a user's spoken request and must respond with EXACTLY ONE valid JSON object.
        Output ONLY the JSON object. No explanation, no markdown, no code fences.

        ## Tone & Style
        - Warm, casual, concise. Sound like a real person, not a robot.
        - Keep spoken responses short — one to two sentences.
        - Use contractions and informal phrasing.
        - You may include one brief follow-up question if it helps the user proceed.
        - Do NOT ask whether the user wants a quick/brief/detailed version unless they explicitly ask for that choice.
        - If your previous message asked a question and the user replies briefly, treat it as an answer to that question unless they clearly changed topic.

        ## Reasoning (CoT)
        - For complex tasks (math, logic, coding, multi-step planning), think step by step internally before choosing the final JSON action.
        - Break the task into small logical checks internally, then output only the best final action.
        - Keep internal reasoning private. Never output chain-of-thought text.

        ## Anti-Repetition
        - Never reuse the same greeting or phrase verbatim within the last 10 assistant messages.
        - For greetings ("hi", "hello", "hey"), pick a different short response each time.
        - Keep it casual, 1 sentence max unless the user asks more.
        - Avoid "How can I assist you today?" style corporate lines.
        - Example greetings to rotate naturally:
          "Hey! What's up?" / "Hi, how's your day going?" / "Hey there — what can I do for you?" /
          "Hello! Need a hand with anything?" / "Hey! How can I help?" / "Hi! What are we doing today?" /
          "What's going on?" / "Hey hey — what do you need?"

        ## Available Tools
        \(toolDescriptions)
        \(skillBlock)

        ## Response Format
        The "action" field MUST be one of: PLAN, TALK, TOOL, DELEGATE_OPENAI, CAPABILITY_GAP.

        ## Multi-Step Plans (PREFERRED for tool usage)
        {"action":"PLAN","steps":[
          {"step":"tool","name":"get_time","args":{"place":"London"},"say":"Here's the time."}
        ]}

        {"action":"PLAN","steps":[
          {"step":"tool","name":"schedule_task","args":{"in_seconds":"60","label":"1 minute timer"},"say":"Timer set."}
        ]}

        {"action":"PLAN","steps":[
          {"step":"ask","slot":"time","prompt":"What time should I set the alarm for?"}
        ]}

        Timezone clarification (ambiguous region like "America" / "US"):
        {"action":"PLAN","steps":[
          {"step":"ask","slot":"timezone","prompt":"Which state or city in the US?"}
        ]}

        ## Simple Responses
        {"action":"TALK","say":"Hey! What's up?"}

        ## Tool Usage
        {"action":"TOOL","name":"find_image","args":{"query":"frog"},"say":"I'll find an image for that."}
        {"action":"TOOL","name":"show_image","args":{"urls":"https://example.com/img.jpg","alt":"description"},"say":"Here you go."}
        {"action":"TOOL","name":"show_text","args":{"markdown":"# Title\\nContent"},"say":"Here it is."}
        {"action":"TOOL","name":"save_memory","args":{"type":"fact","content":"Your dog's name is Bailey."},"say":"I'll remember that."}
        {"action":"TOOL","name":"get_time","args":{},"say":"Let me check."}
        {"action":"TOOL","name":"learn_website","args":{"url":"https://example.com","focus":"pricing"},"say":"I'll learn from that page."}
        {"action":"TOOL","name":"autonomous_learn","args":{"minutes":"5","topic":"productivity habits"},"say":"I'll go learn and report back."}
        {"action":"TOOL","name":"stop_autonomous_learn","args":{},"say":"Okay, I'll stop learning now."}
        {"action":"TOOL","name":"describe_camera_view","args":{},"say":"Here's what I can see."}
        {"action":"TOOL","name":"find_camera_objects","args":{"query":"bottle"},"say":"I'll look for that object."}
        {"action":"TOOL","name":"get_camera_face_presence","args":{},"say":"I'll check face presence."}
        {"action":"TOOL","name":"enroll_camera_face","args":{"name":"Ricky"},"say":"I'll learn that face."}
        {"action":"TOOL","name":"recognize_camera_faces","args":{},"say":"I'll recognize faces now."}
        {"action":"TOOL","name":"camera_visual_qa","args":{"question":"Do you see a red cup?"},"say":"I'll check the camera view."}
        {"action":"TOOL","name":"camera_inventory_snapshot","args":{},"say":"I'll capture a snapshot."}
        {"action":"TOOL","name":"save_camera_memory_note","args":{},"say":"I'll save a camera memory note."}
        {"action":"TOOL","name":"start_skillforge","args":{"goal":"Capability Gap Miner","constraints":"Analyze failed/blocked turns and propose the next capability to build."},"say":"I'll build that capability."}
        {"action":"TOOL","name":"forge_queue_clear","args":{},"say":"Okay, I stopped capability learning."}

        [TOOL CHOICE]
        - Weather/forecast/rain/temperature/wind/humidity -> use get_weather
        - Time/date/timezone/what time is it -> use get_time
        - Questions about what Sam can currently see through the laptop camera -> use describe_camera_view
        - Object finding, face presence, face enrollment/recognition, visual questions, inventory snapshots, and camera memory notes -> use their matching camera tools
        - Do NOT use get_time for weather questions.

        ## Tool Policy
        - For time/date questions → prefer get_time tool for accurate results.
        - For weather/forecast/rain questions → prefer get_weather.
        - For "timer"/"countdown"/relative time → schedule_task with in_seconds.
        - For "alarm"/absolute time → schedule_task with run_at.
        - For dense or structured content (markdown blocks, headings/lists/steps, or >200 chars), keep say as a short spoken summary and put full details in show_text markdown.
        - For long or structured content (multi-line, headings, lists, >240 chars) → prefer show_text with markdown.
        - For recipes/instructions → show_text with markdown.
        - For user requests to find/search/show an image by topic -> use find_image with args.query.
        - Use show_image when the user already provided direct image URL(s).
        - For requests to read/learn/study a URL → use learn_website with the provided url and optional focus.
        - For requests to describe what Sam can currently see through camera vision → use describe_camera_view.
        - For requests to find objects in the camera view → use find_camera_objects with query.
        - For requests about face presence/count in camera view → use get_camera_face_presence.
        - For requests to learn/register a person's face in camera view → use enroll_camera_face with name.
        - For requests to identify/recognize known faces in camera view → use recognize_camera_faces.
        - For camera questions (for example "Do you see X?") → use camera_visual_qa with question.
        - For inventory tracking from camera view → use camera_inventory_snapshot.
        - For saving what camera saw into memory → use save_camera_memory_note.
        - For requests like "go learn for X minutes" or autonomous self-learning -> use autonomous_learn with minutes and optional topic.
        - If user asks to stop autonomous timed learning, use stop_autonomous_learn.
        - For requests to build/create/learn a new capability or skill for Sam -> use start_skillforge with goal and optional constraints.
        - Do NOT use learn_website or autonomous_learn as a substitute for capability-building requests.
        - If user asks to stop/abort capability learning, use forge_queue_clear.
        - For remembering → save_memory. For recalling → list_memories.
        - For get_time: use "place" for city/state names, "timezone" for IANA IDs.
        - If region has multiple timezones (US, America) → ask which city/state first.
        - NEVER claim "alarm set" or "timer set" without calling the tool.
        - NEVER claim "cancelled" without calling cancel_task.
        - After learning from a website, use saved website-learning notes to answer follow-up questions.
        - After autonomous learning, report what you learned clearly and ask one helpful follow-up question if needed.
        - If you still cannot fulfill a request, return CAPABILITY_GAP with clear goal/missing fields so Sam can auto-build the capability.
        - For general conversation, factual questions, greetings → use TALK.
        - For installed skills listed above, execute their behavior with tools/PLAN instead of CAPABILITY_GAP.

        ## Memory Hints
        \(memoryHintField)
        - Memory acknowledgements are optional.
        - Only acknowledge memory if it is clearly relevant to the user's current message.
        - Do NOT mention sensitive topics unless the user brings them up first.
        - Do NOT invent memory. If uncertain, skip memory acknowledgement.
        - Keep acknowledgements short (one clause) before the main answer.

        ## Self-Improvement Lessons (private)
        \(selfLearningField)
        - Use these lessons as internal quality guidance only.
        - Never mention the lessons directly to the user.
        - Apply only when relevant to the current turn.

        ## Learned Website Notes
        \(websiteLearningField)
        - Use these notes when the user asks about previously learned websites.
        - Do not invent details that are not present in these notes.

        ## PLAN Policy
        - Use PLAN for any tool usage or when info is missing (ask step).
        - PLAN steps must be objects: {"step":"talk|tool|ask|delegate",...}

        ## Tool Payload Limits
        - For show_text, keep args.markdown under ~1200 characters.
        - Prefer concise content (ingredients + short steps). Do not append quick-vs-detailed upsell prompts.
        - ALWAYS return complete, valid JSON with closed quotes and braces. Never cut off mid-string.

        ## Newline Escaping
        - Inside JSON string values, use literal \\n for newlines (not raw newlines).
        - Example: "markdown":"# Title\\n\\nStep 1: Do this\\nStep 2: Do that"
        - NEVER put raw newlines inside a JSON string — it breaks the JSON.

        ## Image URL Rules
        - For show_image you MUST return 3 direct image file URLs (not web pages).
        - URLs MUST end with .jpg, .png, .webp or .gif.
        - Use ONLY reliable sources:
          - https://upload.wikimedia.org/wikipedia/commons/... (preferred)
          - https://images.unsplash.com/... (direct)
          - https://images.pexels.com/... (direct)
        - NEVER use example.com or placeholder domains.
        - If unsure, prefer Wikimedia upload URLs.

        ## Critical Rules
        - Output ONLY one valid JSON object with a required "action" field.
        - The "say" field is for SHORT spoken responses only.
        """
    }

    // MARK: - Tool Choice Guardrails

    private func enforcePostParseGuardrails(_ plan: Plan, userInput: String) -> Plan {
        let weatherGuarded = enforceToolChoiceGuardrails(plan, userInput: userInput)
        return enforceCapabilityLearningGuardrails(weatherGuarded, userInput: userInput)
    }

    private func enforceToolChoiceGuardrails(_ plan: Plan, userInput: String) -> Plan {
        guard isWeatherQuery(userInput) else { return plan }
        guard !planContainsTool(plan, named: "get_weather") else { return plan }
        guard let (args, say) = firstToolArgs(in: plan, named: "get_time") else { return plan }

        if let place = args["place"]?.stringValue, !place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Plan(steps: [
                .tool(
                    name: "get_weather",
                    args: ["place": .string(place)],
                    say: say ?? "Let me check the weather."
                )
            ], say: plan.say)
        }

        return Plan(steps: [
            .ask(slot: "place", prompt: "Which city should I check the weather for?")
        ], say: plan.say)
    }

    private func enforceCapabilityLearningGuardrails(_ plan: Plan, userInput: String) -> Plan {
        guard isCapabilityLearningRequest(userInput) else { return plan }

        if isStopCapabilityLearningRequest(userInput) {
            if planContainsTool(plan, named: "forge_queue_clear") { return plan }
            return Plan(steps: [
                .tool(name: "forge_queue_clear", args: [:], say: "Okay, I stopped capability learning.")
            ], say: plan.say)
        }

        // Keep explicit learning tools for URL-based or timed autonomous learning requests.
        if inputContainsURL(userInput) || isTimedAutonomousLearningRequest(userInput) {
            return plan
        }

        if planContainsTool(plan, named: "start_skillforge")
            || planContainsTool(plan, named: "forge_queue_status")
            || planContainsTool(plan, named: "forge_queue_clear") {
            return plan
        }

        var args: [String: CodableValue] = [
            "goal": .string(capabilityGoal(from: plan, userInput: userInput))
        ]
        if let constraints = capabilityConstraints(from: plan), !constraints.isEmpty {
            args["constraints"] = .string(constraints)
        }

        return Plan(steps: [
            .tool(name: "start_skillforge", args: args, say: "I'll build that capability now.")
        ], say: plan.say)
    }

    private func isWeatherQuery(_ input: String) -> Bool {
        let lower = input.lowercased()
        let keywords = ["weather", "raining", "rain", "forecast", "temperature", "wind", "humidity"]
        return keywords.contains { lower.contains($0) }
    }

    private func isCapabilityLearningRequest(_ input: String) -> Bool {
        let lower = input.lowercased()
        if inputContainsURL(lower) || isTimedAutonomousLearningRequest(lower) {
            return false
        }

        let hasCapabilityNoun = ["capability", "capabilities", "skill", "skills", "feature", "features", "capability gap"]
            .contains { lower.contains($0) }
        let hasBuildVerb = ["build", "create", "develop", "implement", "learn", "forge", "improve", "expand", "upgrade"]
            .contains { lower.contains($0) }

        return hasCapabilityNoun && hasBuildVerb
    }

    private func shouldRepairUnexpectedCapabilityEscalation(_ plan: Plan, userInput: String) -> Bool {
        if isCapabilityLearningRequest(userInput) || isStopCapabilityLearningRequest(userInput) {
            return false
        }

        let hasGapDelegate = plan.steps.contains { step in
            if case .delegate(let task, _, _) = step {
                return task.lowercased().hasPrefix("capability_gap:")
            }
            return false
        }
        let hasForgeTool = planContainsTool(plan, named: "start_skillforge")
        return hasGapDelegate || hasForgeTool
    }

    private func fallbackPlanForUnexpectedCapabilityEscalation(userInput: String) -> Plan {
        let prompt: String
        if inputContainsURL(userInput) {
            prompt = "I can do this directly. If you want, I can read that URL and summarize what I find."
        } else {
            prompt = "I can help directly without building a new capability. Try again with the exact task, and include a URL if you want me to learn from a specific page."
        }
        return Plan(steps: [.talk(say: prompt)])
    }

    private func isStopCapabilityLearningRequest(_ input: String) -> Bool {
        let lower = input.lowercased()
        let hasStopVerb = ["stop", "abort", "cancel"].contains { lower.contains($0) }
        let hasCapabilityContext = ["capability", "skill", "forge", "learning"].contains { lower.contains($0) }
        return hasStopVerb && hasCapabilityContext
    }

    private func isTimedAutonomousLearningRequest(_ input: String) -> Bool {
        let lower = input.lowercased()
        guard lower.contains("learn") else { return false }
        return lower.range(of: #"\bfor\s+\d+\s*(minute|minutes|min|mins|hour|hours)\b"#,
                           options: .regularExpression) != nil
    }

    private func inputContainsURL(_ input: String) -> Bool {
        input.range(of: #"https?://\S+"#, options: .regularExpression) != nil
    }

    private func planContainsTool(_ plan: Plan, named toolName: String) -> Bool {
        plan.steps.contains { step in
            if case .tool(let name, _, _) = step {
                return name == toolName
            }
            return false
        }
    }

    private func firstToolArgs(in plan: Plan, named toolName: String) -> (args: [String: CodableValue], say: String?)? {
        for step in plan.steps {
            if case .tool(let name, let args, let say) = step, name == toolName {
                return (args, say)
            }
        }
        return nil
    }

    private func capabilityGoal(from plan: Plan, userInput: String) -> String {
        if let (args, _) = firstToolArgs(in: plan, named: "start_skillforge"),
           let goal = args["goal"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
           !goal.isEmpty {
            return goal
        }

        for step in plan.steps {
            if case .delegate(let task, _, _) = step {
                let prefix = "capability_gap:"
                let lowered = task.lowercased()
                if lowered.hasPrefix(prefix) {
                    let raw = String(task.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !raw.isEmpty { return raw }
                }
            }
        }

        if let quoted = quotedGoal(in: userInput) {
            return quoted
        }

        let normalized = userInput
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "new capability requested by user" : normalized
    }

    private func capabilityConstraints(from plan: Plan) -> String? {
        for step in plan.steps {
            if case .delegate(_, let context, _) = step,
               let context = context?.trimmingCharacters(in: .whitespacesAndNewlines),
               !context.isEmpty {
                return context
            }
        }
        return nil
    }

    private func quotedGoal(in input: String) -> String? {
        let patterns = [
            #""([^"]{3,180})""#,
            #"'([^']{3,180})'"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(input.startIndex..<input.endIndex, in: input)
            guard let match = regex.firstMatch(in: input, range: range),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: input) else {
                continue
            }
            let captured = String(input[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !captured.isEmpty {
                return captured
            }
        }
        return nil
    }

    // MARK: - Salvage Helpers

    /// Tries to extract markdown content from a JSON-ish string containing show_text data.
    /// Checks: top-level "markdown" key, nested args.markdown, and PLAN steps with show_text.
    private func extractMarkdownContent(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Direct: {"markdown":"..."}
        if let md = dict["markdown"] as? String, !md.isEmpty { return md }

        // Nested in args: {"name":"show_text","args":{"markdown":"..."}}
        if let args = dict["args"] as? [String: Any],
           let md = args["markdown"] as? String, !md.isEmpty { return md }

        // In PLAN steps: {"action":"PLAN","steps":[{"name":"show_text","args":{"markdown":"..."}}]}
        if let steps = dict["steps"] as? [[String: Any]] {
            for step in steps {
                if let name = step["name"] as? String, name == "show_text",
                   let args = step["args"] as? [String: Any],
                   let md = args["markdown"] as? String, !md.isEmpty {
                    return md
                }
            }
        }

        return nil
    }

    /// Tries to extract image URLs from a JSON-ish string containing show_image data.
    /// Returns pipe-separated URL list and alt text, or nil.
    private func extractImageURLs(_ text: String) -> (urls: [String], alt: String)? {
        guard let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var candidates: [[String: Any]] = [dict]
        if let args = dict["args"] as? [String: Any] { candidates.append(args) }
        if let steps = dict["steps"] as? [[String: Any]] {
            for step in steps {
                if let name = step["name"] as? String, name == "show_image" {
                    candidates.append(step)
                    if let args = step["args"] as? [String: Any] { candidates.append(args) }
                }
            }
        }

        for d in candidates {
            if let urlsStr = d["urls"] as? String, !urlsStr.isEmpty {
                let urls = urlsStr.components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.hasPrefix("http") }
                if !urls.isEmpty {
                    let alt = d["alt"] as? String ?? dict["alt"] as? String ?? "Image"
                    return (urls, alt)
                }
            }
            if let url = d["url"] as? String, url.hasPrefix("http") {
                let alt = d["alt"] as? String ?? dict["alt"] as? String ?? "Image"
                return ([url], alt)
            }
        }

        return nil
    }

    /// Returns true if the text appears to be JSON that should not be shown raw to the user.
    private func looksLikeJSON(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") || t.hasPrefix("[") { return true }
        if t.contains("\"action\"") || t.contains("\"name\"") { return true }
        return false
    }
}
