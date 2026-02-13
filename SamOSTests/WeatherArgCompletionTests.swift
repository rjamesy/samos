import XCTest
@testable import SamOS

@MainActor
final class WeatherArgCompletionTests: XCTestCase {

    private final class ToolsRuntimeStub: ToolsRuntimeProtocol {
        var executedTools: [(name: String, args: [String: String])] = []

        func toolExists(_ name: String) -> Bool {
            name == "get_weather" || name == "get_time"
        }

        func execute(_ action: ToolAction) -> OutputItem? {
            executedTools.append((name: action.name, args: action.args))
            if action.name == "get_weather" {
                let place = action.args["place"] ?? "unknown"
                return OutputItem(kind: .markdown, payload: "Weather for \(place): Sunny, 24C")
            }
            return OutputItem(kind: .markdown, payload: "Tool executed")
        }
    }

    // MARK: - Pre-execution place injection tests

    func testWeatherInBrisbaneInjectsPlace() async {
        let toolsRuntime = ToolsRuntimeStub()
        let planExecutor = PlanExecutor(toolsRuntime: toolsRuntime)
        let runner = TurnToolRunner(planExecutor: planExecutor, toolsRuntime: toolsRuntime)

        // Plan with get_weather but no place arg (LLM omitted it)
        let plan = Plan(steps: [
            .tool(name: "get_weather", args: [:], say: "Let me check the weather.")
        ])

        let result = await runner.executePlan(plan, originalInput: "weather in Brisbane today", pendingSlotName: nil)

        // Should have injected "Brisbane" pre-execution
        XCTAssertTrue(toolsRuntime.executedTools.contains(where: { $0.name == "get_weather" && $0.args["place"] == "Brisbane" }),
                      "Expected get_weather to be called with place=Brisbane, got: \(toolsRuntime.executedTools)")
        XCTAssertFalse(result.chatMessages.isEmpty, "Should have chat output")
    }

    func testWeatherForSydneyInjectsPlace() async {
        let toolsRuntime = ToolsRuntimeStub()
        let planExecutor = PlanExecutor(toolsRuntime: toolsRuntime)
        let runner = TurnToolRunner(planExecutor: planExecutor, toolsRuntime: toolsRuntime)

        let plan = Plan(steps: [
            .tool(name: "get_weather", args: [:], say: nil)
        ])

        _ = await runner.executePlan(plan, originalInput: "weather in Sydney today", pendingSlotName: nil)

        XCTAssertTrue(toolsRuntime.executedTools.contains(where: { $0.name == "get_weather" && $0.args["place"] == "Sydney" }),
                      "Expected get_weather with place=Sydney, got: \(toolsRuntime.executedTools)")
    }

    func testWeatherWithExistingPlaceNotOverridden() async {
        let toolsRuntime = ToolsRuntimeStub()
        let planExecutor = PlanExecutor(toolsRuntime: toolsRuntime)
        let runner = TurnToolRunner(planExecutor: planExecutor, toolsRuntime: toolsRuntime)

        // LLM already provided place
        let plan = Plan(steps: [
            .tool(name: "get_weather", args: ["place": .string("Melbourne")], say: nil)
        ])

        _ = await runner.executePlan(plan, originalInput: "weather in Brisbane", pendingSlotName: nil)

        // Should keep Melbourne, not override with Brisbane
        XCTAssertTrue(toolsRuntime.executedTools.contains(where: { $0.name == "get_weather" && $0.args["place"] == "Melbourne" }),
                      "Expected place=Melbourne (not overridden), got: \(toolsRuntime.executedTools)")
    }

    func testWeatherNoPlaceInTextNoInjection() async {
        let toolsRuntime = ToolsRuntimeStub()
        let planExecutor = PlanExecutor(toolsRuntime: toolsRuntime)
        let runner = TurnToolRunner(planExecutor: planExecutor, toolsRuntime: toolsRuntime)

        let plan = Plan(steps: [
            .tool(name: "get_weather", args: [:], say: nil)
        ])

        let result = await runner.executePlan(plan, originalInput: "what's the weather", pendingSlotName: nil)

        // No place extractable — tool should still execute but may prompt for place
        let weatherCalls = toolsRuntime.executedTools.filter { $0.name == "get_weather" }
        if let call = weatherCalls.first {
            // If place was not injected, args should not contain a non-empty place
            let place = call.args["place"] ?? ""
            XCTAssertTrue(place.isEmpty, "No place should be injected when input has no city, got: \(place)")
        }
        // Result should exist regardless
        XCTAssertFalse(result.chatMessages.isEmpty || result.pendingSlotRequest != nil,
                       "Should have either chat output or pending slot request")
    }

    func testLocationArgNormalizedToPlace() async {
        let toolsRuntime = ToolsRuntimeStub()
        let planExecutor = PlanExecutor(toolsRuntime: toolsRuntime)
        let runner = TurnToolRunner(planExecutor: planExecutor, toolsRuntime: toolsRuntime)

        // LLM used "location" instead of "place"
        let plan = Plan(steps: [
            .tool(name: "get_weather", args: ["location": .string("Perth")], say: nil)
        ])

        _ = await runner.executePlan(plan, originalInput: "weather Perth", pendingSlotName: nil)

        // canonicalizedStepArgs should map location → place
        XCTAssertTrue(toolsRuntime.executedTools.contains(where: { $0.name == "get_weather" && $0.args["place"] == "Perth" }),
                      "Expected location→place normalization to Perth, got: \(toolsRuntime.executedTools)")
    }

    func testNonWeatherToolNotAffected() async {
        let toolsRuntime = ToolsRuntimeStub()
        let planExecutor = PlanExecutor(toolsRuntime: toolsRuntime)
        let runner = TurnToolRunner(planExecutor: planExecutor, toolsRuntime: toolsRuntime)

        let plan = Plan(steps: [
            .tool(name: "get_time", args: [:], say: "Checking the time.")
        ])

        _ = await runner.executePlan(plan, originalInput: "what time is it in Brisbane", pendingSlotName: nil)

        // get_time should NOT have a place arg injected
        let timeCalls = toolsRuntime.executedTools.filter { $0.name == "get_time" }
        XCTAssertFalse(timeCalls.isEmpty, "get_time should have been called")
        if let call = timeCalls.first {
            XCTAssertNil(call.args["place"], "get_time should not get a place arg from weather injection")
        }
    }
}
