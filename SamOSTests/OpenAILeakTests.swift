import XCTest
import AppKit
@testable import SamOS

@MainActor
final class OpenAILeakTests: XCTestCase {

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
    private var savedTimeout = 3500

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

    // MARK: - Leak Tests

    func testLocalSuccessGreetingNoOpenAILeak() async {
        // Valid combined envelope — OpenAI should NOT be called
        let validGreeting = """
        {
          "intent": "greeting",
          "confidence": 0.95,
          "autoCaptureHint": false,
          "needsWeb": false,
          "notes": "",
          "plan": {
            "action": "PLAN",
            "steps": [
              { "step": "talk", "say": "Hello! How can I help?" }
            ]
          }
        }
        """
        let localTransport = CombinedRouteTransportStub(responseText: validGreeting, wireMs: 10)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"greeting","confidence":0.9,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        _ = await orchestrator.processTurn("hello", history: [], inputMode: .voice)

        XCTAssertEqual(openAIProvider.classifyCalls, 0, "OpenAI classify must not fire on valid local greeting")
        XCTAssertEqual(openAIProvider.routePlanCalls, 0, "OpenAI routePlan must not fire on valid local greeting")
    }

    func testLocalSuccessQnANoOpenAILeak() async {
        let validCombined = """
        {
          "intent": "general_qna",
          "confidence": 0.88,
          "autoCaptureHint": false,
          "needsWeb": false,
          "notes": "",
          "plan": {
            "action": "PLAN",
            "steps": [
              { "step": "talk", "say": "The capital of France is Paris." }
            ]
          }
        }
        """
        let localTransport = CombinedRouteTransportStub(responseText: validCombined, wireMs: 10)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"general_qna","confidence":0.88,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        _ = await orchestrator.processTurn("what is the capital of France", history: [], inputMode: .voice)

        XCTAssertEqual(openAIProvider.classifyCalls, 0, "OpenAI classify must not fire on valid local QnA")
        XCTAssertEqual(openAIProvider.routePlanCalls, 0, "OpenAI routePlan must not fire on valid local QnA")
    }

    func testLocalUncertainTalkFallsBackToOpenAI() async {
        let uncertainCombined = """
        {
          "intent": "general_qna",
          "confidence": 0.86,
          "autoCaptureHint": false,
          "needsWeb": false,
          "notes": "",
          "plan": {
            "action": "PLAN",
            "steps": [
              { "step": "talk", "say": "Sorry, I can't find that answer right now." }
            ]
          }
        }
        """
        let localTransport = CombinedRouteTransportStub(responseText: uncertainCombined, wireMs: 10)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"general_qna","confidence":0.92,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#,
            plan: Plan(steps: [.talk(say: "OpenAI fallback answer")])
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        let result = await orchestrator.processTurn("answer this", history: [], inputMode: .voice)

        XCTAssertEqual(openAIProvider.classifyCalls, 1, "Uncertain local TALK should escalate to OpenAI classify")
        XCTAssertEqual(openAIProvider.routePlanCalls, 1, "Uncertain local TALK should escalate to OpenAI planning")
        XCTAssertEqual(result.llmProvider, .openai)
    }

    func testLocalSuccessToolPlanNoOpenAILeak() async {
        let toolPlan = """
        {
          "intent": "automation_request",
          "confidence": 0.93,
          "autoCaptureHint": false,
          "needsWeb": false,
          "notes": "",
          "plan": {
            "action": "PLAN",
            "steps": [
              { "step": "tool", "name": "get_time", "args": {}, "say": "Let me check the time." }
            ]
          }
        }
        """
        let localTransport = CombinedRouteTransportStub(responseText: toolPlan, wireMs: 10)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"automation_request","confidence":0.93,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        _ = await orchestrator.processTurn("what time is it", history: [], inputMode: .voice)

        XCTAssertEqual(openAIProvider.classifyCalls, 0, "OpenAI classify must not fire on valid local tool plan")
        XCTAssertEqual(openAIProvider.routePlanCalls, 0, "OpenAI routePlan must not fire on valid local tool plan")
    }

    func testMultipleTurnsNoOpenAILeak() async {
        let validResponse = """
        {
          "intent": "general_qna",
          "confidence": 0.90,
          "autoCaptureHint": false,
          "needsWeb": false,
          "notes": "",
          "plan": {
            "action": "PLAN",
            "steps": [
              { "step": "talk", "say": "Here is my answer." }
            ]
          }
        }
        """
        let localTransport = CombinedRouteTransportStub(responseText: validResponse, wireMs: 10)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"general_qna","confidence":0.8,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        for i in 1...5 {
            _ = await orchestrator.processTurn("question \(i)", history: [], inputMode: .voice)
        }

        XCTAssertEqual(openAIProvider.classifyCalls, 0, "OpenAI classify must not fire across 5 successful local turns")
        XCTAssertEqual(openAIProvider.routePlanCalls, 0, "OpenAI routePlan must not fire across 5 successful local turns")
        XCTAssertEqual(localTransport.wireTimedCallCount, 5, "Should have made 5 local transport calls")
    }
}
