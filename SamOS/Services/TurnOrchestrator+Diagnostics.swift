import Foundation

// MARK: - Diagnostics, Model Selection & Fallback Plans

extension TurnOrchestrator {

    func originProvider(for provider: LLMProvider) -> MessageOriginProvider {
        MessageOriginProvider.from(llmProvider: provider)
    }

    func executionProvider(for provider: LLMProvider, hasToolExecution: Bool) -> MessageOriginProvider {
        if hasToolExecution { return .local }
        return originProvider(for: provider)
    }

    func applyRoutingAttribution(_ result: inout TurnResult,
                                         planProvider: LLMProvider? = nil,
                                         planRouterMs: Int? = nil) {
        let resolvedIntent = currentIntentClassification ?? lastIntentClassification
        result.intentProviderSelected = resolvedIntent?.provider ?? .rule
        result.intentRouterMsLocal = resolvedIntent?.intentRouterMsLocal
        result.intentRouterMsOpenAI = resolvedIntent?.intentRouterMsOpenAI
        result.planProviderSelected = planProvider ?? result.llmProvider
        if let planRouterMs {
            result.planRouterMs = planRouterMs
        } else if result.planRouterMs == nil {
            result.planRouterMs = result.routerMs
        }
    }

    func applyOriginMetadata(_ result: inout TurnResult) {
        applyRoutingAttribution(&result)
        for idx in result.appendedChat.indices where result.appendedChat[idx].role == .assistant {
            result.appendedChat[idx].llmProvider = result.llmProvider
            result.appendedChat[idx].originProvider = result.originProvider
            result.appendedChat[idx].executionProvider = result.executionProvider
            if result.appendedChat[idx].originReason == nil {
                result.appendedChat[idx].originReason = result.originReason
            }
        }
    }

    func routerLog(provider: String, reason: String, ms: Int, ok: Bool) {
        #if DEBUG
        print("[ROUTER] provider=\(provider) reason=\(reason) ms=\(ms) ok=\(ok)")
        #endif
    }

    func classifyOllamaFailure(_ error: Error) -> (kind: String, reasonCount: Int, detail: String) {
        if error is RouterTimeout {
            return ("timeout", 0, "exceeded local-first deadline")
        }
        if let e = error as? OllamaRouter.OllamaError {
            switch e {
            case .jsonParseFailed(let raw):
                return ("json_parse", 0, String(raw.prefix(120)))
            case .schemaMismatch(_, let reasons):
                return ("schema", reasons.count, reasons.joined(separator: "; "))
            case .validationFailure(let f):
                return ("unknown_tool", 0, f.toolName)
            case .unreachable(let msg):
                return ("transport", 0, String(msg.prefix(120)))
            case .invalidResponse:
                return ("transport", 0, "invalid HTTP response")
            case .wireDeadlineExceeded(let wireMs, let deadlineMs):
                return ("timeout", 0, "wire deadline exceeded \(wireMs)ms > \(deadlineMs)ms")
            }
        }
        return ("unknown", 0, String(describing: error).prefix(120).description)
    }

    func isTimeoutLikeOpenAIError(_ error: Error) -> Bool {
        if error is RouterTimeout {
            return true
        }
        if let openAIError = error as? OpenAIRouter.OpenAIError {
            switch openAIError {
            case .requestFailed(let message):
                let lower = message.lowercased()
                return lower.contains("timed out")
                    || lower.contains("timeout")
                    || lower.contains("-1001")
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }
        let lower = error.localizedDescription.lowercased()
        return lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("-1001")
    }

    nonisolated static func hasNativeTool(for category: CapabilityRequestCategory) -> Bool {
        let candidateNames: [String]
        switch category {
        case .weather:
            candidateNames = ["get_weather", "weather"]
        case .news:
            let hasNewsToolPackage = ToolPackageStore.shared.isInstalled("news.basic")
            let hasNewsSkill = SkillStore.shared.getPackage(id: "news.latest")?.signoff?.approved == true
            let hasWebRead = PermissionScopeStore.shared.isApproved(PermissionScope.webRead.rawValue)
            return hasNewsToolPackage && hasNewsSkill && hasWebRead
        case .sportsScores:
            candidateNames = ["get_scores", "sports_scores"]
        case .time:
            candidateNames = ["get_time", "time"]
        case .otherWeb:
            candidateNames = []
        }
        guard !candidateNames.isEmpty else { return false }
        for candidate in candidateNames {
            guard let canonical = ToolRegistry.shared.normalizeToolName(candidate) else { continue }
            if ToolRegistry.shared.isAllowedTool(canonical) {
                return true
            }
        }
        return false
    }

    func logAffectClassification(raw: AffectMetadata,
                                         effective: AffectMetadata,
                                         featureEnabled: Bool,
                                         userToneEnabled: Bool) {
        #if DEBUG
        print(
            "[AFFECT] raw=\(raw.affect.rawValue):\(raw.clampedIntensity) " +
            "effective=\(effective.affect.rawValue):\(effective.clampedIntensity) " +
            "feature=\(featureEnabled) user_tone=\(userToneEnabled)"
        )
        DebugLogStore.shared.logAffect(
            turnID: TurnExecutionContext.turnID,
            raw: raw.affect.rawValue,
            effective: effective.affect.rawValue,
            intensity: effective.clampedIntensity,
            featureEnabled: featureEnabled,
            userToneEnabled: userToneEnabled
        )
        #endif
    }

    func logToneLearning(outcome: TonePreferenceLearningOutcome, profile: TonePreferenceProfile) {
        #if DEBUG
        print("[TONE_LEARN] reason=\(outcome.source).\(outcome.reason) delta=\(outcome.deltaSummary)")
        print(
            "[TONE_PROFILE] directness=\(formatToneValue(profile.directness)) " +
            "warmth=\(formatToneValue(profile.warmth)) humor=\(formatToneValue(profile.humor)) " +
            "curiosity=\(formatToneValue(profile.curiosity)) reassurance=\(formatToneValue(profile.reassurance)) " +
            "formality=\(formatToneValue(profile.formality)) hedging=\(formatToneValue(profile.hedging))"
        )
        DebugLogStore.shared.logToneProfile(
            turnID: TurnExecutionContext.turnID,
            reason: "\(outcome.source).\(outcome.reason)",
            delta: outcome.deltaSummary,
            directness: profile.directness,
            warmth: profile.warmth,
            humor: profile.humor,
            curiosity: profile.curiosity,
            reassurance: profile.reassurance,
            formality: profile.formality,
            hedging: profile.hedging
        )
        #endif
    }

    func formatToneValue(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    func normalizedSlotSet(from raw: String) -> Set<String> {
        let values = raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return Set(values)
    }

    func selectOpenAIModel(for input: String,
                                   reason: LLMCallReason,
                                   preferFallbackModel: Bool = false) -> String {
        if preferFallbackModel {
            return ollamaFallbackOpenAIModel
        }
        let general = OpenAISettings.generalModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackGeneral = general.isEmpty ? OpenAISettings.defaultPreferredModel : general
        let escalation = OpenAISettings.escalationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackEscalation = escalation.isEmpty ? fallbackGeneral : escalation
        guard shouldUseEscalationModel(for: input, reason: reason) else {
            return fallbackGeneral
        }
        return fallbackEscalation
    }

    func shouldFallbackToOpenAIForLikelyMiss(plan: Plan,
                                                      classification: IntentClassification?) -> Bool {
        guard M2Settings.useOllama, OpenAISettings.apiKeyStatus == .ready else { return false }

        if let classification {
            if classification.intent == .unknown { return true }
            if classification.confidence < 0.45 { return true }
        }

        guard let line = singleTalkLine(from: plan)?.lowercased() else { return false }
        let missMarkers = [
            "i don't know",
            "i dont know",
            "not sure",
            "cannot answer",
            "can't answer",
            "cannot find",
            "can't find",
            "rephrase that",
            "rephrase your question",
            "unable to answer",
            "i'm not able to",
            "i am not able to",
            "beyond my capabilities",
            "outside my knowledge",
            "i don't have access",
            "i can't help with that",
            "i'm unable to",
            "that's not something i can"
        ]
        return missMarkers.contains(where: { line.contains($0) })
    }

    func shouldUseEscalationModel(for input: String, reason: LLMCallReason) -> Bool {
        switch reason {
        case .alarmTriggered, .alarmRepeat, .snoozeExpired:
            return false
        default:
            break
        }

        if isMultiClauseRequest(input) { return true }
        if input.count > 120 { return true }

        let lower = input.lowercased()
        let complexityMarkers = [
            "step by step",
            "compare",
            "analyze",
            "analyse",
            "tradeoff",
            "pros and cons",
            "plan",
            "design",
            "architecture",
            "debug",
            "investigate",
            "why"
        ]
        if complexityMarkers.contains(where: { lower.contains($0) }) { return true }

        let sentenceBreaks = input.filter { $0 == "." || $0 == "?" || $0 == "!" }.count
        if sentenceBreaks >= 2 && input.count > 70 { return true }
        return false
    }

    func openAIRouteTimeoutSecondsFor(input: String, reason: LLMCallReason) -> Double {
        guard reason == .userChat else { return openAIRouteTimeoutSeconds }
        if isMultiClauseRequest(input) {
            return 6.8
        }
        if input.count > 120 {
            return 6.2
        }
        return openAIRouteTimeoutSeconds
    }

    func friendlyFallbackPlan(_ error: Error? = nil,
                                      userInput: String? = nil,
                                      pendingSlot: PendingSlot? = nil) -> Plan {
        if let deterministicPlan = deterministicTimerFallbackPlan(
            userInput: userInput,
            pendingSlot: pendingSlot
        ) {
            return deterministicPlan
        }

        let msg: String
        if let error, isTimeoutLikeOpenAIError(error) {
            msg = "Sorry — that took too long. Please try again."
        } else if let e = error as? OpenAIRouter.OpenAIError {
            switch e {
            case .notConfigured:
                msg = missingOpenAIKeyMessage()
            case .invalidAPIKey:
                msg = rejectedOpenAIKeyMessage(statusCode: OpenAISettings.authFailureStatusCode)
            case .badResponse(let code):
                if code == 401 || code == 403 {
                    OpenAISettings.markAPIKeyRejected(statusCode: code)
                    msg = rejectedOpenAIKeyMessage(statusCode: code)
                } else {
                    msg = "OpenAI returned an error (HTTP \(code)). Please try again."
                }
            case .validationFailure(let failure):
                switch failure.kind {
                case .unknownTool:
                    msg = "I can't pull that data yet. Can you share the source URL?"
                }
            case .requestFailed(let detail):
                if detail.lowercased().contains("timed out") || detail.lowercased().contains("-1001") {
                    msg = "Sorry — OpenAI timed out twice, so I used a local fallback. Please try again."
                } else {
                    msg = "I couldn't reach OpenAI. Check your connection and try again."
                }
            }
        } else {
            msg = "Sorry — I had trouble generating a response. Please try again."
        }
        #if DEBUG
        if let error = error {
            print("[ROUTER] fallback reason: \(error.localizedDescription)")
        }
        #endif
        return Plan(steps: [.talk(say: msg)])
    }

    func deterministicTimerFallbackPlan(userInput: String?,
                                                pendingSlot: PendingSlot?) -> Plan? {
        let text = (userInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        let pendingTimerName = pendingSlot?.slotName.lowercased() == "timer_name"
        let timerIntent =
            lower.contains("timer")
            || lower.contains("countdown")
            || isTimerDurationPhrase(lower)

        guard pendingTimerName || timerIntent else { return nil }

        return Plan(steps: [
            .tool(
                name: "timer.manage",
                args: ["text": .string(text)],
                say: "I'll handle that timer."
            )
        ])
    }

    func isTimerDurationPhrase(_ lowercasedText: String) -> Bool {
        let pattern = #"\b\d+(?:\.\d+)?\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b"#
        return lowercasedText.range(of: pattern, options: .regularExpression) != nil
    }

    func missingOpenAIKeyMessage() -> String {
        "OpenAI API key isn't set. Open SamOS Settings -> OpenAI and paste your key."
    }

    func rejectedOpenAIKeyMessage(statusCode: Int?) -> String {
        let statusText: String
        if let statusCode, statusCode == 401 || statusCode == 403 {
            statusText = "\(statusCode)"
        } else {
            statusText = "401/403"
        }
        return "OpenAI rejected the request (\(statusText)). Please check your API key in Settings -> OpenAI (it may be missing, invalid, expired, or revoked)."
    }

    // fallbackResult() removed — dead code; all error paths use friendlyFallbackPlan().
}
