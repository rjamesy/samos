import Foundation
import SQLite3

// MARK: - Meta-Cognition Types

struct ConfidenceAssessment: Codable {
    let messageID: String
    let confidence: Double       // 0.0-1.0
    let assumptions: [String]
    let reasoning: String
    let createdAt: Date
}

// MARK: - Meta-Cognition Engine

/// Tracks Sam's confidence, calibration, and epistemic humility.
/// Assesses uncertainty on every response, tracks prediction accuracy over time,
/// and injects uncertainty-aware guidance into the system prompt.
@MainActor
final class MetaCognitionEngine {

    static let shared = MetaCognitionEngine()

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    /// Rolling calibration stats
    private var confidentCorrect: Int = 0
    private var confidentWrong: Int = 0
    private var recentConfidences: [Double] = []

    /// EMA smoothing for calibration
    private let calibrationAlpha: Double = 0.15

    private init() {
        do {
            try openDatabase()
            try createTables()
            isAvailable = true
            loadCalibration()
        } catch {
            #if DEBUG
            print("[METACOG] DB init failed: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Evaluate Sam's response confidence. Call after generating a response.
    func evaluateResponse(messageID: String, userQuery: String, assistantResponse: String) async {
        guard isAvailable else { return }

        let systemPrompt = """
        You assess the confidence and assumptions in an AI assistant's response.
        Return ONLY valid JSON:
        {
          "confidence": 0.0-1.0,
          "assumptions": ["things assumed but not verified"],
          "reasoning": "why this confidence level (1 sentence)"
        }
        High confidence = factual, verifiable, within expertise.
        Low confidence = speculative, subjective, outside knowledge, or stale info.
        """
        let userPrompt = "User asked: \"\(userQuery)\"\nAssistant replied: \"\(assistantResponse.prefix(500))\""

        do {
            let raw = try await IntelligenceLLMClient.engineJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 250
            )
            guard let parsed = IntelligenceLLMClient.parseJSON(raw) else { return }

            let confidence = (parsed["confidence"] as? NSNumber)?.doubleValue ?? 0.5
            let assumptions = parsed["assumptions"] as? [String] ?? []
            let reasoning = parsed["reasoning"] as? String ?? ""

            persistResponse(messageID: messageID, confidence: confidence, assumptions: assumptions, reasoning: reasoning)
            recentConfidences.append(confidence)
            if recentConfidences.count > 20 { recentConfidences.removeFirst() }

            #if DEBUG
            print("[METACOG] message=\(messageID) confidence=\(String(format: "%.2f", confidence)) assumptions=\(assumptions.count)")
            #endif
        } catch {
            #if DEBUG
            print("[METACOG] evaluation failed: \(error)")
            #endif
        }
    }

    /// Record user feedback signal for calibration tracking.
    func recordFeedback(messageID: String, isPositive: Bool) {
        guard isAvailable else { return }

        // Look up the confidence for this message
        let sql = "SELECT confidence FROM meta_responses WHERE message_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (messageID as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return }

        let confidence = sqlite3_column_double(stmt, 0)

        // Only track calibration for confident predictions
        if confidence >= 0.7 {
            if isPositive {
                confidentCorrect += 1
            } else {
                confidentWrong += 1
            }
            persistCalibration()
        }

        // Persist feedback
        let fbSQL = "INSERT INTO meta_feedback (id, message_id, is_positive, created_at) VALUES (?, ?, ?, ?);"
        var fbStmt: OpaquePointer?
        defer { sqlite3_finalize(fbStmt) }
        guard sqlite3_prepare_v2(db, fbSQL, -1, &fbStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(fbStmt, 1, (UUID().uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(fbStmt, 2, (messageID as NSString).utf8String, -1, nil)
        sqlite3_bind_int(fbStmt, 3, isPositive ? 1 : 0)
        sqlite3_bind_double(fbStmt, 4, Date().timeIntervalSince1970)
        sqlite3_step(fbStmt)
    }

    /// Build uncertainty-aware context for prompt injection.
    func uncertaintyContextBlock() -> String {
        let avgConfidence = recentConfidences.isEmpty ? 0.5 : recentConfidences.reduce(0, +) / Double(recentConfidences.count)
        let calibrationScore = calibrationScore()

        var lines: [String] = []

        // Confidence guidance
        if avgConfidence < 0.4 {
            lines.append("Sam's recent confidence is LOW. Use hedging: \"I think...\", \"I might be wrong but...\", \"From what I know...\"")
        } else if avgConfidence < 0.6 {
            lines.append("Sam's recent confidence is MODERATE. Be honest about uncertainty when it exists.")
        } else {
            lines.append("Sam's recent confidence is HIGH. Speak with assurance but remain open to correction.")
        }

        // Calibration guidance
        if calibrationScore < 0.5 && (confidentCorrect + confidentWrong) >= 5 {
            lines.append("CALIBRATION WARNING: Sam has been overconfident recently. Double-check claims before stating them as fact.")
        } else if calibrationScore > 0.8 && (confidentCorrect + confidentWrong) >= 5 {
            lines.append("Sam's calibration is good — confident predictions have been accurate.")
        }

        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    /// Current calibration score (0.0-1.0). Higher = better calibrated.
    func calibrationScore() -> Double {
        let total = confidentCorrect + confidentWrong
        guard total > 0 else { return 0.5 }
        return Double(confidentCorrect) / Double(total)
    }

    // MARK: - Persistence

    private func persistResponse(messageID: String, confidence: Double, assumptions: [String], reasoning: String) {
        let assumptionsJSON = (try? JSONSerialization.data(withJSONObject: assumptions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sql = "INSERT OR REPLACE INTO meta_responses (message_id, confidence, assumptions_json, reasoning, created_at) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (messageID as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, confidence)
        sqlite3_bind_text(stmt, 3, (assumptionsJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (reasoning as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func persistCalibration() {
        let sql = "INSERT OR REPLACE INTO meta_calibration (id, confident_correct, confident_wrong, updated_at) VALUES ('singleton', ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int(stmt, 1, Int32(confidentCorrect))
        sqlite3_bind_int(stmt, 2, Int32(confidentWrong))
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func loadCalibration() {
        let sql = "SELECT confident_correct, confident_wrong FROM meta_calibration WHERE id = 'singleton';"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        if sqlite3_step(stmt) == SQLITE_ROW {
            confidentCorrect = Int(sqlite3_column_int(stmt, 0))
            confidentWrong = Int(sqlite3_column_int(stmt, 1))
        }
    }

    // MARK: - SQLite

    private func openDatabase() throws {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SamOS")
        if !fm.fileExists(atPath: dir.path) { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let path = dir.appendingPathComponent("intelligence.sqlite3").path
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("DB open failed")
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
    }

    private func createTables() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS meta_responses (
            message_id TEXT PRIMARY KEY, confidence REAL NOT NULL, assumptions_json TEXT, reasoning TEXT, created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meta_feedback (
            id TEXT PRIMARY KEY, message_id TEXT NOT NULL, is_positive INTEGER NOT NULL, created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meta_calibration (
            id TEXT PRIMARY KEY, confident_correct INTEGER DEFAULT 0, confident_wrong INTEGER DEFAULT 0, updated_at REAL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("MetaCognition tables creation failed")
        }
    }
}
