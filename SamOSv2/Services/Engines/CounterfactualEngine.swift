import Foundation

/// "What if?" branching engine that suggests alternative perspectives.
final class CounterfactualEngine: IntelligenceEngine {
    let name = "counterfactual"
    let settingsKey = "engine_counterfactual"
    let description = "What-if branching and alternative perspective generation"

    func run(context: EngineTurnContext) async throws -> String {
        let input = context.userText
        guard !input.isEmpty else { return "" }

        var insights: [String] = []

        // Detect decision-making context
        let decisionMarkers = ["should i", "what should", "is it better", "pros and cons",
                               "advantages", "disadvantages", "trade-off", "tradeoff"]
        if decisionMarkers.contains(where: { input.lowercased().contains($0) }) {
            insights.append("Decision context — explore counterfactual outcomes for each option")
        }

        // Detect regret or past-focused language
        let regretMarkers = ["should have", "could have", "wish I had", "if only", "mistake"]
        if regretMarkers.contains(where: { input.lowercased().contains($0) }) {
            insights.append("Regret pattern — gently reframe toward future possibilities")
        }

        // Detect explicit hypotheticals
        let hypothetical = ["what if", "what would happen", "imagine if", "suppose"]
        if hypothetical.contains(where: { input.lowercased().contains($0) }) {
            insights.append("Explicit hypothetical — engage fully with the thought experiment")
        }

        guard !insights.isEmpty else { return "" }
        return "[COUNTERFACTUAL]\n" + insights.joined(separator: "\n")
    }
}
