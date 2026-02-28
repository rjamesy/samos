import XCTest
@testable import SamOSv2

final class SchedulerToolsTests: XCTestCase {
    private let scheduler = TaskScheduler()

    func testScheduleTaskName() {
        let tool = ScheduleTaskTool(taskScheduler: scheduler)
        XCTAssertEqual(tool.name, "schedule_task")
    }

    func testScheduleTaskMissingArgsFails() async {
        let tool = ScheduleTaskTool(taskScheduler: scheduler)
        let result = await tool.execute(args: [:])
        XCTAssertFalse(result.success)
    }

    func testScheduleAlarm() async {
        let tool = ScheduleTaskTool(taskScheduler: scheduler)
        let result = await tool.execute(args: ["run_at": "2026-03-01T07:00:00Z", "label": "Wake up"])
        XCTAssertTrue(result.success)
    }

    func testScheduleTimer() async {
        let tool = ScheduleTaskTool(taskScheduler: scheduler)
        let result = await tool.execute(args: ["in_seconds": "300", "label": "Tea"])
        XCTAssertTrue(result.success)
    }

    func testCancelTaskName() {
        let tool = CancelTaskTool(taskScheduler: scheduler)
        XCTAssertEqual(tool.name, "cancel_task")
    }

    func testCancelTaskMissingIdFails() async {
        let tool = CancelTaskTool(taskScheduler: scheduler)
        let result = await tool.execute(args: [:])
        XCTAssertFalse(result.success)
    }

    func testListTasks() async {
        let tool = ListTasksTool(taskScheduler: scheduler)
        XCTAssertEqual(tool.name, "list_tasks")
        let result = await tool.execute(args: [:])
        XCTAssertTrue(result.success)
    }

    func testTimerManageName() {
        let tool = TimerManageTool(taskScheduler: scheduler)
        XCTAssertEqual(tool.name, "timer.manage")
    }

    func testTimerManageMissingDurationFails() async {
        let tool = TimerManageTool(taskScheduler: scheduler)
        let result = await tool.execute(args: ["action": "set"])
        XCTAssertFalse(result.success)
    }

    func testTimerManageStart() async {
        let tool = TimerManageTool(taskScheduler: scheduler)
        let result = await tool.execute(args: ["action": "set", "duration": "600"])
        XCTAssertTrue(result.success)
    }
}
