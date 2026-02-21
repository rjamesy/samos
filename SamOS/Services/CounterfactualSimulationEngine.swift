import Foundation
import SQLite3

// MARK: - Counterfactual Types

struct CounterfactualBranch: Codable {
    let label: String           // e.g. "Accept the offer", "Negotiate terms", "Decline"
    let shortTermOutcome: String
    let longTermOutcome: String
    let riskLevel: String       // low, medium, high
    let score: Double           // 0.0-1.0 overall desirability
}

struct CounterfactualResult {
    let turnID: String
    let decision: String
    let branches: [CounterfactualBranch]
    let recommendation: String
    let tradeoffs: String
    let createdAt: Date
}

// MARK: - Counterfactual Simulation Engine

/// Detects decisions/dilemmas and simulates forward outcomes.
/// Stage 1 (Ollama): Fast detection — is this a decision?
/// Stage 2 (GPT-5.2): Branch generation and forward simulation with scoring.
/// Results inject advisory context into Sam's system prompt.
@MainActor
final class CounterfactualSimulationEngine {

    static let shared = CounterfactualSimulationEngine()

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    /// Throttle: max one simulation per 30 seconds
    private var lastSimulationAt: Date = .distantPast

    /// Cache the most recent result for prompt injection
    private var lastResult: CounterfactualResult?

    private init() {
        do {
            try openDatabase()
            try createTables()
            isAvailable = true
        } catch {
            #if DEBUG
            print("[COUNTERFACTUAL] DB init failed: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Process a turn: detect if it contains a decision, simulate if so.
    /// Returns nil if no decision detected or throttled.
    func processTurn(turnID: String, userInput: String) async -> CounterfactualResult? {
        guard isAvailable else { return nil }

        // Throttle
        guard Date().timeIntervalSince(lastSimulationAt) > 30 else { return nil }

        // Stage 1: Fast decision detection via Ollama
        let isDecision = await detectDecision(userInput: userInput)
        guard isDecision else { return nil }

        // Stage 2: Branch generation and simulation via GPT
        let result = await simulate(turnID: turnID, userInput: userInput)

        if let result {
            lastResult = result
            lastSimulationAt = Date()
            persist(result)

            #if DEBUG
            print("[COUNTERFACTUAL] turn=\(turnID) branches=\(result.branches.count) recommendation=\(result.recommendation.prefix(60))")
            #endif
        }

        return result
    }

    /// Build a prompt context block from the most recent simulation.
    func simulationContextBlock() -> String {
        guard let result = lastResult else { return "" }

        // Only inject if recent (within last 5 minutes)
        guard Date().timeIntervalSince(result.createdAt) < 300 else { return "" }

        var lines: [String] = ["Sam's analysis of the user's decision:"]
        lines.append("Decision: \(result.decision)")
        for branch in result.branches.prefix(3) {
            let risk = branch.riskLevel
            lines.append("- \(branch.label) (risk: \(risk), score: \(String(format: "%.0f", branch.score * 100))%): \(branch.shortTermOutcome)")
        }
        lines.append("Recommendation: \(result.recommendation)")
        if !result.tradeoffs.isEmpty {
            lines.append("Tradeoffs: \(result.tradeoffs)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Stage 1: Decision Detection (Ollama — fast)

    private func detectDecision(userInput: String) async -> Bool {
        let systemPrompt = """
        You classify whether user input contains a decision, dilemma, or choice the user needs help with.
        Return ONLY valid JSON: {"is_decision": true/false}
        A decision means the user is weighing options, asking for advice on a choice, or facing a dilemma.
        Simple questions, facts, greetings, and status updates are NOT decisions.
        """
        let userPrompt = "User said: \"\(userInput)\""

        do {
            let raw = try await IntelligenceLLMClient.engineJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 120
            )
            if let parsed = IntelligenceLLMClient.parseJSON(raw),
               let isDecision = parsed["is_decision"] as? Bool {
                return isDecision
            }
        } catch {
            #if DEBUG
            print("[COUNTERFACTUAL] detection failed: \(error)")
            #endif
        }
        return false
    }

    // MARK: - Stage 2: Simulation (GPT-5.2)

    private func simulate(turnID: String, userInput: String) async -> CounterfactualResult? {
        let systemPrompt = """
        You are a strategic advisor simulating possible outcomes for a decision.
        The user is facing a choice. Generate 2-3 possible action paths, simulate forward outcomes for each, and recommend the best option.
        Return ONLY valid JSON:
        {
          "decision": "what the user is deciding (1 sentence)",
          "branches": [
            {
              "label": "action path name",
              "short_term_outcome": "what happens in days/weeks",
              "long_term_outcome": "what happens in months",
              "risk_level": "low/medium/high",
              "score": 0.0-1.0
            }
          ],
          "recommendation": "which path and why (2 sentences max)",
          "tradeoffs": "key tradeoff to consider (1 sentence)"
        }
        """
        let userPrompt = "The user said: \"\(userInput)\"\n\nSimulate 2-3 possible paths forward and score them."

        do {
            let raw = try await IntelligenceLLMClient.openAIJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 1200
            )
            guard let parsed = IntelligenceLLMClient.parseJSON(raw) else { return nil }

            let decision = parsed["decision"] as? String ?? userInput
            let recommendation = parsed["recommendation"] as? String ?? ""
            let tradeoffs = parsed["tradeoffs"] as? String ?? ""

            var branches: [CounterfactualBranch] = []
            if let branchArray = parsed["branches"] as? [[String: Any]] {
                for b in branchArray.prefix(3) {
                    branches.append(CounterfactualBranch(
                        label: b["label"] as? String ?? "Option",
                        shortTermOutcome: b["short_term_outcome"] as? String ?? "",
                        longTermOutcome: b["long_term_outcome"] as? String ?? "",
                        riskLevel: b["risk_level"] as? String ?? "medium",
                        score: (b["score"] as? NSNumber)?.doubleValue ?? 0.5
                    ))
                }
            }

            guard !branches.isEmpty else { return nil }

            return CounterfactualResult(
                turnID: turnID,
                decision: decision,
                branches: branches,
                recommendation: recommendation,
                tradeoffs: tradeoffs,
                createdAt: Date()
            )
        } catch {
            #if DEBUG
            print("[COUNTERFACTUAL] simulation failed: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Persistence

    private func persist(_ result: CounterfactualResult) {
        let decisionID = UUID().uuidString
        let sql = """
        INSERT INTO counterfactual_decisions (id, turn_id, decision, recommendation, tradeoffs, created_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (decisionID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (result.turnID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (result.decision as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (result.recommendation as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (result.tradeoffs as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 6, result.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)

        for branch in result.branches {
            let branchSQL = """
            INSERT INTO counterfactual_branches (id, decision_id, label, short_term, long_term, risk_level, score)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            var bStmt: OpaquePointer?
            defer { sqlite3_finalize(bStmt) }
            guard sqlite3_prepare_v2(db, branchSQL, -1, &bStmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(bStmt, 1, (UUID().uuidString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(bStmt, 2, (decisionID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(bStmt, 3, (branch.label as NSString).utf8String, -1, nil)
            sqlite3_bind_text(bStmt, 4, (branch.shortTermOutcome as NSString).utf8String, -1, nil)
            sqlite3_bind_text(bStmt, 5, (branch.longTermOutcome as NSString).utf8String, -1, nil)
            sqlite3_bind_text(bStmt, 6, (branch.riskLevel as NSString).utf8String, -1, nil)
            sqlite3_bind_double(bStmt, 7, branch.score)
            sqlite3_step(bStmt)
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
        CREATE TABLE IF NOT EXISTS counterfactual_decisions (
            id TEXT PRIMARY KEY,
            turn_id TEXT NOT NULL,
            decision TEXT NOT NULL,
            recommendation TEXT,
            tradeoffs TEXT,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cf_decisions_created ON counterfactual_decisions(created_at);
        CREATE TABLE IF NOT EXISTS counterfactual_branches (
            id TEXT PRIMARY KEY,
            decision_id TEXT NOT NULL,
            label TEXT NOT NULL,
            short_term TEXT,
            long_term TEXT,
            risk_level TEXT DEFAULT 'medium',
            score REAL DEFAULT 0.5,
            FOREIGN KEY(decision_id) REFERENCES counterfactual_decisions(id)
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("Counterfactual tables creation failed")
        }
    }
}
