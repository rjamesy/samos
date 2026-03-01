import Foundation

/// SQLite-backed memory store. Actor-isolated for thread safety.
actor MemoryStore: MemoryStoreProtocol {
    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func addMemory(type: MemoryType, content: String, source: String) async throws -> MemoryRow {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        let expiresAt = expiryDate(for: type)

        await database.run("""
            INSERT INTO memories (id, type, content, source, created_at, updated_at, expires_at, is_active)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1)
        """, bindings: [id, type.rawValue, content, source, now, now, expiresAt])

        return MemoryRow(id: id, type: type, content: content, source: source,
                         expiresAt: expiresAt.map { Date(timeIntervalSince1970: $0) })
    }

    func listMemories(filterType: MemoryType?) async -> [MemoryRow] {
        let sql: String
        let bindings: [Any?]
        if let type = filterType {
            sql = "SELECT * FROM memories WHERE is_active = 1 AND type = ? ORDER BY updated_at DESC"
            bindings = [type.rawValue]
        } else {
            sql = "SELECT * FROM memories WHERE is_active = 1 ORDER BY updated_at DESC"
            bindings = []
        }
        let rows = await database.query(sql, bindings: bindings)
        return rows.compactMap(parseMemoryRow)
    }

    func searchMemories(query: String, limit: Int) async -> [MemoryRow] {
        // Simple FTS5 search for now — MemorySearch will provide hybrid ranking
        let rows = await database.query("""
            SELECT m.* FROM memories m
            JOIN memories_fts fts ON m.rowid = fts.rowid
            WHERE memories_fts MATCH ? AND m.is_active = 1
            ORDER BY rank LIMIT ?
        """, bindings: [query, limit])
        return rows.compactMap(parseMemoryRow)
    }

    func deleteMemory(id: String) async throws {
        await database.run("UPDATE memories SET is_active = 0 WHERE id = ?", bindings: [id])
    }

    func clearMemories() async throws {
        await database.execute("UPDATE memories SET is_active = 0")
    }

    func coreIdentityFacts(maxItems: Int) async -> [ProfileFact] {
        let rows = await database.query(
            "SELECT * FROM profile_facts ORDER BY confidence DESC LIMIT ?",
            bindings: [maxItems]
        )
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let attr = row["attribute"] as? String,
                  let val = row["value"] as? String else { return nil }
            return ProfileFact(
                id: id,
                attribute: attr,
                value: val,
                confidence: row["confidence"] as? Double ?? 0.8,
                createdAt: Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"] as? Double ?? 0)
            )
        }
    }

    func temporalContext(query: String, maxChars: Int) async -> String {
        // Basic temporal context — return recent messages if query references time
        let temporalWords = ["yesterday", "last week", "today", "this morning", "earlier", "before"]
        let lower = query.lowercased()
        guard temporalWords.contains(where: { lower.contains($0) }) else { return "" }

        let rows = await database.query(
            "SELECT role, text FROM messages ORDER BY ts DESC LIMIT 20"
        )
        var result = "[Recent conversation context]\n"
        for row in rows {
            if let role = row["role"] as? String, let text = row["text"] as? String {
                result += "\(role): \(text)\n"
                if result.count >= maxChars { break }
            }
        }
        return String(result.prefix(maxChars))
    }

    func pruneExpired() async {
        let now = Date().timeIntervalSince1970
        await database.run(
            "UPDATE memories SET is_active = 0 WHERE expires_at IS NOT NULL AND expires_at < ?",
            bindings: [now]
        )
    }

    func upsertProfileFact(attribute: String, value: String, confidence: Double) async throws {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        await database.run("""
            INSERT INTO profile_facts (id, attribute, value, confidence, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(attribute) DO UPDATE SET value = excluded.value, confidence = excluded.confidence, updated_at = excluded.updated_at
        """, bindings: [id, attribute, value, confidence, now, now])
    }

    func storeEmbedding(memoryId: String, embedding: Data) async {
        // Store embedding as BLOB — the v2 migration adds the column
        await database.run(
            "UPDATE memories SET embedding = ? WHERE id = ?",
            bindings: [embedding, memoryId]
        )
    }

    // MARK: - Helpers

    private func expiryDate(for type: MemoryType) -> Double? {
        let days: Int
        switch type {
        case .fact: days = AppConfig.MemoryTTL.fact
        case .preference: days = AppConfig.MemoryTTL.preference
        case .note: days = AppConfig.MemoryTTL.note
        case .checkin: days = AppConfig.MemoryTTL.checkin
        }
        guard days > 0 else { return nil }  // 0 = permanent, no expiry
        return Date().addingTimeInterval(TimeInterval(days * 86400)).timeIntervalSince1970
    }

    private func parseMemoryRow(_ row: [String: Any]) -> MemoryRow? {
        guard let id = row["id"] as? String,
              let typeStr = row["type"] as? String,
              let type = MemoryType(rawValue: typeStr),
              let content = row["content"] as? String,
              let createdAt = row["created_at"] as? Double,
              let updatedAt = row["updated_at"] as? Double else { return nil }

        return MemoryRow(
            id: id,
            type: type,
            content: content,
            source: row["source"] as? String ?? "conversation",
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            expiresAt: (row["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
            isActive: (row["is_active"] as? Int) == 1,
            accessCount: row["access_count"] as? Int ?? 0,
            lastAccessedAt: (row["last_accessed_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        )
    }
}
