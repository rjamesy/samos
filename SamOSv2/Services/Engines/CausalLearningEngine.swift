import Foundation

/// Extracts cause-effect relationships from conversation.
final class CausalLearningEngine: IntelligenceEngine {
    let name = "causal"
    let settingsKey = "engine_causal"
    let description = "Cause-effect relationship extraction"

    private var causalChains: [CausalRelation] = []

    func run(context: EngineTurnContext) async throws -> String {
        let input = context.userText
        guard !input.isEmpty else { return "" }

        var insights: [String] = []

        // Detect causal language
        let causalPatterns: [(String, String)] = [
            ("because", "Explicit causal reasoning detected"),
            ("caused by", "Causal attribution identified"),
            ("leads to", "Forward causal chain"),
            ("results in", "Consequence reasoning"),
            ("due to", "Attribution to cause"),
            ("so that", "Goal-directed causality"),
            ("therefore", "Logical conclusion"),
            ("as a result", "Effect identification"),
            ("if.*then", "Conditional causality")
        ]

        let lower = input.lowercased()
        for (pattern, label) in causalPatterns {
            if lower.contains(pattern) {
                insights.append(label)
                let relation = CausalRelation(
                    cause: extractCause(from: lower, marker: pattern),
                    effect: extractEffect(from: lower, marker: pattern),
                    confidence: 0.7,
                    timestamp: Date()
                )
                causalChains.append(relation)
                if causalChains.count > 50 { causalChains.removeFirst() }
                break // Only track first match per turn
            }
        }

        // Note if user is building a causal model
        if causalChains.count >= 3 {
            let recentCauses = causalChains.suffix(3).map { $0.cause }
            if Set(recentCauses).count <= 2 {
                insights.append("User building causal model around related concepts")
            }
        }

        guard !insights.isEmpty else { return "" }
        return "[CAUSAL]\n" + insights.joined(separator: "\n")
    }

    private func extractCause(from text: String, marker: String) -> String {
        guard let range = text.range(of: marker) else { return "" }
        let before = text[text.startIndex..<range.lowerBound]
        let words = before.split(separator: " ").suffix(5)
        return words.joined(separator: " ")
    }

    private func extractEffect(from text: String, marker: String) -> String {
        guard let range = text.range(of: marker) else { return "" }
        let after = text[range.upperBound...]
        let words = after.split(separator: " ").prefix(5)
        return words.joined(separator: " ")
    }
}

private struct CausalRelation {
    let cause: String
    let effect: String
    let confidence: Double
    let timestamp: Date
}
