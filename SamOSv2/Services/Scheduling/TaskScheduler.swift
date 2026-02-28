import Foundation

/// Manages alarms and timers with scheduling and state tracking.
actor TaskScheduler {
    private var scheduledTasks: [ScheduledTask] = []
    private var timers: [String: Task<Void, Never>] = [:]

    struct ScheduledTask: Identifiable, Sendable {
        let id: String
        let type: TaskType
        let label: String
        let fireDate: Date
        var status: TaskStatus

        enum TaskType: String, Sendable { case alarm, timer }
        enum TaskStatus: String, Sendable { case scheduled, fired, cancelled }
    }

    /// Schedule an alarm for a specific time.
    func scheduleAlarm(label: String, fireDate: Date, onFire: @escaping @Sendable () -> Void) -> String {
        let id = UUID().uuidString
        let task = ScheduledTask(id: id, type: .alarm, label: label, fireDate: fireDate, status: .scheduled)
        scheduledTasks.append(task)

        let delay = max(fireDate.timeIntervalSinceNow, 0)
        timers[id] = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            onFire()
            await self.markFired(id: id)
        }
        return id
    }

    /// Schedule a timer for a duration in seconds.
    func scheduleTimer(label: String, durationSeconds: TimeInterval, onFire: @escaping @Sendable () -> Void) -> String {
        let id = UUID().uuidString
        let fireDate = Date().addingTimeInterval(durationSeconds)
        let task = ScheduledTask(id: id, type: .timer, label: label, fireDate: fireDate, status: .scheduled)
        scheduledTasks.append(task)

        timers[id] = Task {
            try? await Task.sleep(for: .seconds(durationSeconds))
            guard !Task.isCancelled else { return }
            onFire()
            await self.markFired(id: id)
        }
        return id
    }

    /// Cancel a scheduled task.
    func cancel(id: String) -> Bool {
        guard let index = scheduledTasks.firstIndex(where: { $0.id == id && $0.status == .scheduled }) else {
            return false
        }
        scheduledTasks[index].status = .cancelled
        timers[id]?.cancel()
        timers.removeValue(forKey: id)
        return true
    }

    /// List all scheduled (active) tasks.
    func activeTasks() -> [ScheduledTask] {
        scheduledTasks.filter { $0.status == .scheduled }
    }

    /// List all tasks including fired and cancelled.
    func allTasks() -> [ScheduledTask] {
        scheduledTasks
    }

    private func markFired(id: String) {
        if let index = scheduledTasks.firstIndex(where: { $0.id == id }) {
            scheduledTasks[index].status = .fired
        }
        timers.removeValue(forKey: id)
    }
}
