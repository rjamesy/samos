import Foundation
import SQLite3

// MARK: - Causal Learning Types

struct CausalVariable {
    let id: Int64
    let name: String
    let category: String       // sleep, mood, productivity, diet, exercise, stress, etc.
}

struct CausalEdge {
    let fromID: Int64
    let toID: Int64
    var alpha: Double          // Bayesian alpha (successes)
    var beta: Double           // Bayesian beta (failures)
    var evidenceCount: Int

    /// Belief strength: P(cause → effect)
    var weight: Double { alpha / (alpha + beta) }

    /// Confidence in the weight estimate
    var confidence: Double { min(1.0, log(alpha + beta) / 5.0) }
}

struct CausalExperiment {
    let id: Int64
    let hypothesis: String
    let interventionVarID: Int64
    let outcomeVarID: Int64
    let interventionType: String  // increase, decrease, eliminate
    var status: String            // proposed, active, completed
    var result: String?           // supported, rejected, inconclusive
    let createdAt: Date
}

// MARK: - Causal Learning Engine

/// Builds and maintains a causal graph of user behavior variables.
/// Tracks co-occurrences, user-stated causes, proposes micro-experiments,
/// and updates causal weights via Bayesian updating.
@MainActor
final class CausalLearningEngine {

    static let shared = CausalLearningEngine()

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    /// In-memory causal graph
    private var variables: [Int64: CausalVariable] = [:]
    private var edges: [String: CausalEdge] = [:]  // key: "fromID_toID"

    /// Cooldown for experiment proposals
    private var lastExperimentProposalAt: Date = .distantPast

    private init() {
        do {
            try openDatabase()
            try createTables()
            isAvailable = true
            loadGraph()
        } catch {
            #if DEBUG
            print("[CAUSAL] DB init failed: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Ingest a conversation turn: extract variables, observations, and causal claims.
    func ingestConversation(turnID: String, userText: String) async {
        guard isAvailable else { return }

        let systemPrompt = """
        Extract behavioral variables, their values, and causal relationships from conversation.
        Return ONLY valid JSON:
        {
          "variables": [{"name": "sleep quality", "value": 7, "category": "sleep"}],
          "causal_claims": [{"from": "coffee intake", "to": "sleep quality", "direction": "negative"}]
        }
        Variables are things like: sleep quality, mood, energy, exercise, stress, coffee, screen time, etc.
        Values are 0-10 scale. Only extract what's explicitly or clearly implied in the text.
        If nothing relevant, return {"variables": [], "causal_claims": []}.
        """
        let userPrompt = "Text: \"\(userText)\""

        do {
            let raw = try await IntelligenceLLMClient.engineJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 400
            )
            guard let parsed = IntelligenceLLMClient.parseJSON(raw) else { return }

            // Process variables and observations
            if let vars = parsed["variables"] as? [[String: Any]] {
                for v in vars {
                    guard let name = v["name"] as? String, !name.isEmpty else { continue }
                    let category = v["category"] as? String ?? "other"
                    let value = (v["value"] as? NSNumber)?.doubleValue ?? 5.0
                    let varID = ensureVariable(name: name, category: category)
                    recordObservation(variableID: varID, value: value, source: "inferred")
                }
            }

            // Process causal claims
            if let claims = parsed["causal_claims"] as? [[String: Any]] {
                for claim in claims {
                    guard let fromName = claim["from"] as? String,
                          let toName = claim["to"] as? String else { continue }
                    let direction = claim["direction"] as? String ?? "positive"
                    let fromID = ensureVariable(name: fromName, category: "")
                    let toID = ensureVariable(name: toName, category: "")
                    strengthenEdge(fromID: fromID, toID: toID, supported: direction != "negative")
                }
            }

            #if DEBUG
            let varCount = (parsed["variables"] as? [[String: Any]])?.count ?? 0
            let claimCount = (parsed["causal_claims"] as? [[String: Any]])?.count ?? 0
            if varCount > 0 || claimCount > 0 {
                print("[CAUSAL] turn=\(turnID) vars=\(varCount) claims=\(claimCount)")
            }
            #endif
        } catch {
            #if DEBUG
            print("[CAUSAL] ingestion failed: \(error)")
            #endif
        }
    }

    /// Propose a micro-experiment if there are uncertain edges.
    func proposeExperiment() async -> String? {
        guard isAvailable else { return nil }
        guard Date().timeIntervalSince(lastExperimentProposalAt) > 86400 else { return nil } // Max 1/day

        // Find the most uncertain high-evidence edge
        let uncertain = edges.values.filter {
            abs($0.weight - 0.5) < 0.15 && $0.confidence < 0.4 && $0.evidenceCount >= 3
        }.sorted { $0.evidenceCount > $1.evidenceCount }

        guard let edge = uncertain.first,
              let fromVar = variables[edge.fromID],
              let toVar = variables[edge.toID] else { return nil }

        let systemPrompt = """
        Design a safe, simple behavioral micro-experiment for the user.
        Return ONLY valid JSON:
        {"experiment": "what to try (1 sentence)", "duration": "how long (e.g. '2 days')", "measure": "what to observe"}
        Keep it practical and reversible.
        """
        let userPrompt = "Uncertain causal link: \(fromVar.name) → \(toVar.name) (belief: \(String(format: "%.2f", edge.weight)), confidence: \(String(format: "%.2f", edge.confidence)))"

        do {
            let raw = try await IntelligenceLLMClient.engineJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 200
            )
            if let parsed = IntelligenceLLMClient.parseJSON(raw),
               let experiment = parsed["experiment"] as? String {
                lastExperimentProposalAt = Date()
                persistExperiment(hypothesis: "\(fromVar.name) → \(toVar.name)", interventionVarID: edge.fromID,
                                  outcomeVarID: edge.toID, interventionType: "modify")
                return experiment
            }
        } catch {
            #if DEBUG
            print("[CAUSAL] experiment proposal failed: \(error)")
            #endif
        }
        return nil
    }

    /// Build causal insights block for prompt injection.
    func causalInsightsBlock() -> String {
        let strongEdges = edges.values
            .filter { $0.confidence >= 0.3 && $0.evidenceCount >= 3 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)

        guard !strongEdges.isEmpty else { return "" }

        var lines = ["Behavioral cause-effect patterns Sam has observed:"]
        for edge in strongEdges {
            let fromName = variables[edge.fromID]?.name ?? "?"
            let toName = variables[edge.toID]?.name ?? "?"
            let direction = edge.weight > 0.6 ? "positively affects" : edge.weight < 0.4 ? "negatively affects" : "may affect"
            lines.append("- \(fromName) \(direction) \(toName) (confidence: \(String(format: "%.0f%%", edge.confidence * 100)))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Graph Operations

    private func ensureVariable(name: String, category: String) -> Int64 {
        let canonical = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = variables.values.first(where: { $0.name.lowercased() == canonical }) {
            return existing.id
        }

        let sql = "INSERT OR IGNORE INTO causal_variables (name, category, created_at) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        sqlite3_bind_text(stmt, 1, (canonical as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (category as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_step(stmt)

        let id = sqlite3_last_insert_rowid(db)
        variables[id] = CausalVariable(id: id, name: canonical, category: category)
        return id
    }

    private func recordObservation(variableID: Int64, value: Double, source: String) {
        let sql = "INSERT INTO causal_observations (variable_id, value, timestamp, source) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, variableID)
        sqlite3_bind_double(stmt, 2, value)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 4, (source as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    private func strengthenEdge(fromID: Int64, toID: Int64, supported: Bool) {
        let key = "\(fromID)_\(toID)"
        var edge = edges[key] ?? CausalEdge(fromID: fromID, toID: toID, alpha: 1.0, beta: 1.0, evidenceCount: 0)

        if supported {
            edge.alpha += 1.0
        } else {
            edge.beta += 1.0
        }
        edge.evidenceCount += 1
        edges[key] = edge

        // Persist
        let sql = """
        INSERT INTO causal_edges (from_variable_id, to_variable_id, alpha, beta, evidence_count, last_updated)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(from_variable_id, to_variable_id) DO UPDATE SET
            alpha = excluded.alpha, beta = excluded.beta, evidence_count = excluded.evidence_count, last_updated = excluded.last_updated;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, fromID)
        sqlite3_bind_int64(stmt, 2, toID)
        sqlite3_bind_double(stmt, 3, edge.alpha)
        sqlite3_bind_double(stmt, 4, edge.beta)
        sqlite3_bind_int(stmt, 5, Int32(edge.evidenceCount))
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func persistExperiment(hypothesis: String, interventionVarID: Int64, outcomeVarID: Int64, interventionType: String) {
        let sql = "INSERT INTO causal_experiments (hypothesis, intervention_variable_id, outcome_variable_id, intervention_type, status, created_at) VALUES (?, ?, ?, ?, 'proposed', ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (hypothesis as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, interventionVarID)
        sqlite3_bind_int64(stmt, 3, outcomeVarID)
        sqlite3_bind_text(stmt, 4, (interventionType as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    // MARK: - Load Graph

    private func loadGraph() {
        // Load variables
        let varSQL = "SELECT id, name, category FROM causal_variables;"
        var varStmt: OpaquePointer?
        defer { sqlite3_finalize(varStmt) }
        guard sqlite3_prepare_v2(db, varSQL, -1, &varStmt, nil) == SQLITE_OK else { return }
        while sqlite3_step(varStmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(varStmt, 0)
            let name = sqlite3_column_text(varStmt, 1).map { String(cString: $0) } ?? ""
            let category = sqlite3_column_text(varStmt, 2).map { String(cString: $0) } ?? ""
            variables[id] = CausalVariable(id: id, name: name, category: category)
        }

        // Load edges
        let edgeSQL = "SELECT from_variable_id, to_variable_id, alpha, beta, evidence_count FROM causal_edges;"
        var edgeStmt: OpaquePointer?
        defer { sqlite3_finalize(edgeStmt) }
        guard sqlite3_prepare_v2(db, edgeSQL, -1, &edgeStmt, nil) == SQLITE_OK else { return }
        while sqlite3_step(edgeStmt) == SQLITE_ROW {
            let fromID = sqlite3_column_int64(edgeStmt, 0)
            let toID = sqlite3_column_int64(edgeStmt, 1)
            let alpha = sqlite3_column_double(edgeStmt, 2)
            let beta = sqlite3_column_double(edgeStmt, 3)
            let evidence = Int(sqlite3_column_int(edgeStmt, 4))
            edges["\(fromID)_\(toID)"] = CausalEdge(fromID: fromID, toID: toID, alpha: alpha, beta: beta, evidenceCount: evidence)
        }

        #if DEBUG
        print("[CAUSAL] loaded \(variables.count) variables, \(edges.count) edges")
        #endif
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
        CREATE TABLE IF NOT EXISTS causal_variables (
            id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL, category TEXT, created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS causal_observations (
            id INTEGER PRIMARY KEY AUTOINCREMENT, variable_id INTEGER NOT NULL, value REAL NOT NULL,
            timestamp REAL NOT NULL, source TEXT, FOREIGN KEY(variable_id) REFERENCES causal_variables(id)
        );
        CREATE TABLE IF NOT EXISTS causal_edges (
            from_variable_id INTEGER NOT NULL, to_variable_id INTEGER NOT NULL,
            alpha REAL NOT NULL DEFAULT 1.0, beta REAL NOT NULL DEFAULT 1.0,
            evidence_count INTEGER DEFAULT 0, last_updated REAL,
            PRIMARY KEY(from_variable_id, to_variable_id)
        );
        CREATE TABLE IF NOT EXISTS causal_experiments (
            id INTEGER PRIMARY KEY AUTOINCREMENT, hypothesis TEXT NOT NULL,
            intervention_variable_id INTEGER NOT NULL, outcome_variable_id INTEGER NOT NULL,
            intervention_type TEXT, status TEXT DEFAULT 'proposed', result TEXT, created_at REAL NOT NULL
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("Causal tables creation failed")
        }
    }
}
