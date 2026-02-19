import Foundation

@MainActor
final class TurnRouter: TurnRouting {
    typealias IntentClassificationHandler = @Sendable (IntentClassifierInput, Bool, Bool) async -> IntentClassificationResult
    typealias PlanRouteHandler = @Sendable (TurnPlanRouteRequest) async -> RouteDecision
    typealias CombinedRouteHandler = @Sendable (TurnCombinedRouteRequest) async -> CombinedRouteDecision
    typealias NativeToolExistsHandler = @Sendable (CapabilityRequestCategory) -> Bool
    typealias NormalizeToolNameHandler = @Sendable (String) -> String?
    typealias IsAllowedToolHandler = @Sendable (String) -> Bool

    private let classifyIntentHandler: IntentClassificationHandler
    private let routePlanHandler: PlanRouteHandler
    private let routeCombinedHandler: CombinedRouteHandler
    private let nativeToolExistsHandler: NativeToolExistsHandler
    private let normalizeToolNameHandler: NormalizeToolNameHandler
    private let isAllowedToolHandler: IsAllowedToolHandler

    private let needsWebClarifyingPrompt =
        "What location or source should I check for that live update?"
    private let needsWebSourcePrompt =
        "I still need the exact URL or site for that request. Share it and I'll use it."

    init(classifyIntent: @escaping IntentClassificationHandler,
         routePlan: @escaping PlanRouteHandler,
         routeCombined: CombinedRouteHandler? = nil,
         nativeToolExists: @escaping NativeToolExistsHandler = { _ in false },
         normalizeToolName: @escaping NormalizeToolNameHandler = { _ in nil },
         isAllowedTool: @escaping IsAllowedToolHandler = { _ in false }) {
        self.classifyIntentHandler = classifyIntent
        self.routePlanHandler = routePlan
        if let routeCombined {
            self.routeCombinedHandler = routeCombined
        } else {
            self.routeCombinedHandler = { request in
                let input = IntentClassifierInput(
                    userText: request.text,
                    cameraRunning: request.state.cameraRunning,
                    faceKnown: request.state.faceKnown,
                    pendingSlot: request.state.pendingSlot,
                    lastAssistantLine: request.state.lastAssistantLine
                )
                let classification = await classifyIntent(input, true, true)
                let routed = await routePlan(
                    TurnPlanRouteRequest(
                        text: request.text,
                        history: request.history,
                        pendingSlot: request.pendingSlot,
                        reason: request.reason,
                        promptContext: request.promptContext,
                        intentClassification: classification.classification
                    )
                )
                return CombinedRouteDecision(
                    classification: classification,
                    route: routed,
                    localAttempted: classification.attemptedLocal,
                    localOutcome: classification.escalationReason,
                    localMs: classification.intentRouterMsLocal,
                    openAIMs: classification.intentRouterMsOpenAI
                )
            }
        }
        self.nativeToolExistsHandler = nativeToolExists
        self.normalizeToolNameHandler = normalizeToolName
        self.isAllowedToolHandler = isAllowedTool
    }

    func classifyIntent(_ input: IntentClassifierInput,
                        policy: IntentRoutePolicy) async -> IntentClassificationResult {
        await classifyIntentHandler(input, policy.localFirst, policy.openAIFallback)
    }

    func routePlan(_ request: TurnPlanRouteRequest) async -> RouteDecision {
        let routed = await routePlanHandler(request)
        let normalized = normalizedRouteDecision(routed)
        return applyNeedsWebContract(
            normalized,
            requestText: request.text,
            classification: request.intentClassification
        )
    }

    func routeCombined(_ request: TurnCombinedRouteRequest) async -> CombinedRouteDecision {
        let combined = await routeCombinedHandler(request)
        let normalized = normalizedRouteDecision(combined.route)
        let contracted = applyNeedsWebContract(
            normalized,
            requestText: request.text,
            classification: combined.classification.classification
        )
        return CombinedRouteDecision(
            classification: combined.classification,
            route: contracted,
            localAttempted: combined.localAttempted,
            localOutcome: combined.localOutcome,
            localMs: combined.localMs,
            openAIMs: combined.openAIMs
        )
    }

    func evaluatePendingSlot(_ pendingSlot: PendingSlot?,
                             pendingCapabilityRequest: PendingCapabilityRequest?,
                             now: Date) -> PendingSlotEvaluation {
        guard let slot = pendingSlot else {
            return PendingSlotEvaluation(
                pendingSlot: nil,
                pendingCapabilityRequest: pendingCapabilityRequest,
                action: .none
            )
        }

        if slot.isExpired {
            return PendingSlotEvaluation(
                pendingSlot: nil,
                pendingCapabilityRequest: clearedCapabilityIfExternalSource(pendingCapabilityRequest),
                action: .none
            )
        }

        if slot.attempts >= 3 {
            return PendingSlotEvaluation(
                pendingSlot: nil,
                pendingCapabilityRequest: clearedCapabilityIfExternalSource(pendingCapabilityRequest),
                action: .retryExhausted(message: "I'm not getting it — can you rephrase?")
            )
        }

        return PendingSlotEvaluation(
            pendingSlot: slot,
            pendingCapabilityRequest: pendingCapabilityRequest,
            action: .continueWithSlot(slot)
        )
    }

    func resolvePendingSlotAfterPlan(_ plan: Plan,
                                     previousSlot: PendingSlot?,
                                     pendingCapabilityRequest: PendingCapabilityRequest?) -> PendingSlotResolution {
        guard var slot = previousSlot else {
            return PendingSlotResolution(
                pendingSlot: nil,
                pendingCapabilityRequest: pendingCapabilityRequest
            )
        }

        let hasRepeatAsk = plan.steps.contains { step in
            if case .ask(let stepSlot, _) = step,
               !normalizedSlotSet(from: stepSlot).isDisjoint(with: normalizedSlotSet(from: slot.slotName)) {
                return true
            }
            return false
        }

        if hasRepeatAsk {
            slot.attempts += 1
            return PendingSlotResolution(
                pendingSlot: slot,
                pendingCapabilityRequest: pendingCapabilityRequest
            )
        }

        let shouldClearCapability = normalizedSlotSet(from: slot.slotName).contains("source_url_or_site")
            && pendingCapabilityRequest?.kind == .externalSource

        return PendingSlotResolution(
            pendingSlot: nil,
            pendingCapabilityRequest: shouldClearCapability ? nil : pendingCapabilityRequest
        )
    }

    func shouldEnterExternalSourceCapabilityGapFlow(_ input: CapabilityGapRouteInput) -> Bool {
        guard input.pendingCapabilityRequest == nil else { return false }
        guard input.pendingSlot == nil else { return false }
        let text = input.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard extractFirstURL(from: text) == nil else { return false }
        guard input.classification.intent == .webRequest else { return false }
        guard input.provider == .rule else { return false }
        guard input.classification.confidence >= input.confidenceThreshold else { return false }

        let category = categoryForCapabilityRequest(text: text, classification: input.classification)
        if category == .news {
            return false
        }
        let hasNativeTool = nativeToolExistsHandler(category)
        return !hasNativeTool
    }

    func resolvePendingCapabilityInput(_ input: PendingCapabilityInput) -> PendingCapabilityResolution {
        guard let pending = input.pendingRequest else { return .none }
        guard pending.kind == .externalSource else { return .none }

        let trimmed = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        if let url = extractFirstURL(from: trimmed) {
            let focus = pending.prefersWebsiteURL
                ? "How to find showtimes/listings and location filters"
                : "How to retrieve the requested information from this source"
            let memoryContent = pending.prefersWebsiteURL
                ? "Cinema listings source: \(url)"
                : "Capability source: \(url)"
            let successMessage = pending.prefersWebsiteURL
                ? "Got it - I've learned that page. I can run start_skillforge next to build a cinema listings skill. Want me to build it?"
                : "Got it - I learned that source. I can run start_skillforge to build this capability next. Want me to build it?"

            return .learnSource(
                url: url,
                focus: focus,
                memoryContent: memoryContent,
                successMessage: successMessage
            )
        }

        if pending.reminderCount == 0 {
            let prompt = pending.prefersWebsiteURL
                ? "I still need the exact URL for the listings page (for example, the Event Cinemas page). Paste that link and I'll learn it."
                : "I still need a source URL/app/site for that request. Share one and I'll learn it."

            var updatedRequest = pending
            updatedRequest.lastAskedAt = input.now
            updatedRequest.reminderCount = 1

            let slot = PendingSlot(
                slotName: "source_url_or_site",
                prompt: prompt,
                originalUserText: pending.originalUserGoal
            )
            return .askForSource(
                prompt: prompt,
                pendingSlot: slot,
                updatedRequest: updatedRequest
            )
        }

        let message = pending.prefersWebsiteURL
            ? "No worries. When you have the exact URL, paste it and I'll learn it."
            : "No worries. When you have a source URL/app/site, share it and I'll learn it."
        return .drop(message: message)
    }

    private func normalizedSlotSet(from raw: String) -> Set<String> {
        Set(raw
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        )
    }

    private func clearedCapabilityIfExternalSource(_ request: PendingCapabilityRequest?) -> PendingCapabilityRequest? {
        guard request?.kind == .externalSource else { return request }
        return nil
    }

    private func extractFirstURL(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s]+"#, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let urlRange = Range(match.range, in: text) else {
            return nil
        }
        var candidate = String(text[urlRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = candidate.last,
              [".", ",", ")", "]", "!", "?", ";", ":"].contains(String(last)) {
            candidate.removeLast()
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host?.isEmpty == false else {
            return nil
        }
        return candidate
    }

    private func categoryForCapabilityRequest(text: String,
                                              classification: IntentClassification) -> CapabilityRequestCategory {
        if isLikelyWeatherQuery(text) {
            return .weather
        }
        if isLikelyTimeQuery(text) {
            return .time
        }

        if classification.needsWeb {
            let lower = text.lowercased()
            if lower.contains("breaking news")
                || lower.contains("latest news")
                || lower.hasPrefix("news")
                || lower.contains(" news ") {
                return .news
            }
            if lower.contains("score") || lower.contains("scores") || lower.contains("standings") {
                return .sportsScores
            }
        }

        return .otherWeb
    }

    private func isLikelyWeatherQuery(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "weather",
            "forecast",
            "temperature",
            "rain",
            "raining",
            "humidity",
            "wind",
            "storm",
            "sunny",
            "cloudy"
        ]
        return markers.contains { lower.contains($0) }
    }

    private func isLikelyTimeQuery(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "what time",
            "time in",
            "current time",
            "time is it"
        ]
        return markers.contains { lower.contains($0) }
    }

    private func normalizedRouteDecision(_ decision: RouteDecision) -> RouteDecision {
        var normalizedSteps: [PlanStep] = []
        normalizedSteps.reserveCapacity(decision.plan.steps.count)

        for step in decision.plan.steps {
            switch step {
            case .tool(let name, let args, let say):
                let canonical = normalizeToolNameHandler(name) ?? name
                normalizedSteps.append(.tool(name: canonical, args: args, say: say))
            default:
                normalizedSteps.append(step)
            }
        }

        return RouteDecision(
            plan: Plan(steps: normalizedSteps, say: decision.plan.say),
            provider: decision.provider,
            routerMs: decision.routerMs,
            aiModelUsed: decision.aiModelUsed,
            routeReason: decision.routeReason,
            planLocalWireMs: decision.planLocalWireMs,
            planLocalTotalMs: decision.planLocalTotalMs,
            planOpenAIMs: decision.planOpenAIMs
        )
    }

    private func hasAllowedToolPlan(_ plan: Plan) -> Bool {
        let toolNames = plan.steps.compactMap { step -> String? in
            guard case .tool(let name, _, _) = step else { return nil }
            return normalizeToolNameHandler(name) ?? name
        }
        guard !toolNames.isEmpty else { return false }
        return toolNames.allSatisfy { isAllowedToolHandler($0) }
    }

    private func applyNeedsWebContract(_ route: RouteDecision,
                                       requestText: String,
                                       classification: IntentClassification?) -> RouteDecision {
        guard let classification, classification.needsWeb else {
            return route
        }
        let category = categoryForCapabilityRequest(text: requestText, classification: classification)

        if category == .news {
            if nativeToolExistsHandler(category) {
                return RouteDecision(
                    plan: Plan(steps: [
                        .tool(
                            name: "news.latest",
                            args: [
                                "text": .string(requestText)
                            ],
                            say: "I'll get the latest headlines."
                        )
                    ]),
                    provider: route.provider,
                    routerMs: route.routerMs,
                    aiModelUsed: route.aiModelUsed,
                    routeReason: "news_native_skill_route",
                    planLocalWireMs: route.planLocalWireMs,
                    planLocalTotalMs: route.planLocalTotalMs,
                    planOpenAIMs: route.planOpenAIMs
                )
            }
            return RouteDecision(
                plan: Plan(steps: [
                    .delegate(
                        task: "capability_gap: latest news",
                        context: "missing: news.basic tool package and news.latest skill (permission web.read)",
                        say: "I can't do live news yet. I can learn that if you approve web access."
                    )
                ]),
                provider: route.provider,
                routerMs: route.routerMs,
                aiModelUsed: route.aiModelUsed,
                routeReason: "news_capability_gap_learn",
                planLocalWireMs: route.planLocalWireMs,
                planLocalTotalMs: route.planLocalTotalMs,
                planOpenAIMs: route.planOpenAIMs
            )
        }

        guard !hasAllowedToolPlan(route.plan) else { return route }

        if nativeToolExistsHandler(category) {
            return RouteDecision(
                plan: Plan(steps: [.ask(slot: "web_query_detail", prompt: needsWebClarifyingPrompt)]),
                provider: route.provider,
                routerMs: route.routerMs,
                aiModelUsed: route.aiModelUsed,
                routeReason: "needs_web_clarify_missing_tool_plan",
                planLocalWireMs: route.planLocalWireMs,
                planLocalTotalMs: route.planLocalTotalMs,
                planOpenAIMs: route.planOpenAIMs
            )
        }

        return RouteDecision(
            plan: Plan(steps: [.ask(slot: "source_url_or_site", prompt: needsWebSourcePrompt)]),
            provider: route.provider,
            routerMs: route.routerMs,
            aiModelUsed: route.aiModelUsed,
            routeReason: "needs_web_missing_tool_requires_source",
            planLocalWireMs: route.planLocalWireMs,
            planLocalTotalMs: route.planLocalTotalMs,
            planOpenAIMs: route.planOpenAIMs
        )
    }
}
