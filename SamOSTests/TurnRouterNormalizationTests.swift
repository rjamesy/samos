import XCTest
import AppKit
@testable import SamOS

@MainActor
final class TurnRouterNormalizationTests: XCTestCase {

    private final class CombinedRouteTransportStub: OllamaTransport, OllamaWireTimedTransport {
        var responseText: String
        var wireMs: Int
        private(set) var wireTimedCallCount: Int = 0

        init(responseText: String, wireMs: Int = 10) {
            self.responseText = responseText
            self.wireMs = wireMs
        }

        func chat(messages: [[String: String]], model: String?, maxOutputTokens: Int?) async throws -> String {
            responseText
        }

        func chatWithWireTiming(messages: [[String: String]], model: String?, maxOutputTokens: Int?) async throws -> (responseText: String, wireMs: Int) {
            wireTimedCallCount += 1
            return (responseText, wireMs)
        }
    }

    private struct NoopOpenAITransport: OpenAITransport {
        func chat(messages: [[String: String]], model: String, maxOutputTokens: Int?) async throws -> String {
            throw OpenAIRouter.OpenAIError.requestFailed("unexpected OpenAI transport call")
        }

        func chat(messages: [[String: String]], model: String, maxOutputTokens: Int?, responseFormat: [String: Any]?, temperature: Double?) async throws -> String {
            try await chat(messages: messages, model: model, maxOutputTokens: maxOutputTokens)
        }
    }

    private final class OpenAIProviderStub: OpenAIProviderRouting {
        var intentRawJSON: String
        var plan: Plan
        private(set) var classifyCalls: Int = 0
        private(set) var routePlanCalls: Int = 0

        init(intentRawJSON: String,
             plan: Plan = Plan(steps: [.talk(say: "OpenAI fallback route")])) {
            self.intentRawJSON = intentRawJSON
            self.plan = plan
        }

        func classifyIntentWithRetry(_ input: IntentClassifierInput,
                                     timeoutSeconds: Double?) async throws -> OpenAIIntentDecision {
            classifyCalls += 1
            return OpenAIIntentDecision(
                output: IntentLLMCallOutput(
                    rawText: intentRawJSON,
                    model: "gpt-4o-mini",
                    endpoint: "https://api.openai.com/v1/chat/completions",
                    prompt: "intent"
                ),
                didRetry: false
            )
        }

        func routePlanWithRetry(_ request: OpenAIPlanRequest) async throws -> OpenAIPlanDecision {
            routePlanCalls += 1
            return OpenAIPlanDecision(plan: plan, didRetry: false)
        }
    }

    @MainActor
    private final class ToolRunnerStub: TurnToolRunning {
        private(set) var plans: [Plan] = []

        func executePlan(_ plan: Plan,
                         originalInput: String,
                         pendingSlotName: String?) async -> ToolRunResult {
            plans.append(plan)
            var result = ToolRunResult()
            if let first = plan.steps.first {
                switch first {
                case .talk(let say):
                    result.chatMessages = [ChatMessage(role: .assistant, text: say)]
                    result.spokenLines = [say]
                case .tool(let name, _, _):
                    result.chatMessages = [ChatMessage(role: .assistant, text: "Executed \(name)")]
                    result.spokenLines = ["Executed \(name)"]
                    result.executedToolSteps = [(name: name, args: [:])]
                default:
                    result.chatMessages = [ChatMessage(role: .assistant, text: "ok")]
                    result.spokenLines = ["ok"]
                }
            }
            return result
        }

        func executeTool(_ action: ToolAction) -> OutputItem? { nil }
    }

    private final class CameraStub: CameraVisionProviding {
        var isRunning: Bool = false
        var latestFrameAt: Date? = nil

        func start() throws {}
        func stop() {}
        func latestPreviewImage() -> NSImage? { nil }
        func describeCurrentScene() -> CameraSceneDescription? { nil }
        func currentAnalysis() -> CameraFrameAnalysis? { nil }
    }

    private var savedUseOllama = false
    private var savedAPIKey = ""
    private var savedTimeout = 3000

    override func setUp() {
        super.setUp()
        savedUseOllama = M2Settings.useOllama
        savedAPIKey = OpenAISettings.apiKey
        savedTimeout = M2Settings.ollamaCombinedTimeoutMs
        M2Settings.useOllama = true
        M2Settings.ollamaCombinedTimeoutMs = 5000
        OpenAISettings.apiKey = "test-openai-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-openai-key"
    }

    override func tearDown() {
        M2Settings.useOllama = savedUseOllama
        M2Settings.ollamaCombinedTimeoutMs = savedTimeout
        OpenAISettings.apiKey = savedAPIKey
        OpenAISettings._resetCacheForTesting()
        super.tearDown()
    }

    private func makeOrchestrator(localTransport: CombinedRouteTransportStub,
                                  openAIProvider: OpenAIProviderStub,
                                  toolRunner: ToolRunnerStub) -> TurnOrchestrator {
        let ollamaRouter = OllamaRouter(transport: localTransport)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: NoopOpenAITransport())
        return TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            cameraVision: CameraStub(),
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )
    }

    // MARK: - Normalization Tests

    func testBareActionTalkIsNormalizedToValidCombinedResult() async {
        let bareAction = #"{"action":"TALK","say":"hi"}"#
        let localTransport = CombinedRouteTransportStub(responseText: bareAction, wireMs: 10)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"greeting","confidence":0.9,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        let result = await orchestrator.processTurn("hi", history: [], inputMode: .voice)

        XCTAssertEqual(localTransport.wireTimedCallCount, 1)
        XCTAssertEqual(openAIProvider.classifyCalls, 0, "OpenAI should not be called when bare action is normalized")
        XCTAssertEqual(openAIProvider.routePlanCalls, 0)
        XCTAssertEqual(result.llmProvider, .ollama)
        XCTAssertEqual(result.routeLocalOutcome, "ok")
    }

    func testBarePlanWithStepsIsNormalized() async {
        let barePlan = #"{"action":"PLAN","steps":[{"step":"talk","say":"hello there"}]}"#
        let localTransport = CombinedRouteTransportStub(responseText: barePlan, wireMs: 10)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"greeting","confidence":0.9,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        let result = await orchestrator.processTurn("hello", history: [], inputMode: .voice)

        XCTAssertEqual(localTransport.wireTimedCallCount, 1)
        XCTAssertEqual(openAIProvider.classifyCalls, 0, "OpenAI should not be called for normalized bare PLAN")
        XCTAssertEqual(openAIProvider.routePlanCalls, 0)
        XCTAssertEqual(result.llmProvider, .ollama)
        XCTAssertEqual(result.routeLocalOutcome, "ok")
    }

    func testGreetingDetectedFromBareTalk() async {
        let bareGreeting = #"{"action":"TALK","say":"hello there!"}"#
        let router = OllamaRouter(transport: CombinedRouteTransportStub(responseText: bareGreeting, wireMs: 5))

        let result = try? await router.routeCombinedWithTiming(
            "hello",
            state: TurnRouterState(cameraRunning: false, faceKnown: false, pendingSlot: nil, lastAssistantLine: nil),
            wireDeadlineMs: 5000
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.result.classification.intent, .greeting)
        XCTAssertEqual(result?.result.classification.notes, "normalized_from_bare_action")
    }

    func testNonGreetingDetectedFromBareTalk() async {
        let bareTalk = #"{"action":"TALK","say":"The weather is nice today"}"#
        let router = OllamaRouter(transport: CombinedRouteTransportStub(responseText: bareTalk, wireMs: 5))

        let result = try? await router.routeCombinedWithTiming(
            "how's the weather",
            state: TurnRouterState(cameraRunning: false, faceKnown: false, pendingSlot: nil, lastAssistantLine: nil),
            wireDeadlineMs: 5000
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.result.classification.intent, .generalQnA)
        XCTAssertEqual(result?.result.classification.notes, "normalized_from_bare_action")
    }

    func testInvalidPlanStepsConvertedToTalkFallback() async {
        // Envelope is valid but plan steps are strings instead of objects
        let invalidPlanSteps = """
        {
          "intent": "general_qna",
          "confidence": 0.85,
          "autoCaptureHint": false,
          "needsWeb": false,
          "notes": "",
          "plan": {
            "action": "PLAN",
            "steps": ["step1", "step2"]
          }
        }
        """
        let localTransport = CombinedRouteTransportStub(responseText: invalidPlanSteps, wireMs: 10)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"general_qna","confidence":0.8,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        let result = await orchestrator.processTurn("tell me something", history: [], inputMode: .voice)

        // Should normalize to a talk fallback rather than falling back to OpenAI
        XCTAssertEqual(localTransport.wireTimedCallCount, 1)
        XCTAssertEqual(openAIProvider.classifyCalls, 0, "OpenAI should not be called when invalid plan is normalized to talk fallback")
        XCTAssertEqual(openAIProvider.routePlanCalls, 0)
        XCTAssertEqual(result.llmProvider, .ollama)
        XCTAssertEqual(result.routeLocalOutcome, "ok")
    }

    func testValidCombinedResponsePassesThroughUnchanged() async {
        let validCombined = """
        {
          "intent": "general_qna",
          "confidence": 0.92,
          "autoCaptureHint": false,
          "needsWeb": false,
          "notes": "",
          "plan": {
            "action": "PLAN",
            "steps": [
              { "step": "talk", "say": "Local combined route." }
            ]
          }
        }
        """
        let localTransport = CombinedRouteTransportStub(responseText: validCombined, wireMs: 12)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"general_qna","confidence":0.8,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        let result = await orchestrator.processTurn("test", history: [], inputMode: .voice)

        XCTAssertEqual(localTransport.wireTimedCallCount, 1)
        XCTAssertEqual(openAIProvider.classifyCalls, 0)
        XCTAssertEqual(openAIProvider.routePlanCalls, 0)
        XCTAssertEqual(result.llmProvider, .ollama)
        XCTAssertEqual(result.routeLocalOutcome, "ok")
    }
}
