import Foundation
import SQLite3

/// SQLite-backed persistent memory store. Resilient — continues working even if DB fails.
final class MemoryStore {

    static let shared = MemoryStore()

    // MARK: - Errors

    enum StoreError: Error, LocalizedError {
        case openFailed(String)
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "Memory DB open failed: \(msg)"
            case .queryFailed(let msg): return "Memory DB query failed: \(msg)"
            }
        }
    }

    // MARK: - State

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    // MARK: - Init

    private init() {
        do {
            try openDatabase()
            try createTable()
            isAvailable = true
        } catch {
            print("[MemoryStore] Failed to initialize: \(error.localizedDescription)")
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase() throws {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let samosDir = appSupport.appendingPathComponent("SamOS")

        if !fileManager.fileExists(atPath: samosDir.path) {
            try fileManager.createDirectory(at: samosDir, withIntermediateDirectories: true)
        }

        let dbPath = samosDir.appendingPathComponent("memory.sqlite3").path

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.openFailed(error)
        }

        // Enable WAL mode for better concurrency
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
    }

    private func createTable() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            type TEXT NOT NULL,
            content TEXT NOT NULL,
            source TEXT,
            is_active INTEGER NOT NULL DEFAULT 1
        )
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.queryFailed(error)
        }
    }

    // MARK: - CRUD

    /// Adds a new memory. Returns the created row, or nil on failure.
    @discardableResult
    func addMemory(type: MemoryType, content: String, source: String? = nil) -> MemoryRow? {
        guard let db = db else { return nil }

        let id = UUID()
        let now = Date()
        let sql = "INSERT INTO memories (id, created_at, type, content, source, is_active) VALUES (?, ?, ?, ?, ?, 1)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, type.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 4, content, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let source = source {
            sqlite3_bind_text(stmt, 5, source, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }

        return MemoryRow(id: id, createdAt: now, type: type, content: content, source: source, isActive: true)
    }

    /// Lists active memories, optionally filtered by type.
    func listMemories(filterType: MemoryType? = nil) -> [MemoryRow] {
        guard let db = db else { return [] }

        let sql: String
        if let filterType = filterType {
            sql = "SELECT id, created_at, type, content, source FROM memories WHERE is_active = 1 AND type = '\(filterType.rawValue)' ORDER BY created_at DESC"
        } else {
            sql = "SELECT id, created_at, type, content, source FROM memories WHERE is_active = 1 ORDER BY created_at DESC"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [MemoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = parseRow(stmt) {
                rows.append(row)
            }
        }
        return rows
    }

    /// Returns up to `limit` most recent active memories (for router context).
    func recentMemories(limit: Int = 5) -> [MemoryRow] {
        guard let db = db else { return [] }

        let sql = "SELECT id, created_at, type, content, source FROM memories WHERE is_active = 1 ORDER BY created_at DESC LIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var rows: [MemoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = parseRow(stmt) {
                rows.append(row)
            }
        }
        return rows
    }

    /// Soft-deletes a memory by ID or ID prefix. Returns true if a row was affected.
    @discardableResult
    func deleteMemory(idOrPrefix: String) -> Bool {
        guard let db = db else { return false }

        // Try exact UUID match first, then prefix match
        let resolvedID: String?
        if UUID(uuidString: idOrPrefix) != nil {
            resolvedID = idOrPrefix.uppercased()
        } else {
            // Prefix match
            let prefix = idOrPrefix.uppercased()
            let findSQL = "SELECT id FROM memories WHERE is_active = 1 AND id LIKE '\(prefix)%' LIMIT 1"
            var findStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, findSQL, -1, &findStmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(findStmt) }
            if sqlite3_step(findStmt) == SQLITE_ROW, let cStr = sqlite3_column_text(findStmt, 0) {
                resolvedID = String(cString: cStr)
            } else {
                return false
            }
        }

        guard let id = resolvedID else { return false }

        let sql = "UPDATE memories SET is_active = 0 WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
    }

    /// Soft-deletes all active memories.
    func clearMemories() {
        guard let db = db else { return }
        sqlite3_exec(db, "UPDATE memories SET is_active = 0 WHERE is_active = 1", nil, nil, nil)
    }

    // MARK: - Search

    /// Stopwords excluded from keyword matching.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "is", "my", "your", "where", "what", "who",
        "of", "do", "does", "it", "in", "on", "at", "to", "for", "and",
        "i", "me", "have", "has", "was", "are", "be", "been", "being",
        "that", "this", "these", "those", "can", "could", "would", "should",
        "how", "when", "why", "which", "about", "with", "from"
    ]

    /// Keyword-scored search over active memories. Returns top matches by relevance then recency.
    func searchMemories(query: String, limit: Int = 5) -> [MemoryRow] {
        let all = listMemories()
        if all.isEmpty { return [] }

        let queryTokens = tokenize(query)
        if queryTokens.isEmpty { return Array(all.prefix(limit)) }

        let now = Date()
        var scored: [(row: MemoryRow, score: Int)] = []

        for mem in all {
            var score = 0
            var keywordHits = 0
            let contentLower = mem.content.lowercased()
            let contentWords = Set(tokenize(mem.content))

            for token in queryTokens {
                if contentLower.contains(token) { score += 3; keywordHits += 1 }
                if contentWords.contains(token) { score += 2; keywordHits += 1 }
            }

            guard keywordHits > 0 else { continue } // require at least one real keyword hit

            // Fact/preference rank higher than note
            if mem.type == .fact || mem.type == .preference { score += 1 }

            // Recency bonus
            let age = now.timeIntervalSince(mem.createdAt)
            if age < 86400 { score += 2 }
            else if age < 604800 { score += 1 }

            scored.append((mem, score))
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.row.createdAt > b.row.createdAt
        }

        return Array(scored.prefix(limit).map(\.row))
    }

    /// Tokenizes text into lowercase keywords, stripping punctuation and stopwords.
    func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 1 && !Self.stopwords.contains($0) }
    }

    // MARK: - Canonicalization & Deduplication

    /// Reduces content to a canonical form for comparison.
    /// Strips casing, punctuation, possessives, articles, pronouns, and filler words.
    func canonicalize(_ content: String) -> String {
        var text = content.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip trailing punctuation
        while let last = text.last, ".!?".contains(last) {
            text = String(text.dropLast())
        }

        // Normalize possessives: "dog's" → "dog"
        text = text.replacingOccurrences(of: "'s ", with: " ")
        text = text.replacingOccurrences(of: "'s", with: "")

        // Split into words, drop noise words
        let noiseWords: Set<String> = [
            "my", "your", "the", "a", "an", "is", "are", "was", "were",
            "i", "me", "he", "she", "it", "they", "we", "you",
            "am", "be", "been", "being", "have", "has", "had",
            "do", "does", "did", "will", "would", "could", "should",
            "that", "this", "of", "in", "on", "at", "to", "for",
            "and", "or", "but", "with", "from", "about", "also",
            "very", "really", "just", "so", "quite",
        ]

        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !noiseWords.contains($0) }

        return words.joined(separator: " ")
    }

    /// High-value fact patterns matched against lowercased content (before canonicalization).
    /// Only one active memory per pattern is allowed.
    private static let highValuePrefixes = [
        "your name is ",
        "your dog's name is ",
        "your dog name is ",
        "your cat's name is ",
        "your cat name is ",
        "your partner's name is ",
        "your partner name is ",
        "your wife's name is ",
        "your wife name is ",
        "your husband's name is ",
        "your husband name is ",
    ]

    /// Result of checking incoming content against existing memories.
    enum DedupeResult {
        case duplicate(MemoryRow)           // Exact canonical match — skip insert
        case refinement(MemoryRow)          // Overlapping — update in place
        case highValueReplace(MemoryRow)    // Same high-value slot — replace
        case noDuplicate                    // Insert normally
    }

    /// Checks incoming content against existing active memories of the given type.
    func checkForDuplicate(type: MemoryType, content: String) -> DedupeResult {
        let incoming = canonicalize(content)
        guard !incoming.isEmpty else { return .noDuplicate }

        let existing = listMemories(filterType: type)
        let incomingTokens = Set(incoming.split(separator: " ").map(String.init))
        let incomingLower = content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Check high-value fact patterns (matched on lowercased original content)
        for prefix in Self.highValuePrefixes {
            if incomingLower.hasPrefix(prefix) {
                for mem in existing {
                    let memLower = mem.content.lowercased()
                    if memLower.hasPrefix(prefix) {
                        return canonicalize(mem.content) == incoming
                            ? .duplicate(mem)
                            : .highValueReplace(mem)
                    }
                }
                break // No existing match for this prefix
            }
        }

        // 2) Exact canonical duplicate
        for mem in existing {
            let memCanonical = canonicalize(mem.content)
            if memCanonical == incoming {
                return .duplicate(mem)
            }
        }

        // 3) Refinement detection — incoming is a superset of an existing memory
        for mem in existing {
            let memCanonical = canonicalize(mem.content)
            let memTokens = Set(memCanonical.split(separator: " ").map(String.init))

            guard memTokens.count >= 2 else { continue }

            // Existing is a subset of incoming (incoming adds info)
            if memTokens.isSubset(of: incomingTokens) && incomingTokens.count > memTokens.count {
                return .refinement(mem)
            }

            // High overlap: if ≥80% of existing tokens appear in incoming and incoming is longer
            let overlap = memTokens.intersection(incomingTokens).count
            let overlapRatio = Double(overlap) / Double(memTokens.count)
            if overlapRatio >= 0.8 && incomingTokens.count > memTokens.count {
                return .refinement(mem)
            }
        }

        return .noDuplicate
    }

    /// Replaces an existing memory (soft-delete old, insert new). Returns the new row.
    @discardableResult
    func replaceMemory(old: MemoryRow, newContent: String, source: String? = nil) -> MemoryRow? {
        deleteMemory(idOrPrefix: old.id.uuidString)
        return addMemory(type: old.type, content: newContent, source: source)
    }

    // MARK: - Helpers

    private func parseRow(_ stmt: OpaquePointer?) -> MemoryRow? {
        guard let stmt = stmt else { return nil }

        guard let idCStr = sqlite3_column_text(stmt, 0),
              let typeCStr = sqlite3_column_text(stmt, 2),
              let contentCStr = sqlite3_column_text(stmt, 3)
        else { return nil }

        let idString = String(cString: idCStr)
        guard let uuid = UUID(uuidString: idString) else { return nil }

        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let typeString = String(cString: typeCStr)
        guard let type = MemoryType(rawValue: typeString) else { return nil }

        let content = String(cString: contentCStr)
        let source: String? = sqlite3_column_text(stmt, 4).map { String(cString: $0) }

        return MemoryRow(
            id: uuid,
            createdAt: createdAt,
            type: type,
            content: content,
            source: source,
            isActive: true
        )
    }
}
