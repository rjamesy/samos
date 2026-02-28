import Foundation

/// Fetches, summarizes, and indexes web pages for learning.
actor WebLearningService {
    private let llmClient: LLMClient
    private let db: DatabaseManager

    init(llmClient: LLMClient, db: DatabaseManager) {
        self.llmClient = llmClient
        self.db = db
    }

    /// Learn from a URL by fetching, summarizing, and storing.
    func learnFromURL(_ urlString: String) async throws -> LearnedWebsite {
        guard let url = URL(string: urlString) else {
            throw WebLearningError.invalidURL(urlString)
        }

        // Fetch page content
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WebLearningError.fetchFailed(urlString)
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        let text = stripHTML(html)
        let truncated = String(text.prefix(10000))

        // Summarize with LLM
        let summaryPrompt = """
        Summarize this web page content. Extract:
        1. A title (max 10 words)
        2. A summary (2-3 sentences)
        3. Key highlights (up to 5 bullet points)

        Content:
        \(truncated)
        """

        let response2 = try await llmClient.complete(LLMRequest(
            messages: [LLMMessage(role: "user", content: summaryPrompt)],
            model: "gpt-4o-mini",
            maxTokens: 300
        ))

        let summary = response2.text
        let title = extractTitle(from: html) ?? url.host ?? "Untitled"

        let website = LearnedWebsite(
            id: UUID().uuidString,
            url: urlString,
            host: url.host ?? "",
            title: title,
            summary: summary,
            createdAt: Date()
        )

        // Save to DB
        await db.run(
            """
            INSERT OR REPLACE INTO learned_websites (id, url, host, title, summary, highlights, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                website.id, website.url, website.host, website.title, website.summary,
                "[]", website.createdAt.timeIntervalSince1970,
                Date().timeIntervalSince1970
            ]
        )

        return website
    }

    /// Search learned websites by query.
    func search(query: String) async -> [LearnedWebsite] {
        let rows = await db.query(
            "SELECT * FROM learned_websites WHERE summary LIKE ? OR title LIKE ? ORDER BY created_at DESC LIMIT 5",
            bindings: ["%\(query)%", "%\(query)%"]
        )
        return rows.compactMap { parseWebsite(from: $0) }
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractTitle(from html: String) -> String? {
        guard let titleRange = html.range(of: "<title>"),
              let endRange = html.range(of: "</title>") else { return nil }
        return String(html[titleRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseWebsite(from row: [String: Any]) -> LearnedWebsite? {
        guard let id = row["id"] as? String, let url = row["url"] as? String else { return nil }
        return LearnedWebsite(
            id: id,
            url: url,
            host: row["host"] as? String ?? "",
            title: row["title"] as? String ?? "",
            summary: row["summary"] as? String ?? "",
            createdAt: Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0)
        )
    }
}

struct LearnedWebsite: Sendable {
    let id: String
    let url: String
    let host: String
    let title: String
    let summary: String
    let createdAt: Date
}

enum WebLearningError: Error, LocalizedError {
    case invalidURL(String)
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .fetchFailed(let url): return "Failed to fetch: \(url)"
        }
    }
}
