import XCTest
@testable import SamOS

// MARK: - Mock Alarm Plan Router

@MainActor
final class MockAlarmPlanRouter: AlarmPlanRouter {
    var planToReturn: Plan = Plan(steps: [.talk(say: "Mock response")])
    /// When set, returns plans in sequence (cycling). Takes priority over planToReturn.
    var planSequence: [Plan]?
    private var sequenceIndex = 0
    var shouldThrow = false
    var callLog: [(input: String, history: [ChatMessage], context: AlarmContext)] = []

    func routeAlarmPlan(_ input: String, history: [ChatMessage], alarmContext: AlarmContext) async throws -> Plan {
        callLog.append((input, history, alarmContext))
        if shouldThrow { throw NSError(domain: "test", code: 1) }
        if let seq = planSequence, !seq.isEmpty {
            let plan = seq[sequenceIndex % seq.count]
            sequenceIndex += 1
            return plan
        }
        return planToReturn
    }
}

// MARK: - Tests

final class AlarmSessionTests: XCTestCase {

    private func makeTask(id: UUID = UUID(), label: String = "Test alarm") -> ScheduledTask {
        ScheduledTask(
            id: id,
            runAt: Date(),
            label: label,
            skillId: "alarm_v1",
            payload: [:],
            status: .fired
        )
    }

    private func makeSnoozedTask(from taskId: UUID) -> ScheduledTask {
        ScheduledTask(
            id: UUID(),
            runAt: Date(),
            label: "Snoozed alarm",
            skillId: "alarm_v1",
            payload: ["snoozed_from": taskId.uuidString],
            status: .fired
        )
    }

    // MARK: - 1. Start Ring Speaks LLM Greeting

    @MainActor
    func testStartRingSpeaksLLMGreeting() async throws {
        let mock = MockAlarmPlanRouter()
        mock.planToReturn = Plan(steps: [.talk(say: "Rise and shine!")])
        let session = AlarmSession(planRouter: mock)
        var spokenTexts: [String] = []
        session.onSpeak = { spokenTexts.append($0) }
        session.onAddChatMessage = { _ in }
        session.onRequestFollowUp = {}

        session.startRinging(task: makeTask())

        // Wait for async greeting generation
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(session.isRinging)
        XCTAssertEqual(spokenTexts, ["Rise and shine!"])
    }

    // MARK: - 2. Ack Plan Dismisses Alarm

    @MainActor
    func testAckPlanDismissesAlarm() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        var spokenTexts: [String] = []
        var dismissedId: UUID?
        session.onSpeak = { spokenTexts.append($0) }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { dismissedId = $0 }
        session.onRequestFollowUp = {}

        let task = makeTask()
        session.startRinging(task: task)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Set up ack plan: talk + cancel_task
        mock.planToReturn = Plan(steps: [
            .talk(say: "Have a great day!"),
            .tool(name: "cancel_task", args: ["id": .string("placeholder")], say: nil)
        ])

        await session.handleUserReply("I'm awake")

        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(dismissedId, task.id)
        XCTAssertTrue(spokenTexts.contains("Have a great day!"))
    }

    // MARK: - 3. Snooze Plan Schedules Snooze

    @MainActor
    func testSnoozePlanSchedulesSnooze() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        var spokenTexts: [String] = []
        session.onSpeak = { spokenTexts.append($0) }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        let task = makeTask()
        session.startRinging(task: task)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Set up snooze plan: talk + schedule_task
        mock.planToReturn = Plan(steps: [
            .talk(say: "Fine, 5 more!"),
            .tool(name: "schedule_task", args: ["in_seconds": .string("300")], say: nil)
        ])

        await session.handleUserReply("snooze")

        if case .snoozed(_, _, let snoozedOnce, _) = session.state {
            XCTAssertTrue(snoozedOnce)
        } else {
            XCTFail("Expected .snoozed state, got \(session.state)")
        }
        XCTAssertTrue(spokenTexts.contains("Fine, 5 more!"))
    }

    // MARK: - 4. Snooze Blocked Overrides LLM

    @MainActor
    func testSnoozeBlockedOverridesLLM() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        var spokenTexts: [String] = []
        session.onSpeak = { spokenTexts.append($0) }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        let taskId = UUID()
        let task = makeTask(id: taskId)
        session.startRinging(task: task)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Simulate snooze expired (snoozedOnce = true)
        let snoozedTask = makeSnoozedTask(from: taskId)
        session.snoozeExpired(task: snoozedTask)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(session.canSnooze)

        // LLM returns a snooze plan anyway
        mock.planToReturn = Plan(steps: [
            .talk(say: "Sure, snoozing!"),
            .tool(name: "schedule_task", args: ["in_seconds": .string("300")], say: nil)
        ])

        await session.handleUserReply("snooze")

        // Should still be ringing — sanitizePlan dropped the schedule_task
        XCTAssertTrue(session.isRinging)
        XCTAssertTrue(spokenTexts.contains("No more snoozes — you've got this."))
    }

    // MARK: - 5. Snooze Clamps To 900 Seconds

    @MainActor
    func testSnoozeClampsTo900Seconds() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        mock.planToReturn = Plan(steps: [
            .talk(say: "Okay, snoozing!"),
            .tool(name: "schedule_task", args: ["in_seconds": .string("1200")], say: nil)
        ])

        await session.handleUserReply("snooze for 20 minutes")

        if case .snoozed = session.state {
            // Verify via sanitizePlan static test (detailed below)
        } else {
            XCTFail("Expected .snoozed state")
        }
    }

    // MARK: - 6. Snooze Clamp Floor At 60 Seconds

    @MainActor
    func testSnoozeClampFloorAt60Seconds() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        mock.planToReturn = Plan(steps: [
            .talk(say: "Quick snooze!"),
            .tool(name: "schedule_task", args: ["in_seconds": .string("10")], say: nil)
        ])

        await session.handleUserReply("snooze for 10 seconds")

        if case .snoozed = session.state {
            // Verify via sanitizePlan static test
        } else {
            XCTFail("Expected .snoozed state")
        }
    }

    // MARK: - 7. Other Intent Keeps Ringing

    @MainActor
    func testOtherIntentKeepsRinging() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        var spokenTexts: [String] = []
        session.onSpeak = { spokenTexts.append($0) }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        // LLM returns only talk (no cancel or schedule)
        mock.planToReturn = Plan(steps: [
            .talk(say: "Come on, time to get up!")
        ])

        await session.handleUserReply("what's the weather?")

        XCTAssertTrue(session.isRinging)
        XCTAssertTrue(spokenTexts.contains("Come on, time to get up!"))
    }

    // MARK: - 8. Context Passes Can Snooze

    @MainActor
    func testContextPassesCanSnooze() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        mock.planToReturn = Plan(steps: [.talk(say: "Get up!")])
        await session.handleUserReply("hello")

        // The handleUserReply call should have logged a context
        let lastCall = mock.callLog.last
        XCTAssertNotNil(lastCall)
        XCTAssertTrue(lastCall!.context.canSnooze)
    }

    // MARK: - 9. Context After Snooze Expired

    @MainActor
    func testContextAfterSnoozeExpired() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        let taskId = UUID()
        session.startRinging(task: makeTask(id: taskId))
        try await Task.sleep(nanoseconds: 100_000_000)

        session.snoozeExpired(task: makeSnoozedTask(from: taskId))
        try await Task.sleep(nanoseconds: 100_000_000)

        mock.planToReturn = Plan(steps: [.talk(say: "Get up!")])
        await session.handleUserReply("hello")

        let lastCall = mock.callLog.last
        XCTAssertNotNil(lastCall)
        XCTAssertTrue(lastCall!.context.snoozedOnce)
        XCTAssertFalse(lastCall!.context.canSnooze)
    }

    // MARK: - 10. Context Repeat Count Increments

    @MainActor
    func testContextRepeatCountIncrements() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onRequestFollowUp = {}

        mock.planToReturn = Plan(steps: [.talk(say: "Wake up!")])
        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        // The startRinging call should have set attempt = 1
        // The generateLine call inside startRinging logged a context
        let startCall = mock.callLog.first
        XCTAssertNotNil(startCall)
        XCTAssertEqual(startCall!.context.repeatCount, 1)
    }

    // MARK: - 11. LLM Failure Speaks Generic Line

    @MainActor
    func testLLMFailureSpeaksGenericLine() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        var spokenTexts: [String] = []
        session.onSpeak = { spokenTexts.append($0) }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)
        spokenTexts.removeAll()

        mock.shouldThrow = true
        await session.handleUserReply("I'm up")

        XCTAssertTrue(session.isRinging)
        XCTAssertEqual(spokenTexts, ["Hmm, try again."])
    }

    // MARK: - 12. Sanitize Plan Forces Task ID

    func testSanitizePlanForcesTaskId() {
        let taskId = UUID()
        let plan = Plan(steps: [
            .talk(say: "Bye!"),
            .tool(name: "cancel_task", args: ["id": .string("wrong-id")], say: nil)
        ])

        let sanitized = AlarmSession.sanitizePlan(plan, taskId: taskId, canSnooze: true)

        if case .tool(_, let args, _) = sanitized.steps[1] {
            XCTAssertEqual(args["id"]?.stringValue, taskId.uuidString)
        } else {
            XCTFail("Expected tool step")
        }
    }

    // MARK: - 13. Sanitize Plan Clamps

    func testSanitizePlanClamps() {
        let taskId = UUID()

        // Over 900 → clamp to 900
        let planOver = Plan(steps: [
            .tool(name: "schedule_task", args: ["in_seconds": .string("1200")], say: nil)
        ])
        let sanitizedOver = AlarmSession.sanitizePlan(planOver, taskId: taskId, canSnooze: true)
        if case .tool(_, let args, _) = sanitizedOver.steps[0] {
            XCTAssertEqual(args["in_seconds"]?.stringValue, "900")
        } else {
            XCTFail("Expected tool step")
        }

        // Under 60 → clamp to 60
        let planUnder = Plan(steps: [
            .tool(name: "schedule_task", args: ["in_seconds": .string("10")], say: nil)
        ])
        let sanitizedUnder = AlarmSession.sanitizePlan(planUnder, taskId: taskId, canSnooze: true)
        if case .tool(_, let args, _) = sanitizedUnder.steps[0] {
            XCTAssertEqual(args["in_seconds"]?.stringValue, "60")
        } else {
            XCTFail("Expected tool step")
        }
    }

    // MARK: - 14. Sanitize Plan Drops Snooze When Used

    func testSanitizePlanDropsSnoozeWhenUsed() {
        let taskId = UUID()
        let plan = Plan(steps: [
            .talk(say: "Snoozing!"),
            .tool(name: "schedule_task", args: ["in_seconds": .string("300")], say: nil)
        ])

        let sanitized = AlarmSession.sanitizePlan(plan, taskId: taskId, canSnooze: false)

        // schedule_task should be dropped
        let hasSchedule = sanitized.steps.contains { step in
            if case .tool(let name, _, _) = step, name == "schedule_task" { return true }
            return false
        }
        XCTAssertFalse(hasSchedule, "schedule_task should be dropped when canSnooze is false")

        // "No more snoozes" talk step should be appended
        let hasFallback = sanitized.steps.contains { step in
            if case .talk(let say) = step, say.contains("No more snoozes") { return true }
            return false
        }
        XCTAssertTrue(hasFallback, "Should append 'No more snoozes' talk step")
    }

    // MARK: - 15. Sanitize Plan Passes Through Talk

    func testSanitizePlanPassesThroughTalk() {
        let taskId = UUID()
        let plan = Plan(steps: [
            .talk(say: "Hello!"),
            .talk(say: "Good morning!")
        ])

        let sanitized = AlarmSession.sanitizePlan(plan, taskId: taskId, canSnooze: true)

        XCTAssertEqual(sanitized.steps.count, 2)
        if case .talk(let say) = sanitized.steps[0] {
            XCTAssertEqual(say, "Hello!")
        } else {
            XCTFail("Expected talk step")
        }
        if case .talk(let say) = sanitized.steps[1] {
            XCTAssertEqual(say, "Good morning!")
        } else {
            XCTFail("Expected talk step")
        }
    }

    // MARK: - 16. Dismiss Cancels Loop And State

    @MainActor
    func testDismissCancelsLoopAndState() async throws {
        let mock = MockAlarmPlanRouter()
        mock.planToReturn = Plan(steps: [.talk(say: "Wake up!")])
        let session = AlarmSession(planRouter: mock)
        var dismissedId: UUID?
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { dismissedId = $0 }
        session.onRequestFollowUp = {}

        let task = makeTask()
        session.startRinging(task: task)
        try await Task.sleep(nanoseconds: 100_000_000)
        session.dismiss()

        XCTAssertFalse(session.isRinging)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(dismissedId, task.id)
    }

    // MARK: - 17. Dismiss From Idle Is Noop

    @MainActor
    func testDismissFromIdleIsNoop() {
        let session = AlarmSession(planRouter: MockAlarmPlanRouter())
        var dismissed = false
        session.onDismiss = { _ in dismissed = true }

        session.dismiss()

        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(dismissed, "onDismiss should not be called when idle")
    }

    // MARK: - 18. Snooze Minutes Capped At 15

    func testSnoozeMinutesCappedAt15() {
        XCTAssertEqual(AlarmSession.parseSnoozeMinutes(requested: 30), 15)
        XCTAssertEqual(AlarmSession.parseSnoozeMinutes(requested: 10), 10)
        XCTAssertEqual(AlarmSession.parseSnoozeMinutes(requested: 0), 1)
        XCTAssertEqual(AlarmSession.parseSnoozeMinutes(requested: -5), 1)
        XCTAssertEqual(AlarmSession.parseSnoozeMinutes(requested: 15), 15)
        XCTAssertEqual(AlarmSession.parseSnoozeMinutes(requested: 1), 1)
    }

    // MARK: - 19. Time of Day Greeting Static

    func testTimeOfDayGreetingStatic() {
        let greeting = AlarmSession.timeOfDayGreeting(userName: "Richard")
        XCTAssertTrue(greeting.contains("Richard"), "Greeting should contain user name")
        XCTAssertTrue(greeting.contains("time to get up"), "Greeting should contain wake-up text")
        let lower = greeting.lowercased()
        XCTAssertTrue(
            lower.contains("morning") || lower.contains("afternoon") || lower.contains("evening"),
            "Greeting should have time-of-day"
        )
    }

    // MARK: - 20. Time of Day Greeting Default Name

    func testTimeOfDayGreetingDefaultName() {
        let greeting = AlarmSession.timeOfDayGreeting(userName: nil)
        XCTAssertTrue(greeting.contains("there"), "Default greeting should use 'there'")

        let greetingEmpty = AlarmSession.timeOfDayGreeting(userName: "")
        XCTAssertTrue(greetingEmpty.contains("there"), "Empty name greeting should use 'there'")
    }

    // MARK: - 21. Parse Classifier Backward Compat

    func testParseClassifierBackwardCompat() {
        XCTAssertEqual(AlarmSession.parseClassifierResponse("{\"intent\":\"ACK_AWAKE\"}"), .ackAwake)
        XCTAssertEqual(AlarmSession.parseClassifierResponse("{\"intent\":\"SNOOZE\",\"minutes\":10}"), .snooze(minutes: 10))
        XCTAssertEqual(AlarmSession.parseClassifierResponse("{\"intent\":\"SNOOZE\",\"minutes\":30}"), .snooze(minutes: 15))
        XCTAssertEqual(AlarmSession.parseClassifierResponse("{\"intent\":\"OTHER\"}"), .other)
        XCTAssertEqual(AlarmSession.parseClassifierResponse("not json"), .other)
        XCTAssertEqual(AlarmSession.parseClassifierResponse(""), .other)
        XCTAssertEqual(AlarmSession.parseClassifierResponse("{}"), .other)
        XCTAssertEqual(AlarmSession.parseClassifierResponse("{\"intent\":\"UNKNOWN\"}"), .other)
    }

    // MARK: - 22. Greeting Uses Alarm Trigger Input

    @MainActor
    func testGreetingUsesAlarmTriggerInput() async throws {
        let mock = MockAlarmPlanRouter()
        mock.planToReturn = Plan(steps: [.talk(say: "Good morning!")])
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onRequestFollowUp = {}

        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(mock.callLog.isEmpty)
        XCTAssertEqual(mock.callLog[0].input, "[alarm triggered]")
    }

    // MARK: - 23. Alarm History Passed To Router

    @MainActor
    func testAlarmHistoryPassedToRouter() async throws {
        let mock = MockAlarmPlanRouter()
        mock.planToReturn = Plan(steps: [.talk(say: "Wake up!")])
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        // First call (greeting) has empty history
        XCTAssertEqual(mock.callLog[0].history.count, 0)

        // Now handle a user reply
        mock.planToReturn = Plan(steps: [.talk(say: "Come on, get up!")])
        await session.handleUserReply("what time is it")

        // Second call (handleUserReply) should have history:
        // 1 assistant greeting + 1 user reply = 2 messages
        let replyCall = mock.callLog.last!
        XCTAssertGreaterThanOrEqual(replyCall.history.count, 2)

        // History should contain the greeting as assistant and user reply
        let roles = replyCall.history.map { $0.role }
        XCTAssertTrue(roles.contains(.assistant))
        XCTAssertTrue(roles.contains(.user))
        XCTAssertEqual(replyCall.history.last?.text, "what time is it")
    }

    // MARK: - 24. Alarm History Tracks User Replies

    @MainActor
    func testAlarmHistoryTracksUserReplies() async throws {
        let mock = MockAlarmPlanRouter()
        mock.planToReturn = Plan(steps: [.talk(say: "Good morning!")])
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        // Reply 1
        mock.planToReturn = Plan(steps: [.talk(say: "Get up!")])
        await session.handleUserReply("no")

        // Reply 2
        mock.planToReturn = Plan(steps: [.talk(say: "Come on!")])
        await session.handleUserReply("not yet")

        // Third call should have accumulated history
        let lastCall = mock.callLog.last!
        // greeting(asst) + "no"(user) + "Get up!"(asst) + "not yet"(user) = 4 messages
        XCTAssertGreaterThanOrEqual(lastCall.history.count, 4)
    }

    // MARK: - 25. Alarm History Cleared On Start

    @MainActor
    func testAlarmHistoryClearedOnStart() async throws {
        let mock = MockAlarmPlanRouter()
        mock.planToReturn = Plan(steps: [.talk(say: "Wake up!")])
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        // First alarm
        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        mock.planToReturn = Plan(steps: [.talk(say: "Get up!")])
        await session.handleUserReply("no")

        // Dismiss and start new alarm
        session.dismiss()

        mock.planToReturn = Plan(steps: [.talk(say: "Morning again!")])
        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        // The greeting call for the second alarm should have empty history
        let secondAlarmGreetingCall = mock.callLog.last!
        XCTAssertEqual(secondAlarmGreetingCall.history.count, 0,
                       "History should be cleared when a new alarm starts")
    }

    // MARK: - 26. Alarm History Limited To 12

    @MainActor
    func testAlarmHistoryLimitedTo12() async throws {
        let mock = MockAlarmPlanRouter()
        mock.planToReturn = Plan(steps: [.talk(say: "Wake up!")])
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        // Send 10 replies (each adds 1 user + 1 assistant = 20 total + 1 greeting = 21)
        for i in 1...10 {
            mock.planToReturn = Plan(steps: [.talk(say: "Line \(i)")])
            await session.handleUserReply("reply \(i)")
        }

        // History passed to router should be capped at 12
        let lastCall = mock.callLog.last!
        XCTAssertLessThanOrEqual(lastCall.history.count, 12,
                                 "Alarm history should be limited to 12 messages")
    }

    // MARK: - 27. Follow-Up Called On Speak

    @MainActor
    func testFollowUpCalledOnSpeak() async throws {
        let mock = MockAlarmPlanRouter()
        mock.planToReturn = Plan(steps: [.talk(say: "Wake up!")])
        let session = AlarmSession(planRouter: mock)
        var followUpCount = 0
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = { followUpCount += 1 }

        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        // The loop calls onRequestFollowUp once at start
        XCTAssertGreaterThanOrEqual(followUpCount, 1,
                                    "onRequestFollowUp should be called during alarm")
    }

    // MARK: - 28. Context Last Spoken Variants Passed

    @MainActor
    func testContextLastSpokenVariantsPassed() async throws {
        let mock = MockAlarmPlanRouter()
        mock.planToReturn = Plan(steps: [.talk(say: "Rise and shine!")])
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        session.startRinging(task: makeTask())
        try await Task.sleep(nanoseconds: 100_000_000)

        // After greeting, handle a reply — context should contain the greeting in lastSpokenVariants
        mock.planToReturn = Plan(steps: [.talk(say: "Let's go!")])
        await session.handleUserReply("huh")

        let lastCall = mock.callLog.last!
        XCTAssertFalse(lastCall.context.lastSpokenVariants.isEmpty,
                       "lastSpokenVariants should contain the greeting line")
        XCTAssertTrue(lastCall.context.lastSpokenVariants.contains("Rise and shine!"))
    }
}
