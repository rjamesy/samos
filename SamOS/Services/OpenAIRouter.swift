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
                      responseData: Data?,
                      extraPayload: [String: Any]? = nil) {
        var payload: Any? = parsedPayload(from: responseData)
        if let extraPayload {
            if var dict = payload as? [String: Any] {
                for (key, value) in extraPayload {
                    dict[key] = value
                }
                payload = dict
            } else if let existingPayload = payload {
                payload = [
                    "response": existingPayload,
                    "meta": extraPayload
                ]
            } else {
                payload = extraPayload
            }
        }
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
            payload: payload
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

enum PromptToneInjector {
    private static let maxToneChars = 450

    static func makeToneBlock(profile: TonePreferenceProfile,
                              affect: AffectMetadata?,
                              toneRepairCue: String?) -> String {
        let normalized = normalizedProfile(profile)
        var lines: [String] = [
            "User tone preferences:",
            "- d=\(fmt(normalized.directness)) w=\(fmt(normalized.warmth)) c=\(fmt(normalized.curiosity)) r=\(fmt(normalized.reassurance)) h=\(fmt(normalized.humor)) f=\(fmt(normalized.formality)) g=\(fmt(normalized.hedging))",
            "- flags: cheerful_upset=\(flag(normalized.avoidCheerfulWhenUpset)) therapy=\(flag(normalized.avoidTherapyLanguage)) bullets=\(flag(normalized.preferBulletSteps)) short_opener=\(flag(normalized.preferShortOpeners)) one_q_max=\(flag(normalized.preferOneQuestionMax))",
        ]

        var prioritizedRules: [String] = []

        if let toneRepairCue, !toneRepairCue.isEmpty {
            prioritizedRules.append("- tone_repair_now=true: first sentence briefly acknowledges tone correction ('\(toneRepairCue)'), then stay practical and direct.")
        }
        if normalized.avoidCheerfulWhenUpset, let affect, affect.affect != .neutral {
            prioritizedRules.append("- non-neutral affect: avoid cheerful phrasing; keep tone grounded.")
        }
        if (affect?.affect == .frustrated) && normalized.warmth <= 0.40 {
            prioritizedRules.append("- frustrated+low warmth: brief validation then steps.")
        }
        if (affect?.affect == .anxious) && normalized.reassurance <= 0.40 {
            prioritizedRules.append("- anxious+low reassurance: stay calm and practical; avoid over-validation.")
        }
        if normalized.preferOneQuestionMax {
            prioritizedRules.append("- one_q_max=true: ask at most one question unless problem_report safety clarifiers are needed.")
        }
        if normalized.preferShortOpeners {
            prioritizedRules.append("- short_opener=true: keep any emotional opener to one brief sentence.")
        }
        prioritizedRules.append("- rules: therapy=on => no diagnosis/therapy language; high directness => shorter phrasing with fewer hedges; low curiosity => max 1 question unless problem_report; use bullets in show_text for steps.")

        for rule in prioritizedRules {
            let candidate = (lines + [rule]).joined(separator: "\n")
            guard candidate.count <= maxToneChars else { continue }
            lines.append(rule)
        }

        let compact = lines.joined(separator: "\n")
        if compact.count <= maxToneChars { return compact }
        return String(compact.prefix(maxToneChars - 3)) + "..."
    }

    private static func normalizedProfile(_ profile: TonePreferenceProfile) -> TonePreferenceProfile {
        var copy = profile
        copy.clampKnobs()
        return copy
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", min(1.0, max(0.0, value)))
    }

    private static func flag(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}

enum PromptBuilder {
    private static let maxPromptChars = 5600
    private static let websiteRetrievalThreshold = 0.23

    private static let cachedToolDescriptions: String = {
        let tools = ToolRegistry.shared.allTools.filter { $0.name != "capability_gap_to_claude_prompt" }
        return tools.prefix(30).map {
            "- \($0.name): \(compactDescription($0.description, maxChars: 88))"
        }.joined(separator: "\n")
    }()

    static func buildSystemPrompt(forInput input: String,
                                  promptContext: PromptRuntimeContext?,
                                  includeLongToolExamples: Bool) -> String {
        let installedSkills = SkillStore.shared.loadInstalled()
        let skillLines: [String]
        if installedSkills.isEmpty {
            skillLines = ["- (none)"]
        } else {
            skillLines = installedSkills.prefix(8).map { skill in
                let triggers = skill.triggerPhrases.prefix(2).joined(separator: ", ")
                return "- \(skill.name): triggers on \"\(triggers)\""
            }
        }

        // Keep local context deterministic and fast; runtime summary/state is injected separately.
        let memoryHintLines = ["- memory_hint: []"]
        let selfLessonLines = ["- self_learning: []"]

        let websiteHints = gatedWebsiteLearningContext(query: input, maxItems: includeLongToolExamples ? 10 : 6, maxChars: 1200)
        let websiteLines = websiteHints.isEmpty
            ? ["- website_learning: []"]
            : websiteHints.map { "- website_learning: \($0.replacingOccurrences(of: "\"", with: "'"))" }

        let modePolicy = dynamicModePolicy(promptContext?.mode)
        let identityPolicy = dynamicIdentityGuidance(promptContext?.identityContextLine)
        let summaryPolicy = compactSummary(promptContext?.sessionSummary ?? "")
        let affectPolicy = dynamicAffectGuidance(promptContext?.affect)
        let tonePolicy = promptContext?.tonePreferences.flatMap { profile -> String? in
            guard profile.enabled else { return nil }
            return PromptToneInjector.makeToneBlock(
                profile: profile,
                affect: promptContext?.affect,
                toneRepairCue: promptContext?.toneRepairCue
            )
        }
        let budgetDirective: String
        if promptContext?.responseBudget != nil {
            budgetDirective = """
            - Token budget target:
              chat default 120-350; problem_report 250-600; technical deep 500-1000.
            - Keep TALK.say under 200 chars when possible.
            - If detail exceeds ~240 chars, use PLAN with short talk + show_text.
            """
        } else {
            budgetDirective = """
            - Token budget target: chat 120-350.
            - Keep TALK.say concise and use show_text for long detail.
            """
        }

        let toolExampleBlock: String
        if includeLongToolExamples {
            toolExampleBlock = """
            {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"London"},"say":"Let me check."}]}
            {"action":"PLAN","steps":[{"step":"ask","slot":"timezone","prompt":"Which state or city in the US?"}]}
            {"action":"TOOL","name":"find_image","args":{"query":"frog"},"say":"I'll find an image for that."}
            {"action":"TOOL","name":"show_text","args":{"markdown":"# Title\\n- point"},"say":"Here it is."}
            """
        } else {
            toolExampleBlock = """
            {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"London"},"say":"Let me check."}]}
            {"action":"TALK","say":"Hey! What's up?"}
            """
        }

        let coreSystem = """
        [BLOCK 1: CORE_JSON_CONTRACT]
        Return EXACTLY ONE valid JSON object and nothing else.
        The "action" field MUST be one of: PLAN, TALK, TOOL, DELEGATE_OPENAI, CAPABILITY_GAP.
        think step by step internally before choosing the final JSON action, but never reveal chain-of-thought.
        Never output markdown or prose outside JSON.
        """

        let systemIdentityAndModeBlock = """
        [BLOCK 2: SYSTEM_IDENTITY_AND_MODE]
        You are Sam, a friendly voice assistant inside a macOS app called SamOS.
        \(modePolicy)
        \(identityPolicy)
        - Warm, casual, clear language. Use contractions.
        - Default: medium response length in chat.
        - Chat target: 120-350 tokens for most replies.
        - Problem reports: 250-600 tokens with structure.
        - Technical deep explanations: 500-1000 tokens and prefer show_text.
        - Keep spoken "say" short. If content is >240 chars or structured, return PLAN with:
          1) talk step (short summary)
          2) tool step show_text with markdown details.
        - Ask one follow-up question by default, except problem reports where 2-4 clarifying questions in one turn are allowed.
        \(budgetDirective)
        - If prior assistant turn asked a question and the user replies briefly, treat that as the answer unless topic clearly changes.
        """

        let conversationSummaryBlock = """
        [BLOCK 3: CONVERSATION_SUMMARY]
        \(summaryPolicy)
        """

        let affectBlock = """
        [BLOCK 4: AFFECT_GUIDANCE]
        \(affectPolicy)
        """

        let toneBlock: String? = tonePolicy.map { body in
            """
            [BLOCK 5: TONE_PREFERENCES]
            \(body)
            """
        }

        let toolPolicy = """
        [BLOCK 6: TOOL_POLICY]
        Available tools:
        \(cachedToolDescriptions)
        Tool rules:
        - Weather/forecast -> get_weather.
        - Time/date/timezone -> get_time.
        - Timer/countdown/relative time -> schedule_task with in_seconds.
        - Alarm/absolute time -> schedule_task with run_at.
        - URL learn/read requests -> learn_website.
        - Video lookup -> find_video.
        - File lookup in Downloads/Documents -> find_files.
        - Never claim alarm set/cancelled without the tool call.
        - Use PLAN for tool work or missing information.
        - If multiple fields are missing, ask once with combined slot names.
        Examples:
        \(toolExampleBlock)
        """

        let installedSkillsBlock = """
        [BLOCK 7: INSTALLED_SKILLS]
        Installed skills (matched automatically, not tool names):
        \(skillLines.joined(separator: "\n"))
        """

        let historyRetrievalBlock = """
        [BLOCK 8: HISTORY_RETRIEVAL]
        \(memoryHintLines.joined(separator: "\n"))
        \(selfLessonLines.joined(separator: "\n"))
        \(websiteLines.joined(separator: "\n"))
        - Use website notes only when relevant to the user query. Do not invent details.
        """

        var blocks = [coreSystem, systemIdentityAndModeBlock, conversationSummaryBlock, affectBlock]
        if let toneBlock {
            blocks.append(toneBlock)
        }
        blocks.append(toolPolicy)
        blocks.append(installedSkillsBlock)
        blocks.append(historyRetrievalBlock)

        return cappedPrompt(
            blocks: blocks,
            maxChars: maxPromptChars
        )
    }

    static func dynamicModePolicy(_ mode: ConversationMode?) -> String {
        guard let mode else {
            return "- No special mode policy. Continue with normal medium-length assistance."
        }
        guard mode.intent == .problemReport else {
            return "- Intent=\(mode.intent.rawValue), domain=\(mode.domain.rawValue), urgency=\(mode.urgency.rawValue). Keep response practical and concise."
        }

        var lines: [String] = [
            "- Intent is problem_report. Use this playbook in one message:",
            "  1) one short empathy sentence",
            "  2) ask 2-4 targeted clarifying questions together",
            "  3) offer 1-3 safe immediate next steps",
            "  4) add red flags when urgency is medium/high or domain has safety risk",
            "  5) end with one next-step question: quick checks now or deeper troubleshooting"
        ]

        switch mode.domain {
        case .health:
            lines.append("- Health clarifiers: onset, location, severity 1-10, vomiting/fever/diarrhea/blood, hydration.")
            lines.append("- Health red flags: severe/worsening pain, blood/black stools, persistent vomiting, fainting, rigid abdomen.")
        case .vehicle:
            lines.append("- Vehicle clarifiers: when it happens (idle/accel), warning lights, overheating/smoke, recent oil/service.")
            lines.append("- Vehicle red flags: oil pressure light, overheating, smoke/fuel smell, loud knocking, loss of power; advise stop driving/tow.")
        case .tech:
            lines.append("- Tech clarifiers: exact error text, when started, recent changes, device/network details.")
            lines.append("- Tech red flags: data loss or security compromise.")
        default:
            lines.append("- Use domain-agnostic clarifiers focused on timeline, severity, triggers, and constraints.")
        }

        if mode.domain == .health && mode.urgency == .high {
            lines.append("- If severe/worsening or red flags, seek urgent care.")
        }

        return lines.joined(separator: "\n")
    }

    static func dynamicIdentityGuidance(_ identityLine: String?) -> String {
        guard let identityLine = identityLine?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identityLine.isEmpty else {
            return "- Identity context: none."
        }

        return """
        - Identity context: \(identityLine)
        - Always answer the user's request first.
        - If identity follow-up is needed, ask once at the end.
        """
    }

    static func dynamicAffectGuidance(_ affect: AffectMetadata?) -> String {
        let metadata = affect ?? .neutral
        var lines: [String] = [
            "- Affect=\(metadata.affect.rawValue), intensity=\(metadata.clampedIntensity)."
        ]

        switch metadata.affect {
        case .neutral:
            lines.append("- Keep responses direct and solution-focused.")
        case .frustrated:
            lines.append("- Acknowledge briefly, validate frustration, then pivot to actionable steps.")
        case .anxious:
            lines.append("- Be calming and steady.")
            lines.append("- Avoid alarmist language.")
            lines.append("- Ask safety clarifiers when relevant.")
        case .sad:
            lines.append("- Be warm and gentle.")
            lines.append("- Offer a choice: talk briefly or move into practical steps.")
        case .angry:
            lines.append("- Acknowledge intensity without matching it.")
            lines.append("- De-escalate and redirect to concrete next actions.")
        case .excited:
            lines.append("- Match positive energy.")
            lines.append("- Maintain momentum and clarity.")
        }

        lines.append("- Emotional acknowledgement: max 1 sentence.")
        lines.append("- Never assume motives.")
        lines.append("- Never over-psychologize or diagnose.")
        lines.append("- If user mentions panic attack, suicidal, or hopeless language: offer a gentle disclaimer and suggest professional help; only urgent-emergency escalation if immediate danger is stated.")
        lines.append("- Always continue with task logic, clarifiers, and practical next steps.")
        return lines.joined(separator: "\n")
    }

    private static func compactSummary(_ summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "- (none)" }
        if trimmed.count <= 700 { return trimmed }
        return String(trimmed.prefix(697)) + "..."
    }

    static func gatedWebsiteLearningContext(query: String, maxItems: Int, maxChars: Int) -> [String] {
        let lowerQuery = query.lowercased()
        let explicitReference = queryHasExplicitWebsiteReference(lowerQuery)
        if !explicitReference && !shouldAttemptWebsiteRetrieval(lowerQuery) {
            return []
        }

        let records = WebsiteLearningStore.shared.allRecords()
        guard !records.isEmpty else { return [] }

        let candidateRecords: [WebsiteLearningRecord]
        if explicitReference {
            let mentionedHost = hostMention(in: lowerQuery)
            if let mentionedHost {
                let hostMatches = records.filter { record in
                    record.host.lowercased() == mentionedHost || mentionedHost.hasSuffix(record.host.lowercased())
                }
                candidateRecords = hostMatches.isEmpty ? Array(records.prefix(40)) : Array(hostMatches.prefix(40))
            } else {
                candidateRecords = Array(records.prefix(40))
            }
        } else {
            let queryTokens = retrievalTokens(from: lowerQuery)
            guard !queryTokens.isEmpty else { return [] }
            let filtered = records.filter { record in
                let haystack = "\(record.host) \(record.title) \(record.summary)".lowercased()
                return queryTokens.contains(where: { haystack.contains($0) })
            }
            guard !filtered.isEmpty else { return [] }
            candidateRecords = Array(filtered.prefix(48))
        }

        let ranked = LocalKnowledgeRetriever.rank(
            query: query,
            items: candidateRecords,
            text: { record in
                "\(record.title) \(record.summary) \(record.host)"
            },
            recencyDate: { $0.updatedAt },
            limit: max(6, maxItems * 4),
            minScore: 0.08
        )

        if !explicitReference {
            guard let top = ranked.first,
                  top.finalScore >= websiteRetrievalThreshold,
                  top.sharedTokenCount >= 1 else {
                return []
            }
        }

        var output: [String] = []
        var usedChars = 0
        for entry in ranked.prefix(max(1, maxItems)) {
            let record = entry.item
            let line = "[web \(record.host)] \(record.title): \(record.summary)"
            let clipped = line.count > 320 ? String(line.prefix(317)) + "..." : line
            if output.isEmpty {
                guard clipped.count <= maxChars else { continue }
            } else if usedChars + clipped.count > maxChars {
                break
            }
            output.append(clipped)
            usedChars += clipped.count
        }
        return output
    }

    private static func queryHasExplicitWebsiteReference(_ lowerQuery: String) -> Bool {
        if lowerQuery.contains("learned website")
            || lowerQuery.contains("that site")
            || lowerQuery.contains("learned url")
            || lowerQuery.contains("website note")
            || lowerQuery.contains("from that page")
            || lowerQuery.range(of: #"https?://\S+"#, options: .regularExpression) != nil {
            return true
        }
        let hostPattern = #"\b([a-z0-9-]+\.)+[a-z]{2,}\b"#
        return lowerQuery.range(of: hostPattern, options: .regularExpression) != nil
    }

    private static func shouldAttemptWebsiteRetrieval(_ lowerQuery: String) -> Bool {
        let trimmed = lowerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let greetingTokens = ["hi", "hello", "hey", "yo", "sup", "how are you", "good morning", "good evening"]
        if greetingTokens.contains(where: { trimmed == $0 || trimmed.hasPrefix("\($0) ") }) {
            return false
        }

        let problemSignals = [
            "don't feel", "do not feel", "tummy", "stomach", "pain", "sore", "engine", "car", "wifi", "internet",
            "network", "headache", "fever", "vomit", "accident", "noise", "not working"
        ]
        if problemSignals.contains(where: { trimmed.contains($0) }) {
            return false
        }

        let queryTokens = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        if queryTokens < 4 {
            return false
        }

        return true
    }

    private static func retrievalTokens(from lowerQuery: String) -> [String] {
        Array(Set(lowerQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 }))
    }

    private static func hostMention(in lowerQuery: String) -> String? {
        let pattern = #"([a-z0-9-]+\.)+[a-z]{2,}"#
        guard let range = lowerQuery.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(lowerQuery[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactDescription(_ raw: String, maxChars: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "tool" }
        let first = trimmed.components(separatedBy: ". ").first ?? trimmed
        if first.count <= maxChars { return first }
        return String(first.prefix(maxChars - 3)) + "..."
    }

    private static func cappedPrompt(blocks: [String], maxChars: Int) -> String {
        var assembled = blocks.joined(separator: "\n\n")
        if assembled.count <= maxChars {
            return assembled
        }

        // First trim history/retrieval block aggressively.
        var mutable = blocks
        if let idx = mutable.firstIndex(where: { $0.contains("HISTORY_RETRIEVAL]") }) {
            mutable[idx] = "[BLOCK 8: HISTORY_RETRIEVAL]\n- memory_hint: []\n- self_learning: []\n- website_learning: []"
        }
        assembled = mutable.joined(separator: "\n\n")
        if assembled.count <= maxChars {
            return assembled
        }

        // Then trim tool block examples only.
        if let idx = mutable.firstIndex(where: { $0.contains("TOOL_POLICY]") }) {
            mutable[idx] = """
            [BLOCK 6: TOOL_POLICY]
            Use available tools exactly by name.
            Prefer PLAN for tool work and missing fields.
            Weather -> get_weather; time -> get_time; URL learning -> learn_website; long detail -> show_text.
            """
        }
        assembled = mutable.joined(separator: "\n\n")
        if assembled.count <= maxChars {
            return assembled
        }

        // Then trim installed skills and conversation summary.
        if let idx = mutable.firstIndex(where: { $0.contains("INSTALLED_SKILLS]") }) {
            mutable[idx] = "[BLOCK 7: INSTALLED_SKILLS]\n- (none)"
        }
        if let idx = mutable.firstIndex(where: { $0.contains("CONVERSATION_SUMMARY]") }) {
            mutable[idx] = "[BLOCK 3: CONVERSATION_SUMMARY]\n- (summary omitted for budget)"
        }
        assembled = mutable.joined(separator: "\n\n")
        if assembled.count <= maxChars {
            return assembled
        }

        // Preserve mandatory blocks in budget-constrained fallback.
        let requiredMarkers = [
            "CORE_JSON_CONTRACT]",
            "SYSTEM_IDENTITY_AND_MODE]",
            "AFFECT_GUIDANCE]",
            "TONE_PREFERENCES]",
            "TOOL_POLICY]"
        ]
        let required = mutable.filter { block in
            requiredMarkers.contains(where: { block.contains($0) })
        }
        if !required.isEmpty {
            let requiredOnly = required.joined(separator: "\n\n")
            if requiredOnly.count <= maxChars {
                return requiredOnly
            }
            return String(requiredOnly.prefix(maxChars))
        }

        return String(assembled.prefix(maxChars))
    }
}

/// Abstraction over the OpenAI HTTP API so tests can inject a fake.
protocol OpenAITransport {
    func chat(messages: [[String: String]], model: String, maxOutputTokens: Int?) async throws -> String
}

/// Real transport that hits the OpenAI /v1/chat/completions endpoint.
struct RealOpenAITransport: OpenAITransport {

    private static var didLogStartup = false
    private static let requestTimeoutSeconds: TimeInterval = 8

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
                "slots": ["type": "array", "items": ["type": "string"]],
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

    func chat(messages: [[String: String]], model: String, maxOutputTokens: Int?) async throws -> String {
        OpenAISettings.preloadAPIKey()
        OpenAISettings.clearInvalidatedAPIKeyIfNeeded()
        let apiKey: String
        switch OpenAISettings.apiKeyStatus {
        case .ready:
            apiKey = OpenAISettings.apiKey
        case .missing:
            OpenAIAPILogStore.shared.logBlockedRequest(
                service: "OpenAIRouter.chat",
                endpoint: "https://api.openai.com/v1/chat/completions",
                method: "POST",
                model: model,
                reason: "OpenAI API key missing",
                payload: [
                    "message_count": messages.count,
                    "authorization_header_present": false
                ]
            )
            throw OpenAIRouter.OpenAIError.notConfigured
        case .invalid:
            let statusCode = OpenAISettings.authFailureStatusCode
            OpenAIAPILogStore.shared.logBlockedRequest(
                service: "OpenAIRouter.chat",
                endpoint: "https://api.openai.com/v1/chat/completions",
                method: "POST",
                model: model,
                reason: "OpenAI API key rejected",
                payload: [
                    "message_count": messages.count,
                    "last_auth_failure_status": statusCode as Any,
                    "auth_error_code": statusCode as Any,
                    "authorization_header_present": false
                ]
            )
            throw OpenAIRouter.OpenAIError.invalidAPIKey
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

        let cappedTokens = min(1_200, max(120, maxOutputTokens ?? Self.adaptiveMaxTokens(for: messages)))
        let requestBody: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.4,
            "max_tokens": cappedTokens,
            "response_format": Self.responseFormat
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let authHeaderPresent = (request.value(forHTTPHeaderField: "Authorization")?.isEmpty == false)
        #if DEBUG
        print("[OpenAIRouter] Authorization header present: \(authHeaderPresent)")
        #endif
        let requestID = OpenAIAPILogStore.shared.logHTTPRequest(
            service: "OpenAIRouter.chat",
            endpoint: url.absoluteString,
            method: "POST",
            model: model,
            timeoutSeconds: request.timeoutInterval,
            payload: [
                "request": requestBody,
                "authorization_header_present": authHeaderPresent
            ]
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
                if http.statusCode == 401 || http.statusCode == 403 {
                    OpenAISettings.markAPIKeyRejected(statusCode: http.statusCode)
                }
                OpenAIAPILogStore.shared.logHTTPError(
                    requestID: requestID,
                    service: "OpenAIRouter.chat",
                    endpoint: url.absoluteString,
                    method: "POST",
                    model: model,
                    statusCode: http.statusCode,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                    error: "HTTP \(http.statusCode)",
                    responseData: responseData,
                    extraPayload: [
                        "auth_error_code": http.statusCode,
                        "authorization_header_present": authHeaderPresent
                    ]
                )
                loggedTerminal = true
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw OpenAIRouter.OpenAIError.invalidAPIKey
                }
                throw OpenAIRouter.OpenAIError.badResponse(http.statusCode)
            }
            OpenAISettings.clearInvalidatedAPIKeyIfNeeded()
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
                    responseData: nil,
                    extraPayload: [
                        "auth_error_code": OpenAISettings.authFailureStatusCode as Any,
                        "authorization_header_present": authHeaderPresent
                    ]
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
                responseData: nil,
                extraPayload: [
                    "auth_error_code": OpenAISettings.authFailureStatusCode as Any,
                    "authorization_header_present": authHeaderPresent
                ]
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

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            OpenAIAPILogStore.shared.logHTTPError(
                requestID: requestID,
                service: "OpenAIRouter.chat",
                endpoint: url.absoluteString,
                method: "POST",
                model: model,
                statusCode: nil,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: "OpenAI returned empty content",
                responseData: data
            )
            throw OpenAIRouter.OpenAIError.requestFailed("OpenAI returned empty content")
        }

        return trimmed
    }

    private static func adaptiveMaxTokens(for messages: [[String: String]]) -> Int {
        if let forced = explicitMaxOutputTokens(in: messages) {
            return max(120, min(1400, forced))
        }
        let userText = messages.last(where: { ($0["role"] ?? "").lowercased() == "user" })?["content"] ?? ""
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 768 }

        let lower = trimmed.lowercased()
        let wordCount = lower.split(whereSeparator: \.isWhitespace).count
        let sentenceCount = max(1, lower.split(separator: ".").count)
        let complexityMarkers = [
            "step by step", "detailed", "explain", "why", "how", "analyze",
            "compare", "implement", "architecture", "debug", "code", "plan", "walk me through"
        ]
        let markerHits = complexityMarkers.reduce(0) { partial, marker in
            partial + (lower.contains(marker) ? 1 : 0)
        }

        if lower.contains("\n") || lower.contains("```") {
            return 1400
        }
        if trimmed.count > 300 || wordCount > 55 || markerHits >= 2 || sentenceCount >= 4 {
            return 1100
        }
        if markerHits == 1 || trimmed.count > 140 || wordCount > 24 {
            return 700
        }
        if trimmed.count < 50 && wordCount <= 8 {
            return 220
        }
        return 500
    }

    private static func explicitMaxOutputTokens(in messages: [[String: String]]) -> Int? {
        for message in messages.reversed() {
            guard message["role"] == "system",
                  let content = message["content"] else { continue }
            guard content.contains("max_output_tokens=") else { continue }
            let suffix = content.components(separatedBy: "max_output_tokens=").last ?? ""
            let digits = suffix.prefix { $0.isNumber }
            if let value = Int(digits) {
                return value
            }
        }
        return nil
    }
}

// MARK: - OpenAI Router

/// Routes user input through OpenAI to produce PLAN JSON.
/// Reuses OllamaRouter's message-building and parsing infrastructure.
final class OpenAIRouter {

    enum OpenAIError: Error, LocalizedError {
        case notConfigured
        case invalidAPIKey
        case requestFailed(String)
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OpenAI API key not configured"
            case .invalidAPIKey:
                if let code = OpenAISettings.authFailureStatusCode {
                    return "OpenAI rejected request (HTTP \(code))"
                }
                return "OpenAI rejected request (HTTP 401/403)"
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
                   alarmContext: AlarmContext? = nil,
                   promptContext: PromptRuntimeContext? = nil,
                   modelOverride: String? = nil) async throws -> Plan {
        let routeModel = normalizedRouteModel(modelOverride)
        OpenAISettings.preloadAPIKey()
        OpenAISettings.clearInvalidatedAPIKeyIfNeeded()
        switch OpenAISettings.apiKeyStatus {
        case .ready:
            break
        case .missing:
            OpenAIAPILogStore.shared.logBlockedRequest(
                service: "OpenAIRouter.routePlan",
                endpoint: "https://api.openai.com/v1/chat/completions",
                method: "POST",
                model: routeModel,
                reason: "OpenAI API key missing",
                payload: [
                    "input_preview": String(input.prefix(160)),
                    "authorization_header_present": false
                ]
            )
            throw OpenAIError.notConfigured
        case .invalid:
            let statusCode = OpenAISettings.authFailureStatusCode
            OpenAIAPILogStore.shared.logBlockedRequest(
                service: "OpenAIRouter.routePlan",
                endpoint: "https://api.openai.com/v1/chat/completions",
                method: "POST",
                model: routeModel,
                reason: "OpenAI API key rejected",
                payload: [
                    "input_preview": String(input.prefix(160)),
                    "last_auth_failure_status": statusCode as Any,
                    "auth_error_code": statusCode as Any,
                    "authorization_header_present": false
                ]
            )
            throw OpenAIError.invalidAPIKey
        }

        let systemPrompt = buildLightSystemPrompt(forInput: input, promptContext: promptContext)
        var messages = parser.buildMessages(input: input, history: history,
                                            systemPrompt: systemPrompt,
                                            pendingSlot: pendingSlot,
                                            alarmContext: alarmContext,
                                            promptContext: promptContext)
        parser.appendRepairBlock(to: &messages, repairReasons: repairReasons, rawSnippet: repairRawSnippet)

        let responseText = try await transport.chat(
            messages: messages,
            model: routeModel,
            maxOutputTokens: promptContext?.responseBudget.maxOutputTokens
        )

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
                        alarmContext: alarmContext,
                        promptContext: promptContext,
                        modelOverride: routeModel
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
            let parseFailureReason = debugParseFailureReason(from: error)

            // Stage 1: normalize args (string→object) and retry decode (existing)
            if let data = trimmed.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let normalized = parser.normalizeActionJSON(dict)
                if let normalizedData = try? JSONSerialization.data(withJSONObject: normalized),
                   let action = try? JSONDecoder().decode(Action.self, from: normalizedData) {
                    #if DEBUG
                    print("[OpenAIRouter] Salvaged via normalizeActionJSON")
                    debugLogParseSalvage(
                        stage: "normalizeActionJSON",
                        reason: parseFailureReason,
                        raw: trimmed
                    )
                    #endif
                    let guarded = enforcePostParseGuardrails(Plan.fromAction(action), userInput: input)
                    if shouldRepairUnexpectedCapabilityEscalation(guarded, userInput: input) {
                        return talkOnlyFallbackForUnexpectedCapabilityEscalation(plan: guarded, userInput: input)
                    }
                    return guarded
                }
            }

            // Stage 2: show_text / markdown extraction
            if trimmed.contains("\"show_text\"")
                || trimmed.contains("\"markdown\"")
                || trimmed.contains("\"text\"") {
                if let markdown = extractMarkdownContent(trimmed) {
                    #if DEBUG
                    print("[OpenAIRouter] Salvaged as show_text")
                    debugLogParseSalvage(
                        stage: "show_text_extract",
                        reason: parseFailureReason,
                        raw: trimmed
                    )
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
                debugLogParseSalvage(
                    stage: "raw_markdown_wrap",
                    reason: parseFailureReason,
                    raw: trimmed
                )
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
                    debugLogParseSalvage(
                        stage: "show_image_extract",
                        reason: parseFailureReason,
                        raw: trimmed
                    )
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
                debugLogParseFailure(
                    reason: parseFailureReason,
                    raw: trimmed
                )
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

    private func normalizedRouteModel(_ override: String?) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? OpenAISettings.generalModel : trimmed
    }

    // MARK: - Light System Prompt

    /// Shorter system prompt for OpenAI.
    private func buildLightSystemPrompt(forInput input: String, promptContext: PromptRuntimeContext?) -> String {
        PromptBuilder.buildSystemPrompt(
            forInput: input,
            promptContext: promptContext,
            includeLongToolExamples: false
        )
    }

    private func compactToolDescription(_ raw: String, maxChars: Int = 130) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No description." }
        let firstSentence = trimmed.components(separatedBy: ". ").first ?? trimmed
        if firstSentence.count <= maxChars { return firstSentence }
        return String(firstSentence.prefix(maxChars - 3)) + "..."
    }

    private func fastMemoryHints(for input: String, maxItems: Int, maxChars: Int) -> [MemoryRow] {
        MemoryStore.shared.memoryContext(
            query: input,
            maxItems: max(1, maxItems),
            maxChars: max(120, maxChars)
        )
    }

    private func relevantSkillPromptEntries(for input: String, limit: Int) -> [SkillSpec] {
        let installed = SkillStore.shared.loadInstalled()
        guard !installed.isEmpty else { return [] }

        var seen: Set<String> = []
        var deduped: [SkillSpec] = []
        for skill in installed {
            let triggerKey = skill.triggerPhrases
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .sorted()
                .joined(separator: "|")
            let key = "\(skill.name.lowercased())#\(triggerKey)"
            if seen.insert(key).inserted {
                deduped.append(skill)
            }
        }

        let cappedLimit = max(1, min(limit, 12))
        let ranked = LocalKnowledgeRetriever.rank(
            query: input,
            items: deduped,
            text: { skill in
                "\(skill.name) \(skill.triggerPhrases.joined(separator: " "))"
            },
            limit: cappedLimit,
            minScore: 0.10
        ).map(\.item)

        if ranked.count >= cappedLimit {
            return Array(ranked.prefix(cappedLimit))
        }

        var output = ranked
        for skill in deduped where output.count < cappedLimit {
            if !output.contains(where: { $0.id == skill.id }) {
                output.append(skill)
            }
        }
        return output
    }

    // MARK: - Tool Choice Guardrails

    private func enforcePostParseGuardrails(_ plan: Plan, userInput: String) -> Plan {
        let weatherGuarded = enforceToolChoiceGuardrails(plan, userInput: userInput)
        let recipeGuarded = enforceRecipeToolChoiceGuardrails(weatherGuarded, userInput: userInput)
        let videoGuarded = enforceVideoToolChoiceGuardrails(recipeGuarded, userInput: userInput)
        return enforceCapabilityLearningGuardrails(videoGuarded, userInput: userInput)
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

    private func enforceRecipeToolChoiceGuardrails(_ plan: Plan, userInput: String) -> Plan {
        guard isRecipeQuery(userInput) else { return plan }
        if planContainsTool(plan, named: "find_recipe") || planContainsTool(plan, named: "show_text") {
            return plan
        }

        let hasCapabilityGapDelegate = plan.steps.contains { step in
            if case .delegate(let task, _, _) = step {
                return task.lowercased().hasPrefix("capability_gap:")
            }
            return false
        }

        let hasRefusalTalk = plan.steps.contains { step in
            if case .talk(let say) = step {
                return isRefusalTalk(say)
            }
            return false
        }

        let hasAnyToolStep = plan.steps.contains { step in
            if case .tool = step { return true }
            return false
        }

        guard hasCapabilityGapDelegate || hasRefusalTalk || !hasAnyToolStep else { return plan }

        let query = recipeQuery(from: userInput)
        var steps: [PlanStep] = []
        if isImageRequest(userInput) {
            steps.append(.tool(name: "find_image", args: ["query": .string(query)], say: nil))
        }
        steps.append(.tool(name: "find_recipe", args: ["query": .string(query)], say: nil))
        return Plan(steps: steps, say: plan.say)
    }

    private func enforceVideoToolChoiceGuardrails(_ plan: Plan, userInput: String) -> Plan {
        guard isVideoQuery(userInput) else { return plan }
        if planContainsTool(plan, named: "find_video") { return plan }

        let hasCapabilityGapDelegate = plan.steps.contains { step in
            if case .delegate(let task, _, _) = step {
                return task.lowercased().hasPrefix("capability_gap:")
            }
            return false
        }

        let hasRefusalTalk = plan.steps.contains { step in
            if case .talk(let say) = step {
                return isRefusalTalk(say)
            }
            return false
        }

        let hasAnyToolStep = plan.steps.contains { step in
            if case .tool = step { return true }
            return false
        }

        guard hasCapabilityGapDelegate || hasRefusalTalk || !hasAnyToolStep else { return plan }

        let query = videoQuery(from: userInput)
        return Plan(steps: [
            .tool(name: "find_video", args: ["query": .string(query)], say: nil)
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

    private func isRecipeQuery(_ input: String) -> Bool {
        let lower = input.lowercased()
        let keywords = [
            "recipe", "ingredients", "how to make", "how do i make", "cook", "cooking",
            "bake", "baking", "instructions", "directions", "meal"
        ]
        return keywords.contains { lower.contains($0) }
    }

    private func isImageRequest(_ input: String) -> Bool {
        let lower = input.lowercased()
        let keywords = ["image", "picture", "photo", "show me", "what it looks like"]
        return keywords.contains { lower.contains($0) }
    }

    private func isVideoQuery(_ input: String) -> Bool {
        let lower = input.lowercased()
        let keywords = ["video", "youtube", "clip", "watch"]
        return keywords.contains { lower.contains($0) }
    }

    private func isRefusalTalk(_ say: String) -> Bool {
        let lower = say.lowercased()
        let phrases = [
            "can't", "cannot", "couldn't", "unable", "not able", "don't have",
            "cannot do", "can't find recipes", "can't find recipe"
        ]
        return phrases.contains { lower.contains($0) }
    }

    private func recipeQuery(from input: String) -> String {
        var query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)\b(find|show|get)\s+(me\s+)?(a\s+)?recipe\s+for\s+"#,
            #"(?i)\brecipe\s+for\s+"#,
            #"(?i)\bhow\s+to\s+make\s+"#,
            #"(?i)\bhow\s+do\s+i\s+make\s+"#
        ]
        for pattern in patterns {
            query = query.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        query = query.replacingOccurrences(
            of: #"(?i)\s+(and|&)\s+(show|find|get).*$"#,
            with: "",
            options: .regularExpression
        )
        query = query.replacingOccurrences(of: #"(?i)\s+(image|picture|photo).*$"#, with: "", options: .regularExpression)
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? input.trimmingCharacters(in: .whitespacesAndNewlines) : query
    }

    private func videoQuery(from input: String) -> String {
        var query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)\b(find|show|get|play|watch|search)\s+(me\s+)?(another\s+)?(a\s+)?video\s+(of|about|for)\s+"#,
            #"(?i)\banother\s+video\s+(of|about|for)\s+"#,
            #"(?i)\bvideo\s+(of|about|for)\s+"#,
            #"(?i)\bon\s+youtube\s*"#
        ]
        for pattern in patterns {
            query = query.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? input.trimmingCharacters(in: .whitespacesAndNewlines) : query
    }

    private func isCapabilityLearningRequest(_ input: String) -> Bool {
        let lower = input.lowercased()
        if isTimedAutonomousLearningRequest(lower) { return false }

        let explicitCapabilityPatterns = [
            #"\blearn\s+(a\s+)?(new\s+)?capabilit(y|ies)\b"#,
            #"\b(build|create|develop|implement|forge)\s+(a\s+)?(new\s+)?capabilit(y|ies)\b"#,
            #"\blearn\s+(a\s+)?(new\s+)?skill(s)?\b"#,
            #"\b(build|create|develop|implement|forge|install)\s+(a\s+)?(new\s+)?skill(s)?\b"#,
            #"\bcapability\s+gap\b"#
        ]
        for pattern in explicitCapabilityPatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }

        if inputContainsURL(lower) {
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

    private func talkOnlyFallbackForUnexpectedCapabilityEscalation(plan: Plan, userInput: String) -> Plan {
        let talk = plan.steps.compactMap { step -> String? in
            if case .talk(let say) = step {
                let trimmed = say.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }.first

        if let talk {
            return Plan(steps: [.talk(say: talk)])
        }

        if inputContainsURL(userInput) {
            return Plan(steps: [.talk(say: "I'm not sure yet. If you want, I can read that URL and summarize what I find.")])
        }
        return Plan(steps: [.talk(say: "I'm not sure how to help with that yet — can you try rephrasing?")])
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
        if let md = dict["text"] as? String, !md.isEmpty { return md }
        if let md = dict["content"] as? String, !md.isEmpty { return md }

        // Nested in args: {"name":"show_text","args":{"markdown":"..."}}
        if let args = dict["args"] as? [String: Any] {
            if let md = args["markdown"] as? String, !md.isEmpty { return md }
            if let md = args["text"] as? String, !md.isEmpty { return md }
            if let md = args["content"] as? String, !md.isEmpty { return md }
        }

        // In PLAN steps: {"action":"PLAN","steps":[{"name":"show_text","args":{"markdown":"..."}}]}
        if let steps = dict["steps"] as? [[String: Any]] {
            for step in steps {
                let stepName = (step["name"] as? String ?? "").lowercased()
                let stepType = (step["step"] as? String ?? "").lowercased()
                let isShowText = stepName == "show_text" || stepType == "show_text"
                if isShowText, let args = step["args"] as? [String: Any] {
                    if let md = args["markdown"] as? String, !md.isEmpty { return md }
                    if let md = args["text"] as? String, !md.isEmpty { return md }
                    if let md = args["content"] as? String, !md.isEmpty { return md }
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

    private func debugParseFailureReason(from error: Error) -> String {
        if let ollamaError = error as? OllamaRouter.OllamaError {
            switch ollamaError {
            case .schemaMismatch(_, let reasons):
                return reasons.joined(separator: " | ")
            case .jsonParseFailed:
                return "json_parse_failed"
            case .invalidResponse:
                return "invalid_response"
            case .unreachable(let msg):
                return "unreachable: \(msg)"
            }
        }
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .keyNotFound(let key, _):
                return "missing_key:\(key.stringValue)"
            case .typeMismatch(_, let context):
                return "type_mismatch:\(context.debugDescription)"
            case .valueNotFound(_, let context):
                return "missing_value:\(context.debugDescription)"
            case .dataCorrupted(let context):
                return "data_corrupted:\(context.debugDescription)"
            @unknown default:
                return "decoding_error"
            }
        }
        return error.localizedDescription
    }

    private func debugLogParseFailure(reason: String, raw: String) {
        #if DEBUG
        let snippet = raw.replacingOccurrences(of: "\n", with: " ")
        print("[OpenAIRouter][debug] parse_failed_reason=\(reason) raw_json_prefix=\(snippet.prefix(120))")
        #endif
    }

    private func debugLogParseSalvage(stage: String, reason: String, raw: String) {
        #if DEBUG
        let snippet = raw.replacingOccurrences(of: "\n", with: " ")
        print("[OpenAIRouter][debug] salvage_stage=\(stage) parse_failed_reason=\(reason) raw_json_prefix=\(snippet.prefix(120))")
        #endif
    }
}
