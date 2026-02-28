import Foundation

/// Tracks skill usage patterns and suggests skill improvements or new skills.
final class SkillEvolutionEngine: IntelligenceEngine {
    let name = "skill_evolution"
    let settingsKey = "engine_skill_evolution"
    let description = "Skill usage tracking and evolution suggestions"

    private var toolUsage: [String: ToolUsageStats] = [:]
    private var failedRequests: [FailedRequest] = []

    func run(context: EngineTurnContext) async throws -> String {
        let input = context.userText
        guard !input.isEmpty else { return "" }

        var insights: [String] = []

        // Track tool usage from assistant text
        let assistantLower = context.assistantText.lowercased()
        if assistantLower.contains("tool:") || assistantLower.contains("using") {
            for toolName in ["get_time", "get_weather", "save_memory", "find_image", "find_video"] {
                if assistantLower.contains(toolName.replacingOccurrences(of: "_", with: " ")) ||
                   assistantLower.contains(toolName) {
                    recordUsage(toolName)
                }
            }
        }

        // Detect capability gaps (user asks for something Sam can't do well)
        let gapIndicators = ["can you", "is there a way", "I wish you could", "it would be nice if",
                            "how do I make you", "do you support"]
        if gapIndicators.contains(where: { input.lowercased().contains($0) }) {
            failedRequests.append(FailedRequest(query: input, timestamp: Date()))
            if failedRequests.count > 50 { failedRequests.removeFirst() }
        }

        // Report frequently requested capabilities
        if failedRequests.count >= 3 {
            let recentGaps = failedRequests.suffix(5)
            let topics = Set(recentGaps.map { extractTopic($0.query) })
            if topics.count <= 2 {
                insights.append("Recurring capability request detected — consider skill creation")
            }
        }

        // Report most/least used tools
        let sorted = toolUsage.sorted { $0.value.count > $1.value.count }
        if let top = sorted.first, top.value.count >= 10 {
            insights.append("Most used tool: \(top.key) (\(top.value.count) uses)")
        }

        guard !insights.isEmpty else { return "" }
        return "[SKILL EVOLUTION]\n" + insights.joined(separator: "\n")
    }

    private func recordUsage(_ tool: String) {
        if toolUsage[tool] != nil {
            toolUsage[tool]?.count += 1
            toolUsage[tool]?.lastUsed = Date()
        } else {
            toolUsage[tool] = ToolUsageStats(count: 1, lastUsed: Date())
        }
    }

    private func extractTopic(_ text: String) -> String {
        text.lowercased().split(separator: " ")
            .filter { $0.count > 4 }
            .prefix(2)
            .joined(separator: " ")
    }
}

private struct ToolUsageStats {
    var count: Int
    var lastUsed: Date
}

private struct FailedRequest {
    let query: String
    let timestamp: Date
}
