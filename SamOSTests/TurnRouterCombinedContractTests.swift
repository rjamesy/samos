import XCTest
import AppKit
@testable import SamOS

@MainActor
final class TurnRouterCombinedContractTests: XCTestCase {

    private final class CombinedRouteTransportStub: OllamaTransport, OllamaWireTimedTransport {
        var responseText: String
        var wireMs: Int
        private(set) var wireTimedCallCount: Int = 0

        init(responseText: String, wireMs: Int = 10) {
            self.responseText = responseText
            self.wireMs = wireMs
        }

        func chat(messages: [[String: String]], model: String?, maxOutputTokens: Int?) async throws -> String {
            _ = messages
            _ = model
            _ = maxOutputTokens
            return responseText
        }

        func chatWithWireTiming(messages: [[String: String]], model: String?, maxOutputTokens: Int?) async throws -> (responseText: String, wireMs: Int) {
            _ = messages
            _ = model
            _ = maxOutputTokens
            wireTimedCallCount += 1
            return (responseText, wireMs)
        }
    }

    private struct NoopOpenAITransport: OpenAITransport {
        func chat(messages: [[String: String]], model: String, maxOutputTokens: Int?) async throws -> String {
            _ = messages
            _ = model
            _ = maxOutputTokens
            throw OpenAIRouter.OpenAIError.requestFailed("unexpected OpenAI transport call")
        }

        func chat(messages: [[String: String]], model: String, maxOutputTokens: Int?, responseFormat: [String: Any]?, temperature: Double?) async throws -> String {
            _ = responseFormat
            _ = temperature
            return try await chat(messages: messages, model: model, maxOutputTokens: maxOutputTokens)
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
            _ = input
            _ = timeoutSeconds
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
            _ = request
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
            _ = originalInput
            _ = pendingSlotName
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

        func executeTool(_ action: ToolAction) -> OutputItem? {
            _ = action
            return nil
        }
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

    override func setUp() {
        super.setUp()
        savedUseOllama = M2Settings.useOllama
        savedAPIKey = OpenAISettings.apiKey
        M2Settings.useOllama = true
        OpenAISettings.apiKey = "test-openai-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-openai-key"
    }

    override func tearDown() {
        M2Settings.useOllama = savedUseOllama
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

    private var validCombinedResponse: String {
        """
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
    }

    func testVoiceCombinedRoutingUsesSingleLocalCallWhenSchemaValid() async {
        let localTransport = CombinedRouteTransportStub(responseText: validCombinedResponse, wireMs: 12)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"general_qna","confidence":0.8,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        let result = await orchestrator.processTurn("hello", history: [], inputMode: .voice)

        XCTAssertEqual(localTransport.wireTimedCallCount, 1)
        XCTAssertEqual(openAIProvider.classifyCalls, 0)
        XCTAssertEqual(openAIProvider.routePlanCalls, 0)
        XCTAssertEqual(result.llmProvider, .ollama)
        XCTAssertEqual(result.intentProviderSelected, .ollama)
        XCTAssertEqual(result.routeLocalOutcome, "ok")
    }

    func testVoiceCombinedRoutingFallsBackToOpenAIOnSchemaFailure() async {
        let invalidSchema = #"{"intent":"general_qna","confidence":0.91}"#
        let localTransport = CombinedRouteTransportStub(responseText: invalidSchema, wireMs: 15)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"general_qna","confidence":0.87,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        let result = await orchestrator.processTurn("hello", history: [], inputMode: .voice)

        XCTAssertEqual(localTransport.wireTimedCallCount, 1)
        XCTAssertEqual(openAIProvider.classifyCalls, 1)
        XCTAssertEqual(openAIProvider.routePlanCalls, 1)
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertEqual(result.intentProviderSelected, .openai)
        XCTAssertEqual(result.routeLocalOutcome, "schema_fail")
        XCTAssertEqual(result.originReason, "combined_local_schema_fail_openai_fallback")
    }

    func testVoiceCombinedRoutingFallsBackToOpenAIOnLocalDeadline() async {
        let localTransport = CombinedRouteTransportStub(
            responseText: validCombinedResponse,
            wireMs: RouterTimeouts.localCombinedDeadlineMs + 250
        )
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"general_qna","confidence":0.86,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        let result = await orchestrator.processTurn("hello", history: [], inputMode: .voice)

        XCTAssertEqual(localTransport.wireTimedCallCount, 1)
        XCTAssertEqual(openAIProvider.classifyCalls, 1)
        XCTAssertEqual(openAIProvider.routePlanCalls, 1)
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertEqual(result.intentProviderSelected, .openai)
        XCTAssertEqual(result.routeLocalOutcome, "timeout")
        XCTAssertEqual(result.originReason, "combined_local_timeout_openai_fallback")
    }

    func testVoiceCombinedRoutingSkipsLocalWhenOllamaDisabled() async {
        M2Settings.useOllama = false

        let localTransport = CombinedRouteTransportStub(responseText: validCombinedResponse, wireMs: 10)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"general_qna","confidence":0.84,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        let result = await orchestrator.processTurn("hello", history: [], inputMode: .voice)

        XCTAssertEqual(localTransport.wireTimedCallCount, 0)
        XCTAssertEqual(openAIProvider.classifyCalls, 1)
        XCTAssertEqual(openAIProvider.routePlanCalls, 1)
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertEqual(result.routeLocalOutcome, "local_disabled")
        XCTAssertEqual(result.originReason, "combined_local_disabled_openai")
    }
}
