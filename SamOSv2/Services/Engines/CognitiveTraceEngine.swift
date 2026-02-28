import Foundation

/// Multi-stage reasoning engine that produces cognitive trace context.
/// Breaks complex queries into reasoning steps for the LLM to consider.
final class CognitiveTraceEngine: IntelligenceEngine {
    let name = "cognitive_trace"
    let settingsKey = "engine_cognitive_trace"
    let description = "Multi-stage reasoning and cognitive trace analysis"

    func run(context: EngineTurnContext) async throws -> String {
        let input = context.userText
        guard !input.isEmpty else { return "" }
        let lower = input.lowercased()

        // Analyze complexity indicators
        var traces: [String] = []

        // Check for multi-part questions
        let questionMarks = input.filter { $0 == "?" }.count
        if questionMarks > 1 {
            traces.append("Multi-part question detected (\(questionMarks) parts) — consider addressing each part")
        }

        // Check for comparative reasoning
        let comparatives = ["better", "worse", "compared to", "versus", "vs", "or should", "which is"]
        if comparatives.contains(where: { lower.contains($0) }) {
            traces.append("Comparative reasoning needed — weigh pros and cons")
        }

        // Check for causal reasoning
        let causal = ["why", "because", "cause", "reason", "how come", "what led to"]
        if causal.contains(where: { lower.contains($0) }) {
            traces.append("Causal reasoning — trace cause-effect chain")
        }

        // Check for hypothetical
        let hypothetical = ["what if", "hypothetically", "imagine", "suppose", "would it"]
        if hypothetical.contains(where: { lower.contains($0) }) {
            traces.append("Hypothetical scenario — explore possibilities")
        }

        // Check for planning/sequencing
        let planning = ["how to", "steps to", "plan for", "what order", "sequence"]
        if planning.contains(where: { lower.contains($0) }) {
            traces.append("Sequential planning — break into ordered steps")
        }

        // Check for memory/recall queries
        let memoryQueries = ["what is my", "what's my", "do you remember", "do you know my",
                              "tell me about my", "who is my", "where do i", "when did i"]
        if memoryQueries.contains(where: { lower.contains($0) }) {
            traces.append("Memory recall query — answer from injected memory context, be confident")
        }

        // Simple question — just answer directly
        if lower.hasSuffix("?") && traces.isEmpty {
            traces.append("Direct question — answer concisely using TALK")
        }

        guard !traces.isEmpty else { return "" }
        return "[COGNITIVE TRACE]\n" + traces.joined(separator: "\n")
    }
}
