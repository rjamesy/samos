import Foundation

// MARK: - Skill Engine

/// Runtime interpreter for installed skills. Matches user input against trigger phrases,
/// extracts slots (dates via NSDataDetector, strings from remaining text), and executes
/// skill steps to produce Actions.
final class SkillEngine {

    static let shared = SkillEngine()

    // MARK: - State

    enum EngineState {
        case idle
        case awaitingSlot(skill: SkillSpec, filledSlots: [String: String], missingSlot: String)
    }

    private(set) var state: EngineState = .idle

    private init() {}

    /// For testing: create an engine with custom state.
    init(forTesting: Bool) {}

    // MARK: - Match

    /// Attempts to match user input against installed skills.
    /// Returns the matched skill and extracted slots, or nil if no match.
    func match(_ input: String) -> (SkillSpec, [String: String])? {
        // If we're awaiting a slot, try to fill it
        if case .awaitingSlot(let skill, var filled, let missingSlot) = state {
            let slotDef = skill.slots.first { $0.name == missingSlot }
            if let slotDef = slotDef {
                if let value = extractSlotValue(from: input, type: slotDef.type) {
                    filled[missingSlot] = value
                    // Also set display variant for dates
                    if slotDef.type == .date, let date = parseDetectedDate(from: input) {
                        filled["\(missingSlot)_display"] = formatDateForDisplay(date)
                    }
                    state = .idle
                    return (skill, filled)
                }
            }
            // Couldn't fill the slot — reset
            state = .idle
        }

        let lower = input.lowercased()
        let skills = SkillStore.shared.loadInstalled()

        // Find the best matching skill (prefer longest trigger match)
        var bestMatch: (skill: SkillSpec, trigger: String)?
        for skill in skills {
            for trigger in skill.triggerPhrases {
                if lower.contains(trigger.lowercased()) {
                    if bestMatch == nil || trigger.count > bestMatch!.trigger.count {
                        bestMatch = (skill, trigger)
                    }
                }
            }
        }

        guard let match = bestMatch else { return nil }

        // Extract slots
        var slots: [String: String] = [:]
        for slotDef in match.skill.slots {
            if let value = extractSlotValue(from: input, type: slotDef.type) {
                slots[slotDef.name] = value
                // Add display variant for dates
                if slotDef.type == .date, let date = parseDetectedDate(from: input) {
                    slots["\(slotDef.name)_display"] = formatDateForDisplay(date)
                }
            }
        }

        // Check for missing required slots
        for slotDef in match.skill.slots where slotDef.required {
            if slots[slotDef.name] == nil {
                state = .awaitingSlot(skill: match.skill, filledSlots: slots, missingSlot: slotDef.name)
                return nil // Will be handled as a prompt in the caller
            }
        }

        return (match.skill, slots)
    }

    /// Returns a prompt message if the engine is awaiting a slot fill.
    func pendingSlotPrompt() -> String? {
        if case .awaitingSlot(let skill, _, let missingSlot) = state {
            let slotDef = skill.slots.first { $0.name == missingSlot }
            return slotDef?.prompt ?? "What \(missingSlot) should I use?"
        }
        return nil
    }

    /// Resets the engine state.
    func reset() {
        state = .idle
    }

    // MARK: - Execute

    /// Executes a matched skill's steps and returns the resulting Actions.
    /// Tracks whether schedule_task succeeded so downstream talk steps can be conditioned on it.
    func execute(skill: SkillSpec, slots: [String: String]) -> [Action] {
        var actions: [Action] = []
        var lastScheduleSucceeded = true

        for step in skill.steps {
            let interpolatedArgs = interpolateArgs(step.args, slots: slots)

            switch step.action {
            case "schedule_task":
                if let runAtStr = interpolatedArgs["run_at"],
                   let runAt = Double(runAtStr).map({ Date(timeIntervalSince1970: $0) }) {
                    let label = interpolatedArgs["label"] ?? ""
                    let skillId = interpolatedArgs["skill_id"] ?? skill.id
                    lastScheduleSucceeded = TaskScheduler.shared.schedule(runAt: runAt, label: label, skillId: skillId) != nil
                } else {
                    // Missing or unparseable run_at — don't claim success
                    lastScheduleSucceeded = false
                    actions.append(.talk(Talk(say: "I need a time to set the alarm. What time should I set it for?")))
                }

            case "talk":
                // Only emit the confirmation talk if the preceding schedule succeeded
                if lastScheduleSucceeded, let say = interpolatedArgs["say"] {
                    actions.append(.talk(Talk(say: say)))
                }

            default:
                // Generic tool execution
                actions.append(.tool(ToolAction(
                    name: step.action,
                    args: interpolatedArgs
                )))
            }
        }

        return actions
    }

    // MARK: - Slot Extraction

    private func extractSlotValue(from input: String, type: SkillSpec.SlotType) -> String? {
        switch type {
        case .date:
            return extractDateSlot(from: input)
        case .string:
            return extractStringSlot(from: input)
        case .number:
            return extractNumberSlot(from: input)
        }
    }

    /// Extracts a date from natural language using NSDataDetector.
    /// Returns the date as timeIntervalSince1970 string for storage.
    private func extractDateSlot(from input: String, now: Date = Date()) -> String? {
        guard let date = parseDetectedDate(from: input, relativeTo: now) else { return nil }
        return String(date.timeIntervalSince1970)
    }

    /// Parses a Date from natural language using NSDataDetector.
    /// Applies the today-vs-tomorrow rule: if the resolved time is more than 60 seconds
    /// in the future, keep it as today; otherwise push to tomorrow.
    func parseDetectedDate(from input: String, relativeTo now: Date = Date()) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let range = NSRange(input.startIndex..., in: input)
        let matches = detector.matches(in: input, options: [], range: range)

        for match in matches {
            if let date = match.date {
                var resolved = date
                let calendar = Calendar.current

                // Today-vs-tomorrow rule for time-only references:
                // If the resolved date is today but NOT more than 60s in the future,
                // push to tomorrow at the same time.
                if calendar.isDateInToday(resolved) && resolved < now.addingTimeInterval(60) {
                    resolved = calendar.date(byAdding: .day, value: 1, to: resolved) ?? resolved
                }

                return resolved
            }
        }

        return nil
    }

    private func extractStringSlot(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func extractNumberSlot(from input: String) -> String? {
        let pattern = #"(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range(at: 1), in: input)
        else { return nil }
        return String(input[range])
    }

    // MARK: - Interpolation

    /// Replaces {{placeholder}} tokens in args with slot values.
    func interpolateArgs(_ args: [String: String], slots: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, template) in args {
            var value = template
            for (slotName, slotValue) in slots {
                value = value.replacingOccurrences(of: "{{\(slotName)}}", with: slotValue)
            }
            // Clear any remaining unfilled placeholders
            let placeholderPattern = #"\{\{[^}]+\}\}"#
            if let regex = try? NSRegularExpression(pattern: placeholderPattern) {
                value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
            }
            result[key] = value
        }
        return result
    }

    // MARK: - Date Formatting

    func formatDateForDisplay(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'today at' h:mm a"
        } else if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "'tomorrow at' h:mm a"
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }

        return formatter.string(from: date)
    }
}
