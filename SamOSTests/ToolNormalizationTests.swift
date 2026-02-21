import XCTest
@testable import SamOS

@MainActor
final class ToolNormalizationTests: XCTestCase {

    private final class RuntimeStub: ToolsRuntimeProtocol {
        var outputs: [String: OutputItem] = [:]
        var queuedOutputs: [String: [OutputItem]] = [:]
        private(set) var actions: [ToolAction] = []

        func execute(_ toolAction: ToolAction) -> OutputItem? {
            actions.append(toolAction)
            if var queue = queuedOutputs[toolAction.name], !queue.isEmpty {
                let next = queue.removeFirst()
                queuedOutputs[toolAction.name] = queue
                return next
            }
            return outputs[toolAction.name]
        }

        func toolExists(_ name: String) -> Bool {
            if outputs[name] != nil {
                return true
            }
            if let queue = queuedOutputs[name], !queue.isEmpty {
                return true
            }
            return false
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

    func testWeatherLocationArgNormalizesToPlace() async {
        let runtime = RuntimeStub()
        runtime.outputs["get_weather"] = OutputItem(
            kind: .markdown,
            payload: #"{"spoken":"Sunny in Brisbane.","formatted":"Sunny in Brisbane."}"#
        )

        let executor = PlanExecutor(toolsRuntime: runtime, speechCoordinator: PassthroughSpeechSelector())
        let runner = TurnToolRunner(
            planExecutor: executor,
            toolsRuntime: runtime,
            toolNameNormalizer: ToolRegistry.shared
        )

        let plan = Plan(steps: [.tool(name: "get_weather", args: ["location": .string("Brisbane")], say: nil)])
        _ = await runner.executePlan(plan, originalInput: "weather brisbane", pendingSlotName: nil)

        XCTAssertEqual(runtime.actions.first?.name, "get_weather")
        XCTAssertEqual(runtime.actions.first?.args["place"], "Brisbane")
    }

    func testWeatherPromptAutoFillsPlaceAndRetriesOnce() async {
        let runtime = RuntimeStub()
        runtime.queuedOutputs["get_weather"] = [
            OutputItem(
                kind: .markdown,
                payload: #"{"kind":"prompt","slot":"place","spoken":"Which city?","formatted":"Need place."}"#
            ),
            OutputItem(
                kind: .markdown,
                payload: #"{"spoken":"It's clear in Brisbane.","formatted":"Clear in Brisbane."}"#
            )
        ]

        let executor = PlanExecutor(toolsRuntime: runtime, speechCoordinator: PassthroughSpeechSelector())
        let runner = TurnToolRunner(
            planExecutor: executor,
            toolsRuntime: runtime,
            toolNameNormalizer: ToolRegistry.shared
        )

        let plan = Plan(steps: [.tool(name: "get_weather", args: [:], say: nil)])
        let result = await runner.executePlan(plan, originalInput: "weather in Brisbane", pendingSlotName: nil)

        XCTAssertEqual(runtime.actions.count, 2)
        XCTAssertEqual(runtime.actions.first?.name, "get_weather")
        XCTAssertEqual(runtime.actions.last?.name, "get_weather")
        XCTAssertEqual(runtime.actions.last?.args["place"], "Brisbane")
        XCTAssertNil(result.pendingSlotRequest)
    }

    func testScheduleTaskTimerRewritesToTimerManage() async {
        let runtime = RuntimeStub()
        runtime.outputs["timer.manage"] = OutputItem(
            kind: .markdown,
            payload: #"{"spoken":"Timer set for 10 seconds.","formatted":"Timer set for 10 seconds."}"#
        )

        let executor = PlanExecutor(toolsRuntime: runtime, speechCoordinator: PassthroughSpeechSelector())

        let plan = Plan(steps: [
            .tool(
                name: "schedule_task",
                args: [
                    "type": .string("timer"),
                    "duration_seconds": .int(10)
                ],
                say: nil
            )
        ])

        let result = await executor.execute(plan, originalInput: "set timer 10 seconds", pendingSlotName: nil)

        XCTAssertEqual(runtime.actions.first?.name, "timer.manage")
        XCTAssertEqual(runtime.actions.first?.args["action"], "start")
        XCTAssertEqual(runtime.actions.first?.args["duration_seconds"], "10")
        XCTAssertEqual(result.executedToolSteps.first?.name, "timer.manage")
    }

    func testScheduleTaskTimerInfersDurationFromInputWhenModelOmittedSeconds() async {
        let runtime = RuntimeStub()
        runtime.outputs["timer.manage"] = OutputItem(
            kind: .markdown,
            payload: #"{"spoken":"Timer set for 10 seconds.","formatted":"Timer set for 10 seconds."}"#
        )

        let executor = PlanExecutor(toolsRuntime: runtime, speechCoordinator: PassthroughSpeechSelector())

        let plan = Plan(steps: [
            .tool(
                name: "schedule_task",
                args: [
                    "type": .string("timer")
                ],
                say: nil
            )
        ])

        _ = await executor.execute(plan, originalInput: "set timer 10 seconds", pendingSlotName: nil)

        XCTAssertEqual(runtime.actions.first?.name, "timer.manage")
        XCTAssertEqual(runtime.actions.first?.args["duration_seconds"], "10")
    }
}
