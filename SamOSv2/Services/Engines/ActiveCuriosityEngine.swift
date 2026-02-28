import Foundation

/// Detects knowledge gaps and generates curiosity-driven follow-up suggestions.
final class ActiveCuriosityEngine: IntelligenceEngine {
    let name = "curiosity"
    let settingsKey = "engine_curiosity"
    let description = "Knowledge gap detection and curiosity-driven suggestions"

    private var recentTopics: [String] = []

    func run(context: EngineTurnContext) async throws -> String {
        let input = context.userText
        guard !input.isEmpty else { return "" }

        var insights: [String] = []

        // Detect when user mentions something Sam doesn't know about
        let uncertaintyMarkers = ["I think", "maybe", "probably", "not sure", "I wonder"]
        if uncertaintyMarkers.contains(where: { input.contains($0) }) {
            insights.append("User expressing uncertainty — offer to help clarify")
        }

        // Detect new topics not recently discussed
        let topics = extractTopics(from: input)
        let newTopics = topics.filter { !recentTopics.contains($0) }
        if !newTopics.isEmpty {
            recentTopics.append(contentsOf: newTopics)
            if recentTopics.count > 20 { recentTopics.removeFirst(recentTopics.count - 20) }
        }

        // Detect follow-up opportunity
        let followUpIndicators = ["tell me more", "what about", "and also", "another thing"]
        if followUpIndicators.contains(where: { input.lowercased().contains($0) }) {
            insights.append("User showing curiosity — provide thorough, engaging response")
        }

        guard !insights.isEmpty else { return "" }
        return "[CURIOSITY]\n" + insights.joined(separator: "\n")
    }

    private func extractTopics(from text: String) -> [String] {
        // Simple topic extraction: significant nouns (words > 4 chars, lowercased)
        text.split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { $0.count > 4 && !isStopWord($0) }
    }

    private func isStopWord(_ word: String) -> Bool {
        let stops: Set = ["about", "after", "again", "being", "between", "could",
                          "every", "first", "found", "going", "house", "large",
                          "never", "other", "place", "right", "since", "small",
                          "still", "their", "there", "these", "thing", "those",
                          "through", "under", "using", "where", "which", "while",
                          "would", "should", "could", "really", "think", "maybe"]
        return stops.contains(word)
    }
}
