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
    func chat(messages: [[String: String]], maxOutputTokens: Int?) async throws -> String
}

/// Real transport that hits the Ollama /api/chat endpoint.
struct RealOllamaTransport: OllamaTransport {
    static let inferenceOptions: [String: Any] = [
        "temperature": 0.1,
        "top_p": 0.9,
        "num_predict": 256
    ]

    private static var didLogStartup = false

    func chat(messages: [[String: String]], maxOutputTokens: Int?) async throws -> String {
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

        let adaptive = Self.adaptiveNumPredict(for: messages)
        let numPredict = min(1200, max(120, maxOutputTokens ?? adaptive))
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
        if let forced = explicitMaxOutputTokens(in: messages) {
            return max(120, min(1200, forced))
        }
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

    private static func explicitMaxOutputTokens(in messages: [[String: String]]) -> Int? {
        for message in messages.reversed() {
            guard message["role"] == "system",
                  let content = message["content"] else { continue }
            guard content.contains("max_output_tokens=") else { continue }
            let parts = content.components(separatedBy: "max_output_tokens=")
            guard let suffix = parts.last else { continue }
            let digits = suffix.prefix { $0.isNumber }
            guard let value = Int(digits) else { continue }
            return value
        }
        return nil
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
        let systemPrompt = buildSystemPrompt(forInput: input, promptContext: nil)
        var messages = buildMessages(input: input, history: history, systemPrompt: systemPrompt, pendingSlot: nil, promptContext: nil)
        appendRepairBlock(to: &messages, repairReasons: repairReasons)

        let responseText = try await transport.chat(messages: messages, maxOutputTokens: nil)
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
                   alarmContext: AlarmContext? = nil,
                   promptContext: PromptRuntimeContext? = nil) async throws -> Plan {
        let systemPrompt = buildSystemPrompt(forInput: input, promptContext: promptContext)
        var messages = buildMessages(input: input, history: history, systemPrompt: systemPrompt,
                                     pendingSlot: pendingSlot, alarmContext: alarmContext, promptContext: promptContext)
        appendRepairBlock(to: &messages, repairReasons: repairReasons, rawSnippet: repairRawSnippet)

        let responseText = try await transport.chat(
            messages: messages,
            maxOutputTokens: promptContext?.responseBudget.maxOutputTokens
        )
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
                                       alarmContext: alarmContext,
                                       promptContext: promptContext)
        } catch OllamaError.jsonParseFailed(let raw) where repairReasons == nil {
            // First attempt returned unparseable text — retry once with repair context
            #if DEBUG
            print("[OllamaRouter] JSON parse failed, repair retry: \(raw.prefix(80))")
            #endif
            return try await routePlan(input, history: history,
                                       pendingSlot: pendingSlot,
                                       repairReasons: ["Your response was not valid JSON. Output ONLY a JSON object."],
                                       repairRawSnippet: raw,
                                       alarmContext: alarmContext,
                                       promptContext: promptContext)
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
                       pendingSlot: PendingSlot?, alarmContext: AlarmContext? = nil,
                       promptContext: PromptRuntimeContext? = nil) -> [[String: String]] {
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]

        let historyWindow = 10
        let nonSystem = history.filter { $0.role != .system }
        if nonSystem.count > historyWindow {
            let older = Array(nonSystem.dropLast(historyWindow))
            let summary = promptContext?.sessionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (promptContext?.sessionSummary ?? "")
                : summarizeConversation(older)
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

        if let context = promptContext {
            let modeLine = """
            [MODE]
            {"intent":"\(context.mode.intent.rawValue)","domain":"\(context.mode.domain.rawValue)","urgency":"\(context.mode.urgency.rawValue)","needs_clarification":\(context.mode.needsClarification),"user_goal_hint":"\(context.mode.userGoalHint.rawValue)"}
            """
            messages.append(["role": "system", "content": modeLine])

            let stateLine = """
            [INTERACTION_STATE]
            \(context.interactionStateJSON)
            """
            messages.append(["role": "system", "content": stateLine])

            messages.append([
                "role": "system",
                "content": "[RESPONSE_BUDGET] max_output_tokens=\(context.responseBudget.maxOutputTokens)"
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
                let toolNames = Set(ToolRegistry.shared.allTools.map { $0.name.lowercased() })
                let malformed = steps.compactMap { $0 as? [String: Any] }.filter { step in
                    let hasStepType = step["step"] != nil || step["type"] != nil
                    guard !hasStepType else { return false }
                    guard let name = step["name"] as? String else { return true }
                    return !canNormalizeMissingStepWithName(name, toolNames: toolNames)
                }
                if !malformed.isEmpty {
                    throw OllamaError.schemaMismatch(raw: jsonString, reasons: [
                        "Each PLAN step object must include either \"step\" (or \"type\") OR a known tool \"name\" key."
                    ])
                }
            }

            let normalized = normalizeActionJSON(dict)
            let strictReasons = strictPlanSchemaViolations(normalized)
            if !strictReasons.isEmpty {
                throw OllamaError.schemaMismatch(raw: jsonString, reasons: strictReasons)
            }
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

        let toolNames = Set(ToolRegistry.shared.allTools.map { $0.name.lowercased() })
        let allowedStepTypes = Set(["talk", "tool", "ask", "delegate"])
        if let action = (dict["action"] as? String)?.uppercased(),
           action == "PLAN",
           let steps = dict["steps"] as? [[String: Any]] {
            var reasons: [String] = []
            for (index, step) in steps.enumerated() {
                let rawStep = normalizeToken(step["step"] as? String ?? step["type"] as? String ?? "")
                let rawName = normalizeToken(step["name"] as? String ?? "")
                var inferredStepType = rawStep
                var inferredToolName = rawName

                if inferredStepType.isEmpty {
                    if rawName.isEmpty {
                        reasons.append("missing step type at steps[\(index)]")
                        continue
                    }
                    if canNormalizeMissingStepWithName(rawName, toolNames: toolNames) {
                        inferredStepType = "tool"
                        inferredToolName = rawName
                    } else {
                        reasons.append("missing step type at steps[\(index)]")
                        continue
                    }
                }

                if inferredStepType != "tool" && !allowedStepTypes.contains(inferredStepType) {
                    if canNormalizeStepAliasToTool(inferredStepType) {
                        let aliasToolName = inferredStepType
                        inferredStepType = "tool"
                        if inferredToolName.isEmpty {
                            inferredToolName = aliasToolName
                        }
                    } else {
                        reasons.append("bad step type '\(inferredStepType)' at steps[\(index)]")
                        continue
                    }
                }

                if inferredStepType == "tool" {
                    if inferredToolName.isEmpty {
                        if canNormalizeStepAliasToTool(rawStep) {
                            inferredToolName = rawStep
                        } else {
                            reasons.append("missing tool name at steps[\(index)]")
                            continue
                        }
                    }
                    if !isKnownToolName(inferredToolName, toolNames: toolNames) {
                        reasons.append("unknown tool '\(inferredToolName)' at steps[\(index)]")
                        continue
                    }
                }

                if inferredToolName == "show_text" {
                    guard let args = step["args"] as? [String: Any] else {
                        reasons.append("bad args key at steps[\(index)] for show_text")
                        continue
                    }
                    let hasMarkdown = !(args["markdown"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let hasText = !(args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let hasContent = !(args["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if hasText && !hasMarkdown {
                        reasons.append("bad args key 'text' at steps[\(index)] for show_text (expected 'markdown')")
                    } else if hasContent && !hasMarkdown {
                        reasons.append("bad args key 'content' at steps[\(index)] for show_text (expected 'markdown')")
                    } else if !hasMarkdown && !hasText && !hasContent {
                        reasons.append("missing args.markdown at steps[\(index)] for show_text")
                    }
                }
            }
            if !reasons.isEmpty { return reasons }
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

    private func strictPlanSchemaViolations(_ dict: [String: Any]) -> [String] {
        guard let action = (dict["action"] as? String)?.uppercased(),
              action == "PLAN",
              let steps = dict["steps"] as? [[String: Any]] else {
            return []
        }

        let toolNames = Set(ToolRegistry.shared.allTools.map { $0.name.lowercased() })
        var reasons: [String] = []
        for (index, step) in steps.enumerated() {
            let stepType = normalizeToken(step["step"] as? String ?? step["type"] as? String ?? "")
            let name = normalizeToken(step["name"] as? String ?? "")

            if stepType == "tool" {
                if name.isEmpty {
                    reasons.append("missing tool name at steps[\(index)]")
                } else if !isKnownToolName(name, toolNames: toolNames) {
                    reasons.append("unknown tool '\(name)' at steps[\(index)]")
                }
                continue
            }

            if stepType.isEmpty && !name.isEmpty && !canNormalizeMissingStepWithName(name, toolNames: toolNames) {
                reasons.append("unknown tool '\(name)' at steps[\(index)]")
                continue
            }

            if !stepType.isEmpty && !Set(["talk", "ask", "delegate", "tool"]).contains(stepType) {
                if canNormalizeStepAliasToTool(stepType) {
                    if !isKnownToolName(stepType, toolNames: toolNames) {
                        reasons.append("unknown tool '\(stepType)' at steps[\(index)]")
                    }
                } else {
                    reasons.append("bad step type '\(stepType)' at steps[\(index)]")
                }
            }
        }
        return reasons
    }

    private func canNormalizeMissingStepWithName(_ name: String, toolNames: Set<String>) -> Bool {
        isKnownToolName(name, toolNames: toolNames)
    }

    private func canNormalizeStepAliasToTool(_ stepType: String) -> Bool {
        Self.planStepToolAliasAllowlist.contains(normalizeToken(stepType))
    }

    private func isKnownToolName(_ name: String, toolNames: Set<String>) -> Bool {
        let normalized = normalizeToken(name)
        guard !normalized.isEmpty else { return false }
        return toolNames.contains(normalized) || Self.planStepToolAliasAllowlist.contains(normalized)
    }

    private func normalizeToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    /// Narrow allowlist for alias-style PLAN step normalization.
    /// Prevents over-salvaging arbitrary step values into tool calls.
    private static let planStepToolAliasAllowlist: Set<String> = [
        "show_text",
        "show_image",
        "get_time",
        "get_weather",
        "find_recipe",
        "find_video",
        "find_image",
        "find_files",
        "learn_website"
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
        let toolNames = Set(ToolRegistry.shared.allTools.map { $0.name.lowercased() })
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
            if var args = dict["args"] as? [String: Any] {
                args = normalizeToolArgs(name: toolName, args: args)
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

        if (dict["action"] as? String ?? "").uppercased() == "TOOL",
           let name = (dict["name"] as? String)?.lowercased(),
           var args = dict["args"] as? [String: Any] {
            args = normalizeToolArgs(name: name, args: args)
            dict["args"] = args
        }

        // Case 4: Normalize PLAN step objects (common model schema drift).
        if (dict["action"] as? String ?? "").uppercased() == "PLAN",
           let steps = dict["steps"] as? [[String: Any]] {
            dict["steps"] = steps.map { normalizePlanStepJSON($0, toolNames: toolNames) }
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

    private func normalizePlanStepJSON(_ input: [String: Any], toolNames: Set<String>) -> [String: Any] {
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

        if step["step"] == nil,
           let name = step["name"] as? String,
           canNormalizeMissingStepWithName(name, toolNames: toolNames) {
            step["step"] = "tool"
        }

        let rawStepType = normalizeToken(step["step"] as? String ?? "")
        if canNormalizeStepAliasToTool(rawStepType) {
            if step["name"] == nil {
                step["name"] = rawStepType
            }
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

        if normalizedType == "tool",
           let name = (step["name"] as? String)?.lowercased(),
           var args = step["args"] as? [String: Any] {
            args = normalizeToolArgs(name: name, args: args)
            step["args"] = args
        }

        return step
    }

    private func normalizeToolArgs(name: String, args: [String: Any]) -> [String: Any] {
        var normalized = args
        if name == "show_text" {
            let markdown = (normalized["markdown"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if markdown.isEmpty {
                if let text = normalized["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    normalized["markdown"] = text
                } else if let content = normalized["content"] as? String,
                          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    normalized["markdown"] = content
                }
            }
        }
        return normalized
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

    private func buildSystemPrompt(forInput input: String, promptContext: PromptRuntimeContext?) -> String {
        PromptBuilder.buildSystemPrompt(
            forInput: input,
            promptContext: promptContext,
            includeLongToolExamples: true
        )
    }
}
