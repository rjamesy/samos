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

    func testResolvePendingCapabilityInputAsksThenDropsWithoutURL() {
        let router = makeRouter(
            classify: { _, _, _ in Self.makeClassification(.generalQnA) },
            route: { _ in fatalError("unused") }
        )

        let first = router.resolvePendingCapabilityInput(
            PendingCapabilityInput(
                pendingRequest: Self.makeExternalRequest(reminderCount: 0),
                text: "not sure yet",
                now: Date(timeIntervalSince1970: 200)
            )
        )

        guard case .askForSource(_, _, let updatedRequest) = first else {
            return XCTFail("Expected askForSource")
        }
        XCTAssertEqual(updatedRequest.reminderCount, 1)

        let second = router.resolvePendingCapabilityInput(
            PendingCapabilityInput(
                pendingRequest: updatedRequest,
                text: "still no link",
                now: Date(timeIntervalSince1970: 300)
            )
        )

        guard case .drop(let message) = second else {
            return XCTFail("Expected drop")
        }
        XCTAssertTrue(message.contains("exact URL"))
    }
}
