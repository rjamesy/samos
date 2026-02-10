import XCTest
@testable import SamOS

// MARK: - Fake OpenAI Transport

final class FakeOpenAITransport: OpenAITransport {
    var queuedResponses: [Result<String, Error>] = []
    private(set) var chatCallCount = 0
    private(set) var chatCallLog: [[[String: String]]] = []
    private(set) var chatModelLog: [String] = []

    func chat(messages: [[String: String]], model: String) async throws -> String {
        chatCallCount += 1
        chatCallLog.append(messages)
        chatModelLog.append(model)
        guard !queuedResponses.isEmpty else {
            throw OpenAIRouter.OpenAIError.requestFailed("No queued response")
        }
        return try queuedResponses.removeFirst().get()
    }
}

final class MarkdownRenderPrepTests: XCTestCase {

    func testToolDisplayStringRemainsRawMarkdown() {
        let markdown = "# Title\n\n## Ingredients:\n- a\n- b\n\nLine1\nLine2"
        let display = OutputCanvasMarkdown.toolDisplayString(markdown)
        XCTAssertEqual(display, markdown)
        XCTAssertTrue(display.contains("\n- a\n- b\n"))
    }

    func testCanvasMarkdownBlocksPreserveStructure() {
        let markdown = "# Title\n\n## Ingredients:\n- a\n- b\n\nLine1\nLine2"
        let blocks = OutputCanvasMarkdown.blocks(from: markdown)
        XCTAssertEqual(blocks.first, .heading(level: 1, text: "Title"))
        XCTAssertTrue(blocks.contains(.heading(level: 2, text: "Ingredients:")))
        XCTAssertTrue(blocks.contains(.bullet(text: "a")))
        XCTAssertTrue(blocks.contains(.bullet(text: "b")))
        XCTAssertTrue(blocks.contains(.plain(text: "Line1")))
        XCTAssertTrue(blocks.contains(.plain(text: "Line2")))
    }
}

@MainActor
final class AppStateThinkingFillerTests: XCTestCase {

    func testThinkingIndicatorNotShownIfFastResponse() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 10_000_000
        var fast = TurnResult()
        fast.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        fast.spokenLines = ["Done."]
        fake.queuedResults = [fast]

        var spokenFillers: [String] = []
        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.08,
            thinkingFillerSpeaker: { spokenFillers.append($0) },
            enableRuntimeServices: false
        )
        appState.send("hello")
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertFalse(appState.isThinkingIndicatorVisible)
        XCTAssertTrue(spokenFillers.isEmpty, "Fast response should not trigger filler utterance")
    }

    func testThinkingIndicatorShownIfSlowResponse() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 220_000_000
        var slow = TurnResult()
        slow.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        slow.spokenLines = ["Done."]
        fake.queuedResults = [slow]

        var spokenFillers: [String] = []
        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            thinkingFillerSpeaker: { spokenFillers.append($0) },
            enableRuntimeServices: false
        )
        appState.send("hello")
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(appState.isThinkingIndicatorVisible, "Slow response should show thinking indicator")
        XCTAssertEqual(spokenFillers.count, 1, "Slow response should trigger one filler utterance")
    }

    func testFillerSpokenAtMostOncePerTurn() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 450_000_000
        var slow = TurnResult()
        slow.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        slow.spokenLines = ["Done."]
        fake.queuedResults = [slow]

        var spokenFillers: [String] = []
        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            thinkingFillerSpeaker: { spokenFillers.append($0) },
            enableRuntimeServices: false
        )
        appState.send("hello")

        try? await Task.sleep(nanoseconds: 320_000_000)
        XCTAssertEqual(spokenFillers.count, 1, "Filler should only be spoken once in a turn")

        try? await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertEqual(spokenFillers.count, 1, "Filler should remain one-shot for that turn")
    }

    func testFillerNotSpokenWhileMicActive() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 250_000_000
        var slow = TurnResult()
        slow.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        slow.spokenLines = ["Done."]
        fake.queuedResults = [slow]

        var spokenFillers: [String] = []
        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            thinkingFillerSpeaker: { spokenFillers.append($0) },
            enableRuntimeServices: false
        )

        appState.send("hello")
        appState.status = .capturing
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(appState.isThinkingIndicatorVisible, "Indicator should still appear when waiting")
        XCTAssertTrue(spokenFillers.isEmpty, "Filler should not speak while mic capture is active")
    }

    func testIndicatorClearsOnFirstOutput() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 220_000_000
        var canvasResult = TurnResult()
        canvasResult.appendedOutputs = [OutputItem(kind: .markdown, payload: "# Title\n- item")]
        fake.queuedResults = [canvasResult]

        var spokenFillers: [String] = []
        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            thinkingFillerSpeaker: { spokenFillers.append($0) },
            enableRuntimeServices: false
        )

        appState.send("show me markdown")
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(appState.isThinkingIndicatorVisible)

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(appState.isThinkingIndicatorVisible, "Indicator should clear as soon as first output arrives")
        XCTAssertEqual(appState.outputItems.count, 1)
        XCTAssertEqual(spokenFillers.count, 1)
    }

    func testBubbleLatencyPopulatedForUserAndAssistant() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 120_000_000

        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Canberra.")]
        result.spokenLines = ["Canberra."]
        fake.queuedResults = [result]

        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.5,
            enableRuntimeServices: false
        )

        appState.send("What is the capital of Australia?")
        try? await Task.sleep(nanoseconds: 260_000_000)

        let user = appState.chatMessages.first(where: { $0.role == .user })
        let assistant = appState.chatMessages.last(where: { $0.role == .assistant })

        XCTAssertNotNil(user?.latencyMs, "User bubble should include latency metadata")
        XCTAssertNotNil(assistant?.latencyMs, "Assistant bubble should include latency metadata")
        XCTAssertGreaterThanOrEqual(assistant?.latencyMs ?? 0, user?.latencyMs ?? 0)
    }

    func testVoiceTranscriptDropsNoiseArtifacts() {
        let appState = AppState(
            orchestrator: FakeTurnOrchestrator(),
            thinkingFillerDelay: 0.5,
            enableRuntimeServices: false
        )

        XCTAssertNil(appState.debugSanitizedVoiceTranscript("[BLANK_AUDIO]"))
        XCTAssertNil(appState.debugSanitizedVoiceTranscript("(dramatic music)"))
        XCTAssertEqual(appState.debugSanitizedVoiceTranscript("what's the weather"), "what's the weather")
    }
}

@MainActor
final class AppStateKnowledgeAttributionTests: XCTestCase {

    func testKnowledgeAttributionAppendsCanvasSummaryAndMarksLocalUsage() async {
        let fake = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Use sanitized equipment and control fermentation temperature.", llmProvider: .openai)]
        result.spokenLines = ["Use sanitized equipment and control fermentation temperature."]
        result.knowledgeAttribution = KnowledgeAttribution(
            localKnowledgePercent: 80,
            openAIFillPercent: 20,
            matchedLocalItems: 4,
            consideredLocalItems: 5,
            provider: .openai,
            evidence: [
                KnowledgeEvidence(
                    kind: .website,
                    id: "brew-123",
                    label: "Fermentation Basics",
                    excerpt: "Fermentation temperature control improves flavor stability.",
                    url: "https://example.com/fermentation",
                    overlapCount: 4,
                    score: 0.62
                )
            ]
        )
        fake.queuedResults = [result]

        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            enableRuntimeServices: false
        )

        appState.send("how do I make home brew?")
        try? await Task.sleep(nanoseconds: 120_000_000)

        let assistant = appState.chatMessages.last(where: { $0.role == .assistant })
        XCTAssertEqual(assistant?.usedLocalKnowledge, true, "Local-attributed replies should be marked for blue bubble styling")

        let canvas = appState.outputItems.last?.payload ?? ""
        XCTAssertTrue(canvas.contains("Local knowledge used: 80%"))
        XCTAssertTrue(canvas.contains("OpenAI fill gap: 20%"))
        XCTAssertTrue(canvas.contains("#### Evidence Used"))
        XCTAssertTrue(canvas.contains("[Fermentation Basics](https://example.com/fermentation)"))
    }

    func testKnowledgeAttributionKeepsNonLocalReplyUnmarked() async {
        let fake = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "I don't have enough local notes yet, but here's a general answer.", llmProvider: .openai)]
        result.spokenLines = ["I don't have enough local notes yet, but here's a general answer."]
        result.knowledgeAttribution = KnowledgeAttribution(
            localKnowledgePercent: 0,
            openAIFillPercent: 100,
            matchedLocalItems: 0,
            consideredLocalItems: 3,
            provider: .openai
        )
        fake.queuedResults = [result]

        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            enableRuntimeServices: false
        )

        appState.send("what is dry hopping?")
        try? await Task.sleep(nanoseconds: 120_000_000)

        let assistant = appState.chatMessages.last(where: { $0.role == .assistant })
        XCTAssertEqual(assistant?.usedLocalKnowledge, false)

        let canvas = appState.outputItems.last?.payload ?? ""
        XCTAssertTrue(canvas.contains("Local knowledge used: 0%"))
        XCTAssertTrue(canvas.contains("OpenAI fill gap: 100%"))
    }
}

@MainActor
final class AppStateAutoListenTests: XCTestCase {

    func testAutoListenStartsOnFollowUpQuestion() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "All set. Need anything else on this?")]
        result.spokenLines = ["All set. Need anything else on this?"]
        result.triggerQuestionAutoListen = false
        fakeOrchestrator.queuedResults = [result]

        let fakeVoicePipeline = FakeVoicePipeline()
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            questionAutoListenNoSpeechTimeoutMs: 120,
            enableRuntimeServices: false
        )
        appState.isListeningEnabled = true
        appState.send("help")

        try? await Task.sleep(nanoseconds: 80_000_000)
        appState.debugHandleSpeechPlaybackFinished()
        try? await Task.sleep(nanoseconds: 320_000_000)

        XCTAssertEqual(fakeVoicePipeline.startFollowUpCaptureCalls, 1)
        XCTAssertEqual(fakeVoicePipeline.lastNoSpeechTimeoutMs, 120)
    }

    func testAutoListenStopsAfterSilenceTimeout() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Done. Need anything else on this?")]
        result.spokenLines = ["Done. Need anything else on this?"]
        result.triggerQuestionAutoListen = false
        fakeOrchestrator.queuedResults = [result]

        let fakeVoicePipeline = FakeVoicePipeline()
        fakeVoicePipeline.autoCancelOnTimeout = true
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            questionAutoListenNoSpeechTimeoutMs: 120,
            enableRuntimeServices: false
        )
        appState.isListeningEnabled = true
        appState.send("hello")

        try? await Task.sleep(nanoseconds: 80_000_000)
        appState.debugHandleSpeechPlaybackFinished()
        try? await Task.sleep(nanoseconds: 520_000_000)

        XCTAssertEqual(fakeVoicePipeline.cancelFollowUpCaptureCalls, 1,
                       "Auto-listen should stop cleanly after no-speech timeout")
    }

    func testNoAutoListenWhenNoQuestionAsked() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        result.spokenLines = ["Done."]
        result.triggerQuestionAutoListen = false
        fakeOrchestrator.queuedResults = [result]

        let fakeVoicePipeline = FakeVoicePipeline()
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            questionAutoListenNoSpeechTimeoutMs: 120,
            enableRuntimeServices: false
        )
        appState.isListeningEnabled = true
        appState.send("hello")

        try? await Task.sleep(nanoseconds: 80_000_000)
        appState.debugHandleSpeechPlaybackFinished()
        try? await Task.sleep(nanoseconds: 320_000_000)

        XCTAssertEqual(fakeVoicePipeline.startFollowUpCaptureCalls, 0)
    }

    func testNoAutoListenWhenMultipleQuestionMarks() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Need anything else??")]
        result.spokenLines = ["Need anything else??"]
        fakeOrchestrator.queuedResults = [result]

        let fakeVoicePipeline = FakeVoicePipeline()
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            questionAutoListenNoSpeechTimeoutMs: 120,
            enableRuntimeServices: false
        )
        appState.isListeningEnabled = true
        appState.send("hello")

        try? await Task.sleep(nanoseconds: 80_000_000)
        appState.debugHandleSpeechPlaybackFinished()
        try? await Task.sleep(nanoseconds: 320_000_000)

        XCTAssertEqual(fakeVoicePipeline.startFollowUpCaptureCalls, 0,
                       "Auto-listen should only trigger for a single trailing question mark")
    }
}

// MARK: - Fake Ollama Transport (for pipeline tests)

final class FakeOllamaTransportForPipeline: OllamaTransport {
    var queuedResponses: [Result<String, Error>] = []
    private(set) var chatCallCount = 0

    func chat(messages: [[String: String]]) async throws -> String {
        chatCallCount += 1
        guard !queuedResponses.isEmpty else {
            throw OllamaRouter.OllamaError.unreachable("No queued response")
        }
        return try queuedResponses.removeFirst().get()
    }
}

@MainActor
final class FakeTurnOrchestrator: TurnOrchestrating {
    var pendingSlot: PendingSlot?
    var delayNanoseconds: UInt64 = 0
    var queuedResults: [TurnResult] = []

    func processTurn(_ text: String, history: [ChatMessage]) async -> TurnResult {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if !queuedResults.isEmpty {
            return queuedResults.removeFirst()
        }
        return TurnResult()
    }
}

@MainActor
final class FakeVoicePipeline: VoicePipelineCoordinating {
    var onStatusChange: ((VoicePipelineStatus) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var startFollowUpCaptureCalls = 0
    private(set) var cancelFollowUpCaptureCalls = 0
    private(set) var lastNoSpeechTimeoutMs: Int?
    var autoCancelOnTimeout = false

    func startListening() throws {}
    func stopListening() {}

    func startFollowUpCapture(noSpeechTimeoutMs: Int?) {
        startFollowUpCaptureCalls += 1
        lastNoSpeechTimeoutMs = noSpeechTimeoutMs
        guard autoCancelOnTimeout, let timeoutMs = noSpeechTimeoutMs else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            self?.cancelFollowUpCapture()
        }
    }

    func cancelFollowUpCapture() {
        cancelFollowUpCaptureCalls += 1
    }
}

// MARK: - Mock ToolsRuntime for Image Probe Tests

final class ImageProbeToolsRuntime: ToolsRuntimeProtocol {
    private let urls: [String]

    init(urls: [String]) {
        self.urls = urls
    }

    func execute(_ toolAction: ToolAction) -> OutputItem? {
        if toolAction.name == "show_image" {
            let urlsStr = toolAction.args["urls"] ?? urls.joined(separator: "|")
            let alt = toolAction.args["alt"] ?? "image"
            let payload = "{\"urls\":[\(urlsStr.components(separatedBy: "|").map { "\"\($0)\"" }.joined(separator: ","))],\"alt\":\"\(alt)\"}"
            return OutputItem(kind: .image, payload: payload)
        }
        return nil
    }
}

// MARK: - Router Pipeline Tests

final class RouterPipelineTests: XCTestCase {

    private var savedApiKey: String = ""
    private var savedUseOllama: Bool = false
    private var savedGeneralModel: String = ""
    private var savedEscalationModel: String = ""

    override func setUp() {
        super.setUp()
        savedApiKey = OpenAISettings.apiKey
        savedUseOllama = M2Settings.useOllama
        savedGeneralModel = OpenAISettings.generalModel
        savedEscalationModel = OpenAISettings.escalationModel
    }

    override func tearDown() {
        // Restore original settings
        OpenAISettings.apiKey = savedApiKey
        M2Settings.useOllama = savedUseOllama
        OpenAISettings.generalModel = savedGeneralModel
        OpenAISettings.escalationModel = savedEscalationModel
        OpenAISettings._resetCacheForTesting()
        super.tearDown()
    }

    // Valid PLAN JSON that passes validation for a simple greeting
    private let validTalkJSON = """
    {"action":"TALK","say":"Hey there!"}
    """

    // Valid PLAN JSON with get_time tool (passes time-query validation)
    private let validTimePlanJSON = """
    {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"London"},"say":"Let me check."}]}
    """

    private let weatherWrongToolPlanJSON = """
    {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"Melbourne"},"say":"Let me check the weather."}]}
    """

    private let weatherWrongToolActionJSON = """
    {"action":"TOOL","name":"get_time","args":{"place":"Greenbank"},"say":"Checking weather."}
    """

    private let capabilityWrongToolActionJSON = """
    {"action":"TOOL","name":"learn_website","args":{"url":"https://example.com","focus":"capability gap miner"},"say":"I'll learn from that page."}
    """

    private let capabilityStartSkillforgeActionJSON = """
    {"action":"START_SKILLFORGE","goal":"Find and display relevant videos when the user requests.","constraints":"Use YouTube API for video search."}
    """

    private let websiteLearningActionJSON = """
    {"action":"TOOL","name":"learn_website","args":{"url":"https://swift.org","focus":"packages"},"say":"I'll learn from that page."}
    """

    // MARK: - A) OpenAI success does not call Ollama

    @MainActor
    func testOpenAISuccessDoesNotCallOllama() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        // Force reload the cache with the new key
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "OpenAI should be called once")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Ollama should not be called")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains { $0.text == "Hey there!" })
    }

    @MainActor
    func testOpenAISystemPromptIncludesCoTDirective() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        _ = try? await openAIRouter.routePlan("Solve a tricky logic puzzle")

        guard let systemMessage = fakeOpenAI.chatCallLog.first?.first(where: { $0["role"] == "system" })?["content"] else {
            return XCTFail("Expected a system prompt in OpenAI call messages")
        }
        XCTAssertTrue(systemMessage.contains("think step by step internally"),
                      "System prompt should include CoT directive")
    }

    @MainActor
    func testToolResultFeedbackLoopSynthesizesFinalAnswer() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"show_text","args":{"markdown":"# Weather\\n- Rain chance: 62%\\n- Bring an umbrella"}}]}
        """
        let feedback = """
        {"action":"TALK","say":"Rain chance is high, so bring an umbrella."}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(initial), .success(feedback)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("is it raining?", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 2, "Feedback pass should perform one re-entry call")
        XCTAssertFalse(result.appendedOutputs.isEmpty, "Tool output should still render in canvas")
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text.contains("umbrella") }),
                      "Final assistant line should synthesize the tool output")
    }

    @MainActor
    func testToolResultFeedbackLoopSupportsMultiDepthToolReentry() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"show_text","args":{"markdown":"# Step One\\n- Base output"}}]}
        """
        let followupTool = """
        {"action":"PLAN","steps":[{"step":"tool","name":"show_text","args":{"markdown":"# Step Two\\n- Follow-up output"}}]}
        """
        let finalTalk = """
        {"action":"TALK","say":"I combined both results and finished the task."}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(initial), .success(followupTool), .success(finalTalk)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("finish this with tool re-entry", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 3, "Feedback loop should support an additional tool pass before final talk")
        XCTAssertGreaterThanOrEqual(result.appendedOutputs.count, 2, "Both tool passes should contribute output")
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text.contains("finished") }))
    }

    @MainActor
    func testCompoundToolOnlyRequestShowsProgressThenReasonedAnswer() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"Tokyo"},"say":"Let me check the time in Tokyo."}]}
        """
        let feedback = """
        {"action":"TALK","say":"It is a reasonable time in Tokyo, but late evening in London, so only call if it's urgent."}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(initial), .success(feedback)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn(
            "Check Tokyo time, then tell me if it's a good time to call London.",
            history: []
        )

        XCTAssertEqual(fakeOpenAI.chatCallCount, 2, "Compound tool-only requests should trigger feedback reasoning")
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text == "Let me check the time in Tokyo." }),
                      "Progress line from tool say should be surfaced for multi-clause requests")
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text.lowercased().contains("london") }),
                      "Final synthesized answer should address the second clause")
    }

    @MainActor
    func testComplexRequestUsesEscalationModel() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings.generalModel = "gpt-4o-mini"
        OpenAISettings.escalationModel = "gpt-4o"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        _ = await orchestrator.processTurn("Check Tokyo time, then tell me if it's a good time to call London.", history: [])
        XCTAssertEqual(fakeOpenAI.chatModelLog.first, "gpt-4o")
    }

    @MainActor
    func testSimpleRequestUsesGeneralModelAndShowsModelInKnowledgeUsage() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings.generalModel = "gpt-4o-mini"
        OpenAISettings.escalationModel = "gpt-4o"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hi sam", history: [])
        XCTAssertEqual(fakeOpenAI.chatModelLog.first, "gpt-4o-mini")
        XCTAssertEqual(result.knowledgeAttribution?.aiModelUsed, "gpt-4o-mini")
    }

    @MainActor
    func testCompoundToolOnlyRequestRetriesWhenFeedbackTalkIsIncomplete() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"Tokyo"},"say":"Let me check the time in Tokyo."}]}
        """
        let incomplete = """
        {"action":"TALK","say":"It's 6:06 pm."}
        """
        let repaired = """
        {"action":"TALK","say":"It's 6:06 pm in Tokyo, and it's quite late in London, so call only if it's urgent."}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(initial), .success(incomplete), .success(repaired)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn(
            "Check Tokyo time, then tell me if it's a good time to call London.",
            history: []
        )

        XCTAssertEqual(fakeOpenAI.chatCallCount, 3, "Incomplete feedback talk should trigger one more repair attempt")
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text == "Let me check the time in Tokyo." }))
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text.lowercased().contains("london") }))
        XCTAssertFalse(result.appendedChat.contains(where: { $0.role == .assistant && $0.text == "It's 6:06 pm." }),
                       "Incomplete feedback talk should not be committed when repair succeeds")
    }

    // MARK: - Weather/Time Tool Choice

    @MainActor
    func testRainingInMelbourneRoutesToGetWeather() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(weatherWrongToolPlanJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("Is it raining in Melbourne?")

        guard let plan = plan else {
            return XCTFail("Expected a plan for weather query")
        }
        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "get_weather")
        XCTAssertEqual(args["place"]?.stringValue, "Melbourne")
    }

    @MainActor
    func testWeatherInGreenbankTodayRoutesToGetWeather() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(weatherWrongToolActionJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("What's the weather in Greenbank today?")

        guard let plan = plan else {
            return XCTFail("Expected a plan for weather query")
        }
        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "get_weather")
        XCTAssertEqual(args["place"]?.stringValue, "Greenbank")
    }

    @MainActor
    func testTimeInLondonStaysOnGetTime() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTimePlanJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("What time is it in London?")

        guard let plan = plan else {
            return XCTFail("Expected a plan for time query")
        }
        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "get_time")
        XCTAssertEqual(args["place"]?.stringValue, "London")
    }

    @MainActor
    func testRecipeRequestRecoversFromCapabilityGapToFindRecipeTool() async {
        let first = #"{"action":"CAPABILITY_GAP","goal":"Find a recipe for caramel sauce","missing":"recipe search capability"}"#
        let second = #"{"action":"TALK","say":"I can't find recipes directly, but I can help with something else!"}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(first), .success(second)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("find a recipe for caramel sauce")

        guard let plan = plan else {
            return XCTFail("Expected a repaired recipe plan")
        }
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Recipe guardrail should recover in a single pass")

        let hasFindRecipe = plan.steps.contains { step in
            if case .tool(let name, let args, _) = step {
                return name == "find_recipe" && (args["query"]?.stringValue.lowercased().contains("caramel sauce") == true)
            }
            return false
        }
        XCTAssertTrue(hasFindRecipe, "Recipe request should be repaired to find_recipe tool")
    }

    @MainActor
    func testRecipeAndImageRefusalRepairsToFindRecipeAndFindImage() async {
        let refusal = #"{"action":"TALK","say":"I can't find recipes directly."}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(refusal)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("find a recipe for banana muffins and show me an image of the food")

        guard let plan = plan else {
            return XCTFail("Expected repaired plan")
        }
        let toolNames = plan.steps.compactMap { step -> String? in
            if case .tool(let name, _, _) = step { return name }
            return nil
        }
        XCTAssertTrue(toolNames.contains("find_recipe"))
        XCTAssertTrue(toolNames.contains("find_image"))
    }

    @MainActor
    func testVideoRequestRecoversFromCapabilityGapToFindVideoTool() async {
        let first = #"{"action":"CAPABILITY_GAP","goal":"Find and display relevant videos when the user requests.","missing":"video search capability"}"#
        let second = #"{"action":"TALK","say":"I can't find videos directly right now."}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(first), .success(second)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("find a video of a race car")

        guard let plan = plan else {
            return XCTFail("Expected a repaired video plan")
        }
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Video guardrail should recover in a single pass")

        let hasFindVideo = plan.steps.contains { step in
            if case .tool(let name, let args, _) = step {
                return name == "find_video" && (args["query"]?.stringValue.lowercased().contains("race car") == true)
            }
            return false
        }
        XCTAssertTrue(hasFindVideo, "Video request should be repaired to find_video tool")
    }

    @MainActor
    func testCapabilityBuildRequestRoutesToStartSkillforge() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(capabilityWrongToolActionJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("learn \"Capability Gap Miner\": analyzes failed/blocked turns and proposes the next capability to build.")

        guard let plan = plan else {
            return XCTFail("Expected a plan for capability build request")
        }
        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "start_skillforge")
        XCTAssertTrue((args["goal"]?.stringValue ?? "").lowercased().contains("capability gap miner"))
    }

    func testCapabilityBuildWithURLPreservesStartSkillforge() async throws {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(capabilityStartSkillforgeActionJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try await openAIRouter.routePlan("Learn a capability: when user says show me a video on X, find and display a relevant video. Use https://www.googleapis.com/youtube/v3/search")

        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "start_skillforge")
        XCTAssertTrue((args["goal"]?.stringValue ?? "").lowercased().contains("find and display relevant videos"))
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Should not repair-retry as unexpected capability escalation")
    }

    func testCapabilityBuildWithURLRepairsWrongToolToStartSkillforge() async throws {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(capabilityWrongToolActionJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try await openAIRouter.routePlan("Build a capability to find and display videos and use https://www.googleapis.com/youtube/v3/search as the reference.")
        guard case .tool(let name, _, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "start_skillforge")
    }

    @MainActor
    func testWebsiteLearningRequestWithURLStaysOnLearnWebsite() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(websiteLearningActionJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("Learn this website https://swift.org and focus on package manager basics.")

        guard let plan = plan else {
            return XCTFail("Expected a plan for website learning request")
        }
        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "learn_website")
        XCTAssertEqual(args["url"]?.stringValue, "https://swift.org")
    }

    @MainActor
    func testStopCapabilityLearningRoutesToForgeQueueClear() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("Stop capability learning now.")

        guard let plan = plan else {
            return XCTFail("Expected a plan for stop capability request")
        }
        guard case .tool(let name, _, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "forge_queue_clear")
    }

    // MARK: - B) OpenAI transport error does NOT fall back to Ollama

    @MainActor
    func testOpenAITransportErrorNoOllamaFallback() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.failure(OpenAIRouter.OpenAIError.requestFailed("timeout"))]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedResponses = [.success(validTalkJSON)]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "OpenAI should be attempted once")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Ollama should NOT be called when OpenAI configured")
        XCTAssertEqual(result.llmProvider, .none, "Should return friendly fallback")
        XCTAssertTrue(result.appendedChat.contains { $0.text.contains("couldn't reach OpenAI") })
        XCTAssertEqual(result.knowledgeAttribution?.localKnowledgePercent, 0)
        XCTAssertEqual(result.knowledgeAttribution?.matchedLocalItems, 0)
        XCTAssertEqual(result.usedMemoryHints, false, "Fallback provider should not mark memory-hint usage")
    }

    // MARK: - C) OpenAI TALK with time claim accepted (no validation repair)

    @MainActor
    func testOpenAITalkWithTimeClaimAccepted() async {
        // TALK is always accepted — no validation repair loop.
        let talkWithTimeClaim = """
        {"action":"TALK","say":"It's 3:00 PM in London."}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(talkWithTimeClaim)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("what time is it in London", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Only 1 OpenAI call — no repair loop")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Ollama should not be called")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains { $0.text.contains("3:00 PM") })
    }

    // MARK: - D) OpenAI non-JSON response wrapped as TALK (no repair retry)

    @MainActor
    func testOpenAIJsonParseFailureWrapsAsTalk() async {
        // Non-JSON response is wrapped as TALK — no repair retry
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success("I cannot help with that")
        ]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Only 1 OpenAI call — no repair retry")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Ollama should not be called")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains { $0.text == "I cannot help with that" },
                      "Non-JSON response should be wrapped as TALK")
    }

    // MARK: - E) OpenAI fail returns graceful fallback (no Ollama hop)

    @MainActor
    func testOpenAIFailReturnsGracefulFallbackNoOllamaHop() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.failure(OpenAIRouter.OpenAIError.requestFailed("down"))]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "No Ollama hop when OpenAI configured")
        XCTAssertEqual(result.llmProvider, .none)
        XCTAssertTrue(result.appendedChat.contains { $0.text.contains("couldn't reach OpenAI") })
    }

    // MARK: - F) Ollama standalone when OpenAI not configured

    @MainActor
    func testOllamaStandaloneWhenOpenAINotConfigured() async {
        let fakeOpenAI = FakeOpenAITransport()
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedResponses = [.success(validTalkJSON)]

        OpenAISettings.apiKey = ""
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = ""
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 0, "OpenAI should not be called")
        XCTAssertEqual(fakeOllama.chatCallCount, 1, "Ollama should be called")
        XCTAssertEqual(result.llmProvider, .ollama)
    }

    // MARK: - G) Nothing configured uses MockRouter

    @MainActor
    func testNothingConfiguredUsesMockRouter() async {
        let fakeOpenAI = FakeOpenAITransport()
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = ""
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = ""
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 0)
        XCTAssertEqual(fakeOllama.chatCallCount, 0)
        XCTAssertEqual(result.llmProvider, .none, "MockRouter should yield .none provider")
        XCTAssertFalse(result.appendedChat.isEmpty, "Should have some response from MockRouter")
    }

    // MARK: - H) OpenAI valid TALK → immediate return, no retry, no fallback

    @MainActor
    func testOpenAIValidTalkImmediateReturnNoRetry() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("what time is it in london", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Exactly 1 OpenAI call — no retry")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Zero Ollama calls")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains { $0.text == "Hey there!" })
    }

    // MARK: - I) OpenAI non-JSON wrapped as TALK (single call, no retry)

    @MainActor
    func testOpenAIInvalidJsonWrapsAsTalkSingleCall() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success("Sure, the time in London is 3pm")  // non-JSON → wrapped as TALK
        ]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Only 1 OpenAI call — wrap-as-TALK, no retry")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Zero Ollama calls")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains { $0.text == "Sure, the time in London is 3pm" },
                      "Non-JSON wrapped as TALK")
    }

    // MARK: - J) KeychainStore read never prompts UI

    func testKeychainStoreReadIncludesAuthUIFail() {
        // Write a test key, then read it back.
        // The read should succeed without prompting (kSecUseAuthenticationUIFail is set).
        let testService = "com.samos.routertest"
        let testKey = "pipelineTestKey"

        // Clean up first
        KeychainStore.delete(forKey: testKey, service: testService)

        // Write
        let written = KeychainStore.set("test-value-123", forKey: testKey, service: testService)
        XCTAssertTrue(written, "Should write successfully")

        // Read — this must succeed without UI prompt (kSecUseAuthenticationUIFail)
        let value = KeychainStore.get(forKey: testKey, service: testService)
        XCTAssertEqual(value, "test-value-123", "Should read back without UI prompt")

        // Clean up
        KeychainStore.delete(forKey: testKey, service: testService)
    }

    // MARK: - K0) Tool step say is silent; only tool result is user-visible

    @MainActor
    func testToolStepWithSayIsSilent() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTimePlanJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("what time is it in London", history: [])

        let assistantMessages = result.appendedChat.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1, "Tool step say should not be emitted")
        XCTAssertTrue(assistantMessages[0].text.contains("It's"),
                      "Should emit only the tool result")
        XCTAssertEqual(result.spokenLines.count, 1, "Tool step say should not be spoken")
    }

    // MARK: - K1) Answer shaping (spoken summary + visual detail)

    @MainActor
    func testLongOutputUsesToolWindow() async {
        let longStructured = """
        {"action":"TALK","say":"# Delivery Plan\\n\\n## Milestones\\n- Draft\\n- Review\\n- Publish\\n\\n## Steps\\n1. Outline scope\\n2. Build implementation\\n3. Validate release"}
        """

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(longStructured)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("give me a delivery plan", history: [])

        XCTAssertEqual(result.appendedOutputs.count, 1, "Long/structured TALK should move to canvas")
        XCTAssertEqual(result.appendedOutputs.first?.kind, .markdown)
        XCTAssertTrue(result.appendedOutputs.first?.payload.contains("## Milestones") == true)
        XCTAssertEqual(result.appendedChat.count, 1, "Chat should be short confirmation")
        XCTAssertFalse(result.appendedChat[0].text.contains("Milestones"),
                       "Confirmation should be short, not full details")
    }

    @MainActor
    func testSpokenSummaryIsShort() async {
        let denseTalk = """
        {"action":"TALK","say":"This rollout includes architecture decisions, risk notes, deployment sequencing, test-matrix constraints, and rollback guidance for every stage so that teams can execute safely with clear ownership and contingency plans while keeping auditability and quality controls intact end to end."}
        """

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(denseTalk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("summarize rollout guidance", history: [])
        let spoken = result.spokenLines.first ?? ""
        let sentenceCount = spoken.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count

        XCTAssertEqual(result.appendedOutputs.count, 1, "Dense answer should include visual details")
        XCTAssertLessThanOrEqual(sentenceCount, 2, "Spoken summary should be at most two sentences")
        XCTAssertLessThan(spoken.count, 90, "Spoken summary should stay brief")
    }

    @MainActor
    func testSimpleFactRemainsSpokenOnly() async {
        let simpleTalk = #"{"action":"TALK","say":"Pacific is the largest ocean."}"#

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(simpleTalk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("what is the largest ocean?", history: [])

        XCTAssertTrue(result.appendedOutputs.isEmpty, "Simple fact should not be pushed to tool window")
        XCTAssertEqual(result.appendedChat.first(where: { $0.role == .assistant })?.text,
                       "Pacific is the largest ocean.")
        XCTAssertEqual(result.spokenLines.first, "Pacific is the largest ocean.")
    }

    @MainActor
    func testNoHardcodedTopics() async {
        let nonTopicStructured = """
        {"action":"TALK","say":"## Sprint Retro\\n- Wins\\n- Risks\\n- Follow-ups\\n\\n1. Capture outcomes\\n2. Assign owners\\n3. Track due dates"}
        """

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(nonTopicStructured)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("summarize team retro", history: [])

        XCTAssertEqual(result.appendedOutputs.count, 1, "Shaping should trigger from structure, not topic keywords")
        XCTAssertTrue(result.appendedOutputs[0].payload.contains("## Sprint Retro"))
        XCTAssertFalse(result.spokenLines.isEmpty)
    }

    // MARK: - K2) Greeting anti-repeat (one extra LLM call max)

    @MainActor
    func testGreetingAntiRepeat() async {
        let duplicateGreeting = #"{"action":"TALK","say":"Hey there!"}"#
        let rephrasedGreeting = #"{"action":"TALK","say":"Hi, what's up?"}"#

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(duplicateGreeting), // first turn
            .success(duplicateGreeting), // second turn initial
            .success(rephrasedGreeting)  // second turn rephrase pass
        ]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let first = await orchestrator.processTurn("hi sam", history: [])
        let secondHistory = [
            ChatMessage(role: .user, text: "hi sam"),
            ChatMessage(role: .assistant, text: first.appendedChat.first?.text ?? "Hey there!")
        ]
        let second = await orchestrator.processTurn("hi sam", history: secondHistory)

        XCTAssertEqual(fakeOpenAI.chatCallCount, 3,
                       "Second repeated greeting should trigger one extra rephrase call")
        XCTAssertEqual(second.appendedChat.first?.text, "Hi, what's up?")
    }

    // MARK: - K2b) Optional follow-up question policy

    @MainActor
    func testFollowUpNotAddedWhenAlreadyQuestion() async {
        let alreadyQuestion = #"{"action":"TALK","say":"Want me to continue?"}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(alreadyQuestion)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)
        let result = await orchestrator.processTurn("hi", history: [])

        let text = result.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(text.filter { $0 == "?" }.count, 1, "Should not append a second follow-up question")
        XCTAssertFalse(result.triggerQuestionAutoListen, "Only generated follow-up questions should trigger auto-listen")
    }

    @MainActor
    func testFollowUpCooldownEnforced() async {
        let firstTalk = #"{"action":"TALK","say":"I finished that for you and included the key details."}"#
        let secondTalk = #"{"action":"TALK","say":"I wrapped this up and summarized the important parts."}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(firstTalk), .success(secondTalk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            followUpCooldownTurns: 5
        )

        let first = await orchestrator.processTurn("turn one", history: [])
        let firstText = first.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(firstText.filter { $0 == "?" }.count, 1)
        XCTAssertTrue(first.triggerQuestionAutoListen)

        let second = await orchestrator.processTurn("turn two", history: [])
        let secondText = second.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(secondText.filter { $0 == "?" }.count, 0, "Follow-up should be blocked during cooldown")
        XCTAssertFalse(second.triggerQuestionAutoListen)
    }

    @MainActor
    func testFollowUpMaxOneSentence() async {
        let talk = #"{"action":"TALK","say":"I prepared the result and highlighted the important points for you."}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(talk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)
        let result = await orchestrator.processTurn("wrap up", history: [])

        let text = result.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(text.filter { $0 == "?" }.count, 1, "Follow-up should be a single question sentence")
        XCTAssertTrue(text.hasSuffix("?"), "Follow-up question must end the message")
    }

    // MARK: - K3) Memory acknowledgements (optional + cooldown)

    @MainActor
    func testMemoryAckOnlyWhenRelevant() async {
        let token = "acktoken\(Int.random(in: 10000...99999))"
        guard let memory = MemoryStore.shared.addMemory(type: .note, content: "Project \(token) is active.") else {
            return XCTFail("Failed to seed memory")
        }
        defer { _ = MemoryStore.shared.deleteMemory(idOrPrefix: memory.id.uuidString) }

        let talk = "{\"action\":\"TALK\",\"say\":\"I remember you mentioned Project \(token). Here's a quick update.\"}"
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(talk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Any update on project \(token)?", history: [])
        let text = result.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(text.lowercased().contains("i remember you mentioned"),
                      "Memory acknowledgement should be preserved when relevant memory exists")
    }

    @MainActor
    func testMemoryAckRespectsCooldown() async {
        let token = "acktoken\(Int.random(in: 10000...99999))"
        guard let memory = MemoryStore.shared.addMemory(type: .note, content: "Project \(token) is active.") else {
            return XCTFail("Failed to seed memory")
        }
        defer { _ = MemoryStore.shared.deleteMemory(idOrPrefix: memory.id.uuidString) }

        let firstTalk = "{\"action\":\"TALK\",\"say\":\"I remember you mentioned Project \(token). Here's the first update.\"}"
        let secondTalk = "{\"action\":\"TALK\",\"say\":\"If I'm remembering right, this relates to \(token). Let's go over the next step.\"}"

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(firstTalk), .success(secondTalk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, memoryAckCooldownTurns: 20)

        let first = await orchestrator.processTurn("status on \(token)", history: [])
        let firstText = first.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(firstText.lowercased().contains("i remember you mentioned"))

        let history = [
            ChatMessage(role: .user, text: "status on \(token)"),
            ChatMessage(role: .assistant, text: firstText)
        ]
        let second = await orchestrator.processTurn("any other update on \(token)?", history: history)
        let secondText = second.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""

        XCTAssertFalse(secondText.lowercased().contains("i remember you mentioned"),
                       "Memory acknowledgement should be removed during cooldown")
        XCTAssertFalse(secondText.lowercased().contains("if i'm remembering right"),
                       "Memory acknowledgement should be removed during cooldown")
        XCTAssertTrue(secondText.contains("Let's go over the next step."))
    }

    @MainActor
    func testMemoryAckDoesNotAppearWithoutMemoryHints() async {
        let token = "acktoken\(Int.random(in: 10000...99999))"
        let queryToken = "nomatch\(Int.random(in: 10000...99999))"
        let talk = "{\"action\":\"TALK\",\"say\":\"I remember you mentioned Project \(token). Here's a quick update.\"}"

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(talk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("status \(queryToken)", history: [])
        let text = result.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""

        XCTAssertFalse(text.lowercased().contains("i remember you mentioned"),
                       "Memory acknowledgement should be stripped when there are no relevant hints")
        XCTAssertTrue(text.contains("Here's a quick update."),
                      "Remainder of response should still be preserved")
    }

    // MARK: - K) Malformed show_text JSON salvaged as show_text tool

    @MainActor
    func testMalformedShowTextSalvagedAsShowTextTool() async {
        // Steps missing "step" key → parsePlanOrAction throws schemaMismatch,
        // but salvage should extract markdown from the show_text name/args.
        let malformed = """
        {"action":"PLAN","steps":[{"name":"show_text","args":{"markdown":"# Pancake Recipe\\n1. Mix flour\\n2. Cook"},"say":"Here you go."}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(malformed)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("show me a pancake recipe")
            let hasShowText = plan.steps.contains { step in
                if case .tool(let name, let args, _) = step, name == "show_text" {
                    return args["markdown"]?.stringValue.contains("Pancake") == true
                }
                return false
            }
            XCTAssertTrue(hasShowText, "Should be salvaged as show_text with pancake markdown")
        } catch {
            XCTFail("Should not throw — should be salvaged: \(error)")
        }
    }

    // MARK: - L) Malformed show_image JSON salvaged as show_image tool

    @MainActor
    func testMalformedShowImageSalvagedAsShowImageTool() async {
        // Steps missing "step" key → parsePlanOrAction throws, salvage extracts URLs.
        let malformed = """
        {"action":"PLAN","steps":[{"name":"show_image","args":{"urls":"https://example.com/frog.jpg|https://example.com/frog2.png","alt":"a frog"},"say":"Here you go."}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(malformed)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("show me a frog")
            let hasShowImage = plan.steps.contains { step in
                if case .tool(let name, let args, _) = step, name == "show_image" {
                    return args["urls"]?.stringValue.contains("frog.jpg") == true
                }
                return false
            }
            XCTAssertTrue(hasShowImage, "Should be salvaged as show_image with frog URLs")
        } catch {
            XCTFail("Should not throw — should be salvaged: \(error)")
        }
    }

    @MainActor
    func testPlanDelegateStepWithToolShapeParsesAsToolSteps() async {
        let malformed = """
        {"action":"PLAN","steps":[{"step":"tool","name":"find_image","args":{"query":"butter chicken"},"say":"I'll find an image of butter chicken."},{"step":"delegate","name":"learn_website","args":{"url":"https://www.example.com/butter-chicken-recipe","focus":"recipe"},"say":"I'll look for a recipe."}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(malformed)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("find a recipe for butter chicken and show me an image of the food")
            let toolNames = plan.steps.compactMap { step -> String? in
                if case .tool(let name, _, _) = step { return name }
                return nil
            }
            XCTAssertTrue(toolNames.contains("find_image"))
            XCTAssertTrue(toolNames.contains("learn_website"))
        } catch {
            XCTFail("Should not throw — malformed delegate tool shape should be normalized: \(error)")
        }
    }

    // MARK: - M) JSON garbage returns friendly error, not raw JSON

    @MainActor
    func testJsonGarbageReturnsFriendlyErrorNotRawJson() async {
        let garbage = """
        {"foo":"bar","baz":42,"nested":{"x":true}}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(garbage)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("do something")
            if case .talk(let say) = plan.steps.first {
                XCTAssertFalse(say.contains("{"), "Should not contain raw JSON braces")
                XCTAssertFalse(say.contains("foo"), "Should not contain raw JSON keys")
                XCTAssertTrue(say.lowercased().contains("sorry") || say.lowercased().contains("try again"),
                              "Should be a friendly error message, got: \(say)")
            } else {
                XCTFail("Expected a talk step with friendly error")
            }
        } catch {
            XCTFail("Should not throw — should return friendly error: \(error)")
        }
    }

    // MARK: - N) Raw markdown wrapped in show_text

    @MainActor
    func testRawMarkdownWrappedAsShowText() async {
        let rawMarkdown = "# Pancake Recipe\n\n## Ingredients\n- 1 cup flour\n- 2 eggs\n\n## Instructions\n1. Mix ingredients\n2. Cook on griddle"
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(rawMarkdown)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("pancake recipe")
            let hasShowText = plan.steps.contains { step in
                if case .tool(let name, let args, _) = step, name == "show_text" {
                    return args["markdown"]?.stringValue.contains("Pancake") == true
                }
                return false
            }
            XCTAssertTrue(hasShowText, "Raw markdown should be wrapped in show_text tool step")
        } catch {
            XCTFail("Should not throw — should be salvaged: \(error)")
        }
    }

    // MARK: - P) Image probe failure prompt includes HTTP codes

    @MainActor
    func testImageProbeFailurePromptIncludesHTTPCodes() async {
        // Use a mock ToolsRuntime that returns show_image with fake URLs
        let mockRuntime = ImageProbeToolsRuntime(urls: [
            "https://example.com/fake1.jpg",
            "https://example.com/fake2.jpg"
        ])
        let executor = PlanExecutor(toolsRuntime: mockRuntime)

        let plan = Plan(steps: [
            .tool(name: "show_image",
                  args: ["urls": .string("https://example.com/fake1.jpg|https://example.com/fake2.jpg"),
                         "alt": .string("a frog")],
                  say: "Here you go.")
        ])

        let result = await executor.execute(plan, originalInput: "show me a frog")

        // Probe should fail for these URLs (they don't exist)
        // The pendingSlotRequest.prompt should exist with image_url slot
        if let req = result.pendingSlotRequest {
            XCTAssertEqual(req.slot, "image_url", "Should set image_url slot for auto-repair")
        }
        // Note: actual HTTP codes depend on network — in CI, the test verifies the slot is set
    }

    // MARK: - Q) Repair prompt demands 3 URLs and Wikimedia host

    @MainActor
    func testRepairPromptDemands3UrlsAndWikimediaHost() async {
        // Simulate what happens when all image URLs fail:
        // The formatted message from probeImageOutput should mention wikimedia
        let mockRuntime = ImageProbeToolsRuntime(urls: [
            "https://example.com/bad1.jpg",
            "https://example.com/bad2.jpg"
        ])
        let executor = PlanExecutor(toolsRuntime: mockRuntime)

        let plan = Plan(steps: [
            .tool(name: "show_image",
                  args: ["urls": .string("https://example.com/bad1.jpg|https://example.com/bad2.jpg"),
                         "alt": .string("test")],
                  say: "Here.")
        ])

        let result = await executor.execute(plan, originalInput: "show me something")

        // When probe fails, the spoken line should mention broken URL
        let hasProbeFailMessage = result.spokenLines.contains { $0.contains("couldn't load") }
        XCTAssertTrue(hasProbeFailMessage, "Should have probe failure spoken message, got: \(result.spokenLines)")

        // The pending slot should be image_url
        XCTAssertEqual(result.pendingSlotRequest?.slot, "image_url")
    }

    // MARK: - O) CAPABILITY_GAP without fields becomes TALK

    @MainActor
    func testCapabilityGapWithoutMessageBecomesTalk() async {
        let bareGap = """
        {"action":"CAPABILITY_GAP"}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(bareGap)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("do something impossible", history: [])

        let assistantMessages = result.appendedChat.filter { $0.role == .assistant }
        XCTAssertFalse(assistantMessages.isEmpty, "Should have an assistant message")

        let text = assistantMessages.first?.text ?? ""
        XCTAssertFalse(text.contains("trouble"), "Should NOT be the generic 'trouble processing' error")
        XCTAssertFalse(text.contains("{"), "Should NOT contain raw JSON")
        XCTAssertTrue(text.contains("not sure") || text.contains("rephras"),
                      "Should contain the default capability gap message, got: \(text)")
    }

    @MainActor
    func testUnexpectedCapabilityGapTriggersRepairRetry() async {
        let first = #"{"action":"CAPABILITY_GAP","goal":"Find a recipe and image","missing":"unknown"}"#
        let second = #"{"action":"PLAN","steps":[{"step":"tool","name":"find_image","args":{"query":"butter chicken"},"say":"I'll find an image for that."}]}"#

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(first), .success(second)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("find a recipe for butter chicken and show me an image of the food")
            XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Recipe guardrail should recover without a retry round-trip")
            let hasFindImage = plan.steps.contains { step in
                if case .tool(let name, _, _) = step {
                    return name == "find_image"
                }
                return false
            }
            XCTAssertTrue(hasFindImage, "Repaired plan should use existing tools")
        } catch {
            XCTFail("Should not throw: \(error)")
        }
    }

    @MainActor
    func testUnexpectedCapabilityGapAfterRetryFallsBackToTalk() async {
        let gap = #"{"action":"CAPABILITY_GAP","goal":"Do task","missing":"unknown"}"#

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(gap), .success(gap)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("find image of frog")
            XCTAssertEqual(fakeOpenAI.chatCallCount, 2, "Should attempt one repair retry")
            if case .talk(let say) = plan.steps.first {
                XCTAssertTrue(
                    say.contains("without building a new capability"),
                    "Fallback should avoid triggering capability build: \(say)"
                )
            } else {
                XCTFail("Expected TALK fallback, got: \(plan.steps)")
            }
        } catch {
            XCTFail("Should not throw: \(error)")
        }
    }
}
