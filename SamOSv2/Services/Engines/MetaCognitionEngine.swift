import Foundation

/// Evaluates confidence in Sam's own responses and flags uncertainty.
final class MetaCognitionEngine: IntelligenceEngine {
    let name = "metacognition"
    let settingsKey = "engine_metacognition"
    let description = "Confidence evaluation and self-awareness"

    func run(context: EngineTurnContext) async throws -> String {
        let input = context.userText
        guard !input.isEmpty else { return "" }

        var insights: [String] = []

        // Detect questions that may exceed Sam's knowledge
        let knowledgeBoundary = ["latest", "newest", "2026", "2025", "current", "right now",
                                 "today's", "this week", "breaking news"]
        if knowledgeBoundary.contains(where: { input.lowercased().contains($0) }) {
            insights.append("Query may involve recent/real-time data — acknowledge if uncertain, suggest tools")
        }

        // Detect requests for specific facts/numbers
        let factualMarkers = ["exactly", "precise", "specific number", "how many",
                             "what percentage", "statistics", "data shows"]
        if factualMarkers.contains(where: { input.lowercased().contains($0) }) {
            insights.append("Factual precision requested — flag if approximating, suggest verification")
        }

        // Detect multi-domain complexity
        let domains = detectDomains(input)
        if domains.count >= 3 {
            insights.append("Multi-domain query (\(domains.joined(separator: ", "))) — may need to synthesize across areas")
        }

        // Detect when user questions Sam's previous response
        let doubtMarkers = ["are you sure", "is that right", "that doesn't sound right",
                           "I don't think so", "that's wrong", "incorrect"]
        if doubtMarkers.contains(where: { input.lowercased().contains($0) }) {
            insights.append("User questioning accuracy — re-evaluate previous response honestly")
        }

        guard !insights.isEmpty else { return "" }
        return "[METACOGNITION]\n" + insights.joined(separator: "\n")
    }

    private func detectDomains(_ text: String) -> [String] {
        let domainKeywords: [String: [String]] = [
            "tech": ["code", "software", "api", "database", "programming"],
            "health": ["health", "medical", "exercise", "diet", "sleep"],
            "finance": ["money", "invest", "budget", "price", "cost"],
            "science": ["physics", "chemistry", "biology", "research"],
            "creative": ["art", "music", "write", "design", "creative"]
        ]

        let lower = text.lowercased()
        return domainKeywords.compactMap { (domain, keywords) in
            keywords.contains(where: { lower.contains($0) }) ? domain : nil
        }
    }
}
