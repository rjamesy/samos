import Foundation

/// Schedules a timer or alarm.
struct ScheduleTaskTool: Tool {
    let name = "schedule_task"
    let description = "Schedule a timer or alarm"
    let parameterDescription = "Args: in_seconds (timer), run_at (ISO-8601 alarm), label (optional)"
    let taskScheduler: TaskScheduler

    var schema: ToolSchema? {
        ToolSchema(properties: [
            "in_seconds": ToolSchemaProperty(type: "number", description: "Duration in seconds for a timer"),
            "run_at": ToolSchemaProperty(description: "ISO-8601 datetime for an alarm"),
            "label": ToolSchemaProperty(description: "Name for the timer or alarm")
        ])
    }

    func execute(args: [String: String]) async -> ToolResult {
        let label = args["label"] ?? args["name"] ?? "Timer"

        // Timer mode
        if let secondsStr = args["in_seconds"] ?? args["duration_seconds"] ?? args["seconds"],
           let seconds = Double(secondsStr) {
            guard seconds >= 1 && seconds <= 86400 else {
                return .failure(tool: name, error: "Timer must be between 1 second and 24 hours")
            }
            let _ = await taskScheduler.scheduleTimer(label: label, durationSeconds: seconds, onFire: {
                print("[Timer] \(label) fired!")
            })
            let duration = formatDuration(seconds)
            return .success(tool: name, spoken: "\(label) set for \(duration).")
        }

        // Alarm mode
        if let runAt = args["run_at"] ?? args["datetime_iso"] ?? args["datetime"] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: runAt) else {
                return .failure(tool: name, error: "Invalid ISO-8601 date: \(runAt)")
            }
            let _ = await taskScheduler.scheduleAlarm(label: label, fireDate: date, onFire: {
                print("[Alarm] \(label) fired!")
            })
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "h:mm a"
            let timeStr = displayFormatter.string(from: date)
            return .success(tool: name, spoken: "Alarm set for \(timeStr).")
        }

        return .failure(tool: name, error: "Provide either in_seconds for a timer or run_at for an alarm")
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) seconds" }
        if s < 3600 {
            let m = s / 60
            let r = s % 60
            return r > 0 ? "\(m) minutes and \(r) seconds" : "\(m) minutes"
        }
        let h = s / 3600
        let m = (s % 3600) / 60
        return m > 0 ? "\(h) hours and \(m) minutes" : "\(h) hours"
    }
}

/// Cancels a scheduled task.
struct CancelTaskTool: Tool {
    let name = "cancel_task"
    let description = "Cancel a scheduled timer or alarm"
    let parameterDescription = "Args: task_id (string)"
    let taskScheduler: TaskScheduler

    func execute(args: [String: String]) async -> ToolResult {
        let taskId = args["task_id"] ?? args["id"] ?? ""
        guard !taskId.isEmpty else {
            return .failure(tool: name, error: "No task ID provided")
        }
        let cancelled = await taskScheduler.cancel(id: taskId)
        if cancelled {
            return .success(tool: name, spoken: "Task cancelled.")
        } else {
            return .failure(tool: name, error: "No active task found with that ID.")
        }
    }
}

/// Lists all scheduled tasks.
struct ListTasksTool: Tool {
    let name = "list_tasks"
    let description = "List all active timers and alarms"
    let parameterDescription = "No args"
    let taskScheduler: TaskScheduler

    func execute(args: [String: String]) async -> ToolResult {
        let tasks = await taskScheduler.activeTasks()
        if tasks.isEmpty {
            return .success(tool: name, spoken: "No active timers or alarms.")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let descriptions = tasks.map { t in
            let timeStr = formatter.string(from: t.fireDate)
            return "\(t.type.rawValue): \(t.label) at \(timeStr)"
        }
        let list = descriptions.joined(separator: ". ")
        return .success(tool: name, spoken: "Active tasks: \(list).")
    }
}

/// Manages timers (set, cancel, list).
struct TimerManageTool: Tool {
    let name = "timer.manage"
    let description = "Set, cancel, or list timers"
    let parameterDescription = "Args: action (set/cancel/list), duration (seconds), label (optional)"
    let taskScheduler: TaskScheduler

    func execute(args: [String: String]) async -> ToolResult {
        let action = args["action"] ?? "set"
        switch action.lowercased() {
        case "list":
            let tasks = await taskScheduler.activeTasks()
                .filter { $0.type == .timer }
            if tasks.isEmpty {
                return .success(tool: name, spoken: "No active timers.")
            }
            let descriptions = tasks.map { "\($0.label) — fires in \(formatTimeUntil($0.fireDate))" }
            return .success(tool: name, spoken: "Active timers: \(descriptions.joined(separator: ". ")).")
        case "cancel":
            let taskId = args["task_id"] ?? args["id"] ?? ""
            if taskId.isEmpty {
                // Cancel most recent timer
                if let latest = await taskScheduler.activeTasks().filter({ $0.type == .timer }).last {
                    let _ = await taskScheduler.cancel(id: latest.id)
                    return .success(tool: name, spoken: "Timer '\(latest.label)' cancelled.")
                }
                return .failure(tool: name, error: "No active timer to cancel.")
            }
            let cancelled = await taskScheduler.cancel(id: taskId)
            return cancelled
                ? .success(tool: name, spoken: "Timer cancelled.")
                : .failure(tool: name, error: "Timer not found.")
        default:
            if let duration = args["duration"].flatMap(Double.init) {
                let label = args["label"] ?? "Timer"
                let _ = await taskScheduler.scheduleTimer(label: label, durationSeconds: duration, onFire: {
                    print("[Timer] \(label) fired!")
                })
                let minutes = Int(duration) / 60
                return .success(tool: name, spoken: "Timer set for \(minutes > 0 ? "\(minutes) minutes" : "\(Int(duration)) seconds").")
            }
            return .failure(tool: name, error: "No duration specified")
        }
    }

    private func formatTimeUntil(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
