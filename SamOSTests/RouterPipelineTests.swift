import XCTest
@testable import SamOS

// MARK: - Fake OpenAI Transport

final class FakeOpenAITransport: OpenAITransport {
    var queuedResponses: [Result<String, Error>] = []
    private(set) var chatCallCount = 0

    func chat(messages: [[String: String]], model: String) async throws -> String {
        chatCallCount += 1
        guard !queuedResponses.isEmpty else {
            throw OpenAIRouter.OpenAIError.requestFailed("No queued response")
        }
        return try queuedResponses.removeFirst().get()
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

// MARK: - Router Pipeline Tests

final class RouterPipelineTests: XCTestCase {

    private var savedApiKey: String = ""
    private var savedUseOllama: Bool = false

    override func setUp() {
        super.setUp()
        savedApiKey = OpenAISettings.apiKey
        savedUseOllama = M2Settings.useOllama
    }

    override func tearDown() {
        // Restore original settings
        OpenAISettings.apiKey = savedApiKey
        M2Settings.useOllama = savedUseOllama
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

    // MARK: - K0) Tool step with say produces both say AND tool result in appendedChat

    @MainActor
    func testToolStepWithSayProducesBothMessages() async {
        // get_time plan with say — should produce 2 assistant messages:
        // 1) "Let me check." (step say)
        // 2) "It's X:XX AM/PM." (tool structured spoken)
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
        XCTAssertEqual(assistantMessages.count, 2,
                       "Should have 2 assistant messages: say + tool result, got: \(assistantMessages.map(\.text))")
        XCTAssertEqual(assistantMessages[0].text, "Let me check.",
                       "First message should be the step say")
        XCTAssertTrue(assistantMessages[1].text.contains("It's"),
                      "Second message should be the time result, got: \(assistantMessages[1].text)")
        XCTAssertEqual(result.spokenLines.count, 2,
                       "Should have 2 spoken lines")
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
}
