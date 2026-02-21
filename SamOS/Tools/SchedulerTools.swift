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
        let typeHint = (args["type"] ?? args["kind"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Check timer duration first (timer), then run_at/datetime_iso (alarm).
        // Accept OpenAI variants like duration_seconds/type=timer.
        if let seconds = Self.timerDurationSeconds(from: args) {
            // Clamp in_seconds to 1..86400 (1 second to 24 hours)
            guard seconds >= 1, seconds <= 86400 else {
                return OutputItem(kind: .markdown, payload: "Timer duration must be between 1 second and 24 hours.")
            }
            runAt = Date().addingTimeInterval(seconds)
            isTimer = true
        } else {
            if typeHint == "timer" {
                return OutputItem(kind: .markdown, payload: "I need a timer duration, like 10 seconds or 5 minutes.")
            }
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
            if runAt.timeIntervalSinceNow < 0 {
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

    private static func timerDurationSeconds(from args: [String: String]) -> Double? {
        // Keep order: canonical key first, then compatibility aliases.
        let keys = ["in_seconds", "duration_seconds", "seconds"]
        for key in keys {
            guard let raw = args[key] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let value = Double(trimmed) else { continue }
            return value
        }
        return nil
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
        let labelQuery = (args["label"] ?? args["name"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !labelQuery.isEmpty {
            let pending = TaskScheduler.shared.listPending()
            let matches = pending.filter { task in
                task.label.localizedCaseInsensitiveContains(labelQuery)
            }
            guard !matches.isEmpty else {
                return OutputItem(
                    kind: .markdown,
                    payload: "I couldn't find a pending timer named `\(labelQuery)`."
                )
            }
            var cancelled = 0
            for task in matches where TaskScheduler.shared.cancel(id: task.id.uuidString) {
                cancelled += 1
            }
            let spoken = cancelled == 1
                ? "Cancelled timer \(labelQuery)."
                : "Cancelled \(cancelled) timers matching \(labelQuery)."
            let formatted = cancelled == 1
                ? "Cancelled timer `\(labelQuery)`."
                : "Cancelled \(cancelled) timers matching `\(labelQuery)`."
            let payload: [String: Any] = [
                "spoken": spoken,
                "formatted": formatted,
                "status": "cancelled",
                "cancelled_count": cancelled
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                return OutputItem(kind: .markdown, payload: json)
            }
            return OutputItem(kind: .markdown, payload: formatted)
        }

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

        let labelQuery = (args["label"] ?? args["name"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let allTasks = TaskScheduler.shared.listPending()
        let tasks: [ScheduledTask]
        if labelQuery.isEmpty {
            tasks = allTasks
        } else {
            tasks = allTasks.filter { $0.label.localizedCaseInsensitiveContains(labelQuery) }
        }

        if tasks.isEmpty {
            let payload: [String: Any] = [
                "spoken": labelQuery.isEmpty
                    ? "You don't have any pending tasks."
                    : "No pending timers matched \(labelQuery).",
                "formatted": labelQuery.isEmpty
                    ? "No pending tasks."
                    : "No pending timers matched `\(labelQuery)`."
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                return OutputItem(kind: .markdown, payload: json)
            }
            return OutputItem(kind: .markdown, payload: "No pending tasks.")
        }

        let spoken = labelQuery.isEmpty
            ? "You have \(tasks.count) pending task\(tasks.count == 1 ? "" : "s")."
            : "Found \(tasks.count) pending timer\(tasks.count == 1 ? "" : "s") matching \(labelQuery)."

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

// MARK: - Timer Manage Tool

private struct PendingNamedTimerDraft {
    let seconds: Double
    let createdAt: Date
}

private final class PendingNamedTimerStore {
    static let shared = PendingNamedTimerStore()
    private let queue = DispatchQueue(label: "SamOS.PendingNamedTimerStore")
    private var draft: PendingNamedTimerDraft?

    func save(seconds: Double) {
        queue.sync {
            draft = PendingNamedTimerDraft(seconds: seconds, createdAt: Date())
        }
    }

    func consume(maxAgeSeconds: TimeInterval = 300) -> PendingNamedTimerDraft? {
        queue.sync {
            guard let draft else { return nil }
            guard Date().timeIntervalSince(draft.createdAt) <= maxAgeSeconds else {
                self.draft = nil
                return nil
            }
            self.draft = nil
            return draft
        }
    }
}

struct TimerManageTool: Tool {
    let name = "timer.manage"
    let description = "Manage named timers with natural language. Supports set/cancel/list by name."

    func execute(args: [String: String]) -> OutputItem {
        guard TaskScheduler.shared.isAvailable else {
            return OutputItem(kind: .markdown, payload: "I couldn't do that — the scheduler isn't available right now.")
        }

        if let structured = executeStructuredArgs(args) {
            return structured
        }

        let text = (args["text"] ?? args["input"] ?? args["query"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return OutputItem(kind: .markdown, payload: "I need the timer request text.")
        }

        let lower = text.lowercased()
        if lower.contains("cancel") {
            let label = extractName(from: text) ?? text
            return CancelTaskTool().execute(args: ["label": label])
        }
        if lower.contains("list") {
            if let label = extractName(from: text) {
                return ListTasksTool().execute(args: ["label": label])
            }
            return ListTasksTool().execute(args: [:])
        }

        if let durationSeconds = extractDurationSeconds(from: text) {
            if let label = extractName(from: text), !label.isEmpty {
                return ScheduleTaskTool().execute(args: [
                    "in_seconds": String(Int(durationSeconds.rounded())),
                    "label": label,
                    "skill_id": "timer.named"
                ])
            }
            PendingNamedTimerStore.shared.save(seconds: durationSeconds)
            let payload: [String: Any] = [
                "kind": "prompt",
                "slot": "timer_name",
                "spoken": "What should I call this timer?",
                "formatted": "What should I call this timer? Example: `pasta`."
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                return OutputItem(kind: .markdown, payload: json)
            }
            return OutputItem(kind: .markdown, payload: "What should I call this timer?")
        }

        if let pending = PendingNamedTimerStore.shared.consume(),
           let label = extractFreeformTimerName(from: text) {
            return ScheduleTaskTool().execute(args: [
                "in_seconds": String(Int(pending.seconds.rounded())),
                "label": label,
                "skill_id": "timer.named"
            ])
        }

        return OutputItem(
            kind: .markdown,
            payload: "I can set, cancel, or list timers by name. Example: `set a timer for 20 minutes called pasta`."
        )
    }

    private func executeStructuredArgs(_ args: [String: String]) -> OutputItem? {
        let action = (args["action"] ?? args["operation"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !action.isEmpty else { return nil }

        if action == "cancel" || action == "stop" || action == "delete" {
            let label = normalizedLabel(from: args)
            guard let label, !label.isEmpty else {
                return OutputItem(kind: .markdown, payload: "Which timer should I cancel?")
            }
            return CancelTaskTool().execute(args: ["label": label])
        }

        if action == "list" || action == "show" {
            if let label = normalizedLabel(from: args), !label.isEmpty {
                return ListTasksTool().execute(args: ["label": label])
            }
            return ListTasksTool().execute(args: [:])
        }

        if action == "start" || action == "set" || action == "create" {
            let seconds = durationSeconds(from: args)
            guard let seconds, seconds > 0 else {
                return OutputItem(kind: .markdown, payload: "I need a timer duration, like 10 seconds or 5 minutes.")
            }
            let label = normalizedLabel(from: args)
            if let label, !label.isEmpty {
                return ScheduleTaskTool().execute(args: [
                    "in_seconds": String(Int(seconds.rounded())),
                    "label": label,
                    "skill_id": "timer.named"
                ])
            }
            PendingNamedTimerStore.shared.save(seconds: seconds)
            let payload: [String: Any] = [
                "kind": "prompt",
                "slot": "timer_name",
                "spoken": "What should I call this timer?",
                "formatted": "What should I call this timer? Example: `pasta`."
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                return OutputItem(kind: .markdown, payload: json)
            }
            return OutputItem(kind: .markdown, payload: "What should I call this timer?")
        }

        return nil
    }

    private func durationSeconds(from args: [String: String]) -> Double? {
        let keys = ["duration_seconds", "in_seconds", "seconds", "duration"]
        for key in keys {
            guard let raw = args[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            if let value = Double(raw), value > 0 {
                return value
            }
        }
        return nil
    }

    private func normalizedLabel(from args: [String: String]) -> String? {
        let raw = (args["label"] ?? args["name"] ?? args["timer_name"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower == "timer" || lower == "countdown" {
            return "countdown"
        }
        return String(raw.prefix(40))
    }

    private func extractName(from text: String) -> String? {
        let patterns = [
            #"(?i)\b(?:called|named|by)\s+["']?([A-Za-z0-9][A-Za-z0-9\s_\-]{0,40})["']?\s*$"#,
            #"(?i)\btimer\s+([A-Za-z][A-Za-z0-9\s_\-]{0,40})\s*$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            // Reject captured values that are clearly duration phrases, not names.
            let lower = value.lowercased()
            let looksLikeDuration = lower.range(
                of: #"^\d+(?:\.\d+)?\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)$"#,
                options: .regularExpression
            ) != nil
            if !looksLikeDuration { return value }
        }
        return nil
    }

    private func extractFreeformTimerName(from text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: #"(?i)\b(timer|name|called|named|it|is)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(40))
    }

    private func extractDurationSeconds(from text: String) -> Double? {
        let pattern = #"(?i)\b(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 2,
              let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[valueRange]) else {
            return nil
        }
        let unit = text[unitRange].lowercased()
        if unit.hasPrefix("h") {
            return value * 3600
        }
        if unit.hasPrefix("m") {
            return value * 60
        }
        return value
    }
}
