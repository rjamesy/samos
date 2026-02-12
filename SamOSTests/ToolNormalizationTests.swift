import XCTest
@testable import SamOS

@MainActor
final class ToolNormalizationTests: XCTestCase {

    private final class RuntimeStub: ToolsRuntimeProtocol {
        var outputs: [String: OutputItem] = [:]
        private(set) var actions: [ToolAction] = []

        func execute(_ toolAction: ToolAction) -> OutputItem? {
            actions.append(toolAction)
            return outputs[toolAction.name]
        }

        func toolExists(_ name: String) -> Bool {
            outputs[name] != nil
        }
    }

    private final class PassthroughSpeechSelector: SpeechLineSelecting {
        func selectSpeechDecision(entries: [SpeechLineEntry],
                                  toolProducedUserFacingOutput: Bool,
                                  maxSpeakChars: Int) -> SpeechDecision {
            _ = toolProducedUserFacingOutput
            _ = maxSpeakChars
            return SpeechDecision(spokenLines: entries.map(\.text), wasCondensed: false)
        }
    }

    func testWeatherAliasNormalizesToGetWeather() async {
        let runtime = RuntimeStub()
        runtime.outputs["get_weather"] = OutputItem(
            kind: .markdown,
            payload: #"{"spoken":"It's clear in Brisbane.","formatted":"Clear in Brisbane."}"#
        )

        let executor = PlanExecutor(toolsRuntime: runtime, speechCoordinator: PassthroughSpeechSelector())
        let runner = TurnToolRunner(
            planExecutor: executor,
            toolsRuntime: runtime,
            toolNameNormalizer: ToolRegistry.shared
        )

        let plan = Plan(steps: [.tool(name: "weather", args: ["place": .string("Brisbane")], say: nil)])
        let result = await runner.executePlan(plan, originalInput: "weather brisbane", pendingSlotName: nil)

        XCTAssertEqual(runtime.actions.first?.name, "get_weather")
        XCTAssertEqual(result.executedToolSteps.first?.name, "get_weather")
    }

    func testUnknownToolRejectedWithDeterministicLocalPrompt() async {
        let runtime = RuntimeStub()
        let executor = PlanExecutor(toolsRuntime: runtime, speechCoordinator: PassthroughSpeechSelector())
        let runner = TurnToolRunner(
            planExecutor: executor,
            toolsRuntime: runtime,
            toolNameNormalizer: ToolRegistry.shared
        )

        let plan = Plan(steps: [.tool(name: "mystery_tool", args: [:], say: nil)])
        let result = await runner.executePlan(plan, originalInput: "do mystery thing", pendingSlotName: nil)
        let toolOutput = runner.executeTool(ToolAction(name: "mystery_tool", args: [:], say: nil))

        let expected = "I couldn't run that request because the requested tool isn't available locally. Please rephrase your request."
        XCTAssertEqual(result.spokenLines, [expected])
        XCTAssertEqual(result.chatMessages.first?.text, expected)
        XCTAssertEqual(toolOutput?.payload, expected)
        XCTAssertFalse(expected.lowercased().contains("where do you normally check it"))
    }

    func testWeatherPlanStepDoesNotTriggerCapabilityGapPendingState() async {
        let runtime = RuntimeStub()
        runtime.outputs["get_weather"] = OutputItem(
            kind: .markdown,
            payload: #"{"spoken":"It's 26°C and clear in Brisbane.","formatted":"26°C and clear in Brisbane."}"#
        )

        let executor = PlanExecutor(toolsRuntime: runtime, speechCoordinator: PassthroughSpeechSelector())
        let runner = TurnToolRunner(
            planExecutor: executor,
            toolsRuntime: runtime,
            toolNameNormalizer: ToolRegistry.shared
        )

        let plan = Plan(steps: [.tool(name: "weather", args: ["place": .string("Brisbane")], say: nil)])
        let result = await runner.executePlan(plan, originalInput: "weather brisbane", pendingSlotName: nil)

        XCTAssertNil(result.pendingSlotRequest)
        XCTAssertFalse(result.chatMessages.contains(where: { $0.text.lowercased().contains("source url") }))
        XCTAssertEqual(result.executedToolSteps.first?.name, "get_weather")
    }
}
