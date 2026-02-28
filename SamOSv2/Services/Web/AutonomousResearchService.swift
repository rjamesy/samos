import Foundation

/// Self-directed web research service.
/// Starts from a topic, searches DuckDuckGo/Wikipedia, follows links, summarizes findings.
actor AutonomousResearchService {
    private let llmClient: LLMClient
    private let webLearner: WebLearningService
    private(set) var isResearching = false
    private(set) var currentTopic: String?
    private var findings: [ResearchFinding] = []

    struct ResearchFinding: Sendable {
        let source: String
        let content: String
        let relevance: Double
    }

    init(llmClient: LLMClient, webLearner: WebLearningService) {
        self.llmClient = llmClient
        self.webLearner = webLearner
    }

    /// Start autonomous research on a topic.
    func startResearch(topic: String, maxPages: Int = 5) async throws -> [ResearchFinding] {
        isResearching = true
        currentTopic = topic
        findings = []

        defer {
            isResearching = false
            currentTopic = nil
        }

        // Generate search queries
        let queries = try await generateSearchQueries(topic: topic)

        // Search and learn from each query
        for query in queries.prefix(maxPages) {
            guard isResearching else { break }

            // Use DuckDuckGo HTML search (no API key needed)
            let searchURL = "https://html.duckduckgo.com/html/?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"

            do {
                let website = try await webLearner.learnFromURL(searchURL)
                let finding = ResearchFinding(
                    source: searchURL,
                    content: website.summary,
                    relevance: 0.8
                )
                findings.append(finding)
            } catch {
                // Continue with other queries
                continue
            }
        }

        return findings
    }

    /// Stop current research.
    func stopResearch() {
        isResearching = false
    }

    /// Get current findings.
    func currentFindings() -> [ResearchFinding] {
        findings
    }

    private func generateSearchQueries(topic: String) async throws -> [String] {
        let prompt = """
        Generate 3-5 specific search queries to research this topic: "\(topic)"
        Return only the queries, one per line.
        """

        let response = try await llmClient.complete(LLMRequest(
            messages: [LLMMessage(role: "user", content: prompt)],
            model: "gpt-4o-mini",
            maxTokens: 200
        ))

        return response.text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
