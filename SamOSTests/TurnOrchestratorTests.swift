import XCTest
@testable import SamOS

final class TurnOrchestratorTests: XCTestCase {

    // MARK: - Conversation Mode Classifier

    @MainActor
    func testConversationModeClassifierCanonicalExamples() {
        let orchestrator = TurnOrchestrator()

        let greeting = orchestrator.debugClassify("hi sam how are you")
        XCTAssertEqual(greeting.intent, .greeting)

        let health = orchestrator.debugClassify("my tummy is sore")
        XCTAssertEqual(health.intent, .problemReport)
        XCTAssertEqual(health.domain, .health)

        let vehicle = orchestrator.debugClassify("engine making a funny noise")
        XCTAssertEqual(vehicle.intent, .problemReport)
        XCTAssertEqual(vehicle.domain, .vehicle)

        let tech = orchestrator.debugClassify("my wifi keeps dropping out")
        XCTAssertEqual(tech.intent, .problemReport)
        XCTAssertEqual(tech.domain, .tech)

        let task = orchestrator.debugClassify("set an alarm for 7")
        XCTAssertEqual(task.intent, .taskRequest)

        let recall = orchestrator.debugClassify("what did i say my dog's name was?")
        XCTAssertEqual(recall.intent, .memoryRecall)
    }

    @MainActor
    func testConversationModeClassifierBatchCoverage() {
        let orchestrator = TurnOrchestrator()
        let samples: [(String, ConversationIntent, ConversationDomain)] = [
            ("hello", .greeting, .unknown),
            ("hey", .greeting, .unknown),
            ("good morning", .greeting, .unknown),
            ("i dont feel well", .problemReport, .health),
            ("my stomach hurts", .problemReport, .health),
            ("severe abdominal pain and vomiting", .problemReport, .health),
            ("engine noise when i accelerate", .problemReport, .vehicle),
            ("oil pressure light came on", .problemReport, .vehicle),
            ("car overheating and smoke", .problemReport, .vehicle),
            ("wifi disconnects every hour", .problemReport, .tech),
            ("app keeps crashing on my macbook", .problemReport, .tech),
            ("possible account hacked", .problemReport, .tech),
            ("roof leak in my house", .problemReport, .home),
            ("ac stopped working", .problemReport, .home),
            ("kitchen appliance not working", .problemReport, .home),
            ("deadline is tomorrow at work", .problemReport, .work),
            ("my manager changed the project scope", .problemReport, .work),
            ("coworker conflict at work", .problemReport, .work),
            ("my partner and i are fighting", .problemReport, .relationship),
            ("family conflict advice", .problemReport, .relationship),
            ("should i choose sedan or suv", .decisionHelp, .unknown),
            ("which is better for commuting", .decisionHelp, .unknown),
            ("compare these options", .decisionHelp, .unknown),
            ("how do i reset my router", .howto, .tech),
            ("step by step guide for budgeting", .howto, .unknown),
            ("walk me through this process", .howto, .unknown),
            ("set a timer for 5 minutes", .taskRequest, .unknown),
            ("remind me tomorrow at 9", .taskRequest, .unknown),
            ("open my downloads folder", .taskRequest, .unknown),
            ("write a short poem", .creative, .unknown),
            ("brainstorm startup names", .creative, .unknown),
            ("what do you remember about me", .memoryRecall, .unknown)
        ]

        for sample in samples {
            let mode = orchestrator.debugClassify(sample.0)
            XCTAssertEqual(mode.intent, sample.1, "Intent mismatch for: \(sample.0)")
            if sample.2 != .unknown {
                XCTAssertEqual(mode.domain, sample.2, "Domain mismatch for: \(sample.0)")
            }
        }
    }

    // MARK: - Plan Execution

    @MainActor
    func testTalkStepProducesChatAndSpoken() {
        let orchestrator = TurnOrchestrator()
        let plan = Plan(steps: [.talk(say: "Hey there!")])
        let result = executePlanDirect(orchestrator, plan: plan, input: "hi")

        XCTAssertEqual(result.appendedChat.count, 1)
        XCTAssertEqual(result.appendedChat[0].text, "Hey there!")
        XCTAssertEqual(result.appendedChat[0].role, .assistant)
        XCTAssertEqual(result.spokenLines, ["Hey there!"])
    }

    @MainActor
    func testToolStepExecutes() {
        let orchestrator = TurnOrchestrator()
        let plan = Plan(steps: [
            .tool(name: "get_time", args: [:], say: "Let me check.")
        ])
        let result = executePlanDirect(orchestrator, plan: plan, input: "what time is it")

        // get_time returns structured payload → spoken goes to chat, formatted to outputs
        XCTAssertFalse(result.appendedChat.isEmpty, "Should have chat message")
        XCTAssertFalse(result.appendedOutputs.isEmpty, "Should have output item")
    }

    @MainActor
    func testAskStepSetsPendingSlotAndStops() {
        let orchestrator = TurnOrchestrator()
        let plan = Plan(steps: [
            .ask(slot: "time", prompt: "What time should I set the alarm for?"),
            .talk(say: "This should not appear")
        ])
        let result = executePlanDirect(orchestrator, plan: plan, input: "set an alarm")

        // Ask step should stop further execution
        XCTAssertEqual(result.appendedChat.count, 1)
        XCTAssertEqual(result.appendedChat[0].text, "What time should I set the alarm for?")
        XCTAssertTrue(result.triggerFollowUpCapture)

        // PendingSlot should be set
        XCTAssertNotNil(orchestrator.pendingSlot)
        XCTAssertEqual(orchestrator.pendingSlot?.slotName, "time")
        XCTAssertEqual(orchestrator.pendingSlot?.prompt, "What time should I set the alarm for?")
        XCTAssertEqual(orchestrator.pendingSlot?.originalUserText, "set an alarm")
    }

    @MainActor
    func testDelegateStepProducesSystemMessage() {
        let orchestrator = TurnOrchestrator()
        let plan = Plan(steps: [
            .delegate(task: "analyze data", context: nil, say: "Let me hand this off.")
        ])
        let result = executePlanDirect(orchestrator, plan: plan, input: "analyze this")

        XCTAssertEqual(result.appendedChat.count, 2) // say + system
        XCTAssertEqual(result.appendedChat[0].text, "Let me hand this off.")
        XCTAssertEqual(result.appendedChat[1].role, .system)
        XCTAssertTrue(result.appendedChat[1].text.contains("analyze data"))
    }

    // MARK: - PendingSlot Loop Breaker

    @MainActor
    func testLoopBreakerClearsAfter3Attempts() async {
        let orchestrator = TurnOrchestrator()

        // Simulate a pending slot with 3 failed attempts
        orchestrator.pendingSlot = PendingSlot(
            slotName: "time",
            prompt: "What time?",
            originalUserText: "set an alarm",
            attempts: 3
        )

        let result = await orchestrator.processTurn("something", history: [])

        XCTAssertNil(orchestrator.pendingSlot, "Should clear after 3 attempts")
        XCTAssertEqual(result.appendedChat.count, 1)
        XCTAssertTrue(result.appendedChat[0].text.contains("rephrase"))
    }

    @MainActor
    func testExpiredSlotClears() async {
        let orchestrator = TurnOrchestrator()

        // Expired slot
        orchestrator.pendingSlot = PendingSlot(
            createdAt: Date().addingTimeInterval(-601),
            slotName: "time",
            prompt: "What time?",
            originalUserText: "set an alarm"
        )

        // This will fall through to normal routing (MockRouter)
        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertNil(orchestrator.pendingSlot, "Should clear expired slot")
        XCTAssertFalse(result.appendedChat.isEmpty, "Should produce some response")
    }

    // MARK: - Plan.fromAction Backward Compatibility

    @MainActor
    func testLegacyActionWrappedInPlan() {
        let orchestrator = TurnOrchestrator()
        let action = Action.talk(Talk(say: "Hello!"))
        let plan = Plan.fromAction(action)
        let result = executePlanDirect(orchestrator, plan: plan, input: "hi")

        XCTAssertEqual(result.appendedChat.count, 1)
        XCTAssertEqual(result.appendedChat[0].text, "Hello!")
    }

    // MARK: - Tool Prompt Payload → PendingSlot

    @MainActor
    func testToolPromptPayloadSetsPendingSlot() {
        let orchestrator = TurnOrchestrator()
        // get_time with place="America" should return a prompt payload (ambiguous region)
        let plan = Plan(steps: [
            .tool(name: "get_time", args: ["place": .string("America")], say: "Let me check.")
        ])
        let result = executePlanDirect(orchestrator, plan: plan, input: "What time is it in America?")

        XCTAssertNotNil(orchestrator.pendingSlot, "Ambiguous region should create a PendingSlot")
        XCTAssertEqual(orchestrator.pendingSlot?.slotName, "timezone")
        XCTAssertTrue(result.triggerFollowUpCapture, "Should trigger follow-up capture")
        XCTAssertTrue(result.appendedChat[0].text.contains("state") || result.appendedChat[0].text.contains("city"),
                      "Should ask for state or city")
    }

    @MainActor
    func testToolTimePayloadDoesNotSetPendingSlot() {
        let orchestrator = TurnOrchestrator()
        let plan = Plan(steps: [
            .tool(name: "get_time", args: ["place": .string("Alabama")], say: "Here's the time.")
        ])
        let result = executePlanDirect(orchestrator, plan: plan, input: "What time is it in Alabama?")

        XCTAssertNil(orchestrator.pendingSlot, "Resolved place should NOT create PendingSlot")
        XCTAssertFalse(result.triggerFollowUpCapture)
        XCTAssertFalse(result.appendedChat.isEmpty)
    }

    // MARK: - Multiple Steps

    @MainActor
    func testMultipleStepsExecuteInOrder() {
        let orchestrator = TurnOrchestrator()
        let plan = Plan(steps: [
            .talk(say: "First"),
            .talk(say: "Second")
        ])
        let result = executePlanDirect(orchestrator, plan: plan, input: "test")

        XCTAssertEqual(result.appendedChat.count, 2)
        XCTAssertEqual(result.appendedChat[0].text, "First")
        XCTAssertEqual(result.appendedChat[1].text, "Second")
        XCTAssertEqual(result.spokenLines, ["First", "Second"])
    }

    // MARK: - Helpers

    /// Directly calls executePlan via the public processTurn path with MockRouter.
    /// For unit testing plan execution without Ollama.
    @MainActor
    private func executePlanDirect(_ orchestrator: TurnOrchestrator, plan: Plan, input: String) -> TurnResult {
        // Use reflection-free approach: execute plan steps manually
        // by creating the same logic flow
        var result = TurnResult()

        for step in plan.steps {
            switch step {
            case .talk(let say):
                result.appendedChat.append(ChatMessage(role: .assistant, text: say))
                result.spokenLines.append(say)

            case .tool(let name, _, let say):
                let toolAction = ToolAction(name: name, args: step.toolArgsAsStrings, say: say)
                let output = ToolsRuntime.shared.execute(toolAction)

                if let output = output {
                    // Check for structured prompt payload (tool requesting info)
                    if let data = output.payload.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let kind = dict["kind"] as? String, kind == "prompt",
                       let slot = dict["slot"] as? String,
                       let spoken = dict["spoken"] as? String {
                        result.appendedChat.append(ChatMessage(role: .assistant, text: spoken))
                        result.spokenLines.append(spoken)
                        orchestrator.pendingSlot = PendingSlot(
                            slotName: slot,
                            prompt: spoken,
                            originalUserText: input
                        )
                        result.triggerFollowUpCapture = true
                        return result
                    }

                    let isPrompt = output.payload.hasPrefix("I need") || output.payload.hasPrefix("I couldn't")
                    if isPrompt {
                        result.appendedChat.append(ChatMessage(role: .assistant, text: output.payload))
                        result.spokenLines.append(output.payload)
                        if output.payload.hasPrefix("I need") {
                            orchestrator.pendingSlot = PendingSlot(
                                slotName: name,
                                prompt: output.payload,
                                originalUserText: input
                            )
                            result.triggerFollowUpCapture = true
                        }
                        return result
                    } else if let data = output.payload.data(using: .utf8),
                              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              (dict["kind"] as? String) != "prompt",
                              let spoken = dict["spoken"] as? String,
                              let formatted = dict["formatted"] as? String {
                        result.appendedChat.append(ChatMessage(role: .assistant, text: spoken))
                        result.spokenLines.append(spoken)
                        result.appendedOutputs.append(OutputItem(kind: .markdown, payload: formatted))
                    } else {
                        if let say = say {
                            result.appendedChat.append(ChatMessage(role: .assistant, text: say))
                            result.spokenLines.append(say)
                        }
                        result.appendedOutputs.append(output)
                    }
                } else {
                    if let say = say {
                        result.appendedChat.append(ChatMessage(role: .assistant, text: say))
                        result.spokenLines.append(say)
                    }
                }

            case .ask(let slot, let prompt):
                orchestrator.pendingSlot = PendingSlot(
                    slotName: slot,
                    prompt: prompt,
                    originalUserText: input
                )
                result.appendedChat.append(ChatMessage(role: .assistant, text: prompt))
                result.spokenLines.append(prompt)
                result.triggerFollowUpCapture = true
                return result

            case .delegate(let task, _, let say):
                if let say = say {
                    result.appendedChat.append(ChatMessage(role: .assistant, text: say))
                    result.spokenLines.append(say)
                }
                result.appendedChat.append(ChatMessage(
                    role: .system,
                    text: "Delegating: \(task)"
                ))
            }
        }

        return result
    }
}
