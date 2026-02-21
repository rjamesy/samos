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

    enum UpsertResult {
        case inserted(MemoryRow)
        case updated(MemoryRow)
        case skippedLimit
        case skippedDuplicate
    }

    // MARK: - State

    private static let defaults = UserDefaults.standard
    private static let dailyPruneKey = "memory_prune_last_day"
    private static let totalCap = 1_000
    private static let perDayCap = 75

    private static let highSimilarityThreshold = 0.80

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    private let selectColumns = "id, created_at, last_seen_at, type, content, confidence, ttl_days, source, source_snippet, tags_json, checkin_resolved, is_active"

    // MARK: - Init

    private init() {
        do {
            try openDatabase()
            try createTable()
            try migrateSchemaIfNeeded()
            isAvailable = true
        } catch {
            print("[MemoryStore] Failed to initialize: \(error.localizedDescription)")
        }
    }

    /// Test-only initializer with custom sqlite file path.
    init(dbPath: String) {
        do {
            try openDatabase(atPath: dbPath)
            try createTable()
            try migrateSchemaIfNeeded()
            isAvailable = true
        } catch {
            print("[MemoryStore] Failed to initialize custom DB: \(error.localizedDescription)")
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Defaults

    func defaultTTLDays(for type: MemoryType) -> Int {
        switch type {
        case .fact, .preference:
            return 365
        case .note:
            return 180
        case .checkin:
            return 7
        }
    }

    func maxCount(for type: MemoryType) -> Int {
        switch type {
        case .fact, .preference:
            return 200
        case .note:
            return 200
        case .checkin:
            return 50
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
        try openDatabase(atPath: dbPath)
    }

    private func openDatabase(atPath path: String) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.openFailed(error)
        }

        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
    }

    private func createTable() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            last_seen_at REAL NOT NULL DEFAULT 0,
            type TEXT NOT NULL,
            content TEXT NOT NULL,
            confidence TEXT NOT NULL DEFAULT 'med',
            ttl_days INTEGER NOT NULL DEFAULT 90,
            source TEXT,
            source_snippet TEXT,
            tags_json TEXT NOT NULL DEFAULT '[]',
            checkin_resolved INTEGER NOT NULL DEFAULT 0,
            is_active INTEGER NOT NULL DEFAULT 1
        )
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.queryFailed(error)
        }
    }

    private func migrateSchemaIfNeeded() throws {
        guard let db = db else { return }

        let columns = tableColumns(in: "memories")

        let migrations: [(String, String)] = [
            ("last_seen_at", "ALTER TABLE memories ADD COLUMN last_seen_at REAL NOT NULL DEFAULT 0"),
            ("confidence", "ALTER TABLE memories ADD COLUMN confidence TEXT NOT NULL DEFAULT 'med'"),
            ("ttl_days", "ALTER TABLE memories ADD COLUMN ttl_days INTEGER NOT NULL DEFAULT 90"),
            ("source_snippet", "ALTER TABLE memories ADD COLUMN source_snippet TEXT"),
            ("tags_json", "ALTER TABLE memories ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]'"),
            ("checkin_resolved", "ALTER TABLE memories ADD COLUMN checkin_resolved INTEGER NOT NULL DEFAULT 0")
        ]

        for (name, alterSQL) in migrations where !columns.contains(name) {
            guard sqlite3_exec(db, alterSQL, nil, nil, nil) == SQLITE_OK else {
                let error = String(cString: sqlite3_errmsg(db))
                throw StoreError.queryFailed("Failed migrating column \(name): \(error)")
            }
        }

        // Backfill empty last_seen_at on older rows.
        sqlite3_exec(db, "UPDATE memories SET last_seen_at = created_at WHERE last_seen_at <= 0", nil, nil, nil)
    }

    private func tableColumns(in table: String) -> Set<String> {
        guard let db = db else { return [] }
        let sql = "PRAGMA table_info(\(table))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var columns: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 1) {
                columns.insert(String(cString: cStr))
            }
        }
        return columns
    }

    // MARK: - CRUD

    /// Adds a new memory. Returns the created row, or nil on failure.
    @discardableResult
    func addMemory(type: MemoryType,
                   content: String,
                   source: String? = nil,
                   confidence: MemoryConfidence = .medium,
                   ttlDays: Int? = nil,
                   sourceSnippet: String? = nil,
                   tags: [String] = [],
                   isResolved: Bool = false,
                   createdAt: Date = Date(),
                   lastSeenAt: Date? = nil) -> MemoryRow? {
        guard let db = db else { return nil }

        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else { return nil }

        let id = UUID()
        let created = createdAt
        let seen = lastSeenAt ?? created
        let ttl = max(1, ttlDays ?? defaultTTLDays(for: type))

        let tagsData = (try? JSONSerialization.data(withJSONObject: tags)) ?? Data("[]".utf8)
        let tagsJSON = String(data: tagsData, encoding: .utf8) ?? "[]"

        let sql = """
        INSERT INTO memories
        (id, created_at, last_seen_at, type, content, confidence, ttl_days, source, source_snippet, tags_json, checkin_resolved, is_active)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(stmt, 2, created.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, seen.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 4, type.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 5, normalizedContent, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 6, confidence.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 7, Int32(ttl))
        if let source = source {
            sqlite3_bind_text(stmt, 8, source, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        if let sourceSnippet = sourceSnippet {
            sqlite3_bind_text(stmt, 9, sourceSnippet, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        sqlite3_bind_text(stmt, 10, tagsJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 11, isResolved ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }

        let row = MemoryRow(
            id: id,
            createdAt: created,
            lastSeenAt: seen,
            type: type,
            content: normalizedContent,
            confidence: confidence,
            ttlDays: ttl,
            source: source,
            sourceSnippet: sourceSnippet,
            tags: tags,
            isResolved: isResolved,
            isActive: true
        )

        enforceCaps(referenceDate: Date())
        return row
    }

    @discardableResult
    func upsertMemory(type: MemoryType,
                      content: String,
                      confidence: MemoryConfidence = .medium,
                      ttlDays: Int? = nil,
                      source: String? = nil,
                      sourceSnippet: String? = nil,
                      tags: [String] = [],
                      isResolved: Bool = false,
                      now: Date = Date()) -> UpsertResult {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else { return .skippedDuplicate }

        switch checkForDuplicate(type: type, content: normalizedContent) {
        case .duplicate(let existing):
            if let updated = touchMemory(
                existing,
                confidence: confidence,
                ttlDays: ttlDays,
                sourceSnippet: sourceSnippet,
                tags: tags,
                isResolved: isResolved,
                now: now
            ) {
                return .updated(updated)
            }
            return .skippedDuplicate

        case .refinement(let existing), .highValueReplace(let existing):
            if let replaced = replaceMemory(
                old: existing,
                newContent: normalizedContent,
                source: source,
                confidence: confidence,
                ttlDays: ttlDays,
                sourceSnippet: sourceSnippet,
                tags: tags,
                isResolved: isResolved,
                now: now
            ) {
                return .updated(replaced)
            }
            return .skippedDuplicate

        case .noDuplicate:
            break
        }

        if let similar = firstSimilarMemory(type: type, content: normalizedContent) {
            if let updated = touchMemory(
                similar,
                confidence: confidence,
                ttlDays: ttlDays,
                sourceSnippet: sourceSnippet,
                tags: tags,
                isResolved: isResolved,
                now: now
            ) {
                return .updated(updated)
            }
            return .skippedDuplicate
        }

        if let contradictory = firstContradictoryMemory(type: type, content: normalizedContent) {
            if let replaced = replaceMemory(
                old: contradictory,
                newContent: normalizedContent,
                source: source,
                confidence: confidence,
                ttlDays: ttlDays,
                sourceSnippet: sourceSnippet,
                tags: Array(Set(tags + ["supersedes_contradiction"])).sorted(),
                isResolved: isResolved,
                now: now
            ) {
                return .updated(replaced)
            }
            return .skippedDuplicate
        }

        if countMemoriesCreated(on: now) >= Self.perDayCap {
            return .skippedLimit
        }

        guard let inserted = addMemory(
            type: type,
            content: normalizedContent,
            source: source,
            confidence: confidence,
            ttlDays: ttlDays,
            sourceSnippet: sourceSnippet,
            tags: tags,
            isResolved: isResolved,
            createdAt: now,
            lastSeenAt: now
        ) else {
            return .skippedDuplicate
        }

        return .inserted(inserted)
    }

    /// Returns an active memory by id.
    func memory(id: UUID) -> MemoryRow? {
        guard let db = db else { return nil }
        let sql = "SELECT \(selectColumns) FROM memories WHERE is_active = 1 AND id = ? LIMIT 1"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseRow(stmt)
    }

    /// Lists active memories, optionally filtered by type.
    func listMemories(filterType: MemoryType? = nil) -> [MemoryRow] {
        guard let db = db else { return [] }

        let sql: String
        if filterType != nil {
            sql = "SELECT \(selectColumns) FROM memories WHERE is_active = 1 AND type = ? ORDER BY created_at DESC"
        } else {
            sql = "SELECT \(selectColumns) FROM memories WHERE is_active = 1 ORDER BY created_at DESC"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        if let filterType = filterType {
            sqlite3_bind_text(stmt, 1, filterType.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

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

        let sql = "SELECT \(selectColumns) FROM memories WHERE is_active = 1 ORDER BY created_at DESC LIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(max(0, limit)))

        var rows: [MemoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = parseRow(stmt) {
                rows.append(row)
            }
        }
        return rows
    }

    func unresolvedCheckins(limit: Int = 20) -> [MemoryRow] {
        guard let db = db else { return [] }
        let sql = """
        SELECT \(selectColumns)
        FROM memories
        WHERE is_active = 1 AND type = 'checkin' AND checkin_resolved = 0
        ORDER BY created_at DESC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(max(0, limit)))

        var rows: [MemoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = parseRow(stmt), !isExpired(row) {
                rows.append(row)
            }
        }
        return rows
    }

    @discardableResult
    func markCheckinsResolved(ids: [UUID]) -> Int {
        guard let db = db, !ids.isEmpty else { return 0 }
        var changed = 0

        let sql = "UPDATE memories SET checkin_resolved = 1, last_seen_at = ? WHERE id = ? AND is_active = 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        let now = Date().timeIntervalSince1970

        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(stmt) == SQLITE_DONE {
                changed += Int(sqlite3_changes(db))
            }
        }

        return changed
    }

    /// Marks unresolved checkins as resolved when the user reports improvement.
    func resolveCheckinsIfUserImproved(_ userMessage: String) -> [UUID] {
        guard isImprovementSignal(userMessage) else { return [] }

        let unresolved = unresolvedCheckins(limit: 50)
        guard !unresolved.isEmpty else { return [] }

        let ids = unresolved.map(\.id)
        _ = markCheckinsResolved(ids: ids)
        return ids
    }

    private func isImprovementSignal(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }

        let markers = [
            "feel better", "feeling better", "better now", "i'm better", "i am better",
            "doing better", "all good now", "i'm okay now", "i am okay now",
            "i feel fine", "recovered", "not sick anymore", "less stressed", "stress is better"
        ]

        return markers.contains { lower.contains($0) }
    }

    /// Soft-deletes a memory by ID or ID prefix. Returns true if a row was affected.
    @discardableResult
    func deleteMemory(idOrPrefix: String) -> Bool {
        guard let db = db else { return false }

        let resolvedID: String?
        if UUID(uuidString: idOrPrefix) != nil {
            resolvedID = idOrPrefix.uppercased()
        } else {
            let prefix = idOrPrefix.uppercased()
            let findSQL = "SELECT id FROM memories WHERE is_active = 1 AND id LIKE ? LIMIT 1"
            var findStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, findSQL, -1, &findStmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(findStmt) }
            let pattern = "\(prefix)%"
            sqlite3_bind_text(findStmt, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
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
        let all = listMemories().filter { row in
            if isExpired(row) { return false }
            if row.type == .checkin && row.isResolved { return false }
            if isLowValueWebsiteMemory(row) { return false }
            return true
        }
        if all.isEmpty { return [] }

        let baseRanked = LocalKnowledgeRetriever.rank(
            query: query,
            items: all,
            text: { $0.content },
            recencyDate: { $0.lastSeenAt },
            extraBoost: { memory in
                switch memory.type {
                case .fact, .preference:
                    return 0.08
                case .checkin:
                    return 0.05
                default:
                    return 0.0
                }
            },
            limit: max(1, limit),
            minScore: 0.15,
            requireTokenOverlap: true
        )
        if !baseRanked.isEmpty {
            return baseRanked.map(\.item)
        }

        let expansion = LocalKnowledgeRetriever.expandedQueryTokens(from: query)
        guard !expansion.isEmpty else { return [] }
        let expandedQuery = query + " " + expansion.joined(separator: " ")
        let expandedRanked = LocalKnowledgeRetriever.rank(
            query: expandedQuery,
            items: all,
            text: { $0.content },
            recencyDate: { $0.lastSeenAt },
            extraBoost: { memory in
                switch memory.type {
                case .fact, .preference:
                    return 0.08
                case .checkin:
                    return 0.05
                default:
                    return 0.0
                }
            },
            limit: max(1, limit),
            minScore: 0.18,
            requireTokenOverlap: true
        )

        return expandedRanked.map(\.item)
    }

    private func isLowValueWebsiteMemory(_ row: MemoryRow) -> Bool {
        guard (row.source ?? "").lowercased() == "website_learning" else { return false }
        let lower = row.content.lowercased()
        let signals = [
            "loading your experience", "this won't take long", "we're getting things ready",
            "we are getting things ready", "checking your browser", "enable javascript",
            "please wait", "just a moment"
        ]
        return signals.contains { lower.contains($0) }
    }

    // MARK: - Temporal Query Support

    /// Parse temporal references like "5 days ago", "last week", "yesterday" into a date range.
    static func parseTemporalRange(from query: String, now: Date = Date()) -> (start: Date, end: Date)? {
        let lower = query.lowercased()
        let calendar = Calendar.current

        // "yesterday"
        if lower.contains("yesterday") {
            let startOfToday = calendar.startOfDay(for: now)
            let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            return (startOfYesterday, startOfToday)
        }

        // "today" / "earlier today"
        if lower.contains("earlier today") || (lower.contains("today") && lower.contains("said")) {
            let startOfToday = calendar.startOfDay(for: now)
            return (startOfToday, now)
        }

        // "last week"
        if lower.contains("last week") {
            let start = calendar.date(byAdding: .day, value: -14, to: now)!
            let end = calendar.date(byAdding: .day, value: -7, to: now)!
            return (start, end)
        }

        // "this week"
        if lower.contains("this week") {
            let start = calendar.date(byAdding: .day, value: -7, to: now)!
            return (start, now)
        }

        // "last month"
        if lower.contains("last month") {
            let start = calendar.date(byAdding: .month, value: -2, to: now)!
            let end = calendar.date(byAdding: .month, value: -1, to: now)!
            return (start, end)
        }

        // "N days ago" / "N day ago"
        let daysPattern = #"(\d+)\s+days?\s+ago"#
        if let regex = try? NSRegularExpression(pattern: daysPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
           let numRange = Range(match.range(at: 1), in: lower),
           let days = Int(lower[numRange]) {
            let targetDate = calendar.date(byAdding: .day, value: -days, to: now)!
            let startOfTarget = calendar.startOfDay(for: targetDate)
            let endOfTarget = calendar.date(byAdding: .day, value: 1, to: startOfTarget)!
            return (startOfTarget, endOfTarget)
        }

        // "N weeks ago"
        let weeksPattern = #"(\d+)\s+weeks?\s+ago"#
        if let regex = try? NSRegularExpression(pattern: weeksPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
           let numRange = Range(match.range(at: 1), in: lower),
           let weeks = Int(lower[numRange]) {
            let start = calendar.date(byAdding: .weekOfYear, value: -(weeks + 1), to: now)!
            let end = calendar.date(byAdding: .weekOfYear, value: -weeks + 1, to: now)!
            return (start, end)
        }

        return nil
    }

    /// Query memories within a specific date range. For temporal queries like "what did I say 5 days ago".
    func memoriesInDateRange(start: Date, end: Date, maxItems: Int = 20) -> [MemoryRow] {
        guard let db = db else { return [] }

        let sql = """
        SELECT \(selectColumns) FROM memories
        WHERE is_active = 1 AND created_at >= ? AND created_at <= ?
        ORDER BY created_at DESC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, end.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 3, Int32(maxItems))

        var rows: [MemoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = parseRow(stmt) {
                rows.append(row)
            }
        }
        return rows
    }

    /// Enhanced memory context that handles temporal queries automatically.
    /// If the query contains temporal references ("5 days ago", "yesterday", "last week"),
    /// this will query by date range first, then fall back to keyword search.
    func temporalMemoryContext(query: String, maxItems: Int = 10, maxChars: Int = 1500, now: Date = Date()) -> [MemoryRow] {
        // Check for temporal query first
        if let range = MemoryStore.parseTemporalRange(from: query, now: now) {
            let temporalResults = memoriesInDateRange(start: range.start, end: range.end, maxItems: maxItems)
            if !temporalResults.isEmpty {
                return temporalResults
            }
            // Fall through to keyword search if no temporal results
        }

        // Default to keyword search
        return memoryContext(query: query, maxItems: maxItems, maxChars: maxChars)
    }

    /// Compact top-k recall context with strict size limits.
    func memoryContext(query: String, maxItems: Int = 10, maxChars: Int = 1500) -> [MemoryRow] {
        let candidates = searchMemories(query: query, limit: 10)
        guard !candidates.isEmpty else { return [] }

        var selected: [MemoryRow] = []
        var usedChars = 0

        for candidate in candidates {
            guard selected.count < max(1, maxItems) else { break }
            let snippet = "- \(candidate.type.rawValue): \(candidate.content)"
            let nextChars = usedChars + snippet.count
            if !selected.isEmpty && nextChars > maxChars { break }
            if selected.isEmpty && snippet.count > maxChars { continue }
            selected.append(candidate)
            usedChars = nextChars
        }

        return selected
    }

    /// Lightweight relationship hints derived from memories.
    /// These can be injected as a small graph-like context (subject -> predicate -> object).
    func graphContext(query: String, maxItems: Int = 6, maxChars: Int = 500) -> [String] {
        let candidates = memoryContext(query: query, maxItems: 16, maxChars: 2400)
        guard !candidates.isEmpty else { return [] }

        var edges: [String] = []
        var seen: Set<String> = []

        for memory in candidates {
            for edge in extractGraphEdges(from: memory.content) {
                let key = edge.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                edges.append(edge)
            }
        }

        guard !edges.isEmpty else { return [] }

        var selected: [String] = []
        var usedChars = 0
        for edge in edges {
            guard selected.count < max(1, maxItems) else { break }
            let nextChars = usedChars + edge.count + 3
            if !selected.isEmpty && nextChars > maxChars { break }
            if selected.isEmpty && edge.count > maxChars { continue }
            selected.append(edge)
            usedChars = nextChars
        }
        return selected
    }

    private static let relationNameRegex = try! NSRegularExpression(
        pattern: #"(?:your|my)\s+([a-zA-Z][a-zA-Z0-9' _-]{1,40}?)\s+name\s+is\s+([a-zA-Z][a-zA-Z0-9' _-]{1,40})"#,
        options: [.caseInsensitive]
    )
    private static let relationIsRegex = try! NSRegularExpression(
        pattern: #"([a-zA-Z][a-zA-Z0-9' _-]{1,40})\s+is\s+an?\s+([a-zA-Z][a-zA-Z0-9' _,-]{1,60})"#,
        options: [.caseInsensitive]
    )

    private func extractGraphEdges(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let nsRange = NSRange(trimmed.startIndex..., in: trimmed)

        var edges: [String] = []

        Self.relationNameRegex.enumerateMatches(in: trimmed, options: [], range: nsRange) { match, _, _ in
            guard
                let match,
                let subjectRange = Range(match.range(at: 1), in: trimmed),
                let objectRange = Range(match.range(at: 2), in: trimmed)
            else { return }
            let subject = sanitizeGraphNode(String(trimmed[subjectRange]))
            let object = sanitizeGraphNode(String(trimmed[objectRange]))
            guard !subject.isEmpty, !object.isEmpty else { return }
            edges.append("user -> \(subject) -> \(object)")
        }

        Self.relationIsRegex.enumerateMatches(in: trimmed, options: [], range: nsRange) { match, _, _ in
            guard
                let match,
                let subjectRange = Range(match.range(at: 1), in: trimmed),
                let objectRange = Range(match.range(at: 2), in: trimmed)
            else { return }
            let subject = sanitizeGraphNode(String(trimmed[subjectRange]))
            let object = sanitizeGraphNode(String(trimmed[objectRange]))
            guard !subject.isEmpty, !object.isEmpty else { return }
            edges.append("\(subject) -> is_a -> \(object)")
        }

        return edges
    }

    private func sanitizeGraphNode(_ node: String) -> String {
        var cleaned = node
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        if cleaned.lowercased().hasSuffix("'s") {
            cleaned = String(cleaned.dropLast(2))
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tokenizes text into lowercase keywords, stripping punctuation and stopwords.
    func tokenize(_ text: String) -> [String] {
        LocalKnowledgeRetriever.tokens(from: text)
    }

    // MARK: - Canonicalization & Deduplication

    /// Reduces content to a canonical form for comparison.
    /// Strips casing, punctuation, possessives, articles, pronouns, and filler words.
    func canonicalize(_ content: String) -> String {
        var text = content.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while let last = text.last, ".!?".contains(last) {
            text = String(text.dropLast())
        }

        text = text.replacingOccurrences(of: "'s ", with: " ")
        text = text.replacingOccurrences(of: "'s", with: "")

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

    enum DedupeResult {
        case duplicate(MemoryRow)
        case refinement(MemoryRow)
        case highValueReplace(MemoryRow)
        case noDuplicate
    }

    /// Checks incoming content against existing active memories of the given type.
    func checkForDuplicate(type: MemoryType, content: String) -> DedupeResult {
        let incoming = canonicalize(content)
        guard !incoming.isEmpty else { return .noDuplicate }

        let existing = listMemories(filterType: type)
        let incomingTokens = Set(incoming.split(separator: " ").map(String.init))
        let incomingLower = content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

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
                break
            }
        }

        for mem in existing {
            if canonicalize(mem.content) == incoming {
                return .duplicate(mem)
            }
        }

        for mem in existing {
            let memCanonical = canonicalize(mem.content)
            let memTokens = Set(memCanonical.split(separator: " ").map(String.init))

            guard memTokens.count >= 2 else { continue }

            if memTokens.isSubset(of: incomingTokens) && incomingTokens.count > memTokens.count {
                return .refinement(mem)
            }

            let overlap = memTokens.intersection(incomingTokens).count
            let overlapRatio = Double(overlap) / Double(memTokens.count)
            if overlapRatio >= 0.8 && incomingTokens.count > memTokens.count {
                return .refinement(mem)
            }
        }

        return .noDuplicate
    }

    @discardableResult
    func replaceMemory(old: MemoryRow,
                       newContent: String,
                       source: String? = nil,
                       confidence: MemoryConfidence? = nil,
                       ttlDays: Int? = nil,
                       sourceSnippet: String? = nil,
                       tags: [String]? = nil,
                       isResolved: Bool? = nil,
                       now: Date = Date()) -> MemoryRow? {
        _ = deleteMemory(idOrPrefix: old.id.uuidString)
        return addMemory(
            type: old.type,
            content: newContent,
            source: source ?? old.source,
            confidence: confidence ?? old.confidence,
            ttlDays: ttlDays ?? old.ttlDays,
            sourceSnippet: sourceSnippet ?? old.sourceSnippet,
            tags: tags ?? old.tags,
            isResolved: isResolved ?? old.isResolved,
            createdAt: now,
            lastSeenAt: now
        )
    }

    // MARK: - TTL & Hygiene

    func isExpired(_ row: MemoryRow, relativeTo now: Date = Date()) -> Bool {
        let ttl = max(1, row.ttlDays)
        let expiry = row.createdAt.addingTimeInterval(TimeInterval(ttl * 86_400))
        return now >= expiry
    }

    @discardableResult
    func pruneExpiredMemories(referenceDate: Date = Date()) -> Int {
        guard let db = db else { return 0 }
        let sql = """
        UPDATE memories
        SET is_active = 0
        WHERE is_active = 1
          AND created_at + (CASE WHEN ttl_days < 1 THEN 1 ELSE ttl_days END) * 86400.0 <= ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, referenceDate.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    func pruneExpiredMemoriesDaily(referenceDate: Date = Date()) {
        let dayKey = dayStamp(referenceDate)
        let last = Self.defaults.string(forKey: Self.dailyPruneKey)
        guard last != dayKey else { return }
        _ = pruneExpiredMemories(referenceDate: referenceDate)
        Self.defaults.set(dayKey, forKey: Self.dailyPruneKey)
    }

    // MARK: - Private Helpers

    private func dayStamp(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? 0
        let month = comps.month ?? 0
        let day = comps.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func countMemoriesCreated(on date: Date) -> Int {
        guard let db = db else { return 0 }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }

        let sql = "SELECT COUNT(*) FROM memories WHERE is_active = 1 AND created_at >= ? AND created_at < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, end.timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func activeCountsByType() -> [MemoryType: Int] {
        guard let db = db else { return [:] }
        let sql = "SELECT type, COUNT(*) FROM memories WHERE is_active = 1 GROUP BY type"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var counts: [MemoryType: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let typeRawC = sqlite3_column_text(stmt, 0) else { continue }
            let typeRaw = String(cString: typeRawC)
            guard let type = MemoryType(rawValue: typeRaw) else { continue }
            counts[type] = Int(sqlite3_column_int(stmt, 1))
        }
        return counts
    }

    private func enforceCaps(referenceDate: Date) {
        _ = pruneExpiredMemories(referenceDate: referenceDate)
        let countsByType = activeCountsByType()
        var projectedTotal = countsByType.values.reduce(0, +)

        for type in MemoryType.allCases {
            let maxCountForType = maxCount(for: type)
            let count = countsByType[type] ?? 0
            if count > maxCountForType {
                let overage = count - maxCountForType
                softDeleteOldest(type: type, count: overage)
                projectedTotal -= overage
            }
        }

        if projectedTotal > Self.totalCap {
            softDeleteOldest(type: nil, count: projectedTotal - Self.totalCap)
        }
    }

    private func softDeleteOldest(type: MemoryType?, count: Int) {
        guard let db = db, count > 0 else { return }

        let sql: String
        if type == nil {
            sql = "UPDATE memories SET is_active = 0 WHERE id IN (SELECT id FROM memories WHERE is_active = 1 ORDER BY created_at ASC LIMIT ?)"
        } else {
            sql = "UPDATE memories SET is_active = 0 WHERE id IN (SELECT id FROM memories WHERE is_active = 1 AND type = ? ORDER BY created_at ASC LIMIT ?)"
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        if let type = type {
            sqlite3_bind_text(stmt, 1, type.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, Int32(count))
        } else {
            sqlite3_bind_int(stmt, 1, Int32(count))
        }

        _ = sqlite3_step(stmt)
    }

    private func firstSimilarMemory(type: MemoryType, content: String) -> MemoryRow? {
        let incoming = canonicalize(content)
        guard !incoming.isEmpty else { return nil }

        let existing = listMemories(filterType: type)
        for row in existing {
            let score = normalizedSimilarity(incoming, canonicalize(row.content))
            if score >= Self.highSimilarityThreshold {
                return row
            }
        }
        return nil
    }

    private func firstContradictoryMemory(type: MemoryType, content: String) -> MemoryRow? {
        guard type == .fact || type == .preference || type == .note else { return nil }
        let incomingCanonical = canonicalize(content)
        guard !incomingCanonical.isEmpty else { return nil }
        let incomingTokens = Set(incomingCanonical.split(separator: " ").map(String.init))
        guard incomingTokens.count >= 2 else { return nil }

        let incomingHasNegation = containsNegation(content)
        let existing = listMemories(filterType: type)
        for row in existing {
            let existingCanonical = canonicalize(row.content)
            let existingTokens = Set(existingCanonical.split(separator: " ").map(String.init))
            guard existingTokens.count >= 2 else { continue }

            let overlap = incomingTokens.intersection(existingTokens).count
            let union = incomingTokens.union(existingTokens).count
            guard union > 0 else { continue }
            let overlapRatio = Double(overlap) / Double(union)
            if overlapRatio < 0.55 { continue }

            let existingHasNegation = containsNegation(row.content)
            if incomingHasNegation != existingHasNegation {
                return row
            }
        }

        return nil
    }

    private func normalizedSimilarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let aSet = Set(a.split(separator: " ").map(String.init))
        let bSet = Set(b.split(separator: " ").map(String.init))
        guard !aSet.isEmpty, !bSet.isEmpty else { return 0 }

        let intersection = Double(aSet.intersection(bSet).count)
        let union = Double(aSet.union(bSet).count)
        if union == 0 { return 0 }
        return intersection / union
    }

    private func containsNegation(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "not ", "n't", "never ", "no ", "avoid ", "without ", "don't ", "do not ",
            "can't ", "cannot ", "won't ", "doesn't ", "does not "
        ]
        return markers.contains { lowered.contains($0) }
    }

    private func touchMemory(_ row: MemoryRow,
                             confidence: MemoryConfidence,
                             ttlDays: Int?,
                             sourceSnippet: String?,
                             tags: [String],
                             isResolved: Bool,
                             now: Date) -> MemoryRow? {
        guard let db = db else { return nil }

        let ttl = max(1, ttlDays ?? row.ttlDays)
        let mergedTags = Array(Set(row.tags + tags)).sorted()
        let tagsData = (try? JSONSerialization.data(withJSONObject: mergedTags)) ?? Data("[]".utf8)
        let tagsJSON = String(data: tagsData, encoding: .utf8) ?? "[]"

        let resolved = row.type == .checkin ? (row.isResolved || isResolved) : row.isResolved
        let snippet = sourceSnippet ?? row.sourceSnippet

        let sql = """
        UPDATE memories
        SET last_seen_at = ?, confidence = ?, ttl_days = ?, source_snippet = ?, tags_json = ?, checkin_resolved = ?
        WHERE id = ? AND is_active = 1
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, confidence.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 3, Int32(ttl))
        if let snippet = snippet {
            sqlite3_bind_text(stmt, 4, snippet, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_text(stmt, 5, tagsJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 6, resolved ? 1 : 0)
        sqlite3_bind_text(stmt, 7, row.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return memory(id: row.id)
    }

    private func parseRow(_ stmt: OpaquePointer?) -> MemoryRow? {
        guard let stmt = stmt else { return nil }

        guard let idCStr = sqlite3_column_text(stmt, 0),
              let typeCStr = sqlite3_column_text(stmt, 3),
              let contentCStr = sqlite3_column_text(stmt, 4)
        else { return nil }

        let idString = String(cString: idCStr)
        guard let uuid = UUID(uuidString: idString) else { return nil }

        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        var lastSeen = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        if lastSeen.timeIntervalSince1970 <= 0 { lastSeen = createdAt }

        let typeString = String(cString: typeCStr)
        guard let type = MemoryType(rawValue: typeString) else { return nil }

        let content = String(cString: contentCStr)

        let confidenceRaw = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? MemoryConfidence.medium.rawValue
        let confidence = MemoryConfidence(rawValue: confidenceRaw) ?? .medium

        let ttlDays = Int(sqlite3_column_int(stmt, 6))

        let source: String? = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let sourceSnippet: String? = sqlite3_column_text(stmt, 8).map { String(cString: $0) }

        let tagsJSON = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "[]"
        let tagsData = tagsJSON.data(using: .utf8) ?? Data("[]".utf8)
        let tags = (try? JSONSerialization.jsonObject(with: tagsData) as? [String]) ?? []

        let isResolved = sqlite3_column_int(stmt, 10) == 1
        let isActive = sqlite3_column_int(stmt, 11) == 1

        return MemoryRow(
            id: uuid,
            createdAt: createdAt,
            lastSeenAt: lastSeen,
            type: type,
            content: content,
            confidence: confidence,
            ttlDays: max(1, ttlDays),
            source: source,
            sourceSnippet: sourceSnippet,
            tags: tags,
            isResolved: isResolved,
            isActive: isActive
        )
    }
}
