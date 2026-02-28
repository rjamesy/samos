import Foundation

/// Parses LLM text output into Plan or Action. Falls back to TALK per ARCHITECTURE.md.
struct ResponseParser: Sendable {

    /// Attempt to parse the response as a Plan, then Action, then fall back to raw TALK.
    func parse(_ text: String) -> Plan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Plan(steps: [.talk(say: "I'm not sure how to respond to that.")])
        }

        // Try Plan first (has "steps" array)
        if let plan = tryParsePlan(trimmed) {
            return plan
        }

        // Try Action (has "action" field)
        if let action = tryParseAction(trimmed) {
            return Plan.fromAction(action)
        }

        // Per ARCHITECTURE.md: wrap raw text as TALK
        return Plan(steps: [.talk(say: trimmed)])
    }

    private func tryParsePlan(_ text: String) -> Plan? {
        guard let data = extractJSON(text)?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Plan.self, from: data)
    }

    private func tryParseAction(_ text: String) -> Action? {
        guard let data = extractJSON(text)?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Action.self, from: data)
    }

    /// Extract JSON object from text that may contain markdown fences or preamble.
    private func extractJSON(_ text: String) -> String? {
        // Try direct parse first
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return text
        }

        // Strip markdown code fences
        if let range = text.range(of: "```json") ?? text.range(of: "```") {
            let after = text[range.upperBound...]
            if let endRange = after.range(of: "```") {
                return String(after[after.startIndex..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Find first { and last }
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }

        return nil
    }
}
