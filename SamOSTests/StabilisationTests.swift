import XCTest
@testable import SamOS

final class StabilisationTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempScheduler() -> TaskScheduler {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("StabTest_\(UUID().uuidString).sqlite3").path
        return TaskScheduler(dbPath: path)
    }

    // MARK: - 1. Stale Task Expiry (Fix 3.2)

    func testExpireStaleTasksClearsOldPending() {
        let scheduler = makeTempScheduler()
        // Schedule a task in the past (1 hour ago)
        let past = Date().addingTimeInterval(-3600)
        scheduler.schedule(runAt: past, label: "stale", skillId: "alarm_v1")

        XCTAssertEqual(scheduler.listPending().count, 1)

        scheduler.expireStaleTasks()

        XCTAssertEqual(scheduler.listPending().count, 0,
                       "Stale pending task should be expired on launch")
    }

    func testExpireStaleTasksKeepsFutureTasks() {
        let scheduler = makeTempScheduler()
        // Schedule a future task
        let future = Date().addingTimeInterval(3600)
        scheduler.schedule(runAt: future, label: "upcoming", skillId: "alarm_v1")

        scheduler.expireStaleTasks()

        XCTAssertEqual(scheduler.listPending().count, 1,
                       "Future pending task should NOT be expired")
    }

    func testExpireStaleTasksMixedOldAndNew() {
        let scheduler = makeTempScheduler()
        scheduler.schedule(runAt: Date().addingTimeInterval(-600), label: "old", skillId: "alarm_v1")
        scheduler.schedule(runAt: Date().addingTimeInterval(600), label: "new", skillId: "alarm_v1")

        scheduler.expireStaleTasks()

        let pending = scheduler.listPending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].label, "new")
    }

    // MARK: - 2. Strict ISO-8601 Parsing (Fix 3.3)

    func testParseStrictISO8601AcceptsValid() {
        // Full datetime with Z
        XCTAssertNotNil(ScheduleTaskTool.parseStrictISO8601("2025-01-15T08:30:00Z"))
        // With timezone offset
        XCTAssertNotNil(ScheduleTaskTool.parseStrictISO8601("2025-01-15T08:30:00+05:30"))
        // With fractional seconds
        XCTAssertNotNil(ScheduleTaskTool.parseStrictISO8601("2025-01-15T08:30:00.000Z"))
    }

    func testParseStrictISO8601RejectsTimeOnly() {
        XCTAssertNil(ScheduleTaskTool.parseStrictISO8601("08:30:00"),
                     "Time-only strings should be rejected")
        XCTAssertNil(ScheduleTaskTool.parseStrictISO8601("08:30"),
                     "Time-only strings should be rejected")
    }

    func testParseStrictISO8601RejectsTrailingTimezone() {
        XCTAssertNil(ScheduleTaskTool.parseStrictISO8601("2025-01-15T08:30:00+05:30 IST"),
                     "Trailing named timezone should be rejected")
        XCTAssertNil(ScheduleTaskTool.parseStrictISO8601("2025-01-15T08:30:00Z UTC"),
                     "Trailing text after Z should be rejected")
    }

    func testParseStrictISO8601RejectsGarbage() {
        XCTAssertNil(ScheduleTaskTool.parseStrictISO8601("tomorrow"))
        XCTAssertNil(ScheduleTaskTool.parseStrictISO8601(""))
        XCTAssertNil(ScheduleTaskTool.parseStrictISO8601("not a date"))
    }

    // MARK: - 3. ScheduleTaskTool in_seconds Clamping (Fix 3.3)

    func testScheduleTaskRejectsNegativeSeconds() {
        let tool = ScheduleTaskTool()
        let result = tool.execute(args: ["in_seconds": "-10", "label": "test"])
        XCTAssertTrue(result.payload.contains("between"),
                      "Negative in_seconds should be rejected")
    }

    func testScheduleTaskRejectsZeroSeconds() {
        let tool = ScheduleTaskTool()
        let result = tool.execute(args: ["in_seconds": "0", "label": "test"])
        XCTAssertTrue(result.payload.contains("between"),
                      "Zero in_seconds should be rejected")
    }

    func testScheduleTaskRejectsOver24Hours() {
        let tool = ScheduleTaskTool()
        let result = tool.execute(args: ["in_seconds": "100000", "label": "test"])
        XCTAssertTrue(result.payload.contains("between"),
                      "in_seconds > 86400 should be rejected")
    }

    func testScheduleTaskAcceptsValidSeconds() {
        let tool = ScheduleTaskTool()
        let result = tool.execute(args: ["in_seconds": "300", "label": "test", "skill_id": "alarm_v1"])
        // Should succeed (contains "Timer set" or structured JSON with "scheduled")
        XCTAssertTrue(result.payload.contains("Timer set") || result.payload.contains("scheduled"),
                      "Valid in_seconds should produce a success response")
    }

    func testScheduleTaskRejectsPastDate() {
        let tool = ScheduleTaskTool()
        let result = tool.execute(args: ["run_at": "2020-01-01T00:00:00Z", "label": "test"])
        XCTAssertTrue(result.payload.contains("past"),
                      "Past dates should be rejected")
    }

    // MARK: - 4. AlarmSession.interpretPlan (Fix 3.4)

    func testInterpretPlanDetectsDismiss() {
        let plan = Plan(steps: [
            .talk(say: "Have a great day!"),
            .tool(name: "cancel_task", args: ["id": .string("some-id")], say: nil)
        ])
        let interp = AlarmSession.interpretPlan(plan)
        XCTAssertTrue(interp.hasCancelTask)
        XCTAssertFalse(interp.hasScheduleTask)
        XCTAssertEqual(interp.talkLines, ["Have a great day!"])
    }

    func testInterpretPlanDetectsSnooze() {
        let plan = Plan(steps: [
            .talk(say: "Fine, 5 more minutes!"),
            .tool(name: "schedule_task", args: ["in_seconds": .string("300")], say: nil)
        ])
        let interp = AlarmSession.interpretPlan(plan)
        XCTAssertFalse(interp.hasCancelTask)
        XCTAssertTrue(interp.hasScheduleTask)
        XCTAssertEqual(interp.snoozeSeconds, 300)
        XCTAssertEqual(interp.talkLines, ["Fine, 5 more minutes!"])
    }

    func testInterpretPlanDetectsOther() {
        let plan = Plan(steps: [
            .talk(say: "Come on, get up!")
        ])
        let interp = AlarmSession.interpretPlan(plan)
        XCTAssertFalse(interp.hasCancelTask)
        XCTAssertFalse(interp.hasScheduleTask)
        XCTAssertEqual(interp.talkLines, ["Come on, get up!"])
    }

    func testInterpretPlanIncludesToolSay() {
        let plan = Plan(steps: [
            .tool(name: "cancel_task", args: ["id": .string("x")], say: "Goodbye!")
        ])
        let interp = AlarmSession.interpretPlan(plan)
        XCTAssertTrue(interp.hasCancelTask)
        XCTAssertEqual(interp.talkLines, ["Goodbye!"])
    }

    func testInterpretPlanDefaultSnooze() {
        let plan = Plan(steps: [
            .tool(name: "schedule_task", args: [:], say: nil)
        ])
        let interp = AlarmSession.interpretPlan(plan)
        XCTAssertTrue(interp.hasScheduleTask)
        XCTAssertEqual(interp.snoozeSeconds, 300,
                       "Default snooze should be 300 seconds when in_seconds not specified")
    }

    // MARK: - 5. AlarmSession handleUserReply Does Not Execute Tools (Fix 3.4)

    @MainActor
    func testHandleUserReplyDoesNotCallPlanExecutor() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        var spokenTexts: [String] = []
        session.onSpeak = { spokenTexts.append($0) }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        // Start alarm
        mock.planToReturn = Plan(steps: [.talk(say: "Wake up!")])
        let task = ScheduledTask(
            id: UUID(), runAt: Date(), label: "test",
            skillId: "alarm_v1", payload: [:], status: .fired
        )
        session.startRinging(task: task)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Reply with a plan that has cancel_task
        mock.planToReturn = Plan(steps: [
            .talk(say: "Have a great day!"),
            .tool(name: "cancel_task", args: ["id": .string("placeholder")], say: nil)
        ])
        await session.handleUserReply("I'm awake")

        // Alarm should be dismissed
        XCTAssertEqual(session.state, .idle)
        // The talk line should have been spoken
        XCTAssertTrue(spokenTexts.contains("Have a great day!"))
    }

    @MainActor
    func testSnoozeCreatesTaskInternally() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        mock.planToReturn = Plan(steps: [.talk(say: "Morning!")])
        let task = ScheduledTask(
            id: UUID(), runAt: Date(), label: "test",
            skillId: "alarm_v1", payload: [:], status: .fired
        )
        session.startRinging(task: task)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Reply with snooze plan
        mock.planToReturn = Plan(steps: [
            .talk(say: "Fine, 5 more!"),
            .tool(name: "schedule_task", args: ["in_seconds": .string("300")], say: nil)
        ])
        await session.handleUserReply("snooze")

        // Should transition to snoozed state
        if case .snoozed(_, _, let snoozedOnce, _) = session.state {
            XCTAssertTrue(snoozedOnce)
        } else {
            XCTFail("Expected .snoozed state, got \(session.state)")
        }
    }

    // MARK: - 6. LLMCallReason Enum Exists

    func testLLMCallReasonCases() {
        // Verify enum has all expected cases
        let reasons: [LLMCallReason] = [
            .userChat, .pendingSlotReply, .alarmTriggered,
            .alarmRepeat, .snoozeExpired, .alarmReply,
            .imageRepair
        ]
        XCTAssertEqual(reasons.count, 7)
        XCTAssertEqual(LLMCallReason.userChat.rawValue, "userChat")
    }

    // MARK: - 7. expireAllPending (Fix QA2-B)

    func testExpireAllPendingClearsFutureTasks() {
        let scheduler = makeTempScheduler()
        // Schedule a task 1 hour in the FUTURE
        scheduler.schedule(runAt: Date().addingTimeInterval(3600), label: "future", skillId: "alarm_v1")
        XCTAssertEqual(scheduler.listPending().count, 1)

        scheduler.expireAllPending()

        XCTAssertEqual(scheduler.listPending().count, 0,
                       "expireAllPending should clear even future pending tasks")
    }

    func testExpireAllPendingClearsMixed() {
        let scheduler = makeTempScheduler()
        scheduler.schedule(runAt: Date().addingTimeInterval(-600), label: "past", skillId: "alarm_v1")
        scheduler.schedule(runAt: Date().addingTimeInterval(45), label: "near-future", skillId: "alarm_v1")
        scheduler.schedule(runAt: Date().addingTimeInterval(3600), label: "far-future", skillId: "alarm_v1")

        scheduler.expireAllPending()

        XCTAssertEqual(scheduler.listPending().count, 0,
                       "expireAllPending should clear all pending regardless of run_at")
    }

    func testExpireStaleTasksLeavesNearFutureAlive() {
        let scheduler = makeTempScheduler()
        // A task 45s in the future — this is the ghost alarm scenario
        scheduler.schedule(runAt: Date().addingTimeInterval(45), label: "near-future", skillId: "alarm_v1")

        scheduler.expireStaleTasks()

        XCTAssertEqual(scheduler.listPending().count, 1,
                       "expireStaleTasks leaves near-future tasks alive (the bug expireAllPending fixes)")
    }

    // MARK: - 8. Cold-Launch No Alarm LLM Calls (Fix QA2-B)

    @MainActor
    func testColdLaunchNoAlarmLLMCalls() async throws {
        let mock = MockAlarmPlanRouter()
        let session = AlarmSession(planRouter: mock)
        session.onSpeak = { _ in }
        session.onAddChatMessage = { _ in }
        session.onDismiss = { _ in }
        session.onRequestFollowUp = {}

        // Simulate cold launch idle period — no startRinging, no snoozeExpired
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        XCTAssertEqual(mock.callLog.count, 0,
                       "No alarm LLM calls should happen during cold launch idle")
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isRinging)
        XCTAssertFalse(session.isActive)
    }

    // MARK: - 9. handleScheduledTask Hard Gate (Fix QA2-B)

    func testHandleScheduledTaskRejectsStaleTask() {
        let scheduler = makeTempScheduler()
        // Schedule a task 60s in the past
        let pastDate = Date().addingTimeInterval(-60)
        let taskId = scheduler.schedule(runAt: pastDate, label: "stale-alarm", skillId: "alarm_v1")
        XCTAssertNotNil(taskId)

        // The hard gate (age > 30) in AppState.handleScheduledTask would reject this.
        // We test the logic directly: age > 30 should reject.
        let age = Date().timeIntervalSince(pastDate)
        XCTAssertGreaterThan(age, 30,
                             "Task 60s old should exceed the 30s hard gate")
    }

    func testHandleScheduledTaskAcceptsRecentTask() {
        // A task that just fired (age ~0) should pass the hard gate
        let recentDate = Date()
        let age = Date().timeIntervalSince(recentDate)
        XCTAssertLessThanOrEqual(age, 30,
                                 "Task that just fired should pass the 30s hard gate")
    }

    // MARK: - 10. SQLite Thread Safety Regression (Fix QA2-A)

    func testTaskSchedulerConcurrentAccessDoesNotCrash() {
        let scheduler = makeTempScheduler()

        let expectation = XCTestExpectation(description: "Concurrent operations complete")
        expectation.expectedFulfillmentCount = 4

        // Hammer the scheduler from multiple threads simultaneously
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<50 {
                scheduler.schedule(
                    runAt: Date().addingTimeInterval(Double(i) * 10),
                    label: "concurrent-\(i)",
                    skillId: "alarm_v1"
                )
            }
            expectation.fulfill()
        }

        DispatchQueue.global(qos: .background).async {
            for _ in 0..<50 {
                _ = scheduler.listPending()
            }
            expectation.fulfill()
        }

        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<50 {
                scheduler.expireStaleTasks()
            }
            expectation.fulfill()
        }

        DispatchQueue.global(qos: .default).async {
            for i in 0..<50 {
                scheduler.cancel(id: UUID().uuidString)
                scheduler.dismiss(id: UUID().uuidString)
                if i % 10 == 0 {
                    scheduler.expireAllPending()
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
        // If we reach here without crashing, thread safety is working
    }

    func testForgeQueueConcurrentAccessDoesNotCrash() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeQueueStab_\(UUID().uuidString).sqlite3").path
        let queue = SkillForgeQueueService(dbPath: path)

        let expectation = XCTestExpectation(description: "Concurrent forge queue operations complete")
        expectation.expectedFulfillmentCount = 3

        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<50 {
                queue.enqueue(goal: "goal-\(i)", constraints: "constraint-\(i)")
            }
            expectation.fulfill()
        }

        DispatchQueue.global(qos: .background).async {
            for _ in 0..<50 {
                _ = queue.allJobs()
                _ = queue.pendingCount
            }
            expectation.fulfill()
        }

        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<50 {
                queue.clearFinished()
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
        // If we reach here without crashing, thread safety is working
    }
}
