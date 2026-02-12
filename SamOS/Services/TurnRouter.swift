import Foundation

@MainActor
final class TurnRouter: TurnRouting {
    typealias IntentClassificationHandler = @Sendable (IntentClassifierInput, Bool, Bool) async -> IntentClassificationResult
    typealias PlanRouteHandler = @Sendable (TurnPlanRouteRequest) async -> RouteDecision
    typealias NativeToolExistsHandler = @Sendable (CapabilityRequestCategory) -> Bool

    private let classifyIntentHandler: IntentClassificationHandler
    private let routePlanHandler: PlanRouteHandler
    private let nativeToolExistsHandler: NativeToolExistsHandler

    init(classifyIntent: @escaping IntentClassificationHandler,
         routePlan: @escaping PlanRouteHandler,
         nativeToolExists: @escaping NativeToolExistsHandler = { _ in false }) {
        self.classifyIntentHandler = classifyIntent
        self.routePlanHandler = routePlan
        self.nativeToolExistsHandler = nativeToolExists
    }

    func classifyIntent(_ input: IntentClassifierInput,
                        policy: IntentRoutePolicy) async -> IntentClassificationResult {
        await classifyIntentHandler(input, policy.localFirst, policy.openAIFallback)
    }

    func routePlan(_ request: TurnPlanRouteRequest) async -> RouteDecision {
        await routePlanHandler(request)
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
            if lower.contains("headline") || lower.contains("breaking news") || lower.contains("latest news") {
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
}
