import Foundation

// MARK: - Brain Router Pipeline + Plan Routing + Execution

extension TurnOrchestrator {

    // MARK: - Brain Router Pipeline

    enum CombinedLocalFailureKind: String {
        case timeout
        case schemaFail = "schema_fail"
        case other
    }

    func routeCombined(_ text: String,
                               history: [ChatMessage],
                               pendingSlot: PendingSlot?,
                               reason: LLMCallReason,
                               promptContext: PromptRuntimeContext?,
                               state: TurnRouterState) async -> CombinedRouteDecision {
        OpenAISettings.preloadAPIKey()
        OpenAISettings.clearInvalidatedAPIKeyIfNeeded()

        if !M2Settings.useOllama {
            if OpenAISettings.apiKeyStatus == .ready {
                return await routeCombinedViaOpenAI(
                    text: text,
                    history: history,
                    pendingSlot: pendingSlot,
                    reason: reason,
                    promptContext: promptContext,
                    state: state,
                    localMs: nil,
                    localOutcome: "local_disabled",
                    localAttempted: false,
                    escalationReason: "local_disabled",
                    routeReason: "combined_local_disabled_openai"
                )
            }

            let classification = IntentClassificationResult(
                classification: IntentClassification(
                    intent: .unknown,
                    confidence: 0.2,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: false
                ),
                provider: .rule,
                attemptedLocal: false,
                attemptedOpenAI: false,
                localSkipReason: "local_disabled",
                intentRouterMsLocal: nil,
                intentRouterMsOpenAI: nil,
                localConfidence: nil,
                openAIConfidence: nil,
                confidenceThreshold: 0.7,
                localTimeoutSeconds: nil,
                escalationReason: "local_disabled"
            )
            let route = RouteDecision(
                plan: friendlyFallbackPlan(
                    OpenAIRouter.OpenAIError.requestFailed("combined_local_disabled_no_openai"),
                    userInput: text,
                    pendingSlot: pendingSlot
                ),
                provider: .none,
                routerMs: 0,
                aiModelUsed: nil,
                routeReason: "combined_local_disabled_no_openai",
                planLocalWireMs: nil,
                planLocalTotalMs: nil,
                planOpenAIMs: nil
            )
            return CombinedRouteDecision(
                classification: classification,
                route: route,
                localAttempted: false,
                localOutcome: "local_disabled",
                localMs: nil,
                openAIMs: nil
            )
        }

        let baseTimeoutMs = RouterTimeouts.localCombinedDeadlineMs
        let effectiveTimeoutMs: Int
        if M2Settings.ollamaCombinedTimeoutIsUserOverridden {
            effectiveTimeoutMs = baseTimeoutMs
        } else if let adaptive = latencyTracker.adaptiveTimeoutMs(baseMs: baseTimeoutMs) {
            effectiveTimeoutMs = adaptive
            #if DEBUG
            print("[TIMEOUT_ADAPT] new=\(adaptive) reason=latency_p95")
            #endif
        } else {
            effectiveTimeoutMs = baseTimeoutMs
        }
        let effectiveTimeoutSeconds = Double(effectiveTimeoutMs) / 1000.0

        let localStartedAt = CFAbsoluteTimeGetCurrent()
        do {
            let local = try await withTimeout(effectiveTimeoutSeconds) {
                try await self.ollamaRouter.routeCombinedWithTiming(
                    text,
                    history: history,
                    pendingSlot: pendingSlot,
                    promptContext: promptContext,
                    state: state,
                    wireDeadlineMs: effectiveTimeoutMs
                )
            }
            let localMs = max(0, Int((CFAbsoluteTimeGetCurrent() - localStartedAt) * 1000))
            latencyTracker.record(wireMs: local.timing.wireMs)
            let classification = IntentClassificationResult(
                classification: local.result.classification,
                provider: .ollama,
                attemptedLocal: true,
                attemptedOpenAI: false,
                localSkipReason: nil,
                intentRouterMsLocal: localMs,
                intentRouterMsOpenAI: nil,
                localConfidence: local.result.classification.confidence,
                openAIConfidence: nil,
                confidenceThreshold: 0.7,
                localTimeoutSeconds: effectiveTimeoutSeconds,
                escalationReason: nil
            )
            let route = RouteDecision(
                plan: local.result.plan,
                provider: .ollama,
                routerMs: localMs,
                aiModelUsed: nil,
                routeReason: "combined_local_success",
                planLocalWireMs: local.timing.wireMs,
                planLocalTotalMs: local.timing.totalMs,
                planOpenAIMs: nil
            )
            #if DEBUG
            print("[ROUTE_DECISION] turn=\(turnCounter) chosen=local reason=combined_local_success local_outcome=ok local_ms=\(localMs)")
            DebugLogStore.shared.logRouting(turnID: TurnExecutionContext.turnID, provider: "ollama", reason: "combined_local_success", localOutcome: "ok", durationMs: localMs)
            #endif
            if shouldFallbackToOpenAIForLikelyMiss(
                plan: local.result.plan,
                classification: local.result.classification
            ) {
                #if DEBUG
                print("[ROUTE_DECISION] turn=\(turnCounter) chosen=openai reason=combined_local_uncertain_openai_fallback local_outcome=uncertain_answer local_ms=\(localMs)")
                DebugLogStore.shared.logRouting(turnID: TurnExecutionContext.turnID, provider: "openai", reason: "combined_local_uncertain_openai_fallback", localOutcome: "uncertain_answer", durationMs: localMs)
                #endif
                return await routeCombinedViaOpenAI(
                    text: text,
                    history: history,
                    pendingSlot: pendingSlot,
                    reason: reason,
                    promptContext: promptContext,
                    state: state,
                    localMs: localMs,
                    localOutcome: "uncertain_answer",
                    localAttempted: true,
                    escalationReason: "uncertain_answer",
                    routeReason: "combined_local_uncertain_openai_fallback"
                )
            }
            return CombinedRouteDecision(
                classification: classification,
                route: route,
                localAttempted: true,
                localOutcome: "ok",
                localMs: localMs,
                openAIMs: nil
            )
        } catch {
            let localMs = max(0, Int((CFAbsoluteTimeGetCurrent() - localStartedAt) * 1000))
            let failureKind = classifyCombinedLocalFailure(error)
            if shouldFallbackToOpenAI(for: failureKind) {
                let routeReason = failureKind == .timeout
                    ? "combined_local_timeout_openai_fallback"
                    : "combined_local_schema_fail_openai_fallback"
                #if DEBUG
                print("[ROUTE_DECISION] turn=\(turnCounter) chosen=openai reason=\(routeReason) local_outcome=\(failureKind.rawValue) local_ms=\(localMs)")
                DebugLogStore.shared.logRouting(turnID: TurnExecutionContext.turnID, provider: "openai", reason: routeReason, localOutcome: failureKind.rawValue, durationMs: localMs)
                #endif
                return await routeCombinedViaOpenAI(
                    text: text,
                    history: history,
                    pendingSlot: pendingSlot,
                    reason: reason,
                    promptContext: promptContext,
                    state: state,
                    localMs: localMs,
                    localOutcome: failureKind.rawValue,
                    localAttempted: true,
                    escalationReason: failureKind.rawValue,
                    routeReason: routeReason
                )
            }

            let classification = IntentClassificationResult(
                classification: IntentClassification(
                    intent: .unknown,
                    confidence: 0.2,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: false
                ),
                provider: .rule,
                attemptedLocal: true,
                attemptedOpenAI: false,
                localSkipReason: nil,
                intentRouterMsLocal: localMs,
                intentRouterMsOpenAI: nil,
                localConfidence: nil,
                openAIConfidence: nil,
                confidenceThreshold: 0.7,
                localTimeoutSeconds: effectiveTimeoutSeconds,
                escalationReason: failureKind.rawValue
            )
            let route = RouteDecision(
                plan: friendlyFallbackPlan(error, userInput: text, pendingSlot: pendingSlot),
                provider: .ollama,
                routerMs: localMs,
                aiModelUsed: nil,
                routeReason: "combined_local_error_no_openai_fallback",
                planLocalWireMs: nil,
                planLocalTotalMs: localMs,
                planOpenAIMs: nil
            )
            return CombinedRouteDecision(
                classification: classification,
                route: route,
                localAttempted: true,
                localOutcome: failureKind.rawValue,
                localMs: localMs,
                openAIMs: nil
            )
        }
    }

    func classifyCombinedLocalFailure(_ error: Error) -> CombinedLocalFailureKind {
        if error is RouterTimeout { return .timeout }
        if let ollamaError = error as? OllamaRouter.OllamaError {
            switch ollamaError {
            case .wireDeadlineExceeded:
                return .timeout
            case .schemaMismatch, .jsonParseFailed, .validationFailure:
                return .schemaFail
            default:
                return .other
            }
        }
        return .other
    }

    func shouldFallbackToOpenAI(for failureKind: CombinedLocalFailureKind) -> Bool {
        guard OpenAISettings.apiKeyStatus == .ready else { return false }
        return failureKind == .timeout || failureKind == .schemaFail
    }

    func routeCombinedViaOpenAI(text: String,
                                        history: [ChatMessage],
                                        pendingSlot: PendingSlot?,
                                        reason: LLMCallReason,
                                        promptContext: PromptRuntimeContext?,
                                        state: TurnRouterState,
                                        localMs: Int?,
                                        localOutcome: String?,
                                        localAttempted: Bool,
                                        escalationReason: String,
                                        routeReason: String) async -> CombinedRouteDecision {
        let openAIStartedAt = CFAbsoluteTimeGetCurrent()
        #if DEBUG
        print("[OPENAI_TASK] started turn=\(turnCounter) reason=\(routeReason)")
        #endif
        do {
            try Task.checkCancellation()
            let openAIIntent = try await openAIProvider.classifyIntentWithRetry(
                IntentClassifierInput(
                    userText: text,
                    cameraRunning: state.cameraRunning,
                    faceKnown: state.faceKnown,
                    pendingSlot: state.pendingSlot,
                    lastAssistantLine: state.lastAssistantLine
                ),
                timeoutSeconds: openAIRouteTimeoutSeconds
            )
            guard let parsedClassification = parseIntentClassificationPayload(openAIIntent.output.rawText) else {
                throw OpenAIRouter.OpenAIError.requestFailed("combined intent parse failure")
            }

            let selectedModel = selectOpenAIModel(
                for: text,
                reason: reason,
                preferFallbackModel: localAttempted && M2Settings.useOllama
            )
            let planDecision = try await openAIProvider.routePlanWithRetry(
                OpenAIPlanRequest(
                    input: text,
                    history: history,
                    pendingSlot: pendingSlot,
                    promptContext: promptContext,
                    modelOverride: selectedModel,
                    reason: .plan,
                    timeoutSeconds: openAIRouteTimeoutSeconds,
                    retryMaxOutputTokens: openAITimeoutRetryMaxTokens
                )
            )
            let openAIMs = max(0, Int((CFAbsoluteTimeGetCurrent() - openAIStartedAt) * 1000))
            #if DEBUG
            print("[OPENAI_TASK] completed turn=\(turnCounter) ms=\(openAIMs)")
            #endif
            let classification = IntentClassificationResult(
                classification: parsedClassification,
                provider: .openai,
                attemptedLocal: localAttempted,
                attemptedOpenAI: true,
                localSkipReason: localAttempted ? nil : "local_disabled",
                intentRouterMsLocal: localMs,
                intentRouterMsOpenAI: openAIMs,
                localConfidence: nil,
                openAIConfidence: parsedClassification.confidence,
                confidenceThreshold: 0.7,
                localTimeoutSeconds: localAttempted ? RouterTimeouts.localCombinedDeadlineSeconds : nil,
                escalationReason: escalationReason
            )
            let route = RouteDecision(
                plan: planDecision.plan,
                provider: .openai,
                routerMs: openAIMs,
                aiModelUsed: selectedModel,
                routeReason: routeReason,
                planLocalWireMs: nil,
                planLocalTotalMs: localMs,
                planOpenAIMs: openAIMs
            )
            return CombinedRouteDecision(
                classification: classification,
                route: route,
                localAttempted: localAttempted,
                localOutcome: localOutcome,
                localMs: localMs,
                openAIMs: openAIMs
            )
        } catch {
            let openAIMs = max(0, Int((CFAbsoluteTimeGetCurrent() - openAIStartedAt) * 1000))
            #if DEBUG
            if error is CancellationError {
                print("[OPENAI_CANCEL] turn=\(turnCounter) openai_task_cancelled ms=\(openAIMs)")
            }
            print("[OPENAI_TASK] failed turn=\(turnCounter) ms=\(openAIMs) error=\(error.localizedDescription.prefix(80))")
            #endif
            let classification = IntentClassificationResult(
                classification: IntentClassification(
                    intent: .unknown,
                    confidence: 0.2,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: false
                ),
                provider: .rule,
                attemptedLocal: localAttempted,
                attemptedOpenAI: true,
                localSkipReason: localAttempted ? nil : "local_disabled",
                intentRouterMsLocal: localMs,
                intentRouterMsOpenAI: openAIMs,
                localConfidence: nil,
                openAIConfidence: nil,
                confidenceThreshold: 0.7,
                localTimeoutSeconds: localAttempted ? RouterTimeouts.localCombinedDeadlineSeconds : nil,
                escalationReason: "openai_fallback_failed"
            )
            let route = RouteDecision(
                plan: friendlyFallbackPlan(error, userInput: text, pendingSlot: pendingSlot),
                provider: .openai,
                routerMs: openAIMs,
                aiModelUsed: nil,
                routeReason: "combined_openai_fallback_error",
                planLocalWireMs: nil,
                planLocalTotalMs: localMs,
                planOpenAIMs: openAIMs
            )
            return CombinedRouteDecision(
                classification: classification,
                route: route,
                localAttempted: localAttempted,
                localOutcome: localOutcome,
                localMs: localMs,
                openAIMs: openAIMs
            )
        }
    }

    func parseIntentClassificationPayload(_ raw: String) -> IntentClassification? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intentRaw = dict["intent"] as? String,
              let intent = RoutedIntent(rawValue: intentRaw),
              let confidenceNumber = dict["confidence"] as? NSNumber else {
            return nil
        }
        let notes = (dict["notes"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let autoCaptureHint = dict["autoCaptureHint"] as? Bool ?? false
        let needsWeb = dict["needsWeb"] as? Bool ?? (intent == .webRequest)
        return IntentClassification(
            intent: intent,
            confidence: min(1.0, max(0.0, confidenceNumber.doubleValue)),
            notes: notes,
            autoCaptureHint: autoCaptureHint,
            needsWeb: needsWeb
        )
    }

    func shouldReuseCombinedRouteDecision(_ decision: CombinedRouteDecision?,
                                                  requestedPendingSlot: PendingSlot?,
                                                  initialPendingSlot: PendingSlot?,
                                                  expectedReason: LLMCallReason) -> Bool {
        guard decision != nil else { return false }
        switch expectedReason {
        case .userChat:
            return requestedPendingSlot == nil && initialPendingSlot == nil
        case .pendingSlotReply:
            guard let requestedPendingSlot, let initialPendingSlot else { return false }
            return requestedPendingSlot.slotName.caseInsensitiveCompare(initialPendingSlot.slotName) == .orderedSame
        default:
            return false
        }
    }

    func applyCombinedRouteMetadata(_ result: inout TurnResult,
                                            combinedDecision: CombinedRouteDecision?) {
        guard let combinedDecision else { return }
        result.routeLocalOutcome = combinedDecision.localOutcome
        if result.intentRouterMsLocal == nil {
            result.intentRouterMsLocal = combinedDecision.classification.intentRouterMsLocal
        }
        if result.intentRouterMsOpenAI == nil {
            result.intentRouterMsOpenAI = combinedDecision.classification.intentRouterMsOpenAI
        }
        if result.planLocalTotalMs == nil {
            result.planLocalTotalMs = combinedDecision.localMs
        }
        if result.planOpenAIMs == nil {
            result.planOpenAIMs = combinedDecision.openAIMs
        }
    }

    /// Routes plans through PlanRoutePolicy.
    /// Policy: when Ollama is enabled, route local-first then fall back to OpenAI.
    func routePlan(_ text: String, history: [ChatMessage],
                           pendingSlot: PendingSlot? = nil,
                           reason: LLMCallReason = .userChat,
                           promptContext: PromptRuntimeContext? = nil) async -> (Plan, LLMProvider, Int, String?, String, Int?, Int?, Int?) {
        OpenAISettings.preloadAPIKey()
        OpenAISettings.clearInvalidatedAPIKeyIfNeeded()
        let forceOpenAIPlans = shouldForceOpenAIPlan(for: text, pendingSlot: pendingSlot)
        let planRoutePolicy = PlanRoutePolicy(
            useOllama: M2Settings.useOllama,
            preferOpenAIPlans: M2Settings.preferOpenAIPlans || forceOpenAIPlans,
            openAIStatus: OpenAISettings.apiKeyStatus
        )
        #if DEBUG
        print("[PLAN_ROUTE_POLICY] local_first=\(planRoutePolicy.localFirst) openai_fallback=\(planRoutePolicy.openAIFallback) m2_useOllama=\(M2Settings.useOllama) prefer_openai_plans=\(M2Settings.preferOpenAIPlans || forceOpenAIPlans) force_openai=\(forceOpenAIPlans) openai_status=\(planRoutePolicy.openAIStatus)")
        #endif

        var ollamaLocalFirstFailKind: String?
        var localWireMs: Int?
        var localTotalMs: Int?
        var openAIMs: Int?

        // Local-first: attempt Ollama before OpenAI when both are available
        if planRoutePolicy.routeOrder.first == .ollama && planRoutePolicy.routeOrder.contains(.openai) {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let routed = try await self.ollamaRouter.routePlanWithTiming(
                    text,
                    history: history,
                    pendingSlot: pendingSlot,
                    promptContext: promptContext,
                    skipRepairRetry: true,
                    wireDeadlineMs: RouterTimeouts.localCombinedDeadlineMs
                )
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                localWireMs = routed.timing.wireMs
                localTotalMs = routed.timing.totalMs
                routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: true)
                if shouldFallbackToOpenAIForLikelyMiss(plan: routed.plan, classification: nil) {
                    #if DEBUG
                    print("[OLLAMA_PLAN_FALLBACK] kind=uncertain_answer ms=\(ms)")
                    #endif
                    ollamaLocalFirstFailKind = "uncertain_answer"
                } else {
                    return (routed.plan, .ollama, ms, nil, "ollama_local_first_success", localWireMs, localTotalMs, nil)
                }
            } catch {
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                let failInfo = classifyOllamaFailure(error)
                routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: false)
                #if DEBUG
                print("[OLLAMA_PLAN_FAIL] kind=\(failInfo.kind) reasons=\(failInfo.reasonCount) ms=\(ms) detail=\(failInfo.detail)")
                #endif
                // Fall through to OpenAI with specific fallback reason
                ollamaLocalFirstFailKind = failInfo.kind
            }
        }

        if planRoutePolicy.routeOrder.contains(.openai) {
            let start = CFAbsoluteTimeGetCurrent()
            let selectedModel = selectOpenAIModel(
                for: text,
                reason: reason,
                preferFallbackModel: ollamaLocalFirstFailKind != nil && M2Settings.useOllama
            )
            do {
                let timeoutSeconds = openAIRouteTimeoutSecondsFor(input: text, reason: reason)
                let planDecision = try await self.openAIProvider.routePlanWithRetry(
                    OpenAIPlanRequest(
                        input: text,
                        history: history,
                        pendingSlot: pendingSlot,
                        promptContext: promptContext,
                        modelOverride: selectedModel,
                        reason: .plan,
                        timeoutSeconds: timeoutSeconds,
                        retryMaxOutputTokens: openAITimeoutRetryMaxTokens
                    )
                )
                let plan = planDecision.plan
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                openAIMs = ms
                routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: true)
                if let failKind = ollamaLocalFirstFailKind {
                    return (plan, .openai, ms, selectedModel, "ollama_\(failKind)_fallback", localWireMs, localTotalMs, openAIMs)
                }
                let routeReason = planDecision.didRetry ? "openai_success_timeout_retry" : "openai_success"
                return (plan, .openai, ms, selectedModel, routeReason, localWireMs, localTotalMs, openAIMs)
            } catch {
                if let validationFailure = routerValidationFailure(from: error) {
                    let (plan, routeReason) = planForRouterValidationFailure(
                        validationFailure,
                        userText: text,
                        now: Date()
                    )
                    let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: false)
                    openAIMs = ms
                    return (plan, .openai, ms, selectedModel, routeReason, localWireMs, localTotalMs, openAIMs)
                }

                if isTimeoutLikeOpenAIError(error) {
                    let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: false)
                    openAIMs = ms
                    return (
                        friendlyFallbackPlan(error, userInput: text, pendingSlot: pendingSlot),
                        .openai,
                        ms,
                        selectedModel,
                        "openai_timeout_retry_failed",
                        localWireMs,
                        localTotalMs,
                        openAIMs
                    )
                }

                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: false)
                openAIMs = ms
                return (
                    friendlyFallbackPlan(error, userInput: text, pendingSlot: pendingSlot),
                    .openai,
                    ms,
                    selectedModel,
                    "openai_error_fallback",
                    localWireMs,
                    localTotalMs,
                    openAIMs
                )
            }
        }

        if planRoutePolicy.routeOrder.first == LLMProvider.none,
           planRoutePolicy.openAIStatus == .invalid || OpenAISettings.authFailureStatusCode == 401 || OpenAISettings.authFailureStatusCode == 403 {
            return (
                friendlyFallbackPlan(
                    OpenAIRouter.OpenAIError.invalidAPIKey,
                    userInput: text,
                    pendingSlot: pendingSlot
                ),
                .none,
                0,
                nil,
                "openai_invalid_key",
                localWireMs,
                localTotalMs,
                openAIMs
            )
        }

        if planRoutePolicy.routeOrder.first == .ollama {
            return await ollamaFallback(text, history: history, pendingSlot: pendingSlot, reason: reason, promptContext: promptContext)
        }

        return (
            friendlyFallbackPlan(
                OpenAIRouter.OpenAIError.notConfigured,
                userInput: text,
                pendingSlot: pendingSlot
            ),
            .none,
            0,
            nil,
            "no_provider_configured",
            localWireMs,
            localTotalMs,
            openAIMs
        )
    }

    func shouldForceOpenAIPlan(for input: String, pendingSlot: PendingSlot?) -> Bool {
        if let slot = pendingSlot?.slotName.lowercased(),
           slot.contains("skills.learn")
            || slot.contains("skillforge")
            || slot.contains("permission_review") {
            return true
        }

        let lower = input.lowercased()
        let triggers = [
            "learn new skill",
            "learn a new skill",
            "create new skill",
            "build new skill",
            "learn skill",
            "build skill",
            "create skill",
            "teach sam",
            "start skillforge",
            "start_skillforge"
        ]
        return triggers.contains(where: { lower.contains($0) })
    }

    /// Ollama attempt — single call, no validation repair.
    func ollamaFallback(_ text: String, history: [ChatMessage],
                                pendingSlot: PendingSlot?,
                                reason: LLMCallReason,
                                promptContext: PromptRuntimeContext?) async -> (Plan, LLMProvider, Int, String?, String, Int?, Int?, Int?) {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let routed = try await self.ollamaRouter.routePlanWithTiming(
                text,
                history: history,
                pendingSlot: pendingSlot,
                promptContext: promptContext,
                skipRepairRetry: false,
                wireDeadlineMs: RouterTimeouts.localCombinedDeadlineMs
            )
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: true)
            return (routed.plan, .ollama, ms, nil, "ollama_success", routed.timing.wireMs, routed.timing.totalMs, nil)
        } catch {
            if let validationFailure = routerValidationFailure(from: error) {
                let (plan, routeReason) = planForRouterValidationFailure(
                    validationFailure,
                    userText: text,
                    now: Date()
                )
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: false)
                return (plan, .none, ms, nil, routeReason, nil, nil, nil)
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: false)
            return (
                friendlyFallbackPlan(error, userInput: text, pendingSlot: pendingSlot),
                .ollama,
                ms,
                nil,
                "ollama_error_fallback",
                nil,
                nil,
                nil
            )
        }
    }

    // MARK: - Execute Plan

    func executePlan(_ plan: Plan,
                             originalInput: String,
                             history: [ChatMessage],
                             provider: LLMProvider,
                             aiModelUsed: String?,
                             routerMs: Int,
                             planLocalWireMs: Int? = nil,
                             planLocalTotalMs: Int? = nil,
                             planOpenAIMs: Int? = nil,
                             localKnowledgeContext: LocalKnowledgeContext,
                             hasMemoryHints: Bool,
                             turnIndex: Int,
                             feedbackDepth: Int,
                             turnStartedAt: Date,
                             mode: ConversationMode,
                             toneRepairCue: String? = nil,
                             affect: AffectMetadata = .neutral,
                             originReason: String? = nil) async -> TurnResult {
        let exec = await toolRunner.executePlan(plan, originalInput: originalInput, pendingSlotName: pendingSlot?.slotName)

        var result = TurnResult()
        result.llmProvider = provider
        result.aiModelUsed = aiModelUsed
        result.executedToolSteps = exec.executedToolSteps
        result.toolMsTotal = exec.toolMsTotal
        result.planExecutionMs = exec.executionMs
        result.speechSelectionMs = exec.speechSelectionMs
        result.routerMs = routerMs
        result.planLocalWireMs = planLocalWireMs
        result.planLocalTotalMs = planLocalTotalMs
        result.planOpenAIMs = planOpenAIMs
        result.originProvider = originProvider(for: provider)
        result.executionProvider = executionProvider(for: provider, hasToolExecution: !exec.executedToolSteps.isEmpty)
        result.originReason = originReason

        // Stamp provider on assistant messages
        result.appendedChat = exec.chatMessages.map { msg in
            if msg.role == .assistant {
                var stamped = msg
                stamped.llmProvider = provider
                stamped.originProvider = result.originProvider
                stamped.executionProvider = result.executionProvider
                stamped.originReason = result.originReason
                return stamped
            }
            return msg
        }
        result.spokenLines = exec.spokenLines
        result.appendedOutputs = exec.outputItems
        result.triggerFollowUpCapture = exec.triggerFollowUpCapture
        result.usedMemoryHints = hasMemoryHints && provider != .none

        // Auto-repair: image_url slot means the image probe failed.
        // Retry once via LLM without bothering the user.
        if let req = exec.pendingSlotRequest, req.slot == "image_url" {
            #if DEBUG
            print("[TurnOrchestrator] Image probe failed — auto-repair retry")
            #endif
            let retryResult = await autoRepairImage(originalInput: originalInput,
                                                    history: history,
                                                    failureReason: req.prompt,
                                                    aiModelUsed: aiModelUsed,
                                                    localKnowledgeContext: localKnowledgeContext,
                                                    hasMemoryHints: hasMemoryHints,
                                                    turnIndex: turnIndex,
                                                    feedbackDepth: feedbackDepth,
                                                    turnStartedAt: turnStartedAt,
                                                    originReason: originReason)
            if let retryResult = retryResult {
                return retryResult
            }
            return result
        }

        // Handle pendingSlot from executor result (non-image)
        if let req = exec.pendingSlotRequest {
            pendingSlot = PendingSlot(slotName: req.slot, prompt: req.prompt, originalUserText: originalInput)
            result.triggerFollowUpCapture = true
        }

        let shouldNarrateProgress = shouldNarrateToolProgress(for: originalInput, plan: plan)
        let forceToolFeedback = shouldForceToolFeedback(for: originalInput, plan: plan)
        if shouldNarrateProgress {
            prependAssistantProgressLines(toolProgressLines(from: plan), into: &result, provider: provider)
        }

        await applyToolResultFeedbackLoop(
            &result,
            originalInput: originalInput,
            history: history,
            provider: provider,
            aiModelUsed: aiModelUsed,
            force: forceToolFeedback,
            allowFeedback: shouldAllowToolFeedback(for: plan),
            depth: feedbackDepth,
            turnStartedAt: turnStartedAt
        )
        result.executionProvider = executionProvider(for: provider, hasToolExecution: !result.executedToolSteps.isEmpty)
        applyCanvasPresentationPolicy(&result)
        applyResponsePolish(&result, plan: plan, hasMemoryHints: hasMemoryHints, turnIndex: turnIndex)
        applyAffectMirroringResponsePolicy(&result, affect: affect)
        applyToneRepairResponsePolicy(&result, cue: toneRepairCue)
        applyFollowUpQuestionPolicy(&result, turnIndex: turnIndex)
        applyCuriosityQuestionPolicy(&result, turnIndex: turnIndex)
        if currentTurnCaptureAfterReplyHint, !result.triggerFollowUpCapture {
            result.triggerQuestionAutoListen = true
        }
        applyKnowledgeAttribution(&result,
                                  userInput: originalInput,
                                  provider: provider,
                                  aiModelUsed: aiModelUsed,
                                  localKnowledgeContext: localKnowledgeContext)
        applyRoutingAttribution(&result, planProvider: provider, planRouterMs: nil)
        applyOriginMetadata(&result)
        updateAssistantState(after: result, mode: mode)
        rememberAssistantLines(result.appendedChat)
        return result
    }

}
