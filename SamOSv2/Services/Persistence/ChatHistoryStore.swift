import Foundation

/// Persists and loads chat messages from SQLite.
actor ChatHistoryStore {
    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func save(_ message: ChatMessage, sessionId: String) async {
        await database.run("""
            INSERT OR REPLACE INTO chat_history (id, role, text, ts, latency_ms, provider, used_memory, session_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            message.id.uuidString,
            message.role.rawValue,
            message.text,
            message.ts.timeIntervalSince1970,
            message.latencyMs,
            message.provider,
            message.usedMemory ? 1 : 0,
            sessionId
        ])
    }

    func loadSession(_ sessionId: String) async -> [ChatMessage] {
        let rows = await database.query(
            "SELECT * FROM chat_history WHERE session_id = ? ORDER BY ts ASC",
            bindings: [sessionId]
        )
        return rows.compactMap { row in
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
                text: text,
                latencyMs: row["latency_ms"] as? Int,
                provider: row["provider"] as? String,
                usedMemory: (row["used_memory"] as? Int) == 1
            )
        }
    }

    func recentSessions(limit: Int = 5) async -> [[ChatMessage]] {
        let rows = await database.query("""
            SELECT DISTINCT session_id FROM chat_history ORDER BY ts DESC LIMIT ?
        """, bindings: [limit])
        var sessions: [[ChatMessage]] = []
        for row in rows {
            if let sid = row["session_id"] as? String {
                let msgs = await loadSession(sid)
                if !msgs.isEmpty { sessions.append(msgs) }
            }
        }
        return sessions
    }
}
