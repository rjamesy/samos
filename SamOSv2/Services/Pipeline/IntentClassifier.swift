import Foundation

/// Intent categories for routing decisions.
enum Intent: String, Sendable {
    case question
    case command
    case conversation
    case skillRequest
    case memoryOperation
    case unknown
}

/// OpenAI-based intent classification. Used for routing and engine prioritization.
final class IntentClassifier: @unchecked Sendable {
    private let llmClient: any LLMClient

    init(llmClient: any LLMClient) {
        self.llmClient = llmClient
    }

    /// Classify intent from user text. Returns best-guess intent.
    func classify(_ text: String) async -> Intent {
        // Simple heuristic classification (avoids extra LLM call for most cases)
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Memory operations
        if lower.hasPrefix("remember") || lower.hasPrefix("forget") || lower.contains("save memory") {
            return .memoryOperation
        }

        // Skill learning
        if lower.hasPrefix("learn how to") || lower.hasPrefix("teach yourself") {
            return .skillRequest
        }

        // Questions
        if lower.hasSuffix("?") || lower.hasPrefix("what") || lower.hasPrefix("who") ||
           lower.hasPrefix("where") || lower.hasPrefix("when") || lower.hasPrefix("how") ||
           lower.hasPrefix("why") || lower.hasPrefix("is ") || lower.hasPrefix("are ") ||
           lower.hasPrefix("can ") || lower.hasPrefix("do ") || lower.hasPrefix("does ") {
            return .question
        }

        // Commands
        if lower.hasPrefix("set ") || lower.hasPrefix("turn ") || lower.hasPrefix("open ") ||
           lower.hasPrefix("close ") || lower.hasPrefix("start ") || lower.hasPrefix("stop ") ||
           lower.hasPrefix("show ") || lower.hasPrefix("find ") || lower.hasPrefix("search ") {
            return .command
        }

        return .conversation
    }
}
