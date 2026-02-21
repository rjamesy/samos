import XCTest
import AppKit
@testable import SamOS

@MainActor
final class CombinedTimeoutBudgetTests: XCTestCase {

    private final class CombinedRouteTransportStub: OllamaTransport, OllamaWireTimedTransport {
        var responseText: String
        var wireMs: Int
        private(set) var wireTimedCallCount: Int = 0
        private(set) var capturedDeadlineMs: [Int] = []

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
    private var savedTimeout = 3500

    override func setUp() {
        super.setUp()
        savedUseOllama = M2Settings.useOllama
        savedAPIKey = OpenAISettings.apiKey
        savedTimeout = M2Settings.ollamaCombinedTimeoutMs
        M2Settings.useOllama = true
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

    // MARK: - Timeout Budget Tests

    func testDefaultTimeoutIs3500Ms() {
        M2Settings.ollamaCombinedTimeoutMs = 3500
        XCTAssertEqual(RouterTimeouts.localCombinedDeadlineMs, 3500)
        XCTAssertEqual(RouterTimeouts.localCombinedDeadlineSeconds, 3.5, accuracy: 0.001)
    }

    func testSettingsChangeAffectsRouterTimeouts() {
        M2Settings.ollamaCombinedTimeoutMs = 3500
        XCTAssertEqual(RouterTimeouts.localCombinedDeadlineMs, 3500)

        M2Settings.ollamaCombinedTimeoutMs = 3000
        XCTAssertEqual(RouterTimeouts.localCombinedDeadlineMs, 3000)
        XCTAssertEqual(RouterTimeouts.localCombinedDeadlineSeconds, 3.0, accuracy: 0.001)
    }

    func testTimeoutClampedToMinimum500() {
        M2Settings.ollamaCombinedTimeoutMs = 100
        XCTAssertEqual(M2Settings.ollamaCombinedTimeoutMs, 500)
        XCTAssertEqual(RouterTimeouts.localCombinedDeadlineMs, 500)
    }

    func testTimeoutClampedToMaximum10000() {
        M2Settings.ollamaCombinedTimeoutMs = 20000
        XCTAssertEqual(M2Settings.ollamaCombinedTimeoutMs, 10000)
        XCTAssertEqual(RouterTimeouts.localCombinedDeadlineMs, 10000)
    }

    func testTimeoutMidSessionChangeAffectsNextTurn() async {
        M2Settings.ollamaCombinedTimeoutMs = 3500
        XCTAssertEqual(RouterTimeouts.localCombinedDeadlineMs, 3500)

        let localTransport = CombinedRouteTransportStub(responseText: validCombinedResponse, wireMs: 10)
        let openAIProvider = OpenAIProviderStub(
            intentRawJSON: #"{"intent":"general_qna","confidence":0.8,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#
        )
        let toolRunner = ToolRunnerStub()
        let orchestrator = makeOrchestrator(
            localTransport: localTransport,
            openAIProvider: openAIProvider,
            toolRunner: toolRunner
        )

        // Turn 1 at 3500ms budget
        let result1 = await orchestrator.processTurn("turn 1", history: [], inputMode: .voice)
        XCTAssertEqual(result1.llmProvider, .ollama)

        // Change timeout mid-session
        M2Settings.ollamaCombinedTimeoutMs = 2000
        XCTAssertEqual(RouterTimeouts.localCombinedDeadlineMs, 2000)

        // Turn 2 should use new budget (still succeeds since wireMs=10)
        let result2 = await orchestrator.processTurn("turn 2", history: [], inputMode: .voice)
        XCTAssertEqual(result2.llmProvider, .ollama)
    }

    func testSecondsConversionAccurate() {
        let testCases: [(ms: Int, expectedSeconds: Double)] = [
            (500, 0.5),
            (1000, 1.0),
            (2500, 2.5),
            (3500, 3.5),
            (5000, 5.0),
            (10000, 10.0)
        ]
        for tc in testCases {
            M2Settings.ollamaCombinedTimeoutMs = tc.ms
            XCTAssertEqual(RouterTimeouts.localCombinedDeadlineSeconds, tc.expectedSeconds, accuracy: 0.001,
                           "Expected \(tc.expectedSeconds)s for \(tc.ms)ms")
        }
    }
}
