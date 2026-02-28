import Foundation

/// Detects long-term behavioral patterns from user interactions.
/// 9 pattern types: novelty_seeker, 80_percent_completion, friction_withdrawal,
/// rapid_context_shift, escalation_stabilize, procrastination_loop,
/// late_night_surge, abandonment_cycle, perfection_paralysis
final class BehaviorPatternEngine: IntelligenceEngine {
    let name = "behavior"
    let settingsKey = "engine_behavior"
    let description = "Long-term behavioral pattern detection and reflection"

    private var signals: [BehaviorSignal] = []
    private var patterns: [String: PatternState] = [:]
    private var turnCount: Int = 0

    func run(context: EngineTurnContext) async throws -> String {
        turnCount += 1
        let input = context.userText

        // Record signal
        let signal = BehaviorSignal(
            text: input,
            timestamp: Date(),
            hour: Calendar.current.component(.hour, from: Date())
        )
        signals.append(signal)
        if signals.count > 200 { signals.removeFirst(signals.count - 200) }

        // Only analyze every 10th turn to reduce overhead
        guard turnCount % 10 == 0 else { return "" }

        var insights: [String] = []

        // Late night surge detection
        let nightSignals = signals.filter { $0.hour >= 22 || $0.hour < 4 }
        if nightSignals.count >= 5 {
            updatePattern("late_night_surge", confidence: min(Double(nightSignals.count) / 10.0, 1.0))
            insights.append("Late night activity pattern detected — consider energy/wellbeing")
        }

        // Rapid context shifting
        let recentTopics = signals.suffix(10).map { extractMainTopic($0.text) }
        let uniqueTopics = Set(recentTopics).count
        if uniqueTopics >= 8 {
            updatePattern("rapid_context_shift", confidence: 0.7)
            insights.append("Rapid context shifting detected — user may be exploring or restless")
        }

        // Check for abandonment patterns (short conversations, abrupt ends)
        let shortInteractions = signals.suffix(20).filter { $0.text.count < 20 }
        if shortInteractions.count >= 12 {
            updatePattern("friction_withdrawal", confidence: 0.6)
        }

        guard !insights.isEmpty else { return "" }
        return "[BEHAVIOR REFLECTION]\n" + insights.joined(separator: "\n")
    }

    private func updatePattern(_ type: String, confidence: Double) {
        if patterns[type] != nil {
            patterns[type]?.confidence = confidence
            patterns[type]?.evidenceCount += 1
            patterns[type]?.lastSeen = Date()
        } else {
            patterns[type] = PatternState(
                type: type,
                confidence: confidence,
                evidenceCount: 1,
                firstSeen: Date(),
                lastSeen: Date()
            )
        }
    }

    private func extractMainTopic(_ text: String) -> String {
        let words = text.lowercased().split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 3 }
        return words.first ?? "unknown"
    }
}

private struct BehaviorSignal {
    let text: String
    let timestamp: Date
    let hour: Int
}

private struct PatternState {
    let type: String
    var confidence: Double
    var evidenceCount: Int
    let firstSeen: Date
    var lastSeen: Date
}
