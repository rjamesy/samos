import Foundation

// MARK: - LLM Call Reason (debug tracing)

enum LLMCallReason: String {
    case userChat
    case pendingSlotReply
    case alarmTriggered
    case alarmRepeat
    case snoozeExpired
    case alarmReply
    case imageRepair
}

// MARK: - Ollama Transport Protocol

/// Abstraction over the Ollama HTTP API so tests can inject a fake.
protocol OllamaTransport {
    func chat(messages: [[String: String]]) async throws -> String
}

/// Real transport that hits the Ollama /api/chat endpoint.
struct RealOllamaTransport: OllamaTransport {
    static let inferenceOptions: [String: Any] = [
        "temperature": 0.1,
        "top_p": 0.9,
        "num_predict": 256
    ]

    private static var didLogStartup = false

    func chat(messages: [[String: String]]) async throws -> String {
        let endpoint = M2Settings.ollamaEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = M2Settings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)

        #if DEBUG
        if !Self.didLogStartup {
            Self.didLogStartup = true
            print("[Ollama] model=\(model) endpoint=\(endpoint)")
        }
        #endif

        guard let url = URL(string: "\(endpoint)/api/chat") else {
            throw OllamaRouter.OllamaError.unreachable("Invalid endpoint URL")
        }

        let numPredict = Self.adaptiveNumPredict(for: messages)
        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "format": "json",
            "options": [
                "temperature": 0.1,
                "top_p": 0.9,
                "num_predict": numPredict
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let data: Data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw OllamaRouter.OllamaError.invalidResponse
            }
            data = responseData
        } catch let error as OllamaRouter.OllamaError {
            throw error
        } catch {
            throw OllamaRouter.OllamaError.unreachable(error.localizedDescription)
        }

        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = envelope["message"] as? [String: Any],
              let responseText = message["content"] as? String
        else {
            throw OllamaRouter.OllamaError.invalidResponse
        }

        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OllamaRouter.OllamaError.invalidResponse
        }

        return trimmed
    }

    private static func adaptiveNumPredict(for messages: [[String: String]]) -> Int {
        let userText = messages.last(where: { ($0["role"] ?? "").lowercased() == "user" })?["content"] ?? ""
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 512 }

        let lower = trimmed.lowercased()
        let wordCount = lower.split(whereSeparator: \.isWhitespace).count
        let sentenceCount = max(1, lower.split(separator: ".").count)
        let complexityMarkers = [
            "step by step", "detailed", "explain", "why", "how", "analyze",
            "compare", "implement", "architecture", "debug", "code", "plan"
        ]
        let markerHits = complexityMarkers.reduce(0) { partial, marker in
            partial + (lower.contains(marker) ? 1 : 0)
        }
        if lower.contains("\n") || lower.contains("```") {
            return 1200
        }
        if trimmed.count > 260 || wordCount > 45 || markerHits >= 2 || sentenceCount >= 4 {
            return 900
        }
        if trimmed.count < 50 && wordCount <= 8 {
            return 220
        }
        return 420
    }
}

/// Routes user input through a local Ollama LLM to produce Action JSON.
/// Falls back with an error if Ollama is unreachable.
final class OllamaRouter {

    // MARK: - Errors

    enum OllamaError: Error, LocalizedError {
        case unreachable(String)
        case invalidResponse
        case jsonParseFailed(String)
        case schemaMismatch(raw: String, reasons: [String])

        var errorDescription: String? {
            switch self {
            case .unreachable(let msg): return "Ollama unreachable: \(msg)"
            case .invalidResponse: return "Invalid response from Ollama"
            case .jsonParseFailed(let raw): return "Failed to parse Action JSON: \(raw.prefix(200))"
            case .schemaMismatch(let raw, let reasons):
                return "LLM returned non-schema JSON: \(reasons.joined(separator: "; ")) — raw: \(raw.prefix(200))"
            }
        }
    }

    private let transport: OllamaTransport

    init(transport: OllamaTransport = RealOllamaTransport()) {
        self.transport = transport
    }

    // MARK: - Route

    /// Sends user text to Ollama and returns a decoded Action.
    /// Throws `OllamaError` on connection or parse failure.
    func route(_ input: String, history: [ChatMessage] = [], repairReasons: [String]? = nil) async throws -> Action {
        let systemPrompt = buildSystemPrompt(forInput: input)
        var messages = buildMessages(input: input, history: history, systemPrompt: systemPrompt, pendingSlot: nil)
        appendRepairBlock(to: &messages, repairReasons: repairReasons)

        let responseText = try await transport.chat(messages: messages)
        print("[OllamaRouter] Raw response text: \(responseText)")
        return try parseAction(from: responseText)
    }

    // MARK: - Route Plan

    /// Sends user text to Ollama and returns a decoded Plan.
    /// Accepts PendingSlot for context injection so the LLM decides reply-vs-new-topic.
    /// Accepts AlarmContext for alarm wake-loop context injection.
    func routePlan(_ input: String, history: [ChatMessage] = [],
                   pendingSlot: PendingSlot? = nil,
                   repairReasons: [String]? = nil,
                   repairRawSnippet: String? = nil,
                   alarmContext: AlarmContext? = nil) async throws -> Plan {
        let systemPrompt = buildSystemPrompt(forInput: input)
        var messages = buildMessages(input: input, history: history, systemPrompt: systemPrompt,
                                     pendingSlot: pendingSlot, alarmContext: alarmContext)
        appendRepairBlock(to: &messages, repairReasons: repairReasons, rawSnippet: repairRawSnippet)

        let responseText = try await transport.chat(messages: messages)
        print("[OllamaRouter] Raw plan response: \(responseText)")

        // Parse with repair retry for schemaMismatch OR jsonParseFailed
        do {
            return try parsePlanOrAction(from: responseText)
        } catch OllamaError.schemaMismatch(let raw, let reasons) where repairReasons == nil {
            // First attempt returned valid JSON with wrong schema — retry once with repair context
            #if DEBUG
            print("[OllamaRouter] Schema mismatch, repair retry: \(reasons.joined(separator: "; "))")
            #endif
            return try await routePlan(input, history: history,
                                       pendingSlot: pendingSlot,
                                       repairReasons: reasons,
                                       repairRawSnippet: raw,
                                       alarmContext: alarmContext)
        } catch OllamaError.jsonParseFailed(let raw) where repairReasons == nil {
            // First attempt returned unparseable text — retry once with repair context
            #if DEBUG
            print("[OllamaRouter] JSON parse failed, repair retry: \(raw.prefix(80))")
            #endif
            return try await routePlan(input, history: history,
                                       pendingSlot: pendingSlot,
                                       repairReasons: ["Your response was not valid JSON. Output ONLY a JSON object."],
                                       repairRawSnippet: raw,
                                       alarmContext: alarmContext)
        }
    }

    // MARK: - Repair Block

    func appendRepairBlock(to messages: inout [[String: String]], repairReasons: [String]?, rawSnippet: String? = nil) {
        guard let reasons = repairReasons else { return }
        let tools = ToolRegistry.shared.allTools
        var toolList = ""
        for tool in tools where tool.name != "capability_gap_to_claude_prompt" {
            toolList += "- \(tool.name): \(tool.description)\n"
        }
        let bulletedReasons = reasons.map { "• \($0)" }.joined(separator: "\n")
        let rawBlock: String
        if let snippet = rawSnippet {
            rawBlock = "\nYour raw output was: \(String(snippet.prefix(200)))\n"
        } else {
            rawBlock = ""
        }
        messages.append(["role": "system", "content": """
        [REPAIR]
        Your previous response was INVALID:
        \(bulletedReasons)
        \(rawBlock)
        HARD RULE: Return ONLY ONE JSON object. It MUST include an "action" field and be valid JSON. No arrays, no prose, no fragments.

        Minimal valid examples:
        TALK:  {"action":"TALK","say":"Hello!"}
        TOOL:  {"action":"TOOL","name":"get_time","args":{"place":"London"},"say":"Let me check."}
        PLAN:  {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"London"},"say":"Here you go."}]}

        The "action" field MUST be one of: PLAN, TALK, TOOL, DELEGATE_OPENAI, CAPABILITY_GAP.
        PLAN steps MUST be objects with a "step" key, not strings.

        Output ONLY the corrected JSON. No prose, no explanation.
        Available tools:
        \(toolList)
        """])
    }

    // MARK: - Message Building (PendingSlot)

    /// Builds messages for /api/chat with PendingSlot and AlarmContext injection.
    func buildMessages(input: String, history: [ChatMessage], systemPrompt: String,
                       pendingSlot: PendingSlot?, alarmContext: AlarmContext? = nil) -> [[String: String]] {
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]

        let historyWindow = 12
        let nonSystem = history.filter { $0.role != .system }
        if nonSystem.count > historyWindow {
            let older = Array(nonSystem.dropLast(historyWindow))
            let summary = summarizeConversation(older)
            if !summary.isEmpty {
                messages.append([
                    "role": "system",
                    "content": """
                    [CONVERSATION_SUMMARY]
                    \(summary)
                    Use this summary as earlier context before the recent turns below.
                    """
                ])
            }
        }
        for msg in nonSystem.suffix(historyWindow) {
            messages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.text
            ])
        }

        if let slot = pendingSlot {
            let contextBlock = """
            [PENDING_SLOT]
            Original user request: "\(slot.originalUserText)"
            Sam asked: "\(slot.prompt)"
            Slot names: "\(slot.slotName)"
            User reply: "\(input)"

            Decide: (A) fill the missing field(s) and complete the original intent, OR (B) treat the reply as a new unrelated request.
            Output a PLAN either way.
            """
            messages.append(["role": "system", "content": contextBlock])
        }

        if let alarm = alarmContext {
            var lastLinesBlock = ""
            if !alarm.lastSpokenVariants.isEmpty {
                let lines = alarm.lastSpokenVariants.map { "  - \"\($0)\"" }.joined(separator: "\n")
                lastLinesBlock = """

                Lines already spoken (DO NOT repeat or paraphrase any of these):
                \(lines)
                """
            }

            let contextBlock = """
            [ALARM_CONTEXT]
            An alarm is currently ringing. You are helping wake up the user.
            User name: \(alarm.userName)
            Local time: \(alarm.localTime) (\(alarm.timeOfDay))
            Wake attempt: \(alarm.repeatCount)
            Snooze available: \(alarm.canSnooze) (already used: \(alarm.snoozedOnce), max 15 minutes)
            \(lastLinesBlock)

            ALARM RULES — follow these exactly:
            - If input is "[alarm triggered]": produce a warm greeting including the time of day and the user's name.
              Example: "Good morning Richard — time to get up."
            - If input is "[alarm repeat]" or "[snooze expired]": produce a FRESH, creative wake-up line. Be funny, motivational, or playful. NEVER repeat a prior line.
            - If user acknowledges being awake (e.g. "I'm up", "okay", "stop") → output a PLAN with:
              1. A talk step with a short friendly farewell
              2. A tool step: {"step":"tool","name":"cancel_task","args":{"id":"<current_alarm_task_id>"}}
              (Swift will override the id arg during sanitization — any placeholder is fine)
            - If user requests snooze (e.g. "snooze", "5 more minutes") → output a PLAN with:
              1. A talk step with a playful snooze confirmation mentioning the minutes
              2. A tool step: {"step":"tool","name":"schedule_task","args":{"in_seconds":"<seconds>"}}
              (Swift will clamp in_seconds to 60–900 during sanitization)
            - If unclear or unrelated → output a PLAN with ONLY a talk step gently encouraging them to wake up
            - Generate varied, warm, human responses. Every line must be unique.
            - Keep responses to 1-2 sentences. Sound like a friend, not a robot.
            """
            messages.append(["role": "system", "content": contextBlock])
        }

        // Schema reminder right before user message to reduce off-schema responses
        messages.append(["role": "system", "content": """
        [REMINDER] Output ONLY a JSON object with a required "action" field. \
        Valid actions: PLAN, TALK, TOOL, DELEGATE_OPENAI, CAPABILITY_GAP. \
        No empty objects. No invented keys. No prose.
        """])

        if history.last?.role != .user || history.last?.text != input {
            messages.append(["role": "user", "content": input])
        }

        return messages
    }

    private func summarizeConversation(_ messages: [ChatMessage]) -> String {
        guard !messages.isEmpty else { return "" }
        let clipped = messages.suffix(40)
        var lines: [String] = []
        lines.reserveCapacity(6)

        for message in clipped {
            guard lines.count < 6 else { break }
            let text = message.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let prefix = message.role == .user ? "User:" : "Sam:"
            let snippet = text.count > 120 ? String(text.prefix(117)) + "..." : text
            lines.append("- \(prefix) \(snippet)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Text Sanitisation

    /// Strips known LLM token garbage before JSON parsing.
    /// - Removes `<|...|>` special-token markers (e.g. `<|python_tag|>`)
    /// - Strips markdown code fences (```json ... ```)
    /// - Trims leading/trailing whitespace
    func sanitizeLLMText(_ text: String) -> String {
        var s = text
        // Strip <|...|> token markers
        if let regex = try? NSRegularExpression(pattern: #"<\|[^|]*\|>"#) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        // Strip code fences
        if s.contains("```") {
            // Remove ```json or ``` lines
            let lines = s.components(separatedBy: .newlines)
            let filtered = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            s = filtered.joined(separator: "\n")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Plan Parsing

    /// Tries to parse as PLAN first, falls back to legacy Action wrapped in Plan.
    /// Throws `schemaMismatch` (not `jsonParseFailed`) for valid JSON with wrong schema.
    func parsePlanOrAction(from text: String) throws -> Plan {
        let sanitized = sanitizeLLMText(text)
        let jsonString = extractJSON(from: sanitized)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw OllamaError.jsonParseFailed(text)
        }

        // Try PLAN decode first
        if let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            guard let actionField = dict["action"] as? String else {
                throw OllamaError.schemaMismatch(raw: jsonString, reasons: diagnoseSchemaMismatch(dict))
            }

            if actionField.uppercased() != "PLAN" {
                do {
                    return Plan.fromAction(try parseAction(from: text))
                } catch {
                    throw OllamaError.schemaMismatch(raw: jsonString, reasons: diagnoseSchemaMismatch(dict))
                }
            }

            // Validate steps structure before attempting decode
            if let steps = dict["steps"] as? [Any] {
                let nonObjects = steps.filter { !($0 is [String: Any]) }
                if !nonObjects.isEmpty {
                    throw OllamaError.schemaMismatch(raw: jsonString, reasons: [
                        "PLAN.steps must be an array of step objects like {\"step\":\"tool\",...}, not strings or primitives."
                    ])
                }
                let malformed = steps.compactMap { $0 as? [String: Any] }.filter { step in
                    step["step"] == nil && step["type"] == nil
                }
                if !malformed.isEmpty {
                    throw OllamaError.schemaMismatch(raw: jsonString, reasons: [
                        "Each PLAN step object must include a \"step\" key (or \"type\" alias) with talk/tool/ask/delegate."
                    ])
                }
            }

            let normalized = normalizeActionJSON(dict)
            let normalizedData = (try? JSONSerialization.data(withJSONObject: normalized)) ?? jsonData
            if let plan = try? JSONDecoder().decode(Plan.self, from: normalizedData) {
                return plan
            }

            // PLAN recognized but decode failed — diagnose specific issue
            let reasons = diagnoseSchemaMismatch(normalized)
            throw OllamaError.schemaMismatch(raw: jsonString, reasons: reasons)
        }

        // Fallback: decode legacy Action, wrap in synthetic Plan
        return Plan.fromAction(try parseAction(from: text))
    }

    /// Produces explicit repair reasons for a valid-JSON-but-wrong-schema response.
    private func diagnoseSchemaMismatch(_ dict: [String: Any]) -> [String] {
        if dict.isEmpty {
            return ["You returned an empty JSON object {}. You MUST include an \"action\" field set to PLAN, TALK, or TOOL."]
        }

        if let action = dict["action"] as? String {
            return [
                "You returned JSON with action=\"\(action)\" but the response is incomplete or malformed.",
                "For TALK: include a \"say\" field. For TOOL: include \"name\" and \"args\". For PLAN: include a \"steps\" array."
            ]
        }

        let keys = dict.keys.sorted().joined(separator: ", ")
        return [
            "You returned a JSON object with keys [\(keys)] but no \"action\" field.",
            "The \"action\" field is REQUIRED and must be one of: PLAN, TALK, TOOL, DELEGATE_OPENAI, CAPABILITY_GAP."
        ]
    }

    // MARK: - JSON Parsing

    func parseAction(from text: String) throws -> Action {
        let sanitized = sanitizeLLMText(text)
        let jsonString = extractJSON(from: sanitized)

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw OllamaError.jsonParseFailed(text)
        }

        // Try direct decode first
        if let action = try? JSONDecoder().decode(Action.self, from: jsonData) {
            return action
        }

        // If direct decode fails, try normalizing the JSON
        guard var dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw OllamaError.jsonParseFailed(text)
        }

        dict = normalizeActionJSON(dict)

        guard let normalizedData = try? JSONSerialization.data(withJSONObject: dict) else {
            throw OllamaError.jsonParseFailed(text)
        }

        do {
            return try JSONDecoder().decode(Action.self, from: normalizedData)
        } catch {
            // Last resort: if there's a "say" field, treat as TALK
            if let say = dict["say"] as? String ?? dict["response"] as? String ?? dict["text"] as? String {
                return .talk(Talk(say: say))
            }
            // Rescue strictly conversational JSON (e.g. {"Hello":"Hi!"})
            if let rescued = rescueAsTalk(dict) {
                return rescued
            }
            throw OllamaError.jsonParseFailed(text)
        }
    }

    // MARK: - Conversational Rescue

    /// Whitelist of keys that indicate a conversational (non-tool) JSON object.
    private static let conversationalKeys: Set<String> = [
        "say", "text", "message", "hello", "response", "greeting",
        "reply", "answer", "hi", "hey", "output", "content"
    ]

    /// Attempts to rescue a non-schema JSON object as TALK if it looks conversational.
    /// Strict whitelist: dict must have 1-3 keys, all lowercase keys must be in the
    /// conversational whitelist, and at least one value must be a short human sentence.
    func rescueAsTalk(_ dict: [String: Any]) -> Action? {
        guard (1...3).contains(dict.count) else { return nil }

        // All keys must be in the conversational whitelist
        let allConversational = dict.keys.allSatisfy {
            Self.conversationalKeys.contains($0.lowercased())
        }
        guard allConversational else { return nil }

        // Find the longest string value that looks like a human sentence (3-200 chars)
        let candidates = dict.values
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && $0.count <= 200 }
            .filter { !$0.hasPrefix("http") && !$0.hasPrefix("/") }

        guard let best = candidates.max(by: { $0.count < $1.count }) else {
            return nil
        }

        return .talk(Talk(say: best))
    }

    /// Normalizes common LLM deviations from the expected Action JSON schema.
    func normalizeActionJSON(_ input: [String: Any]) -> [String: Any] {
        var dict = input
        let toolNames = Set(ToolRegistry.shared.allTools.map { $0.name })
        var actionRaw = (dict["action"] as? String ?? "").lowercased()

        // Coerce args from JSON string to object (LLM sometimes returns args as a string)
        if let argsString = dict["args"] as? String,
           let data = argsString.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict["args"] = obj
        }

        // Move "say" from inside args to top level (LLM sometimes nests it)
        if var args = dict["args"] as? [String: Any],
           let say = args["say"] as? String,
           (dict["say"] == nil || (dict["say"] as? String)?.isEmpty == true) {
            dict["say"] = say
            args.removeValue(forKey: "say")
            dict["args"] = args
        }

        // Case 1: LLM used tool name as action (e.g. "action": "show_image")
        if toolNames.contains(actionRaw) {
            let toolName = actionRaw
            dict["action"] = "TOOL"
            dict["name"] = toolName
            // Collect top-level keys as args if no "args" key exists
            if dict["args"] == nil {
                var args: [String: Any] = [:]
                let reservedKeys: Set<String> = ["action", "name", "say"]
                for (key, value) in dict where !reservedKeys.contains(key) {
                    args[key] = value
                }
                // Remove moved keys from top level
                for key in args.keys {
                    dict.removeValue(forKey: key)
                }
                dict["args"] = args
            }
            return dict
        }

        // Case 2: No "action" key but has "tool" or "type" key
        if dict["action"] == nil {
            if let toolField = dict["tool"] as? String {
                dict["action"] = "TOOL"
                dict["name"] = toolField
                dict.removeValue(forKey: "tool")
            } else if let typeField = dict["type"] as? String {
                dict["action"] = typeField
                dict.removeValue(forKey: "type")
            }
            actionRaw = (dict["action"] as? String ?? "").lowercased()
        }

        // Case 3: "args" missing for TOOL — collect remaining keys
        if (dict["action"] as? String ?? "").uppercased() == "TOOL" && dict["args"] == nil {
            var args: [String: Any] = [:]
            let reservedKeys: Set<String> = ["action", "name", "say"]
            for (key, value) in dict where !reservedKeys.contains(key) {
                args[key] = value
            }
            for key in args.keys {
                dict.removeValue(forKey: key)
            }
            dict["args"] = args
        }

        // Case 4: Normalize PLAN step objects (common model schema drift).
        if (dict["action"] as? String ?? "").uppercased() == "PLAN",
           let steps = dict["steps"] as? [[String: Any]] {
            dict["steps"] = steps.map(normalizePlanStepJSON)
        }

        // Case 5: CAPABILITY_GAP missing required fields — inject defaults
        if actionRaw == "capability_gap" {
            if dict["goal"] == nil { dict["goal"] = "unknown" }
            if dict["missing"] == nil { dict["missing"] = "unknown" }
            if dict["say"] == nil {
                dict["say"] = "I'm not sure how to help with that yet — can you try rephrasing?"
            }
        }

        return dict
    }

    private func normalizePlanStepJSON(_ input: [String: Any]) -> [String: Any] {
        var step = input

        if step["step"] == nil, let type = step["type"] as? String {
            step["step"] = type
            step.removeValue(forKey: "type")
        }

        if let argsString = step["args"] as? String,
           let data = argsString.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            step["args"] = obj
        }

        if var args = step["args"] as? [String: Any],
           let say = args["say"] as? String,
           (step["say"] as? String)?.isEmpty ?? true {
            step["say"] = say
            args.removeValue(forKey: "say")
            step["args"] = args
        }

        if step["step"] == nil, step["name"] != nil {
            step["step"] = "tool"
        }

        if (step["step"] as? String ?? "").lowercased() == "ask",
           step["slot"] == nil,
           let slots = step["slots"] as? [Any] {
            let normalized = slots
                .compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !normalized.isEmpty {
                step["slot"] = normalized.joined(separator: ",")
            }
        }

        let stepType = (step["step"] as? String ?? "").lowercased()

        // Some model outputs misuse delegate for tool execution (name/args shape).
        if stepType == "delegate" {
            let task = (step["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hasToolShape = step["name"] != nil || step["args"] != nil
            if task.isEmpty && hasToolShape {
                step["step"] = "tool"
            }
        }

        let normalizedType = (step["step"] as? String ?? "").lowercased()
        if normalizedType == "talk", step["say"] == nil {
            if let text = step["text"] as? String {
                step["say"] = text
            } else if let message = step["message"] as? String {
                step["say"] = message
            }
        }

        return step
    }

    /// Extracts a JSON object from text, preferring objects with an "action" key.
    /// If multiple balanced-brace JSON candidates exist, selects the one with "action".
    /// Fallback: returns the largest valid JSON object, or first-`{`-to-last-`}`.
    func extractJSON(from text: String) -> String {
        guard text.contains("{") && text.contains("}") else { return text }

        // Find all balanced-brace JSON object candidates
        let candidates = findJSONObjects(in: text)
        guard !candidates.isEmpty else {
            // Fallback: first `{` to last `}`
            guard let start = text.firstIndex(of: "{"),
                  let end = text.lastIndex(of: "}")
            else { return text }
            return String(text[start...end])
        }

        // Prefer a candidate containing "action" key
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               dict["action"] != nil {
                return candidate
            }
        }

        // No "action" found — return the largest valid candidate
        return candidates.max(by: { $0.count < $1.count }) ?? candidates[0]
    }

    /// Scans text for balanced-brace JSON object substrings.
    private func findJSONObjects(in text: String) -> [String] {
        var results: [String] = []
        var depth = 0
        var startIdx: String.Index?

        for i in text.indices {
            if text[i] == "{" {
                if depth == 0 { startIdx = i }
                depth += 1
            } else if text[i] == "}" {
                depth -= 1
                if depth == 0, let s = startIdx {
                    let candidate = String(text[s...i])
                    // Verify it's valid JSON
                    if let data = candidate.data(using: .utf8),
                       (try? JSONSerialization.jsonObject(with: data)) != nil {
                        results.append(candidate)
                    }
                    startIdx = nil
                }
                if depth < 0 { depth = 0 }
            }
        }
        return results
    }

    // MARK: - System Prompt

    private func buildSystemPrompt(forInput input: String) -> String {
        let tools = ToolRegistry.shared.allTools
        var toolDescriptions = ""
        for tool in tools where tool.name != "capability_gap_to_claude_prompt" {
            toolDescriptions += "- \(tool.name): \(tool.description)\n"
        }

        // Build compact memory context to avoid prompt bloat.
        let relevantMemories = MemoryStore.shared.memoryContext(query: input, maxItems: 6, maxChars: 900)
        let graphHints = MemoryStore.shared.graphContext(query: input, maxItems: 4, maxChars: 320)

        var memoryBlock = ""
        if !relevantMemories.isEmpty {
            memoryBlock += "\n## Relevant Memories (matching this query)\n"
            for mem in relevantMemories {
                memoryBlock += "- [\(mem.type.rawValue)]: \(mem.content)\n"
            }
        }
        if !graphHints.isEmpty {
            memoryBlock += "\n## Memory Graph Hints\n"
            for edge in graphHints {
                memoryBlock += "- \(edge)\n"
            }
        }

        let selfLessons = SelfLearningStore.shared.relevantLessonTexts(query: input, maxItems: 4, maxChars: 480)
        var selfLearningBlock = ""
        if !selfLessons.isEmpty {
            selfLearningBlock += "\n## Self-Improvement Lessons (private)\n"
            for lesson in selfLessons {
                selfLearningBlock += "- \(lesson)\n"
            }
            selfLearningBlock += "- Use these lessons as internal quality guidance only.\n"
            selfLearningBlock += "- Never mention these lessons directly to the user.\n"
        }

        let websiteHints = WebsiteLearningStore.shared.relevantContext(query: input, maxItems: 12, maxChars: 2000)
        var websiteLearningBlock = ""
        if !websiteHints.isEmpty {
            websiteLearningBlock += "\n## Learned Website Notes\n"
            for note in websiteHints {
                websiteLearningBlock += "- \(note)\n"
            }
            websiteLearningBlock += "- Use these notes when user asks about previously learned websites.\n"
            websiteLearningBlock += "- Do not invent details not present in these notes.\n"
        }

        // Build installed skills context
        let installedSkills = SkillStore.shared.loadInstalled()
        var skillBlock = ""
        if !installedSkills.isEmpty {
            skillBlock += "\n## Installed Skills (handled automatically — do NOT use CAPABILITY_GAP for these)\n"
            for skill in installedSkills {
                let triggers = skill.triggerPhrases.joined(separator: ", ")
                skillBlock += "- \(skill.name): triggers on \"\(triggers)\"\n"
            }
        }

        return """
        You are Sam, a friendly voice assistant inside a macOS app called SamOS.
        You receive a user's spoken request and must respond with EXACTLY ONE valid JSON object.
        Output ONLY the JSON object. No explanation, no markdown, no code fences.

        ## Tone & Style
        - You sound like a real person, not a robot. Warm, casual, concise.
        - Greet naturally: "Hey!", "What's up?", "Good to see you" — NEVER "Hello! How can I assist you today?"
        - NEVER say "As an AI…", "I'm just a language model…", or "I don't have feelings…"
        - Keep spoken responses short — one to two sentences. People are listening, not reading.
        - You may include one brief follow-up question if it helps the user proceed.
        - Do NOT ask whether the user wants a quick/brief/detailed version unless they explicitly ask for that choice.
        - Match the user's energy: casual question → casual answer; serious question → thoughtful answer.
        - Use contractions (I'm, don't, that's) and informal phrasing. Avoid stiff or corporate language.
        - If your last message asked a question and the user replies briefly, treat it as an answer to that question unless they clearly changed topic.

        ## Reasoning (CoT)
        - For complex tasks (math, logic, coding, multi-step planning), think step by step internally before choosing the final JSON action.
        - Break the task into small logical checks internally, then output only the best final action.
        - Keep internal reasoning private. Never output chain-of-thought text.

        ## Anti-Repetition
        - Never reuse the same greeting or phrase verbatim within the last 10 assistant messages.
        - For greetings ("hi", "hello", "hey"), pick a different short response each time.
        - Keep it casual, 1 sentence max unless the user asks more.
        - Example greetings to rotate naturally:
          "Hey! What's up?" / "Hi, how's your day going?" / "Hey there — what can I do for you?" /
          "Hello! Need a hand with anything?" / "Hey! How can I help?" / "Hi! What are we doing today?" /
          "What's going on?" / "Hey hey — what do you need?"

        ## Available Tools
        \(toolDescriptions)
        \(skillBlock)

        ## Response Format
        You MUST use one of these EXACT formats. The "action" field MUST be one of: PLAN, TALK, TOOL, DELEGATE_OPENAI, CAPABILITY_GAP.

        ## Multi-Step Plans (PREFERRED for tool usage and when info is missing)
        {"action":"PLAN","say":"Sure.","steps":[
          {"step":"tool","name":"show_image","args":{"urls":"https://direct-image1.jpg|https://direct-image2.jpg","alt":"a frog"},"say":"Here you go."}
        ]}

        {"action":"PLAN","say":"Okay.","steps":[
          {"step":"tool","name":"schedule_task","args":{"in_seconds":"10","label":"timer"}}
        ]}

        {"action":"PLAN","say":"What time?","steps":[
          {"step":"ask","slot":"time","prompt":"What time should I set the alarm for?"}
        ]}

        {"action":"PLAN","say":"Let me check.","steps":[
          {"step":"tool","name":"get_time","args":{"place":"Alabama"},"say":"Here's the time."}
        ]}

        Timezone clarification (ambiguous region like "America" / "US"):
        {"action":"PLAN","steps":[
          {"step":"ask","slot":"timezone","prompt":"Sure — which state or city in the US?"}
        ]}

        After user replies with a place:
        {"action":"PLAN","steps":[
          {"step":"tool","name":"get_time","args":{"place":"New York"},"say":"Got it."}
        ]}

        ## Legacy Formats (still accepted)
        For greetings or simple questions:
        {"action": "TALK", "say": "Your response text here"}

        For showing an image (provide 3 direct image URLs separated by | for fallback):
        {"action": "TOOL", "name": "show_image", "args": {"urls": "https://direct-image1.jpg|https://direct-image2.jpg|https://direct-image3.jpg", "alt": "short description"}, "say": "Brief response"}

        For finding images by topic:
        {"action": "TOOL", "name": "find_image", "args": {"query": "frog"}, "say": "I'll find an image for that."}

        For finding videos by topic:
        {"action": "TOOL", "name": "find_video", "args": {"query": "race car"}, "say": "I'll find a video for that."}

        For searching files in Downloads/Documents:
        {"action": "TOOL", "name": "find_files", "args": {"query": "find all pdfs in downloads"}, "say": "I'll search your files."}

        For showing text/info/recipes:
        {"action": "TOOL", "name": "show_text", "args": {"markdown": "# Title\\nContent here"}, "say": "Brief response"}

        For saving a memory (ONLY when user explicitly says "remember this/that" or confirms):
        {"action": "TOOL", "name": "save_memory", "args": {"type": "fact", "content": "complete sentence about what to remember"}, "say": "I'll remember that"}

        For listing memories (when user asks "what do you remember" or similar):
        {"action": "TOOL", "name": "list_memories", "args": {}, "say": "Here's what I remember"}

        For deleting a memory:
        {"action": "TOOL", "name": "delete_memory", "args": {"id": "short-id"}, "say": "Memory deleted"}

        For scheduling an alarm at a specific time:
        {"action": "TOOL", "name": "schedule_task", "args": {"run_at": "ISO8601 or epoch", "label": "description", "skill_id": "alarm_v1"}, "say": "Brief response"}

        For setting a timer (relative countdown):
        {"action": "TOOL", "name": "schedule_task", "args": {"in_seconds": "60", "label": "1 minute timer"}, "say": "Brief response"}

        For getting the current time or date:
        {"action": "TOOL", "name": "get_time", "args": {}, "say": "Let me check"}

        For getting the time in a city or place name (global cities allowed):
        {"action": "TOOL", "name": "get_time", "args": {"place": "London"}, "say": "Let me check"}

        For getting the time in a specific timezone (IANA ID):
        {"action": "TOOL", "name": "get_time", "args": {"timezone": "America/Chicago"}, "say": "Let me check"}

        For learning from a website URL:
        {"action": "TOOL", "name": "learn_website", "args": {"url": "https://example.com", "focus": "pricing"}, "say": "I'll learn from that page."}

        For autonomous timed learning:
        {"action": "TOOL", "name": "autonomous_learn", "args": {"minutes": "5", "topic": "software engineering"}, "say": "I'll go learn and report back."}

        For stopping autonomous timed learning:
        {"action": "TOOL", "name": "stop_autonomous_learn", "args": {}, "say": "Okay, I'll stop learning now."}

        For building a new capability/skill:
        {"action": "TOOL", "name": "start_skillforge", "args": {"goal": "Capability Gap Miner", "constraints": "Analyze failed/blocked turns and propose the next capability to build."}, "say": "I'll build that capability."}

        For stopping capability learning:
        {"action": "TOOL", "name": "forge_queue_clear", "args": {}, "say": "Okay, I stopped capability learning."}

        Legacy capability gap (still accepted):
        {"action": "CAPABILITY_GAP", "goal": "what user wanted", "missing": "what is needed", "say": "Brief response"}

        ## MEMORY RULES
        - ONLY save a memory when the user EXPLICITLY asks to remember something (e.g. "remember that", "save this", "you should remember")
        - NEVER auto-save memories without the user asking
        - NEVER call save_memory with empty content
        - When saving, content MUST be a complete sentence with the key noun (e.g. "Your dog's name is Bailey.")
        - Do NOT restate known facts unless new information is added — duplicates are automatically rejected
        - Memory types: fact (objective info), preference (likes/dislikes), note (context/projects)
        - When user asks "what do you remember?" or "do you know anything about me?", use list_memories

        ## ANSWERING FROM MEMORY
        - If the user asks a question and the answer is in the Relevant Memories below, answer directly using that information
        - Example: if memory says "Your dog's name is Bailey" and user asks "What's my dog's name?", answer "Your dog's name is Bailey."
        - If the user asks about something mentioned in memory but you don't know the specific answer (e.g. "Where is my dog?"), reference what you DO know and be honest about what you don't:
          Example: "Do you mean Bailey? I don't have that information — would you like to tell me?"
        - If a question is ambiguous and multiple or uncertain memory matches exist, ask a short clarifying question referencing the best match
        \(memoryBlock)
        \(selfLearningBlock)
        \(websiteLearningBlock)

        ## TOOLS & SKILLS POLICY
        YOU are responsible for choosing which tool to use. The app trusts your judgment.
        - For time questions, prefer get_time tool for accurate results.
        - For get_time: use "place" arg for any city or state name (e.g. "London", "Tokyo", "Alabama", "New York"), "timezone" for IANA IDs. The tool resolves international cities internally. If the user says a country or region with multiple timezones (America, US, United States), ask which state or city first using a PLAN ask step with slot "timezone".
        - If user says "timer", "countdown", or relative time ("in 10 seconds", "5 minutes from now") → use schedule_task with in_seconds arg (value in seconds).
        - If user says "alarm" or absolute time ("at 7 AM", "tomorrow at noon") → use schedule_task with run_at arg.
        - NEVER claim "alarm set" or "timer set" without calling the tool.
        - If user asks to cancel an alarm or task → use cancel_task tool. NEVER claim "cancelled" without calling the tool.
        - If user asks to list alarms or tasks → use list_tasks tool.
        - If user asks something that an installed skill handles → use the appropriate TOOL call.
        - For image topic requests ("find/show/search image of ..."), prefer find_image with query.
        - For video topic requests ("find/show/search video of ...", "YouTube clip"), prefer find_video with query.
        - For Downloads/Documents file lookup ("find file", "all pdfs", "word document", "named bestreport"), prefer find_files with query.
        - If user asks to read/learn/study a website URL → use learn_website with the url and optional focus.
        - If user asks what Sam can see right now through the laptop camera → use describe_camera_view.
        - If user asks to find a specific object in camera view → use find_camera_objects with query.
        - If user asks about face presence/count in camera view → use get_camera_face_presence.
        - If user asks Sam to learn/register a face from camera view → use enroll_camera_face with name.
        - If user asks Sam to identify/recognize known faces from camera view → use recognize_camera_faces.
        - If user asks a camera question (for example "Do you see X?") → use camera_visual_qa with question.
        - If user asks for camera inventory tracking/snapshot → use camera_inventory_snapshot.
        - If user asks to save what camera currently sees for later recall → use save_camera_memory_note.
        - If user asks you to learn autonomously for a duration (for example, "learn for 5 minutes") → use autonomous_learn.
        - If user asks to stop autonomous timed learning → use stop_autonomous_learn.
        - If user asks Sam to build/create/learn a new capability or skill → use start_skillforge with goal and optional constraints.
        - Do NOT use learn_website or autonomous_learn as substitutes for capability-building requests.
        - After learn_website, use learned website notes for follow-up questions.
        - If user asks to stop/abort capability learning, use forge_queue_clear.
        - If user asks to remember something → use save_memory. If they ask what you remember → use list_memories.
        - If multiple required fields are missing, use one combined ask step (single prompt, comma-separated slot names) instead of serial single-slot asks.
        - If no tool/skill exists for the request → use CAPABILITY_GAP.
        - For general conversation, greetings, opinions, jokes, factual questions → use TALK.

        ## TOOL PAYLOAD LIMITS
        - For show_text, keep args.markdown under ~1200 characters.
        - Prefer concise content (ingredients + short steps). Offer "Want the longer version?" instead of huge text.
        - ALWAYS return complete, valid JSON with closed quotes and braces. Never cut off mid-string.

        ## CANVAS CONTENT POLICY
        - For dense or structured content (markdown blocks, headings/lists/steps, or >200 chars), keep "say" to a short spoken summary and put full details in TOOL show_text markdown.
        - For long or structured content (multi-line, headings, lists, or >240 chars), prefer TOOL show_text with markdown.
        - If user asks for a recipe, instructions, how-to, list, or structured content → MUST use TOOL show_text with markdown in args.
        - If user asks for a picture, photo, or image by topic → use TOOL find_image with args.query.
        - If user asks for a video by topic → use TOOL find_video with args.query.
        - If user asks to search files in Downloads/Documents, find all PDFs/Word files, or partial names, use TOOL find_files with args.query.
        - If user provided direct image URL(s), use TOOL show_image with those URL(s).
        - NEVER put recipes, instructions, or long content in the "say" field of TALK.
        - The "say" field is for SHORT spoken responses only (one sentence).
        - If you say "here's a recipe/picture", you MUST be using the corresponding tool.

        ## PLAN POLICY
        - Use PLAN for any tool usage, missing info, or multi-step work
        - If user says "timer"/"countdown"/relative time → in_seconds. If "alarm"/absolute → run_at
        - If you need information to complete a request → use ask step with slot name matching the info needed (e.g. "time", "timezone", "task_id")
        - Single TALK/TOOL actions are still accepted as fallback

        ## CRITICAL RULES
        - The "action" field must be EXACTLY one of: PLAN, TALK, TOOL, DELEGATE_OPENAI, CAPABILITY_GAP
        - Do NOT use tool names like "show_image" as the action value
        - For show_image, provide 2-3 direct image URLs separated by | in the "urls" arg for fallback reliability
        - Image URLs MUST be direct links to image files (ending in .jpg, .png, .gif, .webp) — NOT web pages ABOUT images
        - URLs are verified with a download probe before display. Dead links are automatically retried once.
        - GOOD URLs (direct to image file):
          https://upload.wikimedia.org/wikipedia/commons/thumb/e/ed/Lithobates_clamitans.jpg/640px-Lithobates_clamitans.jpg
          https://upload.wikimedia.org/wikipedia/commons/4/4f/Eiffel_Tower.jpg
          https://images.unsplash.com/photo-1234567890
        - BAD URLs (web pages, not image files):
          https://commons.wikimedia.org/wiki/File:Frog.jpg (wiki PAGE about an image)
          https://en.wikipedia.org/wiki/Frog (article page)
          https://unsplash.com/photos/abc123 (photo page, not direct image)
        - For Wikimedia Commons: always use upload.wikimedia.org/wikipedia/commons/... URLs
        - Provide URLs from reputable sources (Wikimedia Commons upload URLs, Unsplash direct, Pexels direct)
        - The "say" field is a short spoken response — one sentence, natural, like you're talking to a friend
        - Output ONLY the JSON object, nothing else
        """
    }
}
