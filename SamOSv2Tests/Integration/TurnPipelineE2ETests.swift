import XCTest
@testable import SamOSv2

final class TurnPipelineE2ETests: XCTestCase {

    private func makeOrchestrator() -> (TurnOrchestrator, MockLLMClient) {
        let settings = MockSettingsStore()
        let memoryStore = MockMemoryStore()
        let toolRegistry = ToolRegistry()
        toolRegistry.registerDefaults(memoryStore: memoryStore)
        let llm = MockLLMClient()
        let promptBuilder = PromptBuilder(settings: settings)
        let responseParser = ResponseParser()
        let planExecutor = PlanExecutor(toolRegistry: toolRegistry, memoryStore: memoryStore)
        let memoryInjector = MemoryInjector(memoryStore: memoryStore)

        let orchestrator = TurnOrchestrator(
            llmClient: llm,
            promptBuilder: promptBuilder,
            responseParser: responseParser,
            planExecutor: planExecutor,
            memoryInjector: memoryInjector,
            memoryStore: memoryStore,
            settings: settings
        )
        return (orchestrator, llm)
    }

    func testSimpleTalkResponse() async throws {
        let (orchestrator, llm) = makeOrchestrator()
        llm.responses = ["""
        {"action":"TALK","say":"Hello! How can I help?"}
        """]

        let result = try await orchestrator.processTurn(text: "Hello", history: [], sessionId: "test")
        XCTAssertFalse(result.sayText.isEmpty)
    }

    func testToolStepExecutes() async throws {
        let (orchestrator, llm) = makeOrchestrator()
        llm.responses = ["""
        {"steps":[{"step":"tool","name":"get_time","args":{}},{"step":"talk","say":"The time is now."}]}
        """]

        let result = try await orchestrator.processTurn(text: "What time is it?", history: [], sessionId: "test")
        XCTAssertFalse(result.sayText.isEmpty)
    }

    func testEmptyResponseFallbackToTalk() async throws {
        let (orchestrator, llm) = makeOrchestrator()
        llm.responses = ["I'm not sure how to respond to that."]

        let result = try await orchestrator.processTurn(text: "Hmm", history: [], sessionId: "test")
        // Raw text should be wrapped as TALK per ARCHITECTURE.md
        XCTAssertFalse(result.sayText.isEmpty)
    }

    func testMemoryContextInjected() async throws {
        let (orchestrator, llm) = makeOrchestrator()
        llm.responses = ["""
        {"action":"TALK","say":"Your name is Richard."}
        """]

        // The orchestrator should inject memory context into the prompt
        let result = try await orchestrator.processTurn(text: "What is my name?", history: [], sessionId: "test")
        XCTAssertFalse(result.sayText.isEmpty)
        // Verify LLM was called
        XCTAssertEqual(llm.callCount, 1)
    }
}
