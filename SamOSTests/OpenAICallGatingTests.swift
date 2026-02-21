import XCTest
import AppKit
@testable import SamOS

@MainActor
final class OpenAICallGatingTests: XCTestCase {

    private final class CombinedRouteTransportStub: OllamaTransport, OllamaWireTimedTransport {
        var responseText: String
        var wireMs: Int
        var shouldThrow: Error?
        private(set) var wireTimedCallCount: Int = 0

        init(responseText: String, wireMs: Int = 10, shouldThrow: Error? = nil) {
            self.responseText = responseText
            self.wireMs = wireMs
            self.shouldThrow = shouldThrow
        }

        func chat(messages: [[String: String]], model: String?, maxOutputTokens: Int?) async throws -> String {
            if let error = shouldThrow { throw error }
            return responseText
        }

        func chatWithWireTiming(messages: [[String: String]], model: String?, maxOutputTokens: Int?) async throws -> (responseText: String, wireMs: Int) {
            wireTimedCallCount += 1
            if let error = shouldThrow { throw error }
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
        var health: CameraHealth { CameraHealth(lastGoodFrameAt: nil, lastFrameErrorAt: nil, consecutiveErrors: 0, isHealthy: true) }
        func enrollFace(name: String) -> CameraFaceEnrollmentResult { .init(status: .unsupported, enrolledName: nil, samplesForName: 0, totalKnownNames: 0, capturedAt: nil) }
        func recognizeKnownFaces() -> CameraFaceRecognitionResult? { nil }
        func knownFaceNames() -> [String] { [] }
        func clearKnownFaces() -> Bool { false }
        func detectFacialEmotions() -> CameraEmotionSnapshot? { nil }
        func captureFrameAsJPEG(quality: CGFloat) -> Data? { nil }
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

    // MARK: - Gating Tests

    func testLocalSuccessDoesNotCallOpenAI() async {
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

        _ = await orchestrator.processTurn("hello", history: [], inputMode: .voice)

        XCTAssertEqual(openAIProvider.classifyCalls, 0, "OpenAI classify should not be called on local success")
        XCTAssertEqual(openAIProvider.routePlanCalls, 0, "OpenAI routePlan should not be called on local success")
    }

    func testLocalSchemaFailCallsOpenAIExactlyOnce() async {
        // Missing plan object — strict schema fail
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

        _ = await orchestrator.processTurn("hello", history: [], inputMode: .voice)

        XCTAssertEqual(openAIProvider.classifyCalls, 1, "OpenAI classify should be called exactly once on schema fail")
        XCTAssertEqual(openAIProvider.routePlanCalls, 1, "OpenAI routePlan should be called exactly once on schema fail")
    }

    func testLocalTimeoutCallsOpenAIExactlyOnce() async {
        let localTransport = CombinedRouteTransportStub(
            responseText: validCombinedResponse,
            wireMs: M2Settings.ollamaCombinedTimeoutMs + 250
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

        _ = await orchestrator.processTurn("hello", history: [], inputMode: .voice)

        XCTAssertEqual(openAIProvider.classifyCalls, 1, "OpenAI classify should be called exactly once on timeout")
        XCTAssertEqual(openAIProvider.routePlanCalls, 1, "OpenAI routePlan should be called exactly once on timeout")
    }

    func testLocalOtherErrorDoesNotCallOpenAI() async {
        // Connection error — .other failure kind, no fallback
        let localTransport = CombinedRouteTransportStub(
            responseText: "",
            wireMs: 10,
            shouldThrow: OllamaRouter.OllamaError.unreachable("Connection refused")
        )
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"general_qna","confidence":0.8,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        _ = await orchestrator.processTurn("hello", history: [], inputMode: .voice)

        XCTAssertEqual(openAIProvider.classifyCalls, 0, "OpenAI should not be called on connection error (.other)")
        XCTAssertEqual(openAIProvider.routePlanCalls, 0, "OpenAI should not be called on connection error (.other)")
    }
}
