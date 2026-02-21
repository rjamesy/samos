import Foundation
import SQLite3

// MARK: - Strategy Outcome Types

enum OutcomeSignal: String, Codable {
    case positive   // user thanks, continues topic, uses result
    case neutral    // topic change, no feedback
    case negative   // user corrects, expresses frustration, retries
}

struct StrategyOutcome: Codable, Identifiable {
    let id: UUID
    let strategyName: String       // e.g. "ollama_direct", "openai_fallback", "tool_first", "talk_only"
    let category: String           // e.g. "routing", "response_style", "tool_selection"
    let intentType: String         // matched ConversationIntent rawValue
    let signal: OutcomeSignal
    let compositeScore: Double     // 0.0-1.0
    let routerMs: Int?
    let turnID: String
    let createdAt: Date
}

struct StrategyMetrics: Codable {
    let strategyName: String
    let category: String
    var emaScore: Double           // EMA of composite scores
    var emaSuccessRate: Double     // EMA of success (positive signals)
    var sampleCount: Int
    var lastUpdated: Date
}

// MARK: - Skill Evolution Loop

/// Tracks which response strategies work best and adapts over time.
/// Observes outcome signals (positive/neutral/negative) and adjusts strategy weights
/// using Exponential Moving Average scoring with exploration bonuses.
@MainActor
final class SkillEvolutionLoop {

    static let shared = SkillEvolutionLoop()

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    /// EMA smoothing factor — 0.25 balances recent vs historical
    private let alpha: Double = 0.25

    private init() {
        do {
            try openDatabase()
            try createTables()
            isAvailable = true
        } catch {
            #if DEBUG
            print("[EVOLUTION] DB init failed: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Record the outcome of a strategy used in a turn.
    func recordOutcome(
        strategyName: String,
        category: String,
        intentType: String,
        signal: OutcomeSignal,
        routerMs: Int?,
        turnID: String
    ) {
        guard isAvailable else { return }

        let score = compositeScore(signal: signal, routerMs: routerMs)
        let outcome = StrategyOutcome(
            id: UUID(),
            strategyName: strategyName,
            category: category,
            intentType: intentType,
            signal: signal,
            compositeScore: score,
            routerMs: routerMs,
            turnID: turnID,
            createdAt: Date()
        )
        persistOutcome(outcome)
        updateMetrics(strategyName: strategyName, category: category, newScore: score, isSuccess: signal == .positive)

        #if DEBUG
        print("[EVOLUTION] recorded strategy=\(strategyName) signal=\(signal.rawValue) score=\(String(format: "%.2f", score))")
        #endif
    }

    /// Detect outcome signals from user's next turn.
    /// Call with the new user text and info about the previous turn.
    func detectSignal(userText: String, previousStrategy: String?) -> OutcomeSignal {
        let lower = userText.lowercased()

        // Positive signals
        let positiveMarkers = [
            "thanks", "thank you", "great", "perfect", "awesome", "nice",
            "that's what i needed", "exactly", "cool", "good", "helpful",
            "yes", "yep", "yeah", "correct", "right"
        ]
        if positiveMarkers.contains(where: { lower.contains($0) }) {
            return .positive
        }

        // Negative signals
        let negativeMarkers = [
            "no that's wrong", "that's not right", "wrong", "incorrect",
            "that's not what i", "i said", "try again", "not helpful",
            "frustrated", "annoying", "useless", "stupid"
        ]
        if negativeMarkers.contains(where: { lower.contains($0) }) {
            return .negative
        }

        return .neutral
    }

    /// Recommend the best strategy for a given category and intent.
    /// Returns the strategy name with the highest EMA score, or nil if no data.
    func recommendStrategy(category: String, intentType: String? = nil) -> String? {
        guard isAvailable else { return nil }

        let metrics = loadMetricsForCategory(category)
        guard !metrics.isEmpty else { return nil }

        // Score with exploration bonus (UCB)
        let totalTrials = metrics.reduce(0) { $0 + $1.sampleCount }
        guard totalTrials > 0 else { return nil }

        let scored = metrics.map { m -> (name: String, score: Double) in
            let base = 0.6 * m.emaScore + 0.4 * m.emaSuccessRate
            let explorationBonus = m.sampleCount > 0
                ? sqrt(log(Double(totalTrials)) / Double(m.sampleCount))
                : 1.0
            let final = base + 0.15 * explorationBonus
            return (m.strategyName, final)
        }

        let best = scored.max(by: { $0.score < $1.score })

        #if DEBUG
        if let best {
            print("[EVOLUTION] recommend category=\(category) strategy=\(best.name) score=\(String(format: "%.3f", best.score))")
        }
        #endif

        return best?.name
    }

    /// Get current metrics for all strategies (for diagnostics).
    func allMetrics() -> [StrategyMetrics] {
        guard isAvailable else { return [] }
        let sql = """
        SELECT strategy_name, category, ema_score, ema_success_rate, sample_count, last_updated
        FROM strategy_metrics
        ORDER BY ema_score DESC;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var results: [StrategyMetrics] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let m = decodeMetrics(stmt) {
                results.append(m)
            }
        }
        return results
    }

    // MARK: - Scoring

    private func compositeScore(signal: OutcomeSignal, routerMs: Int?) -> Double {
        let signalScore: Double
        switch signal {
        case .positive: signalScore = 1.0
        case .neutral: signalScore = 0.5
        case .negative: signalScore = 0.0
        }

        // Efficiency bonus — faster responses score slightly higher
        let efficiencyBonus: Double
        if let ms = routerMs {
            // Under 500ms is great, over 3000ms is poor
            efficiencyBonus = max(0, min(0.2, 0.2 * (1.0 - Double(ms) / 3000.0)))
        } else {
            efficiencyBonus = 0.1
        }

        return min(1.0, signalScore * 0.8 + efficiencyBonus)
    }

    private func ema(old: Double, new: Double) -> Double {
        alpha * new + (1 - alpha) * old
    }

    // MARK: - Persistence

    private func persistOutcome(_ outcome: StrategyOutcome) {
        let sql = """
        INSERT INTO strategy_outcomes
        (id, strategy_name, category, intent_type, signal, composite_score, router_ms, turn_id, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (outcome.id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (outcome.strategyName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (outcome.category as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (outcome.intentType as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (outcome.signal.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 6, outcome.compositeScore)
        if let ms = outcome.routerMs {
            sqlite3_bind_int(stmt, 7, Int32(ms))
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_text(stmt, 8, (outcome.turnID as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 9, outcome.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func updateMetrics(strategyName: String, category: String, newScore: Double, isSuccess: Bool) {
        let checkSql = "SELECT ema_score, ema_success_rate, sample_count FROM strategy_metrics WHERE strategy_name = ? AND category = ?;"
        var checkStmt: OpaquePointer?
        sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil)
        sqlite3_bind_text(checkStmt, 1, (strategyName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(checkStmt, 2, (category as NSString).utf8String, -1, nil)

        if sqlite3_step(checkStmt) == SQLITE_ROW {
            let oldEmaScore = sqlite3_column_double(checkStmt, 0)
            let oldSuccessRate = sqlite3_column_double(checkStmt, 1)
            let sampleCount = Int(sqlite3_column_int(checkStmt, 2))
            sqlite3_finalize(checkStmt)

            let newEma = ema(old: oldEmaScore, new: newScore)
            let newSuccessRate = ema(old: oldSuccessRate, new: isSuccess ? 1.0 : 0.0)

            let updateSql = """
            UPDATE strategy_metrics
            SET ema_score = ?, ema_success_rate = ?, sample_count = ?, last_updated = ?
            WHERE strategy_name = ? AND category = ?;
            """
            var updateStmt: OpaquePointer?
            defer { sqlite3_finalize(updateStmt) }
            guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(updateStmt, 1, newEma)
            sqlite3_bind_double(updateStmt, 2, newSuccessRate)
            sqlite3_bind_int(updateStmt, 3, Int32(sampleCount + 1))
            sqlite3_bind_double(updateStmt, 4, Date().timeIntervalSince1970)
            sqlite3_bind_text(updateStmt, 5, (strategyName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(updateStmt, 6, (category as NSString).utf8String, -1, nil)
            sqlite3_step(updateStmt)
        } else {
            sqlite3_finalize(checkStmt)

            let insertSql = """
            INSERT INTO strategy_metrics
            (strategy_name, category, ema_score, ema_success_rate, sample_count, last_updated)
            VALUES (?, ?, ?, ?, 1, ?);
            """
            var insertStmt: OpaquePointer?
            defer { sqlite3_finalize(insertStmt) }
            guard sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(insertStmt, 1, (strategyName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 2, (category as NSString).utf8String, -1, nil)
            sqlite3_bind_double(insertStmt, 3, newScore)
            sqlite3_bind_double(insertStmt, 4, isSuccess ? 1.0 : 0.0)
            sqlite3_bind_double(insertStmt, 5, Date().timeIntervalSince1970)
            sqlite3_step(insertStmt)
        }
    }

    private func loadMetricsForCategory(_ category: String) -> [StrategyMetrics] {
        let sql = """
        SELECT strategy_name, category, ema_score, ema_success_rate, sample_count, last_updated
        FROM strategy_metrics
        WHERE category = ? AND sample_count >= 3
        ORDER BY ema_score DESC;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, (category as NSString).utf8String, -1, nil)

        var results: [StrategyMetrics] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let m = decodeMetrics(stmt) {
                results.append(m)
            }
        }
        return results
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
        CREATE TABLE IF NOT EXISTS strategy_outcomes (
            id TEXT PRIMARY KEY,
            strategy_name TEXT NOT NULL,
            category TEXT NOT NULL,
            intent_type TEXT NOT NULL,
            signal TEXT NOT NULL,
            composite_score REAL NOT NULL,
            router_ms INTEGER,
            turn_id TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_strategy_outcomes_strategy ON strategy_outcomes(strategy_name);
        CREATE INDEX IF NOT EXISTS idx_strategy_outcomes_created ON strategy_outcomes(created_at);
        CREATE TABLE IF NOT EXISTS strategy_metrics (
            strategy_name TEXT NOT NULL,
            category TEXT NOT NULL,
            ema_score REAL NOT NULL,
            ema_success_rate REAL NOT NULL,
            sample_count INTEGER NOT NULL,
            last_updated REAL NOT NULL,
            PRIMARY KEY (strategy_name, category)
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("Strategy tables creation failed")
        }
    }

    private func decodeMetrics(_ stmt: OpaquePointer?) -> StrategyMetrics? {
        guard let stmt else { return nil }
        let strategyName = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let category = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let emaScore = sqlite3_column_double(stmt, 2)
        let emaSuccessRate = sqlite3_column_double(stmt, 3)
        let sampleCount = Int(sqlite3_column_int(stmt, 4))
        let lastUpdated = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))

        return StrategyMetrics(
            strategyName: strategyName, category: category,
            emaScore: emaScore, emaSuccessRate: emaSuccessRate,
            sampleCount: sampleCount, lastUpdated: lastUpdated
        )
    }
}
