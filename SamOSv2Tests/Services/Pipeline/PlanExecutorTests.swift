import XCTest
@testable import SamOSv2

final class PlanExecutorTests: XCTestCase {

    func testExecuteTalkStep() async {
        let registry = MockToolRegistry()
        let memoryStore = MockMemoryStore()
        let executor = PlanExecutor(toolRegistry: registry, memoryStore: memoryStore)

        let plan = Plan(steps: [.talk(say: "Hello!")])
        let result = await executor.execute(plan: plan)

        XCTAssertEqual(result.spokenText, "Hello!")
        XCTAssertTrue(result.outputItems.isEmpty)
        XCTAssertTrue(result.toolCalls.isEmpty)
    }

    func testExecuteToolStep() async {
        let registry = MockToolRegistry()
        let tool = MockTool(name: "get_time", result: .success(
            tool: "get_time",
            output: OutputItem(kind: .markdown, payload: "3:00 PM"),
            spoken: "It's 3 PM"
        ))
        registry.register(tool)

        let memoryStore = MockMemoryStore()
        let executor = PlanExecutor(toolRegistry: registry, memoryStore: memoryStore)

        let plan = Plan(steps: [.tool(name: "get_time", args: [:], say: nil)])
        let result = await executor.execute(plan: plan)

        XCTAssertTrue(result.spokenText.contains("3 PM"))
        XCTAssertEqual(result.outputItems.count, 1)
        XCTAssertEqual(result.toolCalls, ["get_time"])
    }

    func testExecuteMultiStepPlan() async {
        let registry = MockToolRegistry()
        let memoryStore = MockMemoryStore()
        let executor = PlanExecutor(toolRegistry: registry, memoryStore: memoryStore)

        let plan = Plan(steps: [
            .talk(say: "Let me check."),
            .talk(say: "All done!")
        ])
        let result = await executor.execute(plan: plan)

        XCTAssertTrue(result.spokenText.contains("Let me check."))
        XCTAssertTrue(result.spokenText.contains("All done!"))
    }

    func testUnknownToolReturnsMessage() async {
        let registry = MockToolRegistry()
        let memoryStore = MockMemoryStore()
        let executor = PlanExecutor(toolRegistry: registry, memoryStore: memoryStore)

        let plan = Plan(steps: [.tool(name: "nonexistent_tool", args: [:], say: nil)])
        let result = await executor.execute(plan: plan)

        XCTAssertTrue(result.spokenText.contains("nonexistent_tool"))
    }
}
