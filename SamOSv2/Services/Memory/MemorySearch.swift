import Foundation

/// Hybrid memory search: BM25 (FTS5) + embedding cosine similarity + recency boost.
/// Combined score = 0.4 * BM25 + 0.4 * vector/semantic + 0.2 * recency
actor MemorySearch {
    private let database: DatabaseManager
    private let embeddingClient: OpenAIEmbeddingClient?

    init(database: DatabaseManager, embeddingClient: OpenAIEmbeddingClient? = nil) {
        self.database = database
        self.embeddingClient = embeddingClient
    }

    /// Search memories using hybrid ranking (vector + keyword + recency).
    func search(query: String, limit: Int = 12) async -> [ScoredMemory] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        // Try to get query embedding for vector search
        let queryEmbedding: [Float]?
        if let client = embeddingClient {
            queryEmbedding = try? await client.embed(query)
        } else {
            queryEmbedding = nil
        }

        // Get all active memories for scoring
        let rows = await database.query(
            "SELECT id, type, content, source, created_at, updated_at, access_count, embedding FROM memories WHERE is_active = 1"
        )

        let now = Date()
        var scored: [ScoredMemory] = []

        for row in rows {
            guard let id = row["id"] as? String,
                  let content = row["content"] as? String,
                  let updatedAt = row["updated_at"] as? Double else { continue }

            let contentTokens = tokenize(content)

            // BM25-like score (simplified TF-IDF)
            let bm25Score = computeBM25(queryTokens: queryTokens, docTokens: contentTokens)

            // Semantic/vector similarity
            let semanticScore: Double
            if let queryEmb = queryEmbedding,
               let embeddingData = row["embedding"] as? Data,
               embeddingData.count > 0 {
                // Deserialize stored embedding
                let storedEmbedding = embeddingData.withUnsafeBytes { ptr in
                    Array(ptr.bindMemory(to: Float.self))
                }
                if storedEmbedding.count == queryEmb.count {
                    semanticScore = Double(OpenAIEmbeddingClient.cosineSimilarity(queryEmb, storedEmbedding))
                } else {
                    // Fallback to token overlap
                    semanticScore = computeTokenOverlap(queryTokens: queryTokens, docTokens: contentTokens)
                }
            } else {
                // No embeddings available — use token overlap
                semanticScore = computeTokenOverlap(queryTokens: queryTokens, docTokens: contentTokens)
            }

            // Recency boost (exponential decay, 30-day half-life)
            let ageInDays = now.timeIntervalSince(Date(timeIntervalSince1970: updatedAt)) / 86400
            let recencyScore = exp(-0.693 * ageInDays / 30.0) // ln(2) ≈ 0.693

            // Combined score
            let combined = 0.4 * bm25Score + 0.4 * semanticScore + 0.2 * recencyScore

            guard combined > 0.01 else { continue }

            let typeStr = row["type"] as? String ?? "note"
            scored.append(ScoredMemory(
                id: id,
                type: MemoryType(rawValue: typeStr) ?? .note,
                content: content,
                score: combined,
                source: row["source"] as? String ?? "conversation",
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            ))
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// Check if two texts are duplicates (Jaccard similarity > 0.80).
    func isDuplicate(_ a: String, _ b: String) -> Bool {
        let tokensA = Set(tokenize(a))
        let tokensB = Set(tokenize(b))
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return false }
        let intersection = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        return Double(intersection) / Double(union) > 0.80
    }

    // MARK: - Scoring

    private func computeBM25(queryTokens: [String], docTokens: [String]) -> Double {
        let k1 = 1.2
        let b = 0.75
        let avgDocLen = 20.0
        let docLen = Double(docTokens.count)
        let docSet = Dictionary(grouping: docTokens, by: { $0 }).mapValues { $0.count }

        var score = 0.0
        for qt in Set(queryTokens) {
            let tf = Double(docSet[qt] ?? 0)
            guard tf > 0 else { continue }
            let idf = 1.0 // Simplified — no corpus-wide IDF
            let numerator = tf * (k1 + 1)
            let denominator = tf + k1 * (1 - b + b * docLen / avgDocLen)
            score += idf * numerator / denominator
        }
        return min(score / Double(max(queryTokens.count, 1)), 1.0)
    }

    private func computeTokenOverlap(queryTokens: [String], docTokens: [String]) -> Double {
        let querySet = Set(queryTokens)
        let docSet = Set(docTokens)
        guard !querySet.isEmpty else { return 0 }
        let overlap = querySet.intersection(docSet).count
        return Double(overlap) / Double(querySet.count)
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }
}

/// A memory entry with a relevance score.
struct ScoredMemory: Sendable {
    let id: String
    let type: MemoryType
    let content: String
    let score: Double
    let source: String
    let updatedAt: Date
}
