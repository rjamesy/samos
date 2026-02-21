import Foundation
import SQLite3

// MARK: - Pattern Types

enum LongitudinalPatternType: String, Codable, CaseIterable {
    case temporal     // time-of-day, day-of-week patterns
    case topical      // recurring themes/topics
    case behavioral   // mood cycles, productivity rhythms
}

struct DailySnapshot: Codable, Identifiable {
    let id: UUID
    let date: String              // YYYY-MM-DD
    let summary: String
    var sentimentScore: Double?
    var dominantTopics: [String]
    var behavioralMarkers: [String]
    let hour: Int                 // hour of day when most active
    let createdAt: Date
}

struct LongitudinalPattern: Codable, Identifiable {
    let id: UUID
    let patternType: LongitudinalPatternType
    let title: String
    let description: String
    var confidence: Double
    let firstDetected: Date
    var lastObserved: Date
    var occurrenceCount: Int
    let createdAt: Date
    var updatedAt: Date
}

// MARK: - Longitudinal Pattern Engine

/// Detects long-term behavioral patterns across days and weeks.
/// Analyzes daily snapshots to find: recurring topics at specific times,
/// mood cycles, productivity rhythms, and seasonal preferences.
@MainActor
final class LongitudinalPatternEngine {

    static let shared = LongitudinalPatternEngine()

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    /// Minimum snapshots needed before pattern detection kicks in
    private let minSnapshotsForDetection = 5

    private init() {
        do {
            try openDatabase()
            try createTables()
            isAvailable = true
        } catch {
            #if DEBUG
            print("[PATTERNS] DB init failed: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Record a daily snapshot from the day's conversation activity.
    /// Call at end of day or session to capture behavioral data.
    func recordSnapshot(
        summary: String,
        topics: [String],
        markers: [String],
        sentimentScore: Double?
    ) {
        guard isAvailable else { return }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: Date())
        let hour = Calendar.current.component(.hour, from: Date())

        let snapshot = DailySnapshot(
            id: UUID(),
            date: dateStr,
            summary: summary,
            sentimentScore: sentimentScore,
            dominantTopics: topics,
            behavioralMarkers: markers,
            hour: hour,
            createdAt: Date()
        )
        persistSnapshot(snapshot)
    }

    /// Record a lightweight snapshot from a single turn's data.
    /// Called each turn to accumulate daily behavioral signals.
    func recordTurnSignal(
        topic: String,
        affect: String,
        intentType: String
    ) {
        guard isAvailable else { return }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: Date())
        let hour = Calendar.current.component(.hour, from: Date())

        // Upsert today's snapshot with accumulated data
        if let existing = findSnapshot(date: dateStr) {
            // Merge topics
            var topics = existing.dominantTopics
            if !topics.contains(topic) && !topic.isEmpty { topics.append(topic) }
            if topics.count > 10 { topics = Array(topics.suffix(10)) }

            // Merge markers
            var markers = existing.behavioralMarkers
            let marker = "\(intentType):\(affect)"
            markers.append(marker)
            if markers.count > 20 { markers = Array(markers.suffix(20)) }

            updateSnapshot(id: existing.id, topics: topics, markers: markers)
        } else {
            let snapshot = DailySnapshot(
                id: UUID(),
                date: dateStr,
                summary: "Turn signal",
                sentimentScore: nil,
                dominantTopics: topic.isEmpty ? [] : [topic],
                behavioralMarkers: ["\(intentType):\(affect)"],
                hour: hour,
                createdAt: Date()
            )
            persistSnapshot(snapshot)
        }
    }

    /// Run pattern detection across accumulated daily snapshots.
    /// Call periodically (e.g. nightly or weekly).
    func detectPatterns() async {
        guard isAvailable else { return }

        let snapshots = recentSnapshots(limit: 30) // Last 30 days
        guard snapshots.count >= minSnapshotsForDetection else {
            #if DEBUG
            print("[PATTERNS] not enough snapshots for detection (\(snapshots.count)/\(minSnapshotsForDetection))")
            #endif
            return
        }

        let startedAt = CFAbsoluteTimeGetCurrent()

        // Temporal patterns
        detectTemporalPatterns(snapshots)

        // Topical patterns
        detectTopicalPatterns(snapshots)

        // Behavioral patterns
        detectBehavioralPatterns(snapshots)

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        #if DEBUG
        print("[PATTERNS] detection completed in \(elapsedMs)ms from \(snapshots.count) snapshots")
        #endif
    }

    /// Generate a prompt context block from detected patterns.
    func patternsContextBlock(limit: Int = 3) -> String {
        let patterns = topPatterns(limit: limit)
        guard !patterns.isEmpty else { return "" }
        let lines = patterns.map { p in
            "- \(p.title): \(p.description) (seen \(p.occurrenceCount)x, conf: \(String(format: "%.0f%%", p.confidence * 100)))"
        }
        return "Behavioral patterns:\n\(lines.joined(separator: "\n"))"
    }

    /// LLM-powered insight generation from patterns.
    func generateInsight() async -> String? {
        guard isAvailable else { return nil }

        let patterns = topPatterns(limit: 5)
        guard !patterns.isEmpty else { return nil }

        let patternsText = patterns.map { p in
            "[\(p.patternType.rawValue)] \(p.title): \(p.description) (confidence: \(String(format: "%.0f%%", p.confidence * 100)), occurrences: \(p.occurrenceCount))"
        }.joined(separator: "\n")

        let systemPrompt = "You analyze behavioral patterns and generate a single, actionable insight. Be concise (1-2 sentences max)."
        let userPrompt = "Patterns detected:\n\(patternsText)\n\nGenerate one useful insight."

        do {
            let raw = try await IntelligenceLLMClient.hybridJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                ollamaMaxTokens: 200,
                openAIMaxTokens: 300
            )
            if let parsed = IntelligenceLLMClient.parseJSON(raw),
               let insight = parsed["insight"] as? String {
                return insight
            }
            // Maybe raw text response
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            #if DEBUG
            print("[PATTERNS] insight generation failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Pattern Detection

    private func detectTemporalPatterns(_ snapshots: [DailySnapshot]) {
        // Find recurring activity at specific hours
        var hourCounts: [Int: Int] = [:]
        for s in snapshots {
            hourCounts[s.hour, default: 0] += 1
        }

        for (hour, count) in hourCounts where count >= 3 {
            let confidence = min(1.0, Double(count) / Double(snapshots.count))
            let timeLabel: String
            switch hour {
            case 5..<9: timeLabel = "early morning"
            case 9..<12: timeLabel = "morning"
            case 12..<14: timeLabel = "midday"
            case 14..<17: timeLabel = "afternoon"
            case 17..<20: timeLabel = "evening"
            case 20..<23: timeLabel = "late evening"
            default: timeLabel = "night"
            }
            upsertPattern(
                type: .temporal,
                title: "Active \(timeLabel)",
                description: "User is frequently active around \(hour):00 (\(count) of last \(snapshots.count) days)",
                confidence: confidence
            )
        }
    }

    private func detectTopicalPatterns(_ snapshots: [DailySnapshot]) {
        // Find recurring topics across days
        var topicCounts: [String: Int] = [:]
        for s in snapshots {
            for topic in s.dominantTopics {
                let normalized = topic.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    topicCounts[normalized, default: 0] += 1
                }
            }
        }

        for (topic, count) in topicCounts where count >= 3 {
            let confidence = min(1.0, Double(count) / Double(snapshots.count))
            upsertPattern(
                type: .topical,
                title: "Recurring topic: \(topic)",
                description: "The topic '\(topic)' comes up frequently (\(count) of last \(snapshots.count) days)",
                confidence: confidence
            )
        }
    }

    private func detectBehavioralPatterns(_ snapshots: [DailySnapshot]) {
        // Find recurring affect patterns
        var affectCounts: [String: Int] = [:]
        for s in snapshots {
            for marker in s.behavioralMarkers {
                let parts = marker.split(separator: ":")
                if parts.count >= 2 {
                    let affect = String(parts[1])
                    affectCounts[affect, default: 0] += 1
                }
            }
        }

        let totalMarkers = snapshots.flatMap(\.behavioralMarkers).count
        for (affect, count) in affectCounts where count >= 5 && affect != "neutral" {
            let ratio = Double(count) / Double(max(1, totalMarkers))
            if ratio > 0.15 {
                upsertPattern(
                    type: .behavioral,
                    title: "Mood pattern: \(affect)",
                    description: "User frequently shows '\(affect)' affect (\(String(format: "%.0f%%", ratio * 100)) of interactions)",
                    confidence: min(1.0, ratio * 2)
                )
            }
        }
    }

    // MARK: - Queries

    private func recentSnapshots(limit: Int) -> [DailySnapshot] {
        let sql = """
        SELECT id, date, summary, sentiment_score, dominant_topics, behavioral_markers, hour, created_at
        FROM daily_snapshots
        ORDER BY date DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [DailySnapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = decodeSnapshot(stmt) {
                results.append(s)
            }
        }
        return results
    }

    private func findSnapshot(date: String) -> DailySnapshot? {
        let sql = """
        SELECT id, date, summary, sentiment_score, dominant_topics, behavioral_markers, hour, created_at
        FROM daily_snapshots WHERE date = ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (date as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeSnapshot(stmt)
    }

    private func topPatterns(limit: Int) -> [LongitudinalPattern] {
        let sql = """
        SELECT id, pattern_type, title, description, confidence,
               first_detected, last_observed, occurrence_count, created_at, updated_at
        FROM longitudinal_patterns
        WHERE confidence >= 0.3
        ORDER BY (confidence * occurrence_count) DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [LongitudinalPattern] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = decodePattern(stmt) {
                results.append(p)
            }
        }
        return results
    }

    // MARK: - Persistence

    private func persistSnapshot(_ snapshot: DailySnapshot) {
        let sql = """
        INSERT OR REPLACE INTO daily_snapshots
        (id, date, summary, sentiment_score, dominant_topics, behavioral_markers, hour, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        let topicsJSON = (try? JSONSerialization.data(withJSONObject: snapshot.dominantTopics))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let markersJSON = (try? JSONSerialization.data(withJSONObject: snapshot.behavioralMarkers))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        sqlite3_bind_text(stmt, 1, (snapshot.id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (snapshot.date as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (snapshot.summary as NSString).utf8String, -1, nil)
        if let score = snapshot.sentimentScore {
            sqlite3_bind_double(stmt, 4, score)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_text(stmt, 5, (topicsJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (markersJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 7, Int32(snapshot.hour))
        sqlite3_bind_double(stmt, 8, snapshot.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func updateSnapshot(id: UUID, topics: [String], markers: [String]) {
        let sql = "UPDATE daily_snapshots SET dominant_topics = ?, behavioral_markers = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        let topicsJSON = (try? JSONSerialization.data(withJSONObject: topics))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let markersJSON = (try? JSONSerialization.data(withJSONObject: markers))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        sqlite3_bind_text(stmt, 1, (topicsJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (markersJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    private func upsertPattern(type: LongitudinalPatternType, title: String, description: String, confidence: Double) {
        // Check existing by title
        let checkSql = "SELECT id, occurrence_count FROM longitudinal_patterns WHERE title = ?;"
        var checkStmt: OpaquePointer?
        sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil)
        sqlite3_bind_text(checkStmt, 1, (title as NSString).utf8String, -1, nil)

        if sqlite3_step(checkStmt) == SQLITE_ROW {
            let existingID = String(cString: sqlite3_column_text(checkStmt, 0))
            sqlite3_finalize(checkStmt)

            let updateSql = """
            UPDATE longitudinal_patterns
            SET confidence = ?, occurrence_count = occurrence_count + 1,
                last_observed = ?, updated_at = ?, description = ?
            WHERE id = ?;
            """
            var updateStmt: OpaquePointer?
            defer { sqlite3_finalize(updateStmt) }
            guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(updateStmt, 1, confidence)
            sqlite3_bind_double(updateStmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_double(updateStmt, 3, Date().timeIntervalSince1970)
            sqlite3_bind_text(updateStmt, 4, (description as NSString).utf8String, -1, nil)
            sqlite3_bind_text(updateStmt, 5, (existingID as NSString).utf8String, -1, nil)
            sqlite3_step(updateStmt)
        } else {
            sqlite3_finalize(checkStmt)

            let insertSql = """
            INSERT INTO longitudinal_patterns
            (id, pattern_type, title, description, confidence,
             first_detected, last_observed, occurrence_count, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?);
            """
            var insertStmt: OpaquePointer?
            defer { sqlite3_finalize(insertStmt) }
            guard sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else { return }

            let now = Date().timeIntervalSince1970
            sqlite3_bind_text(insertStmt, 1, (UUID().uuidString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 2, (type.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 3, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 4, (description as NSString).utf8String, -1, nil)
            sqlite3_bind_double(insertStmt, 5, confidence)
            sqlite3_bind_double(insertStmt, 6, now)
            sqlite3_bind_double(insertStmt, 7, now)
            sqlite3_bind_double(insertStmt, 8, now)
            sqlite3_bind_double(insertStmt, 9, now)
            sqlite3_step(insertStmt)
        }
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
        CREATE TABLE IF NOT EXISTS daily_snapshots (
            id TEXT PRIMARY KEY,
            date TEXT NOT NULL UNIQUE,
            summary TEXT NOT NULL,
            sentiment_score REAL,
            dominant_topics TEXT DEFAULT '[]',
            behavioral_markers TEXT DEFAULT '[]',
            hour INTEGER DEFAULT 12,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_daily_snapshots_date ON daily_snapshots(date);
        CREATE TABLE IF NOT EXISTS longitudinal_patterns (
            id TEXT PRIMARY KEY,
            pattern_type TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            confidence REAL NOT NULL,
            first_detected REAL NOT NULL,
            last_observed REAL NOT NULL,
            occurrence_count INTEGER DEFAULT 1,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_patterns_type ON longitudinal_patterns(pattern_type);
        CREATE INDEX IF NOT EXISTS idx_patterns_confidence ON longitudinal_patterns(confidence);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("Pattern tables creation failed")
        }
    }

    // MARK: - Row Decoding

    private func decodeSnapshot(_ stmt: OpaquePointer?) -> DailySnapshot? {
        guard let stmt else { return nil }
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr) else { return nil }

        let date = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let summary = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let sentimentScore: Double? = sqlite3_column_type(stmt, 3) != SQLITE_NULL
            ? sqlite3_column_double(stmt, 3) : nil
        let topicsRaw = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "[]"
        let markersRaw = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "[]"
        let hour = Int(sqlite3_column_int(stmt, 6))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))

        let topics = (try? JSONSerialization.jsonObject(with: Data(topicsRaw.utf8)) as? [String]) ?? []
        let markers = (try? JSONSerialization.jsonObject(with: Data(markersRaw.utf8)) as? [String]) ?? []

        return DailySnapshot(
            id: id, date: date, summary: summary, sentimentScore: sentimentScore,
            dominantTopics: topics, behavioralMarkers: markers, hour: hour, createdAt: createdAt
        )
    }

    private func decodePattern(_ stmt: OpaquePointer?) -> LongitudinalPattern? {
        guard let stmt else { return nil }
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr) else { return nil }

        let typeStr = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "behavioral"
        let type = LongitudinalPatternType(rawValue: typeStr) ?? .behavioral
        let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let description = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let confidence = sqlite3_column_double(stmt, 4)
        let firstDetected = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let lastObserved = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let occurrenceCount = Int(sqlite3_column_int(stmt, 7))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))

        return LongitudinalPattern(
            id: id, patternType: type, title: title, description: description,
            confidence: confidence, firstDetected: firstDetected, lastObserved: lastObserved,
            occurrenceCount: occurrenceCount, createdAt: createdAt, updatedAt: updatedAt
        )
    }
}
