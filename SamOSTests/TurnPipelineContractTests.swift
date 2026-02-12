import XCTest
@testable import SamOS

private final class ContractImageURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class TurnPipelineContractTests: XCTestCase {
    private final class ContractToolsRuntime: ToolsRuntimeProtocol {
        var outputsByToolName: [String: OutputItem] = [:]
        private(set) var actions: [ToolAction] = []

        func execute(_ toolAction: ToolAction) -> OutputItem? {
            actions.append(toolAction)
            return outputsByToolName[toolAction.name]
        }

        func toolExists(_ name: String) -> Bool {
            outputsByToolName[name] != nil
        }
    }

    private struct TurnScript {
        let input: String
        let expectedProvider: LLMProvider
        let expectedRouteReason: String
        let expectedToolName: String?
    }

    private func makeRouter(routeByInput: @escaping (String, PendingSlot?) -> RouteDecision) -> TurnRouter {
        TurnRouter(
            classifyIntent: { _, _, _ in
                IntentClassificationResult(
                    classification: IntentClassification(
                        intent: .webRequest,
                        confidence: 0.95,
                        notes: "",
                        autoCaptureHint: false,
                        needsWeb: true
                    ),
                    provider: .rule,
                    attemptedLocal: true,
                    attemptedOpenAI: false,
                    localSkipReason: nil,
                    intentRouterMsLocal: 5,
                    intentRouterMsOpenAI: nil,
                    localConfidence: 0.95,
                    openAIConfidence: nil,
                    confidenceThreshold: 0.70,
                    localTimeoutSeconds: nil,
                    escalationReason: nil
                )
            },
            routePlan: { request in
                routeByInput(request.text, request.pendingSlot)
            },
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

    func testScriptedTurnContracts() async {
        let runtime = ContractToolsRuntime()
        runtime.outputsByToolName["get_weather"] = OutputItem(
            kind: .markdown,
            payload: #"{"spoken":"It's 26°C and clear in Brisbane.","formatted":"26°C and clear in Brisbane."}"#
        )
        runtime.outputsByToolName["show_image"] = OutputItem(
            kind: .image,
            payload: #"{"urls":["https://images.example.com/ok.jpg"],"alt":"Example image"}"#
        )
        runtime.outputsByToolName["show_text"] = OutputItem(
            kind: .markdown,
            payload: #"{"spoken":"\#(String(repeating: "Long output line ", count: 40))","formatted":"Long detailed report"}"#
        )

        let speechCoordinator = SpeechCoordinator()
        let executor = PlanExecutor(toolsRuntime: runtime, speechCoordinator: speechCoordinator)
        let toolRunner = TurnToolRunner(planExecutor: executor, toolsRuntime: runtime)

        let router = makeRouter { input, pendingSlot in
            switch input.lowercased() {
            case "brisbane":
                XCTAssertNotNil(pendingSlot, "Weather slot should be active before resolution turn")
                return RouteDecision(
                    plan: Plan(steps: [.tool(name: "get_weather", args: ["place": .string("Brisbane")], say: nil)]),
                    provider: .openai,
                    routerMs: 12,
                    aiModelUsed: "gpt-test",
                    routeReason: "pending_slot_weather_resolved",
                    planLocalWireMs: nil,
                    planLocalTotalMs: nil,
                    planOpenAIMs: 12
                )
            case "image url":
                return RouteDecision(
                    plan: Plan(steps: [.tool(name: "show_image", args: ["query": .string("frog")], say: nil)]),
                    provider: .openai,
                    routerMs: 10,
                    aiModelUsed: "gpt-test",
                    routeReason: "image_probe_contract",
                    planLocalWireMs: nil,
                    planLocalTotalMs: nil,
                    planOpenAIMs: 10
                )
            case "tts slow start":
                return RouteDecision(
                    plan: Plan(steps: [.talk(say: "Still working through it.")]),
                    provider: .openai,
                    routerMs: 9,
                    aiModelUsed: "gpt-test",
                    routeReason: "tts_slow_start_contract",
                    planLocalWireMs: nil,
                    planLocalTotalMs: nil,
                    planOpenAIMs: 9
                )
            case "tool output long":
                return RouteDecision(
                    plan: Plan(steps: [.tool(name: "show_text", args: ["markdown": .string("# report")], say: nil)]),
                    provider: .openai,
                    routerMs: 11,
                    aiModelUsed: "gpt-test",
                    routeReason: "tool_output_long_contract",
                    planLocalWireMs: nil,
                    planLocalTotalMs: nil,
                    planOpenAIMs: 11
                )
            case "ollama schema fail":
                return RouteDecision(
                    plan: Plan(steps: [.talk(say: "Recovered on OpenAI fallback.")]),
                    provider: .openai,
                    routerMs: 14,
                    aiModelUsed: "gpt-test",
                    routeReason: "ollama_schema_fallback_contract",
                    planLocalWireMs: 2,
                    planLocalTotalMs: 4,
                    planOpenAIMs: 10
                )
            default:
                return RouteDecision(
                    plan: Plan(steps: [.talk(say: "Unexpected input")]),
                    provider: .none,
                    routerMs: 0,
                    aiModelUsed: nil,
                    routeReason: "unexpected",
                    planLocalWireMs: nil,
                    planLocalTotalMs: nil,
                    planOpenAIMs: nil
                )
            }
        }

        let scripts: [TurnScript] = [
            TurnScript(input: "Brisbane", expectedProvider: .openai, expectedRouteReason: "pending_slot_weather_resolved", expectedToolName: "get_weather"),
            TurnScript(input: "image url", expectedProvider: .openai, expectedRouteReason: "image_probe_contract", expectedToolName: "show_image"),
            TurnScript(input: "tts slow start", expectedProvider: .openai, expectedRouteReason: "tts_slow_start_contract", expectedToolName: nil),
            TurnScript(input: "tool output long", expectedProvider: .openai, expectedRouteReason: "tool_output_long_contract", expectedToolName: "show_text"),
            TurnScript(input: "ollama schema fail", expectedProvider: .openai, expectedRouteReason: "ollama_schema_fallback_contract", expectedToolName: nil)
        ]

        let imageConfig = URLSessionConfiguration.ephemeral
        imageConfig.protocolClasses = [ContractImageURLProtocol.self]
        ContractImageURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://images.example.com/ok.jpg")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/jpeg"]
            )!
            return (response, nil)
        }
        #if DEBUG
        ImageProber.setSessionForTesting(URLSession(configuration: imageConfig))
        #endif

        defer {
            #if DEBUG
            ImageProber.setSessionForTesting(nil)
            #endif
            ContractImageURLProtocol.handler = nil
        }

        var pendingSlot: PendingSlot? = PendingSlot(
            slotName: "place",
            prompt: "Which city?",
            originalUserText: "weather"
        )
        var pendingCapability: PendingCapabilityRequest?

        let savedMaxSpeakChars = M2Settings.maxSpeakChars
        M2Settings.maxSpeakChars = 120
        defer { M2Settings.maxSpeakChars = savedMaxSpeakChars }

        var observedRouteReasons: [String] = []

        for script in scripts {
            let evaluation = router.evaluatePendingSlot(
                pendingSlot,
                pendingCapabilityRequest: pendingCapability,
                now: Date()
            )
            pendingSlot = evaluation.pendingSlot
            pendingCapability = evaluation.pendingCapabilityRequest

            let decision = await router.routePlan(
                TurnPlanRouteRequest(
                    text: script.input,
                    history: [],
                    pendingSlot: pendingSlot,
                    reason: .userChat,
                    promptContext: nil
                )
            )
            observedRouteReasons.append(decision.routeReason)
            XCTAssertEqual(decision.routeReason, script.expectedRouteReason)
            XCTAssertEqual(decision.provider, script.expectedProvider)

            let slotResolution = router.resolvePendingSlotAfterPlan(
                decision.plan,
                previousSlot: pendingSlot,
                pendingCapabilityRequest: pendingCapability
            )
            pendingSlot = slotResolution.pendingSlot
            pendingCapability = slotResolution.pendingCapabilityRequest

            if script.input == "tts slow start" {
                speechCoordinator.recordSlowStart(correlationID: "contract-turn-3")
            }

            let run = await toolRunner.executePlan(
                decision.plan,
                originalInput: script.input,
                pendingSlotName: pendingSlot?.slotName
            )

            if let expectedToolName = script.expectedToolName {
                XCTAssertEqual(run.executedToolSteps.last?.name, expectedToolName)
            } else {
                XCTAssertTrue(run.executedToolSteps.isEmpty || run.executedToolSteps.last?.name != nil)
            }

            if script.input == "image url" {
                XCTAssertNil(run.pendingSlotRequest, "Image probe should pass without repair prompt")
                XCTAssertTrue(run.outputItems.contains(where: { $0.kind == .image }))
            }

            if script.input == "tool output long" {
                let spoken = run.spokenLines.first ?? ""
                XCTAssertLessThanOrEqual(spoken.count, 120, "Long tool output speech should be capped")
            }
        }

        XCTAssertNil(pendingSlot, "Pending slot should be resolved after weather city turn")
        XCTAssertEqual(speechCoordinator.lastSlowStartCorrelationID, "contract-turn-3", "Slow-start tracking should be retained")
        XCTAssertTrue(observedRouteReasons.contains("ollama_schema_fallback_contract"))
    }
}
