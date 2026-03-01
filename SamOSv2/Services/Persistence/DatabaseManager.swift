import Foundation
import SQLite3

/// Actor-isolated SQLite database manager. Single DB file, WAL mode, all migrations.
actor DatabaseManager {
    private var db: OpaquePointer?
    private let dbPath: String

    init(path: String? = nil) {
        if let path {
            self.dbPath = path
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent(AppConfig.appName)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.dbPath = dir.appendingPathComponent(AppConfig.databaseFilename).path
        }
    }

    /// Open database and run all migrations.
    func initialize() {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("[DB] Failed to open database at \(dbPath)")
            return
        }

        // Enable WAL mode
        execute("PRAGMA journal_mode=WAL")
        execute("PRAGMA foreign_keys=ON")

        runMigrations()
        print("[DB] Initialized at \(dbPath)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Public Query API

    func execute(_ sql: String) {
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let error = errMsg.map { String(cString: $0) } ?? "unknown"
            print("[DB] SQL error: \(error) — \(sql.prefix(100))")
            sqlite3_free(errMsg)
        }
    }

    func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let error = String(cString: sqlite3_errmsg(db))
            print("[DB] Prepare error: \(error) — \(sql.prefix(100))")
            return nil
        }
        return stmt
    }

    func run(_ sql: String, bindings: [Any?]) {
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bindValues(stmt: stmt, values: bindings)
        sqlite3_step(stmt)
    }

    func query(_ sql: String, bindings: [Any?] = []) -> [[String: Any]] {
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindValues(stmt: stmt, values: bindings)

        var results: [[String: Any]] = []
        let colCount = sqlite3_column_count(stmt)

        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(stmt, i)
                    if let blob = sqlite3_column_blob(stmt, i), bytes > 0 {
                        row[name] = Data(bytes: blob, count: Int(bytes))
                    } else {
                        row[name] = NSNull()
                    }
                case SQLITE_NULL:
                    row[name] = NSNull()
                default:
                    row[name] = NSNull()
                }
            }
            results.append(row)
        }
        return results
    }

    // MARK: - Migrations

    private func runMigrations() {
        execute("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY
            )
        """)

        let currentVersion = (query("SELECT version FROM schema_version ORDER BY version DESC LIMIT 1")
            .first?["version"] as? Int) ?? 0

        if currentVersion < 1 {
            migrateV1()
            run("INSERT OR REPLACE INTO schema_version (version) VALUES (?)", bindings: [1])
        }

        if currentVersion < 2 {
            migrateV2()
            run("INSERT OR REPLACE INTO schema_version (version) VALUES (?)", bindings: [2])
        }

        if currentVersion < 3 {
            migrateV3()
            run("INSERT OR REPLACE INTO schema_version (version) VALUES (?)", bindings: [3])
        }
    }

    private func migrateV2() {
        // Add embedding column for vector search
        execute("ALTER TABLE memories ADD COLUMN embedding BLOB")
    }

    private func migrateV3() {
        // Make all existing memories permanent — nullify expiry dates
        execute("UPDATE memories SET expires_at = NULL WHERE is_active = 1")
    }

    private func migrateV1() {
        // Core memories
        execute("""
            CREATE TABLE IF NOT EXISTS memories (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL CHECK(type IN ('fact','preference','note','checkin')),
                content TEXT NOT NULL,
                source TEXT DEFAULT 'conversation',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                expires_at REAL,
                is_active INTEGER DEFAULT 1,
                access_count INTEGER DEFAULT 0,
                last_accessed_at REAL
            )
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_memories_type ON memories(type)")
        execute("CREATE INDEX IF NOT EXISTS idx_memories_active ON memories(is_active, type)")
        execute("CREATE INDEX IF NOT EXISTS idx_memories_expires ON memories(expires_at) WHERE expires_at IS NOT NULL")

        // FTS5 for memory search
        execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
                content, content=memories, content_rowid=rowid, tokenize='porter unicode61'
            )
        """)

        // Semantic episodes
        execute("""
            CREATE TABLE IF NOT EXISTS episodes (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                summary TEXT NOT NULL,
                topics TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                local_date TEXT NOT NULL
            )
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_episodes_date ON episodes(local_date)")

        // Profile facts
        execute("""
            CREATE TABLE IF NOT EXISTS profile_facts (
                id TEXT PRIMARY KEY,
                attribute TEXT NOT NULL,
                value TEXT NOT NULL,
                confidence REAL DEFAULT 0.8,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_profile_attribute ON profile_facts(attribute)")

        // Daily summaries
        execute("""
            CREATE TABLE IF NOT EXISTS daily_summaries (
                date TEXT PRIMARY KEY,
                summary TEXT NOT NULL,
                created_at REAL NOT NULL
            )
        """)

        // Raw messages
        execute("""
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                role TEXT NOT NULL CHECK(role IN ('user','assistant','system')),
                text TEXT NOT NULL,
                ts REAL NOT NULL,
                session_id TEXT,
                local_date TEXT NOT NULL
            )
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(ts)")
        execute("CREATE INDEX IF NOT EXISTS idx_messages_date ON messages(local_date)")
        execute("CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id)")

        // Chat history
        execute("""
            CREATE TABLE IF NOT EXISTS chat_history (
                id TEXT PRIMARY KEY,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                ts REAL NOT NULL,
                latency_ms INTEGER,
                provider TEXT,
                used_memory INTEGER DEFAULT 0,
                session_id TEXT NOT NULL
            )
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_chat_ts ON chat_history(ts)")
        execute("CREATE INDEX IF NOT EXISTS idx_chat_session ON chat_history(session_id)")

        // Engine outputs
        execute("""
            CREATE TABLE IF NOT EXISTS engine_outputs (
                id TEXT PRIMARY KEY,
                engine_name TEXT NOT NULL,
                context_block TEXT NOT NULL,
                turn_id TEXT,
                created_at REAL NOT NULL
            )
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_engine_name ON engine_outputs(engine_name, created_at)")

        // Behavior patterns
        execute("""
            CREATE TABLE IF NOT EXISTS behavior_patterns (
                id TEXT PRIMARY KEY,
                pattern_type TEXT NOT NULL,
                description TEXT NOT NULL,
                confidence REAL DEFAULT 0.5,
                evidence_count INTEGER DEFAULT 0,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                is_active INTEGER DEFAULT 1
            )
        """)

        // Behavior signals
        execute("""
            CREATE TABLE IF NOT EXISTS behavior_signals (
                id TEXT PRIMARY KEY,
                pattern_type TEXT NOT NULL,
                signal_data TEXT,
                created_at REAL NOT NULL
            )
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_signals_type ON behavior_signals(pattern_type, created_at)")

        // Skills
        execute("""
            CREATE TABLE IF NOT EXISTS skills (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                trigger_phrases TEXT NOT NULL,
                parameters TEXT,
                steps TEXT NOT NULL,
                approved_by_gpt INTEGER DEFAULT 0,
                approved_by_user INTEGER DEFAULT 0,
                created_at REAL NOT NULL,
                usage_count INTEGER DEFAULT 0,
                last_used_at REAL
            )
        """)

        // Forge jobs
        execute("""
            CREATE TABLE IF NOT EXISTS forge_jobs (
                id TEXT PRIMARY KEY,
                goal TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('queued','planning','building','validating','simulating','awaiting_approval','installed','failed')),
                skill_id TEXT,
                error_message TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        // Learned websites
        execute("""
            CREATE TABLE IF NOT EXISTS learned_websites (
                id TEXT PRIMARY KEY,
                url TEXT NOT NULL,
                host TEXT NOT NULL,
                title TEXT NOT NULL,
                summary TEXT NOT NULL,
                highlights TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_websites_host ON learned_websites(host)")

        // Self-learning
        execute("""
            CREATE TABLE IF NOT EXISTS self_learning (
                id TEXT PRIMARY KEY,
                category TEXT NOT NULL,
                text TEXT NOT NULL,
                confidence REAL DEFAULT 0.5,
                observed_count INTEGER DEFAULT 1,
                applied_count INTEGER DEFAULT 0,
                created_at REAL NOT NULL,
                last_updated_at REAL NOT NULL
            )
        """)

        // Debug log
        execute("""
            CREATE TABLE IF NOT EXISTS debug_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                level TEXT NOT NULL,
                category TEXT NOT NULL,
                message TEXT NOT NULL,
                created_at REAL NOT NULL
            )
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_debug_created ON debug_log(created_at)")

        // Settings
        execute("""
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
    }

    // MARK: - Helpers

    private func bindValues(stmt: OpaquePointer, values: [Any?]) {
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case nil:
                sqlite3_bind_null(stmt, idx)
            case let v as String:
                sqlite3_bind_text(stmt, idx, (v as NSString).utf8String, -1, nil)
            case let v as Int:
                sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double:
                sqlite3_bind_double(stmt, idx, v)
            case let v as Bool:
                sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            case let v as Data:
                v.withUnsafeBytes { ptr in
                    _ = sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(v.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            default:
                sqlite3_bind_text(stmt, idx, "\(value!)", -1, nil)
            }
        }
    }
}
