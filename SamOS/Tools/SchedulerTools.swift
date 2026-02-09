import Foundation

private enum SchedulerFormatting {
    static let mediumDateShortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let strictISOWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let strictISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Schedule Task Tool

struct ScheduleTaskTool: Tool {
    let name = "schedule_task"
    let description = "Schedule a task to run at a future time (e.g. alarm, reminder)"

    func execute(args: [String: String]) -> OutputItem {
        guard TaskScheduler.shared.isAvailable else {
            return OutputItem(kind: .markdown, payload: "I couldn't set that — the scheduler isn't available right now.")
        }

        let runAt: Date
        var isTimer = false

        // Check in_seconds first (timer), then run_at/datetime_iso (alarm)
        if let secondsStr = args["in_seconds"], let seconds = Double(secondsStr) {
            // Clamp in_seconds to 1..86400 (1 second to 24 hours)
            guard seconds >= 1, seconds <= 86400 else {
                return OutputItem(kind: .markdown, payload: "Timer duration must be between 1 second and 24 hours.")
            }
            runAt = Date().addingTimeInterval(seconds)
            isTimer = true
        } else {
            let runAtStr = args["run_at"] ?? args["datetime_iso"] ?? ""
            guard !runAtStr.isEmpty else {
                return OutputItem(kind: .markdown, payload: "I need a time to set the alarm. What time should I set it for?")
            }

            // Parse the date — try epoch first, then strict ISO-8601
            if let ti = Double(runAtStr) {
                runAt = Date(timeIntervalSince1970: ti)
            } else if let d = Self.parseStrictISO8601(runAtStr) {
                runAt = d
            } else {
                return OutputItem(kind: .markdown, payload: "I couldn't understand that time format. Please use ISO-8601 (e.g. 2025-01-15T08:30:00Z).")
            }

            // Reject dates in the past
            if runAt.timeIntervalSinceNow < -5 {
                return OutputItem(kind: .markdown, payload: "That time is in the past. What future time should I set it for?")
            }
        }

        let label = args["label"] ?? ""
        let skillId = args["skill_id"] ?? ""

        if let taskId = TaskScheduler.shared.schedule(runAt: runAt, label: label, skillId: skillId) {
            let shortId = String(taskId.uuidString.prefix(8)).lowercased()

            let spoken: String
            let formatted: String

            if isTimer {
                let seconds = runAt.timeIntervalSince(Date())
                let display = Self.formatDuration(seconds)
                spoken = "Timer set for \(display)."
                formatted = "Timer set for \(display). `(\(shortId))`"
            } else {
                let display = SchedulerFormatting.mediumDateShortTime.string(from: runAt)
                spoken = "Alarm set for \(display)."
                formatted = "Alarm set for \(display). `(\(shortId))`"
            }

            let payload: [String: Any] = [
                "spoken": spoken,
                "formatted": formatted,
                "task_id": taskId.uuidString,
                "run_at": runAt.timeIntervalSince1970,
                "status": "scheduled"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                return OutputItem(kind: .markdown, payload: json)
            }
            return OutputItem(kind: .markdown, payload: formatted)
        }

        return OutputItem(kind: .markdown, payload: "I couldn't set that. Please try again.")
    }

    /// Parses a strict ISO-8601 datetime string. Rejects time-only strings,
    /// trailing text (e.g. " IST"), and anything that isn't a valid full datetime.
    static func parseStrictISO8601(_ str: String) -> Date? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        // Reject time-only (no date component — must contain at least one '-' for date)
        guard trimmed.contains("-") else { return nil }
        // Reject trailing non-ISO text (e.g. "2025-01-15T08:30:00+05:30 IST")
        // Valid ISO-8601 ends with Z, digit, or +/- offset digits
        let lastChar = trimmed.last
        guard lastChar == "Z" || lastChar == "z" || lastChar?.isNumber == true else { return nil }

        if let d = SchedulerFormatting.strictISOWithFractional.date(from: trimmed) { return d }
        if let d = SchedulerFormatting.strictISO.date(from: trimmed) { return d }

        return nil
    }

    /// Formats a duration in seconds into a human-readable string.
    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(total) second\(total == 1 ? "" : "s")"
        } else if total < 3600 {
            let mins = total / 60
            let secs = total % 60
            if secs == 0 {
                return "\(mins) minute\(mins == 1 ? "" : "s")"
            }
            return "\(mins) minute\(mins == 1 ? "" : "s") and \(secs) second\(secs == 1 ? "" : "s")"
        } else {
            let hours = total / 3600
            let mins = (total % 3600) / 60
            if mins == 0 {
                return "\(hours) hour\(hours == 1 ? "" : "s")"
            }
            return "\(hours) hour\(hours == 1 ? "" : "s") and \(mins) minute\(mins == 1 ? "" : "s")"
        }
    }
}

// MARK: - Cancel Task Tool

struct CancelTaskTool: Tool {
    let name = "cancel_task"
    let description = "Cancel a scheduled task by its ID"

    func execute(args: [String: String]) -> OutputItem {
        guard TaskScheduler.shared.isAvailable else {
            return OutputItem(kind: .markdown, payload: "I couldn't do that — the scheduler isn't available right now.")
        }

        let id = args["id"] ?? args["task_id"] ?? ""
        guard !id.isEmpty else {
            // No ID provided — list pending tasks so user can pick
            let pending = TaskScheduler.shared.listPending()
            if pending.isEmpty {
                return OutputItem(kind: .markdown, payload: "There are no pending alarms to cancel.")
            }

            let spoken = "Which one do you want to cancel?"
            var formattedLines: [String] = []
            for task in pending {
                let shortId = String(task.id.uuidString.prefix(8)).lowercased()
                var line = "- **\(shortId)**: \(SchedulerFormatting.mediumDateShortTime.string(from: task.runAt))"
                if !task.label.isEmpty { line += " — \(task.label)" }
                formattedLines.append(line)
            }
            let formatted = formattedLines.joined(separator: "\n")

            let payload: [String: Any] = [
                "spoken": spoken,
                "formatted": formatted
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                return OutputItem(kind: .markdown, payload: json)
            }
            return OutputItem(kind: .markdown, payload: formatted)
        }

        if TaskScheduler.shared.cancel(id: id) {
            let spoken = "Cancelled."
            let formatted = "Alarm `\(String(id.prefix(8)))` cancelled."

            let payload: [String: Any] = [
                "spoken": spoken,
                "formatted": formatted,
                "task_id": id,
                "status": "cancelled"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                return OutputItem(kind: .markdown, payload: json)
            }
            return OutputItem(kind: .markdown, payload: spoken)
        }

        return OutputItem(kind: .markdown, payload: "I couldn't find that alarm. It may have already fired or been cancelled.")
    }
}

// MARK: - List Tasks Tool

struct ListTasksTool: Tool {
    let name = "list_tasks"
    let description = "List all pending scheduled tasks"

    func execute(args: [String: String]) -> OutputItem {
        guard TaskScheduler.shared.isAvailable else {
            return OutputItem(kind: .markdown, payload: "I couldn't do that — the scheduler isn't available right now.")
        }

        let tasks = TaskScheduler.shared.listPending()

        if tasks.isEmpty {
            let payload: [String: Any] = [
                "spoken": "You don't have any pending tasks.",
                "formatted": "No pending tasks."
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                return OutputItem(kind: .markdown, payload: json)
            }
            return OutputItem(kind: .markdown, payload: "No pending tasks.")
        }

        let spoken = "You have \(tasks.count) pending task\(tasks.count == 1 ? "" : "s")."

        var md = "| ID | Time | Label | Skill |\n"
        md += "|:---|:-----|:------|:------|\n"
        for task in tasks {
            let shortId = String(task.id.uuidString.prefix(8)).lowercased()
            md += "| `\(shortId)` | \(SchedulerFormatting.mediumDateShortTime.string(from: task.runAt)) | \(task.label) | \(task.skillId) |\n"
        }
        md += "\n*\(tasks.count) pending task\(tasks.count == 1 ? "" : "s").*"

        let payload: [String: Any] = [
            "spoken": spoken,
            "formatted": md
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: md)
    }
}
