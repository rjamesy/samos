import Foundation

/// Models the user's mental state, knowledge level, and emotional context.
final class TheoryOfMindEngine: IntelligenceEngine {
    let name = "theory_of_mind"
    let settingsKey = "engine_theory_of_mind"
    let description = "User mental model and knowledge level tracking"

    private var knowledgeDomains: [String: KnowledgeLevel] = [:]
    private var communicationStyle: CommunicationStyle = .balanced

    func run(context: EngineTurnContext) async throws -> String {
        let input = context.userText
        guard !input.isEmpty else { return "" }
        let lower = input.lowercased()

        var insights: [String] = []

        // Detect expertise indicators
        let technicalTerms = countTechnicalTerms(input)
        if technicalTerms > 3 {
            insights.append("User demonstrates technical expertise — match their level")
        } else if lower.contains("what is") || lower.contains("explain") || lower.contains("how does") {
            insights.append("User seeking understanding — provide clear explanations")
        }

        // Detect personal/memory questions
        let personalMarkers = ["my name", "my dog", "my cat", "my pet", "my job", "my wife", "my husband",
                                "my partner", "remember", "you know", "do you know", "what's my", "where do i"]
        if personalMarkers.contains(where: { lower.contains($0) }) {
            insights.append("Personal question — use injected memories to answer directly and warmly")
        }

        // Detect frustration
        let frustrationMarkers = ["doesn't work", "broken", "keeps failing", "still not",
                                   "tried everything", "frustrated", "annoying", "ugh"]
        if frustrationMarkers.contains(where: { lower.contains($0) }) {
            insights.append("User may be frustrated — be empathetic, solution-focused")
        }

        // Detect urgency
        let urgencyMarkers = ["urgent", "asap", "right now", "immediately", "hurry", "quick"]
        if urgencyMarkers.contains(where: { lower.contains($0) }) {
            insights.append("Urgency detected — be concise and action-oriented")
        }

        // Detect social/emotional context
        let emotionalMarkers = ["feel", "feeling", "happy", "sad", "worried", "excited", "nervous",
                                 "love", "miss", "lonely", "grateful", "tired", "stressed"]
        if emotionalMarkers.contains(where: { lower.contains($0) }) {
            insights.append("Emotional context — acknowledge feelings before problem-solving")
        }

        // Detect greetings — user wants warmth
        let greetingMarkers = ["hi", "hey", "hello", "good morning", "good evening", "good afternoon",
                                "howdy", "what's up", "how are you", "how's it going"]
        if greetingMarkers.contains(where: { lower.hasPrefix($0) || lower.contains($0) }) {
            insights.append("Social greeting — be warm, personal, ask about their day")
        }

        guard !insights.isEmpty else { return "" }
        return "[THEORY OF MIND]\n" + insights.joined(separator: "\n")
    }

    private func countTechnicalTerms(_ text: String) -> Int {
        let technical = ["api", "database", "algorithm", "protocol", "async", "concurrency",
                        "framework", "architecture", "deployment", "refactor", "endpoint",
                        "middleware", "cache", "latency", "throughput", "schema", "migration",
                        "dependency", "injection", "singleton", "actor", "thread", "mutex"]
        let lower = text.lowercased()
        return technical.filter { lower.contains($0) }.count
    }
}

private enum KnowledgeLevel {
    case beginner, intermediate, expert
}

private enum CommunicationStyle {
    case technical, casual, balanced
}
