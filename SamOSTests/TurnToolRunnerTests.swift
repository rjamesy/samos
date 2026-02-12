import XCTest
@testable import SamOS

@MainActor
final class TurnToolRunnerTests: XCTestCase {

    private final class RecordingToolsRuntime: ToolsRuntimeProtocol {
        var nextOutput: OutputItem?
        private(set) var actions: [ToolAction] = []

        func execute(_ toolAction: ToolAction) -> OutputItem? {
            actions.append(toolAction)
            return nextOutput
        }

        func toolExists(_ name: String) -> Bool {
            _ = name
            return true
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

        func selectSpokenLines(entries: [SpeechLineEntry],
                               toolProducedUserFacingOutput: Bool,
                               maxSpeakChars: Int) -> [String] {
            selectSpeechDecision(
                entries: entries,
                toolProducedUserFacingOutput: toolProducedUserFacingOutput,
                maxSpeakChars: maxSpeakChars
            ).spokenLines
        }
    }

    func testExecutePlanDelegatesToPlanExecutor() async {
        let runtime = RecordingToolsRuntime()
        runtime.nextOutput = OutputItem(kind: .markdown, payload: "tool result")

        let executor = PlanExecutor(toolsRuntime: runtime, speechCoordinator: PassthroughSpeechSelector())
        let runner = TurnToolRunner(planExecutor: executor, toolsRuntime: runtime)

        let plan = Plan(steps: [
            .tool(name: "show_text", args: ["markdown": .string("# hi")], say: nil)
        ])

        let result = await runner.executePlan(plan, originalInput: "show", pendingSlotName: nil)

        XCTAssertEqual(runtime.actions.count, 1)
        XCTAssertEqual(runtime.actions.first?.name, "show_text")
        XCTAssertEqual(result.executedToolSteps.first?.name, "show_text")
        XCTAssertEqual(result.outputItems.first?.payload, "tool result")
    }

    func testExecuteToolDelegatesToToolsRuntime() {
        let runtime = RecordingToolsRuntime()
        runtime.nextOutput = OutputItem(kind: .markdown, payload: "ok")

        let executor = PlanExecutor(toolsRuntime: runtime, speechCoordinator: PassthroughSpeechSelector())
        let runner = TurnToolRunner(planExecutor: executor, toolsRuntime: runtime)

        let action = ToolAction(name: "save_memory", args: ["content": "abc"], say: nil)
        let output = runner.executeTool(action)

        XCTAssertEqual(runtime.actions.count, 1)
        XCTAssertEqual(runtime.actions.first?.name, "save_memory")
        XCTAssertEqual(output?.payload, "ok")
    }
}
