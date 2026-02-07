import Foundation

// MARK: - OpenAI Transport Protocol

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
            "max_tokens": 192,
            "response_format": Self.responseFormat
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let data: Data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenAIRouter.OpenAIError.requestFailed("Invalid response")
            }
            guard (200...299).contains(http.statusCode) else {
                throw OpenAIRouter.OpenAIError.badResponse(http.statusCode)
            }
            data = responseData
        } catch let error as OpenAIRouter.OpenAIError {
            throw error
        } catch {
            throw OpenAIRouter.OpenAIError.requestFailed(error.localizedDescription)
        }

        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = envelope["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
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
        guard OpenAISettings.isConfigured else { throw OpenAIError.notConfigured }

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
            return try parser.parsePlanOrAction(from: responseText)
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
                    return Plan.fromAction(action)
                }
            }

            // Stage 2: show_text / markdown extraction
            if trimmed.contains("\"show_text\"") || trimmed.contains("\"markdown\"") {
                if let markdown = extractMarkdownContent(trimmed) {
                    #if DEBUG
                    print("[OpenAIRouter] Salvaged as show_text")
                    #endif
                    return Plan(steps: [.tool(
                        name: "show_text",
                        args: ["markdown": .string(markdown)],
                        say: "Here you go."
                    )])
                }
            }

            // Stage 2b: raw markdown (starts with # heading)
            if trimmed.hasPrefix("#") {
                #if DEBUG
                print("[OpenAIRouter] Salvaged raw markdown as show_text")
                #endif
                return Plan(steps: [.tool(
                    name: "show_text",
                    args: ["markdown": .string(trimmed)],
                    say: "Here you go."
                )])
            }

            // Stage 3: show_image / image URL extraction
            if trimmed.contains("\"show_image\"") || trimmed.contains("\"urls\"") || trimmed.contains("\"url\"") {
                if let imageData = extractImageURLs(trimmed) {
                    #if DEBUG
                    print("[OpenAIRouter] Salvaged as show_image")
                    #endif
                    return Plan(steps: [.tool(
                        name: "show_image",
                        args: [
                            "urls": .string(imageData.urls.joined(separator: "|")),
                            "alt": .string(imageData.alt)
                        ],
                        say: "Here you go."
                    )])
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

    /// Shorter system prompt for OpenAI — omits memory, installed skills, SkillForge policy, canvas content policy.
    private func buildLightSystemPrompt(forInput input: String) -> String {
        let tools = ToolRegistry.shared.allTools
        var toolDescriptions = ""
        for tool in tools where tool.name != "capability_gap_to_claude_prompt" {
            toolDescriptions += "- \(tool.name): \(tool.description)\n"
        }

        return """
        You are Sam, a friendly voice assistant inside a macOS app called SamOS.
        You receive a user's spoken request and must respond with EXACTLY ONE valid JSON object.
        Output ONLY the JSON object. No explanation, no markdown, no code fences.

        ## Tone & Style
        - Warm, casual, concise. Sound like a real person, not a robot.
        - Keep spoken responses short — one to two sentences.
        - Use contractions and informal phrasing.

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
        {"action":"TOOL","name":"show_image","args":{"urls":"https://example.com/img.jpg","alt":"description"},"say":"Here you go."}
        {"action":"TOOL","name":"show_text","args":{"markdown":"# Title\\nContent"},"say":"Here it is."}
        {"action":"TOOL","name":"save_memory","args":{"type":"fact","content":"Your dog's name is Bailey."},"say":"I'll remember that."}
        {"action":"TOOL","name":"get_time","args":{},"say":"Let me check."}

        ## Tool Policy
        - For time/date questions → prefer get_time tool for accurate results.
        - For "timer"/"countdown"/relative time → schedule_task with in_seconds.
        - For "alarm"/absolute time → schedule_task with run_at.
        - For recipes/instructions → show_text with markdown.
        - For images → show_image with direct image URLs (2-3, pipe-separated).
        - For remembering → save_memory. For recalling → list_memories.
        - For get_time: use "place" for city/state names, "timezone" for IANA IDs.
        - If region has multiple timezones (US, America) → ask which city/state first.
        - NEVER claim "alarm set" or "timer set" without calling the tool.
        - NEVER claim "cancelled" without calling cancel_task.
        - For general conversation, factual questions, greetings → use TALK.
        - For requests you cannot handle → CAPABILITY_GAP.

        ## PLAN Policy
        - Use PLAN for any tool usage or when info is missing (ask step).
        - PLAN steps must be objects: {"step":"talk|tool|ask|delegate",...}

        ## Critical Rules
        - Output ONLY one valid JSON object with a required "action" field.
        - Image URLs must be direct links (ending in .jpg/.png/.gif/.webp), not web pages.
        - The "say" field is for SHORT spoken responses only.
        """
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
