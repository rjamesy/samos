import XCTest
@testable import SamOS

final class SchedulerTests: XCTestCase {

    private func makeTempScheduler() -> TaskScheduler {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchedulerTest_\(UUID().uuidString).sqlite3").path
        return TaskScheduler(dbPath: path)
    }

    // MARK: - TaskScheduler

    func testScheduleCreatesTask() {
        let scheduler = makeTempScheduler()
        XCTAssertTrue(scheduler.isAvailable)

        let future = Date().addingTimeInterval(3600) // 1 hour from now
        let id = scheduler.schedule(runAt: future, label: "Test alarm", skillId: "alarm_v1")
        XCTAssertNotNil(id)

        let pending = scheduler.listPending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].label, "Test alarm")
        XCTAssertEqual(pending[0].skillId, "alarm_v1")
        XCTAssertEqual(pending[0].status, .pending)
    }

    func testCancelChangesStatus() {
        let scheduler = makeTempScheduler()
        let future = Date().addingTimeInterval(3600)
        guard let id = scheduler.schedule(runAt: future, label: "Cancel me", skillId: "test") else {
            return XCTFail("Failed to schedule")
        }

        XCTAssertTrue(scheduler.cancel(id: id.uuidString))

        let pending = scheduler.listPending()
        XCTAssertEqual(pending.count, 0, "Cancelled task should not appear in pending list")
    }

    func testListPendingFiltersCorrectly() {
        let scheduler = makeTempScheduler()
        let future = Date().addingTimeInterval(3600)

        scheduler.schedule(runAt: future, label: "Task 1", skillId: "s1")
        let id2 = scheduler.schedule(runAt: future, label: "Task 2", skillId: "s2")
        scheduler.schedule(runAt: future, label: "Task 3", skillId: "s3")

        // Cancel one
        if let id = id2 {
            scheduler.cancel(id: id.uuidString)
        }

        let pending = scheduler.listPending()
        XCTAssertEqual(pending.count, 2, "Should have 2 pending after cancelling 1")
    }

    func testFireCallbackInvokedForDueTasks() {
        let scheduler = makeTempScheduler()
        let past = Date().addingTimeInterval(-10) // already due

        let expectation = XCTestExpectation(description: "Task fired")
        var firedTask: ScheduledTask?

        scheduler.onTaskFired = { task in
            firedTask = task
            expectation.fulfill()
        }

        scheduler.schedule(runAt: past, label: "Due now", skillId: "alarm_v1")

        // Manually trigger poll since we're not using the timer in tests
        // Access the private method through the polling mechanism
        scheduler.startPolling()

        wait(for: [expectation], timeout: 10)
        scheduler.stopPolling()

        XCTAssertNotNil(firedTask)
        XCTAssertEqual(firedTask?.label, "Due now")
    }

    func testCancelledTaskDoesNotFire() {
        let scheduler = makeTempScheduler()
        let past = Date().addingTimeInterval(-10)

        guard let id = scheduler.schedule(runAt: past, label: "Don't fire", skillId: "test") else {
            return XCTFail("Failed to schedule")
        }

        scheduler.cancel(id: id.uuidString)

        var fired = false
        scheduler.onTaskFired = { _ in
            fired = true
        }

        scheduler.startPolling()
        // Wait a bit
        let expectation = XCTestExpectation(description: "Wait for potential fire")
        expectation.isInverted = true
        wait(for: [expectation], timeout: 6)
        scheduler.stopPolling()

        XCTAssertFalse(fired, "Cancelled task should not fire")
    }

    func testDismissTask() {
        let scheduler = makeTempScheduler()
        let future = Date().addingTimeInterval(3600)
        guard let id = scheduler.schedule(runAt: future, label: "Dismiss me", skillId: "test") else {
            return XCTFail("Failed to schedule")
        }

        XCTAssertTrue(scheduler.dismiss(id: id.uuidString))
        XCTAssertEqual(scheduler.listPending().count, 0)
    }

    // MARK: - Scheduler Tools

    func testScheduleTaskToolMissingRunAt() {
        let tool = ScheduleTaskTool()
        let result = tool.execute(args: [:])
        XCTAssertTrue(result.payload.hasPrefix("I need"), "Missing run_at should produce a friendly prompt, got: \(result.payload)")
        XCTAssertFalse(result.payload.contains("Error"), "Should not show 'Error' to user")
    }

    func testScheduleTaskToolMissingRunAtAlsoAcceptsDatetimeIso() {
        let tool = ScheduleTaskTool()
        let future = Date().addingTimeInterval(3600)
        let result = tool.execute(args: ["datetime_iso": String(future.timeIntervalSince1970)])
        // Structured JSON payload contains "Alarm set" in spoken/formatted fields
        XCTAssertTrue(result.payload.contains("Alarm set"), "Should accept datetime_iso as fallback key")

        // Verify structured JSON
        if let data = result.payload.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            XCTAssertEqual(dict["status"] as? String, "scheduled")
            XCTAssertNotNil(dict["task_id"], "Should include task_id")
            XCTAssertNotNil(dict["spoken"], "Should include spoken field")
        } else {
            XCTFail("Schedule result should be structured JSON")
        }
    }

    func testScheduleTaskToolRejectsPastEpoch() {
        let tool = ScheduleTaskTool()
        let past = Date().addingTimeInterval(-1)
        let result = tool.execute(args: ["run_at": String(past.timeIntervalSince1970)])
        XCTAssertTrue(result.payload.lowercased().contains("in the past"),
                      "Past run_at should be rejected, got: \(result.payload)")
    }

    func testCancelTaskToolMissingId() {
        let tool = CancelTaskTool()
        let result = tool.execute(args: [:])
        // Should either ask which to cancel (structured JSON) or say there are none
        XCTAssertTrue(
            result.payload.contains("cancel") || result.payload.contains("no pending"),
            "Missing id should produce a friendly prompt, got: \(result.payload)"
        )
        XCTAssertFalse(result.payload.contains("Error"), "Should not show 'Error' to user")
    }

    func testCancelTaskToolMissingIdListsPending() {
        let scheduler = makeTempScheduler()
        let future = Date().addingTimeInterval(3600)
        scheduler.schedule(runAt: future, label: "My alarm", skillId: "alarm_v1")

        // CancelTaskTool uses TaskScheduler.shared, so this test checks the
        // format when the shared scheduler has tasks. We verify the tool's
        // empty-id path independently.
        let tool = CancelTaskTool()
        let result = tool.execute(args: [:])
        // With shared scheduler potentially having tasks, just check no Error
        XCTAssertFalse(result.payload.contains("Error"))
    }

    func testCancelTaskToolSucceeds() {
        // Schedule on shared scheduler, then cancel
        let future = Date().addingTimeInterval(7200)
        guard let id = TaskScheduler.shared.schedule(runAt: future, label: "Cancel test", skillId: "test") else {
            return XCTFail("Failed to schedule")
        }

        let tool = CancelTaskTool()
        let result = tool.execute(args: ["id": id.uuidString])

        // Structured JSON payload with spoken/formatted/status
        XCTAssertTrue(result.payload.contains("Cancelled"), "Should contain 'Cancelled', got: \(result.payload)")
        XCTAssertTrue(result.payload.contains("cancelled"), "Should contain status 'cancelled'")

        // Verify it's valid JSON with expected fields
        if let data = result.payload.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            XCTAssertEqual(dict["spoken"] as? String, "Cancelled.")
            XCTAssertEqual(dict["status"] as? String, "cancelled")
            XCTAssertEqual(dict["task_id"] as? String, id.uuidString)
        } else {
            XCTFail("Cancel result should be structured JSON")
        }
    }

    func testCancelTaskToolNotFound() {
        let tool = CancelTaskTool()
        let result = tool.execute(args: ["id": UUID().uuidString])
        XCTAssertTrue(result.payload.hasPrefix("I couldn't"), "Not-found should produce friendly message")
    }

    func testListTasksToolEmptyList() {
        let tool = ListTasksTool()
        let result = tool.execute(args: [:])
        // Should either show "No pending tasks" or a table (depending on shared scheduler state)
        XCTAssertFalse(result.payload.isEmpty)
    }

    // MARK: - GetTimeTool

    func testGetTimeToolReturnsStructuredPayload() {
        let tool = GetTimeTool()
        let result = tool.execute(args: [:])
        XCTAssertFalse(result.payload.isEmpty, "get_time should return non-empty string")

        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed, "Payload should be parseable structured JSON")
        XCTAssertTrue(parsed!.spoken.hasPrefix("It's "), "spoken should start with 'It's ', got: \(parsed!.spoken)")
        XCTAssertTrue(parsed!.spoken.hasSuffix("."), "spoken should end with period")
        XCTAssertTrue(parsed!.timestamp > 0, "timestamp should be positive")
    }

    func testGetTimeToolIgnoresUnknownArgs() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["foo": "bar"])
        XCTAssertFalse(result.payload.isEmpty, "get_time should work regardless of args")
        XCTAssertNotNil(GetTimeTool.parsePayload(result.payload))
    }
}
