import Foundation

/// Persists debug/audit log entries to SQLite.
actor DebugLogStore {
    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func log(level: String, category: String, message: String) async {
        await database.run("""
            INSERT INTO debug_log (level, category, message, created_at) VALUES (?, ?, ?, ?)
        """, bindings: [level, category, message, Date().timeIntervalSince1970])
    }

    func recent(limit: Int = 100) async -> [(level: String, category: String, message: String, ts: Date)] {
        let rows = await database.query(
            "SELECT level, category, message, created_at FROM debug_log ORDER BY created_at DESC LIMIT ?",
            bindings: [limit]
        )
        return rows.compactMap { row in
            guard let level = row["level"] as? String,
                  let cat = row["category"] as? String,
                  let msg = row["message"] as? String,
                  let ts = row["created_at"] as? Double else { return nil }
            return (level: level, category: cat, message: msg, ts: Date(timeIntervalSince1970: ts))
        }
    }

    func clear() async {
        await database.execute("DELETE FROM debug_log")
    }
}
