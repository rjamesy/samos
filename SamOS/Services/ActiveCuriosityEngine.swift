import Foundation
import SQLite3

// MARK: - Knowledge Gap Model

struct KnowledgeGap: Codable, Identifiable {
    let id: UUID
    let category: String      // e.g. "routine", "preference", "relationship", "goal"
    let topic: String          // e.g. "morning_routine", "favorite_cuisine"
    let description: String    // What Sam wants to know
    var priority: Double       // 0.0-1.0 information gain estimate
    var questionTemplate: String
    var askCount: Int
    let createdAt: Date
    var lastAskedAt: Date?
    var resolvedAt: Date?
    var resolutionConfidence: Double?
}

// MARK: - Active Curiosity Engine

/// Tracks knowledge gaps — things Sam doesn't know about the user but would benefit from knowing.
/// Identifies high-information-gain questions and injects them at natural conversation moments.
@MainActor
final class ActiveCuriosityEngine {

    static let shared = ActiveCuriosityEngine()

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    /// Minimum seconds between curiosity questions (10 minutes)
    private let askCooldownSeconds: TimeInterval = 600
    /// Maximum times to ask about a single gap before giving up
    private let maxAskCount = 3

    private var lastAskedAt: Date?

    private init() {
        do {
            try openDatabase()
            try createTables()
            isAvailable = true
        } catch {
            #if DEBUG
            print("[CURIOSITY] DB init failed: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Detect knowledge gaps from conversation and persist them.
    /// Called after each turn to discover what Sam doesn't know.
    func detectGaps(turnID: String, userText: String) async {
        guard isAvailable else { return }

        let startedAt = CFAbsoluteTimeGetCurrent()

        do {
            let gaps = try await identifyGaps(from: userText)
            for gap in gaps where gap.priority > 0.4 {
                upsertGap(gap)
            }

            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            #if DEBUG
            print("[CURIOSITY] turn=\(turnID) gaps_detected=\(gaps.count) persisted=\(gaps.filter { $0.priority > 0.4 }.count) ms=\(elapsedMs)")
            #endif
        } catch {
            #if DEBUG
            print("[CURIOSITY] gap detection failed: \(error)")
            #endif
        }
    }

    /// Attempt to resolve gaps from user's response.
    /// Called each turn to check if the user answered a curiosity question.
    func attemptResolution(userText: String) {
        guard isAvailable else { return }
        let unresolved = fetchUnresolvedGaps(limit: 10)
        let lower = userText.lowercased()

        for gap in unresolved {
            let topicWords = gap.topic.replacingOccurrences(of: "_", with: " ")
                .lowercased().components(separatedBy: " ")
            let matchCount = topicWords.filter { lower.contains($0) }.count
            let matchRatio = topicWords.isEmpty ? 0 : Double(matchCount) / Double(topicWords.count)

            if matchRatio >= 0.5 || lower.contains(gap.topic.lowercased().replacingOccurrences(of: "_", with: " ")) {
                resolveGap(id: gap.id, confidence: matchRatio)
            }
        }
    }

    /// Returns an optional curiosity question to append to the response.
    /// Respects timing constraints and conversation flow.
    func maybeCuriosityQuestion() -> String? {
        guard isAvailable else { return nil }
        guard shouldAsk() else { return nil }

        guard let gap = fetchTopUnresolvedGap() else { return nil }

        markAsked(gap.id)
        lastAskedAt = Date()

        #if DEBUG
        print("[CURIOSITY] injecting question for gap=\(gap.topic) priority=\(String(format: "%.2f", gap.priority)) ask_count=\(gap.askCount + 1)")
        #endif

        return gap.questionTemplate
    }

    /// Count of unresolved gaps (for diagnostics).
    func unresolvedCount() -> Int {
        guard isAvailable else { return 0 }
        let sql = "SELECT COUNT(*) FROM knowledge_gaps WHERE resolved_at IS NULL;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Gap Detection (LLM)

    private func identifyGaps(from text: String) async throws -> [KnowledgeGap] {
        let systemPrompt = """
        You identify knowledge gaps — things a personal AI assistant should know about the user but doesn't yet.
        Focus on high-information-gain topics: routines, preferences, relationships, goals, constraints.
        Return JSON: {"gaps": [{"category": "preference|routine|relationship|goal|constraint", "topic": "snake_case_key", "description": "what to learn", "priority": 0.0-1.0, "question": "natural conversational question to ask"}]}
        Return at most 3 gaps. Only include genuinely useful gaps, not trivial ones.
        """
        let userPrompt = "User said: \"\(text)\"\nIdentify knowledge gaps that would help personalize future responses."

        let raw = try await IntelligenceLLMClient.hybridJSON(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            ollamaMaxTokens: 400,
            openAIMaxTokens: 800
        )

        guard let parsed = IntelligenceLLMClient.parseJSON(raw),
              let gapDicts = parsed["gaps"] as? [[String: Any]] else {
            return []
        }

        let now = Date()
        return gapDicts.prefix(3).compactMap { dict -> KnowledgeGap? in
            guard let category = dict["category"] as? String,
                  let topic = dict["topic"] as? String,
                  let description = dict["description"] as? String,
                  let question = dict["question"] as? String else { return nil }
            let priority = (dict["priority"] as? NSNumber)?.doubleValue ?? 0.5
            return KnowledgeGap(
                id: UUID(),
                category: category,
                topic: topic,
                description: description,
                priority: min(1.0, max(0.0, priority)),
                questionTemplate: question,
                askCount: 0,
                createdAt: now,
                lastAskedAt: nil,
                resolvedAt: nil,
                resolutionConfidence: nil
            )
        }
    }

    // MARK: - Timing

    private func shouldAsk() -> Bool {
        if let lastAsked = lastAskedAt {
            guard Date().timeIntervalSince(lastAsked) >= askCooldownSeconds else { return false }
        }
        return true
    }

    // MARK: - Queries

    private func fetchTopUnresolvedGap() -> KnowledgeGap? {
        let sql = """
        SELECT id, category, topic, description, priority, question_template,
               ask_count, created_at, last_asked_at, resolved_at, resolution_confidence
        FROM knowledge_gaps
        WHERE resolved_at IS NULL AND ask_count < ?
        ORDER BY priority DESC
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(stmt, 1, Int32(maxAskCount))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeGap(stmt)
    }

    private func fetchUnresolvedGaps(limit: Int) -> [KnowledgeGap] {
        let sql = """
        SELECT id, category, topic, description, priority, question_template,
               ask_count, created_at, last_asked_at, resolved_at, resolution_confidence
        FROM knowledge_gaps
        WHERE resolved_at IS NULL
        ORDER BY priority DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [KnowledgeGap] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let gap = decodeGap(stmt) {
                results.append(gap)
            }
        }
        return results
    }

    // MARK: - Mutations

    private func upsertGap(_ gap: KnowledgeGap) {
        // Check if topic already exists
        let checkSql = "SELECT id FROM knowledge_gaps WHERE topic = ? AND resolved_at IS NULL;"
        var checkStmt: OpaquePointer?
        sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil)
        sqlite3_bind_text(checkStmt, 1, (gap.topic as NSString).utf8String, -1, nil)
        let exists = sqlite3_step(checkStmt) == SQLITE_ROW
        sqlite3_finalize(checkStmt)

        if exists {
            // Boost priority of existing gap
            let updateSql = "UPDATE knowledge_gaps SET priority = MIN(1.0, priority + 0.1) WHERE topic = ? AND resolved_at IS NULL;"
            var updateStmt: OpaquePointer?
            defer { sqlite3_finalize(updateStmt) }
            guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(updateStmt, 1, (gap.topic as NSString).utf8String, -1, nil)
            sqlite3_step(updateStmt)
        } else {
            // Insert new gap
            let sql = """
            INSERT INTO knowledge_gaps
            (id, category, topic, description, priority, question_template, ask_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?, 0, ?);
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, (gap.id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (gap.category as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (gap.topic as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (gap.description as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 5, gap.priority)
            sqlite3_bind_text(stmt, 6, (gap.questionTemplate as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 7, gap.createdAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    private func markAsked(_ id: UUID) {
        let sql = "UPDATE knowledge_gaps SET ask_count = ask_count + 1, last_asked_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, (id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    private func resolveGap(id: UUID, confidence: Double) {
        let sql = "UPDATE knowledge_gaps SET resolved_at = ?, resolution_confidence = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, confidence)
        sqlite3_bind_text(stmt, 3, (id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
        #if DEBUG
        print("[CURIOSITY] resolved gap=\(id.uuidString.prefix(8)) confidence=\(String(format: "%.2f", confidence))")
        #endif
    }

    // MARK: - SQLite

    private func openDatabase() throws {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SamOS")
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let path = dir.appendingPathComponent("intelligence.sqlite3").path
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("DB open failed")
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
    }

    private func createTables() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS knowledge_gaps (
            id TEXT PRIMARY KEY,
            category TEXT NOT NULL,
            topic TEXT NOT NULL,
            description TEXT NOT NULL,
            priority REAL DEFAULT 0.5,
            question_template TEXT NOT NULL,
            ask_count INTEGER DEFAULT 0,
            created_at REAL NOT NULL,
            last_asked_at REAL,
            resolved_at REAL,
            resolution_confidence REAL
        );
        CREATE INDEX IF NOT EXISTS idx_knowledge_gaps_priority ON knowledge_gaps(resolved_at, priority DESC);
        CREATE INDEX IF NOT EXISTS idx_knowledge_gaps_topic ON knowledge_gaps(topic);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("Knowledge gaps table creation failed")
        }
    }

    private func decodeGap(_ stmt: OpaquePointer?) -> KnowledgeGap? {
        guard let stmt else { return nil }
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr) else { return nil }

        let category = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let topic = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let description = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let priority = sqlite3_column_double(stmt, 4)
        let questionTemplate = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
        let askCount = Int(sqlite3_column_int(stmt, 6))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let lastAskedAt: Date? = sqlite3_column_type(stmt, 8) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)) : nil
        let resolvedAt: Date? = sqlite3_column_type(stmt, 9) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)) : nil
        let resolutionConfidence: Double? = sqlite3_column_type(stmt, 10) != SQLITE_NULL
            ? sqlite3_column_double(stmt, 10) : nil

        return KnowledgeGap(
            id: id, category: category, topic: topic, description: description,
            priority: priority, questionTemplate: questionTemplate,
            askCount: askCount, createdAt: createdAt, lastAskedAt: lastAskedAt,
            resolvedAt: resolvedAt, resolutionConfidence: resolutionConfidence
        )
    }
}
