import XCTest
@testable import SamOS

@MainActor
final class TurnRouterTests: XCTestCase {

    private func makeRouter(classify: @escaping TurnRouter.IntentClassificationHandler,
                            route: @escaping TurnRouter.PlanRouteHandler) -> TurnRouter {
        TurnRouter(
            classifyIntent: classify,
            routePlan: route,
            nativeToolExists: { category in
                switch category {
                case .weather, .time:
                    return true
                case .news, .sportsScores, .otherWeb:
                    return false
                }
            },
            normalizeToolName: { raw in
                ToolRegistry.shared.normalizeToolName(raw)
            },
            isAllowedTool: { name in
                ToolRegistry.shared.isAllowedTool(name)
            }
        )
    }

    nonisolated private static func makeClassification(_ intent: RoutedIntent,
                                                       provider: IntentClassificationProvider = .rule,
                                                       needsWeb: Bool = false) -> IntentClassificationResult {
        IntentClassificationResult(
            classification: IntentClassification(
                intent: intent,
                confidence: 0.9,
                notes: "",
                autoCaptureHint: false,
                needsWeb: needsWeb
            ),
            provider: provider,
            attemptedLocal: true,
            attemptedOpenAI: false,
            localSkipReason: nil,
            intentRouterMsLocal: 11,
            intentRouterMsOpenAI: nil,
            localConfidence: 0.9,
            openAIConfidence: nil,
            confidenceThreshold: 0.7,
            localTimeoutSeconds: nil,
            escalationReason: nil
        )
    }

    nonisolated private static func makeExternalRequest(reminderCount: Int = 0) -> PendingCapabilityRequest {
        let now = Date(timeIntervalSince1970: 100)
        return PendingCapabilityRequest(
            kind: .externalSource,
            desiredToolName: "external_source",
            originalUserGoal: "show movie times",
            prefersWebsiteURL: true,
            createdAt: now,
            lastAskedAt: now,
            reminderCount: reminderCount
        )
    }

    func testClassifyIntentUsesPolicyFlags() async {
        let router = makeRouter(
            classify: { _, localFirst, openAIFallback in
                if localFirst && openAIFallback {
                    return Self.makeClassification(.generalQnA)
                }
                return Self.makeClassification(.unknown)
            },
            route: { _ in
                RouteDecision(
                    plan: Plan(steps: [.talk(say: "hi")]),
                    provider: .none,
                    routerMs: 0,
                    aiModelUsed: nil,
                    routeReason: "test",
                    planLocalWireMs: nil,
                    planLocalTotalMs: nil,
                    planOpenAIMs: nil
                )
            }
        )

        let input = IntentClassifierInput(userText: "hello", cameraRunning: false, faceKnown: false, pendingSlot: nil, lastAssistantLine: nil)
        let result = await router.classifyIntent(input, policy: IntentRoutePolicy(useOllama: true))
        XCTAssertEqual(result.classification.intent, .generalQnA)
    }

    func testRoutePlanDelegatesRequest() async {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.generalQnA) },
            route: { request in
                return RouteDecision(
                    plan: Plan(steps: [.talk(say: request.text)]),
                    provider: .openai,
                    routerMs: 25,
                    aiModelUsed: "gpt-test",
                    routeReason: request.text,
                    planLocalWireMs: nil,
                    planLocalTotalMs: nil,
                    planOpenAIMs: 25
                )
            }
        )

        let result = await router.routePlan(
            TurnPlanRouteRequest(
                text: "route this",
                history: [],
                pendingSlot: nil,
                reason: .userChat,
                promptContext: nil
            )
        )

        XCTAssertEqual(result.routeReason, "route this")
        XCTAssertEqual(result.plan, Plan(steps: [.talk(say: "route this")]))
        XCTAssertEqual(result.provider, .openai)
        XCTAssertEqual(result.routerMs, 25)
    }

    func testWeatherBrisbaneRouteNormalizesToolAndAvoidsSourceURLSlot() async {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.webRequest, needsWeb: true) },
            route: { _ in
                RouteDecision(
                    plan: Plan(steps: [.tool(name: "weather", args: ["place": .string("Brisbane")], say: nil)]),
                    provider: .openai,
                    routerMs: 12,
                    aiModelUsed: "gpt-test",
                    routeReason: "raw_weather_tool",
                    planLocalWireMs: nil,
                    planLocalTotalMs: nil,
                    planOpenAIMs: 12
                )
            }
        )

        let decision = await router.routePlan(
            TurnPlanRouteRequest(
                text: "weather brisbane",
                history: [],
                pendingSlot: nil,
                reason: .userChat,
                promptContext: nil,
                intentClassification: IntentClassification(
                    intent: .webRequest,
                    confidence: 0.95,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: true
                )
            )
        )

        guard case .tool(let name, _, _) = decision.plan.steps.first else {
            return XCTFail("Expected tool step")
        }
        XCTAssertEqual(name, "get_weather")
        let hasSourceSlotAsk = decision.plan.steps.contains { step in
            guard case .ask(let slot, _) = step else { return false }
            return slot == "source_url_or_site"
        }
        XCTAssertFalse(hasSourceSlotAsk)
    }

    func testOpenAITimeoutFallbackPlanKeepsNormalizedToolName() async {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.webRequest, needsWeb: true) },
            route: { _ in
                RouteDecision(
                    plan: Plan(steps: [.tool(name: "getWeather", args: ["place": .string("Brisbane")], say: nil)]),
                    provider: .ollama,
                    routerMs: 18,
                    aiModelUsed: "local-fallback",
                    routeReason: "openai_timeout_fallback_ollama",
                    planLocalWireMs: 4,
                    planLocalTotalMs: 7,
                    planOpenAIMs: nil
                )
            }
        )

        let decision = await router.routePlan(
            TurnPlanRouteRequest(
                text: "weather brisbane",
                history: [],
                pendingSlot: nil,
                reason: .userChat,
                promptContext: nil,
                intentClassification: IntentClassification(
                    intent: .webRequest,
                    confidence: 0.9,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: true
                )
            )
        )

        XCTAssertEqual(decision.provider, .ollama)
        guard case .tool(let name, _, _) = decision.plan.steps.first else {
            return XCTFail("Expected tool step")
        }
        XCTAssertEqual(name, "get_weather")
    }

    func testNeedsWebWithoutAllowedToolDelegatesToCapabilityGapLearning() async {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.webRequest, needsWeb: true) },
            route: { _ in
                RouteDecision(
                    plan: Plan(steps: [.talk(say: "Let me think.")]),
                    provider: .openai,
                    routerMs: 9,
                    aiModelUsed: "gpt-test",
                    routeReason: "talk_only",
                    planLocalWireMs: nil,
                    planLocalTotalMs: nil,
                    planOpenAIMs: 9
                )
            }
        )

        let decision = await router.routePlan(
            TurnPlanRouteRequest(
                text: "latest headlines",
                history: [],
                pendingSlot: nil,
                reason: .userChat,
                promptContext: nil,
                intentClassification: IntentClassification(
                    intent: .webRequest,
                    confidence: 0.9,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: true
                )
            )
        )

        guard case .delegate(let task, let context, let say) = decision.plan.steps.first else {
            return XCTFail("Expected capability-gap delegate")
        }
        XCTAssertTrue(task.lowercased().hasPrefix("capability_gap:"))
        XCTAssertTrue((context ?? "").contains("auto_source_discovery_via_gpt=true"))
        XCTAssertEqual(say, "I can learn this via GPT and discover trusted sources automatically.")
        XCTAssertEqual(decision.routeReason, "needs_web_capability_gap_gpt_discovery")
    }

    func testNeedsWebWithoutAllowedToolAndNativeToolReturnsDetailClarifier() async {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.webRequest, needsWeb: true) },
            route: { _ in
                RouteDecision(
                    plan: Plan(steps: [.talk(say: "Let me think.")]),
                    provider: .openai,
                    routerMs: 9,
                    aiModelUsed: "gpt-test",
                    routeReason: "talk_only",
                    planLocalWireMs: nil,
                    planLocalTotalMs: nil,
                    planOpenAIMs: 9
                )
            }
        )

        let decision = await router.routePlan(
            TurnPlanRouteRequest(
                text: "weather in brisbane today",
                history: [],
                pendingSlot: nil,
                reason: .userChat,
                promptContext: nil,
                intentClassification: IntentClassification(
                    intent: .webRequest,
                    confidence: 0.9,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: true
                )
            )
        )

        guard case .ask(let slot, let prompt) = decision.plan.steps.first else {
            return XCTFail("Expected deterministic clarifying ask")
        }
        XCTAssertEqual(slot, "web_query_detail")
        XCTAssertEqual(prompt, "What location or source should I check for that live update?")
        XCTAssertEqual(decision.routeReason, "needs_web_clarify_missing_tool_plan")
    }

    func testEvaluatePendingSlotRetryExhaustedAtMaxAttempts() {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.generalQnA) },
            route: { _ in fatalError("unused") }
        )
        let slot = PendingSlot(slotName: "time", prompt: "time?", originalUserText: "set alarm", attempts: 3)

        let evaluation = router.evaluatePendingSlot(slot, pendingCapabilityRequest: nil, now: Date())

        guard case .retryExhausted(let message) = evaluation.action else {
            return XCTFail("Expected retry exhaustion")
        }
        XCTAssertEqual(message, "I'm not getting it — can you rephrase?")
        XCTAssertNil(evaluation.pendingSlot)
    }

    func testEvaluatePendingSlotClearsExternalCapabilityWhenExpired() {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.generalQnA) },
            route: { _ in fatalError("unused") }
        )
        let expired = PendingSlot(
            slotName: "source_url_or_site",
            prompt: "source?",
            originalUserText: "movie times",
            ttl: -1
        )

        let evaluation = router.evaluatePendingSlot(expired, pendingCapabilityRequest: Self.makeExternalRequest(), now: Date())

        XCTAssertNil(evaluation.pendingSlot)
        XCTAssertNil(evaluation.pendingCapabilityRequest)
        XCTAssertEqual(evaluation.action, .none)
    }

    func testResolvePendingSlotAfterPlanIncrementsAttemptsOnRepeatAsk() {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.generalQnA) },
            route: { _ in fatalError("unused") }
        )
        let slot = PendingSlot(slotName: "time", prompt: "time?", originalUserText: "set alarm", attempts: 1)
        let plan = Plan(steps: [.ask(slot: "time", prompt: "what time?")])

        let resolved = router.resolvePendingSlotAfterPlan(plan, previousSlot: slot, pendingCapabilityRequest: nil)

        XCTAssertEqual(resolved.pendingSlot?.attempts, 2)
        XCTAssertEqual(resolved.pendingSlot?.slotName, "time")
    }

    func testResolvePendingSlotAfterPlanClearsExternalCapabilityWhenSourceResolved() {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.generalQnA) },
            route: { _ in fatalError("unused") }
        )
        let slot = PendingSlot(slotName: "source_url_or_site", prompt: "source?", originalUserText: "movie times")
        let plan = Plan(steps: [.talk(say: "thanks")])

        let resolved = router.resolvePendingSlotAfterPlan(plan, previousSlot: slot, pendingCapabilityRequest: Self.makeExternalRequest())

        XCTAssertNil(resolved.pendingSlot)
        XCTAssertNil(resolved.pendingCapabilityRequest)
    }

    func testCapabilityGapFlowSkipsWeatherQueries() {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.generalQnA) },
            route: { _ in fatalError("unused") }
        )
        let weatherClassification = IntentClassification(
            intent: .webRequest,
            confidence: 0.9,
            notes: "",
            autoCaptureHint: false,
            needsWeb: true
        )

        let shouldEnter = router.shouldEnterExternalSourceCapabilityGapFlow(
            CapabilityGapRouteInput(
                text: "what's the weather in sydney today",
                classification: weatherClassification,
                provider: .rule,
                pendingSlot: nil,
                pendingCapabilityRequest: nil,
                confidenceThreshold: 0.7
            )
        )

        XCTAssertFalse(shouldEnter)
    }

    func testResolvePendingCapabilityInputLearnsSourceFromURL() {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.generalQnA) },
            route: { _ in fatalError("unused") }
        )

        let resolution = router.resolvePendingCapabilityInput(
            PendingCapabilityInput(
                pendingRequest: Self.makeExternalRequest(),
                text: "Use this: https://example.com/listings",
                now: Date()
            )
        )

        guard case .learnSource(let url, _, let memoryContent, _) = resolution else {
            return XCTFail("Expected learnSource")
        }
        XCTAssertEqual(url, "https://example.com/listings")
        XCTAssertTrue(memoryContent.contains("Cinema listings source"))
    }

    func testResolvePendingCapabilityInputDropsToGPTDiscoveryWithoutURL() {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.generalQnA) },
            route: { _ in fatalError("unused") }
        )

        let resolution = router.resolvePendingCapabilityInput(
            PendingCapabilityInput(
                pendingRequest: Self.makeExternalRequest(reminderCount: 0),
                text: "not sure yet",
                now: Date(timeIntervalSince1970: 200)
            )
        )

        guard case .drop(let message) = resolution else {
            return XCTFail("Expected drop")
        }
        XCTAssertTrue(message.lowercased().contains("without a url"))
        XCTAssertTrue(message.lowercased().contains("gpt"))
    }
}
