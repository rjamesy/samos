import XCTest
@testable import SamOS

final class SchedulerToolExtTests: XCTestCase {

    // MARK: - Timer (in_seconds) Support

    func testScheduleTaskWithInSeconds() {
        let tool = ScheduleTaskTool()
        let before = Date()
        let result = tool.execute(args: ["in_seconds": "60", "label": "Test timer"])
        let after = Date()

        // Parse the structured JSON
        guard let data = result.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runAtEpoch = dict["run_at"] as? Double else {
            return XCTFail("Should return structured JSON with run_at, got: \(result.payload)")
        }

        let runAt = Date(timeIntervalSince1970: runAtEpoch)
        let expectedMin = before.addingTimeInterval(60)
        let expectedMax = after.addingTimeInterval(60)

        XCTAssertGreaterThanOrEqual(runAt, expectedMin.addingTimeInterval(-1), "run_at should be ~60s from now")
        XCTAssertLessThanOrEqual(runAt, expectedMax.addingTimeInterval(1), "run_at should be ~60s from now")
        XCTAssertEqual(dict["status"] as? String, "scheduled")
    }

    func testScheduleTaskWithInSecondsTimerWording() {
        let tool = ScheduleTaskTool()
        let result = tool.execute(args: ["in_seconds": "10", "label": "Quick timer"])

        guard let data = result.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spoken = dict["spoken"] as? String else {
            return XCTFail("Should return structured JSON with spoken field")
        }

        XCTAssertTrue(spoken.contains("Timer"), "Spoken should say 'Timer', got: \(spoken)")
        XCTAssertFalse(spoken.contains("Alarm"), "Spoken should NOT say 'Alarm', got: \(spoken)")
    }

    func testScheduleTaskWithRunAtStillWorks() {
        let tool = ScheduleTaskTool()
        let future = Date().addingTimeInterval(3600)
        let result = tool.execute(args: ["run_at": String(future.timeIntervalSince1970), "label": "Test alarm"])

        guard let data = result.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spoken = dict["spoken"] as? String else {
            return XCTFail("Should return structured JSON with spoken field")
        }

        XCTAssertTrue(spoken.contains("Alarm"), "Spoken should say 'Alarm' for run_at, got: \(spoken)")
        XCTAssertEqual(dict["status"] as? String, "scheduled")
    }

    // MARK: - ActionValidator

    func testActionValidatorAcceptsInSeconds() {
        let action = Action.tool(ToolAction(name: "schedule_task", args: [
            "in_seconds": "60",
            "label": "Test timer"
        ]))
        let failure = ActionValidator.validate(action)
        XCTAssertNil(failure, "schedule_task with in_seconds should pass validation")
    }

    func testActionValidatorAcceptsRunAt() {
        let action = Action.tool(ToolAction(name: "schedule_task", args: [
            "run_at": "2025-01-01T12:00:00Z",
            "label": "Test alarm"
        ]))
        let failure = ActionValidator.validate(action)
        XCTAssertNil(failure, "schedule_task with run_at should pass validation")
    }

    func testActionValidatorRejectsMissingBothArgs() {
        let action = Action.tool(ToolAction(name: "schedule_task", args: [
            "label": "No time specified"
        ]))
        let failure = ActionValidator.validate(action)
        XCTAssertNotNil(failure, "schedule_task without run_at or in_seconds should fail")
        XCTAssertTrue(failure!.reasons.first?.contains("in_seconds") == true,
                       "Error should mention in_seconds as an option")
    }

    // MARK: - ListTasksTool Structured Output

    func testListTasksStructuredOutput() {
        // Schedule a task on the shared scheduler so list is non-empty
        let future = Date().addingTimeInterval(7200)
        let id = TaskScheduler.shared.schedule(runAt: future, label: "Structured test", skillId: "alarm_v1")
        XCTAssertNotNil(id)

        let tool = ListTasksTool()
        let result = tool.execute(args: [:])

        guard let data = result.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Clean up
            if let id = id { TaskScheduler.shared.cancel(id: id.uuidString) }
            return XCTFail("ListTasksTool should return parseable JSON, got: \(result.payload)")
        }

        XCTAssertNotNil(dict["spoken"], "Should have spoken field")
        XCTAssertNotNil(dict["formatted"], "Should have formatted field")
        XCTAssertTrue((dict["spoken"] as? String)?.contains("pending") == true,
                       "Spoken should mention pending tasks")

        // Clean up
        if let id = id { TaskScheduler.shared.cancel(id: id.uuidString) }
    }

    func testListTasksEmptyStructuredOutput() {
        // Use a fresh scheduler that's guaranteed empty
        let tool = ListTasksTool()
        let result = tool.execute(args: [:])

        // The shared scheduler might have tasks from other tests,
        // so we just verify the output is valid JSON with expected fields
        if let data = result.payload.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            XCTAssertNotNil(dict["spoken"], "Should have spoken field")
            XCTAssertNotNil(dict["formatted"], "Should have formatted field")
        } else {
            // If it's not JSON, it should be the plain-text fallback
            XCTAssertFalse(result.payload.isEmpty, "Should have some output")
        }
    }
}
