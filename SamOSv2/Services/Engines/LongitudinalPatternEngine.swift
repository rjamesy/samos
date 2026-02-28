import Foundation

/// Detects temporal patterns in user behavior over time.
/// Tracks time-of-day patterns, recurring topics, and seasonal behaviors.
final class LongitudinalPatternEngine: IntelligenceEngine {
    let name = "longitudinal"
    let settingsKey = "engine_longitudinal"
    let description = "Temporal behavior pattern detection"

    private var timePatterns: [Int: [String]] = [:] // hour -> topics
    private var topicFrequency: [String: Int] = [:]

    func run(context: EngineTurnContext) async throws -> String {
        let input = context.userText
        guard !input.isEmpty else { return "" }

        let hour = Calendar.current.component(.hour, from: Date())
        let topics = extractKeywords(from: input)

        // Record temporal patterns
        var existing = timePatterns[hour] ?? []
        existing.append(contentsOf: topics)
        timePatterns[hour] = existing

        // Track topic frequency
        for topic in topics {
            topicFrequency[topic, default: 0] += 1
        }

        var insights: [String] = []

        // Check for time-of-day patterns
        let timeLabel = timeOfDayLabel(hour)
        let commonAtThisTime = (timePatterns[hour] ?? [])
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(2)

        if !commonAtThisTime.isEmpty {
            let topicList = commonAtThisTime.map { $0.key }.joined(separator: ", ")
            insights.append("User often discusses \(topicList) during \(timeLabel)")
        }

        // Check for recurring topics
        let recurring = topicFrequency
            .filter { $0.value >= 5 }
            .sorted { $0.value > $1.value }
            .prefix(3)

        if !recurring.isEmpty {
            let topicList = recurring.map { "\($0.key) (\($0.value)x)" }.joined(separator: ", ")
            insights.append("Recurring interests: \(topicList)")
        }

        guard !insights.isEmpty else { return "" }
        return "[LONGITUDINAL PATTERNS]\n" + insights.joined(separator: "\n")
    }

    private func extractKeywords(from text: String) -> [String] {
        text.lowercased()
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 4 }
    }

    private func timeOfDayLabel(_ hour: Int) -> String {
        switch hour {
        case 5..<9: return "early morning"
        case 9..<12: return "morning"
        case 12..<14: return "midday"
        case 14..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "night"
        }
    }
}
