import Foundation

/// Injects recent turns from prior sessions into the current prompt.
actor CrossSessionHistory {
    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    /// Get recent messages from the last N sessions (excluding current).
    func recentCrossSessions(currentSessionId: String, maxMessages: Int = 10) async -> [ChatMessage] {
        let rows = await database.query("""
            SELECT id, role, text, ts, session_id FROM messages
            WHERE session_id != ?
            ORDER BY ts DESC LIMIT ?
        """, bindings: [currentSessionId, maxMessages])

        return rows.reversed().compactMap { row in
            guard let idStr = row["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let roleStr = row["role"] as? String,
                  let role = MessageRole(rawValue: roleStr),
                  let text = row["text"] as? String,
                  let ts = row["ts"] as? Double else { return nil }
            return ChatMessage(
                id: id,
                ts: Date(timeIntervalSince1970: ts),
                role: role,
                text: text
            )
        }
    }

    /// Build a cross-session context string for the prompt.
    func buildCrossSessionBlock(currentSessionId: String, maxChars: Int = 2000) async -> String {
        let messages = await recentCrossSessions(currentSessionId: currentSessionId)
        guard !messages.isEmpty else { return "" }

        var block = "[RECENT PRIOR SESSIONS]\n"
        for msg in messages {
            let line = "\(msg.role.rawValue): \(msg.text)\n"
            if block.count + line.count > maxChars { break }
            block += line
        }
        return block
    }
}
