import Foundation

/// Background processing: episode compression, profile extraction, daily summaries.
actor SemanticMemoryEngine {
    private let database: DatabaseManager
    private let llmClient: any LLMClient

    init(database: DatabaseManager, llmClient: any LLMClient) {
        self.database = database
        self.llmClient = llmClient
    }

    /// Compress recent messages into an episode summary.
    func compressEpisode(messages: [ChatMessage], sessionId: String) async {
        guard messages.count >= 4 else { return }

        let transcript = messages.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")

        let request = LLMRequest(
            system: """
            Summarize this conversation segment in 2-3 sentences.
            Extract the main topic and any facts about the user.
            Respond with JSON: {"title":"...","summary":"...","topics":["..."]}
            """,
            messages: [LLMMessage(role: "user", content: transcript)],
            maxTokens: 300,
            responseFormat: .jsonObject
        )

        guard let response = try? await llmClient.complete(request),
              let data = response.text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String,
              let summary = json["summary"] as? String else { return }

        let topics = json["topics"] as? [String] ?? []
        let topicsJSON = (try? JSONEncoder().encode(topics)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let now = Date()
        let dateStr = Self.dateFormatter.string(from: now)

        await database.run("""
            INSERT INTO episodes (id, title, summary, topics, created_at, updated_at, local_date)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            UUID().uuidString, title, summary, topicsJSON,
            now.timeIntervalSince1970, now.timeIntervalSince1970, dateStr
        ])
    }

    /// Extract profile facts from conversation using LLM.
    func extractProfileFacts(messages: [ChatMessage]) async {
        let transcript = messages.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")

        let request = LLMRequest(
            system: """
            Extract user profile facts from this conversation.
            Look for: name, pet names, location, job, hobbies, preferences.
            Respond with JSON array: [{"attribute":"name","value":"Richard","confidence":0.9}]
            Only include facts you are confident about. Return [] if none found.
            """,
            messages: [LLMMessage(role: "user", content: transcript)],
            maxTokens: 300,
            responseFormat: .jsonObject
        )

        guard let response = try? await llmClient.complete(request),
              let data = response.text.data(using: .utf8),
              let facts = try? JSONDecoder().decode([ExtractedFact].self, from: data) else { return }

        let now = Date().timeIntervalSince1970
        for fact in facts {
            await database.run("""
                INSERT INTO profile_facts (id, attribute, value, confidence, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(attribute) DO UPDATE SET value = excluded.value, confidence = excluded.confidence, updated_at = excluded.updated_at
            """, bindings: [UUID().uuidString, fact.attribute, fact.value, fact.confidence, now, now])
        }
    }

    /// Generate daily summary from today's messages.
    func generateDailySummary() async {
        let today = Self.dateFormatter.string(from: Date())

        // Check if already generated
        let existing = await database.query(
            "SELECT date FROM daily_summaries WHERE date = ?", bindings: [today]
        )
        guard existing.isEmpty else { return }

        let messages = await database.query(
            "SELECT role, text FROM messages WHERE local_date = ? ORDER BY ts ASC", bindings: [today]
        )
        guard messages.count >= 3 else { return }

        let transcript = messages.map { "\($0["role"] ?? ""): \($0["text"] ?? "")" }.joined(separator: "\n")

        let request = LLMRequest(
            system: "Summarize today's conversations in 2-3 sentences. Focus on key topics discussed and any decisions made.",
            messages: [LLMMessage(role: "user", content: transcript)],
            maxTokens: 200
        )

        guard let response = try? await llmClient.complete(request) else { return }

        await database.run(
            "INSERT INTO daily_summaries (date, summary, created_at) VALUES (?, ?, ?)",
            bindings: [today, response.text, Date().timeIntervalSince1970]
        )
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

private struct ExtractedFact: Decodable {
    let attribute: String
    let value: String
    let confidence: Double
}
