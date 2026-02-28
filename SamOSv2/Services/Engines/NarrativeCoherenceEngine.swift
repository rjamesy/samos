import Foundation

/// Maintains narrative consistency across conversation turns.
/// Tracks promises, commitments, and ongoing storylines.
final class NarrativeCoherenceEngine: IntelligenceEngine {
    let name = "narrative"
    let settingsKey = "engine_narrative"
    let description = "Conversation narrative consistency and continuity"

    private var commitments: [String] = []
    private var openThreads: [String] = []

    func run(context: EngineTurnContext) async throws -> String {
        let input = context.userText
        guard !input.isEmpty else { return "" }

        var insights: [String] = []

        // Track when Sam made commitments (from assistant text)
        let commitmentPhrases = ["I'll", "I will", "let me", "I can help", "I'll remember"]
        let assistantText = context.assistantText
        for phrase in commitmentPhrases {
            if assistantText.contains(phrase) {
                let commitment = extractCommitment(from: assistantText)
                if !commitment.isEmpty {
                    commitments.append(commitment)
                    if commitments.count > 10 { commitments.removeFirst() }
                }
            }
        }

        // Detect callback to earlier topic
        let callbackMarkers = ["earlier", "before", "you said", "you mentioned", "remember when",
                               "going back to", "as I said"]
        if callbackMarkers.contains(where: { input.lowercased().contains($0) }) {
            insights.append("User referencing earlier context — maintain narrative continuity")
        }

        // Detect topic continuation
        let continuationMarkers = ["also", "another thing", "and what about", "speaking of"]
        if continuationMarkers.contains(where: { input.lowercased().contains($0) }) {
            insights.append("Topic continuation — link back to previous discussion naturally")
        }

        guard !insights.isEmpty else { return "" }
        return "[NARRATIVE]\n" + insights.joined(separator: "\n")
    }

    private func extractCommitment(from text: String) -> String {
        // Simple extraction: take the sentence containing a commitment phrase
        let sentences = text.split(separator: ".").map(String.init)
        let commitmentPhrases = ["I'll", "I will", "let me"]
        for sentence in sentences {
            if commitmentPhrases.contains(where: { sentence.contains($0) }) {
                return sentence.trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
