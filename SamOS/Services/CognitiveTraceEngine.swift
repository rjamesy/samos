import Foundation
import SQLite3

// MARK: - Cognitive Trace Model

struct CognitiveTrace: Codable {
    let id: UUID
    let turnID: String
    let userInput: String
    let hypotheses: [String]
    let risks: [String]
    let refinedIntent: String
    let confidence: Double
    let shouldClarify: Bool
    let clarifyQuestion: String?
    let reasoningNotes: String
    let createdAt: Date
}

// MARK: - Cognitive Trace Engine

/// Multi-stage reasoning engine. Sam thinks before speaking.
/// Stage 1 (Ollama): Fast hypothesis generation — 3 possible interpretations
/// Stage 2 (GPT-5.2): Deep reasoning — risks, refined intent, confidence, clarification needs
/// Traces are persisted for longitudinal learning.
@MainActor
final class CognitiveTraceEngine {

    static let shared = CognitiveTraceEngine()

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    private init() {
        do {
            try openDatabase()
            try createTables()
            isAvailable = true
        } catch {
            #if DEBUG
            print("[COGNITIVE_TRACE] DB init failed: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Run the full cognitive trace pipeline. Returns nil if disabled or fails gracefully.
    func reason(turnID: String,
                userInput: String,
                recentContext: String = "") async -> CognitiveTrace? {
        guard M2Settings.cognitiveTraceEnabled, isAvailable else { return nil }

        let startedAt = CFAbsoluteTimeGetCurrent()

        // Stage 1: Fast hypotheses via Ollama
        let hypotheses = await generateHypotheses(userInput: userInput)

        // Stage 2: Deep reasoning via GPT-5.2
        let trace = await deepReason(
            turnID: turnID,
            userInput: userInput,
            hypotheses: hypotheses,
            recentContext: recentContext
        )

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)

        #if DEBUG
        if let trace {
            print("[COGNITIVE_TRACE] turn=\(turnID) intent=\(trace.refinedIntent) conf=\(String(format: "%.2f", trace.confidence)) risks=\(trace.risks.count) clarify=\(trace.shouldClarify) ms=\(elapsedMs)")
        } else {
            print("[COGNITIVE_TRACE] turn=\(turnID) trace=nil ms=\(elapsedMs)")
        }
        #endif

        if let trace {
            persist(trace)
        }
        return trace
    }

    /// Retrieve recent traces for pattern analysis.
    func recentTraces(limit: Int = 20) -> [CognitiveTrace] {
        guard isAvailable else { return [] }
        let sql = "SELECT id, turn_id, user_input, hypotheses, risks, refined_intent, confidence, should_clarify, clarify_question, reasoning_notes, created_at FROM cognitive_traces ORDER BY created_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [CognitiveTrace] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let trace = decodeRow(stmt) {
                results.append(trace)
            }
        }
        return results
    }

    /// Build a prompt context block from recent reasoning.
    func reasoningContextBlock(limit: Int = 3) -> String {
        let traces = recentTraces(limit: limit)
        guard !traces.isEmpty else { return "" }
        let lines = traces.map { trace in
            "- Intent: \(trace.refinedIntent) (conf: \(String(format: "%.0f%%", trace.confidence * 100)))" +
            (trace.risks.isEmpty ? "" : " Risks: \(trace.risks.joined(separator: ", "))")
        }
        return "Recent reasoning:\n\(lines.joined(separator: "\n"))"
    }

    // MARK: - Stage 1: Fast Hypotheses (Ollama)

    private func generateHypotheses(userInput: String) async -> [String] {
        let systemPrompt = "You are a fast intent analyzer. Return a JSON object with a \"hypotheses\" array of exactly 3 short possible interpretations of what the user wants. Each under 15 words."
        let userPrompt = "User said: \"\(userInput)\""

        do {
            let raw = try await IntelligenceLLMClient.engineJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 300
            )
            if let parsed = IntelligenceLLMClient.parseJSON(raw),
               let arr = parsed["hypotheses"] as? [String] {
                return Array(arr.prefix(3))
            }
        } catch {
            #if DEBUG
            print("[COGNITIVE_TRACE] hypothesis generation failed: \(error)")
            #endif
        }
        // Fallback: single literal interpretation
        return [userInput]
    }

    // MARK: - Stage 2: Deep Reasoning (GPT-5.2)

    private func deepReason(turnID: String,
                            userInput: String,
                            hypotheses: [String],
                            recentContext: String) async -> CognitiveTrace? {
        let hypothesesText = hypotheses.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let systemPrompt = """
        You are Sam's internal reasoning engine. You think deeply before Sam speaks.
        Analyze the user's input, consider multiple interpretations, identify risks, and produce a refined understanding.

        CRITICAL RULE for should_clarify:
        should_clarify must be FALSE by default. Set it to TRUE **only** when ALL of these are true:
        1. The action is IRREVERSIBLE (deleting files, sending emails, making purchases, cancelling subscriptions)
        2. The user's intent is genuinely AMBIGUOUS — multiple interpretations lead to very different irreversible outcomes
        3. Getting it wrong would cause real HARM to the user

        should_clarify must be FALSE for:
        - Conversation, chitchat, greetings, emotional sharing, opinions, stories
        - Questions that Sam can simply answer (even if imperfectly)
        - Requests to learn about the user, remember things, set preferences
        - ANY request where Sam can take a reasonable action and course-correct later
        - Cases where Sam can make a best guess and ask "did I get that right?" after acting

        Sam's philosophy: ACT FIRST, ADJUST LATER. Never stall a conversation with clarifying questions when you can just respond naturally.

        Return ONLY valid JSON.
        """

        let userPrompt = """
        USER INPUT: "\(userInput)"

        HYPOTHESES:
        \(hypothesesText)

        \(recentContext.isEmpty ? "" : "RECENT CONTEXT:\n\(recentContext)\n")
        Analyze and return JSON:
        {
          "refined_intent": "what the user most likely wants (1 sentence)",
          "confidence": 0.0-1.0,
          "risks": ["potential misunderstanding or pitfall"],
          "should_clarify": false,
          "clarify_question": "ONLY if should_clarify is true AND action is irreversible, else empty string",
          "reasoning_notes": "brief internal reasoning (2-3 sentences max)"
        }
        """

        do {
            let raw = try await IntelligenceLLMClient.openAIJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 800
            )
            guard let parsed = IntelligenceLLMClient.parseJSON(raw) else { return nil }

            return CognitiveTrace(
                id: UUID(),
                turnID: turnID,
                userInput: userInput,
                hypotheses: hypotheses,
                risks: parsed["risks"] as? [String] ?? [],
                refinedIntent: parsed["refined_intent"] as? String ?? userInput,
                confidence: (parsed["confidence"] as? NSNumber)?.doubleValue ?? 0.5,
                shouldClarify: parsed["should_clarify"] as? Bool ?? false,
                clarifyQuestion: parsed["clarify_question"] as? String,
                reasoningNotes: parsed["reasoning_notes"] as? String ?? "",
                createdAt: Date()
            )
        } catch {
            #if DEBUG
            print("[COGNITIVE_TRACE] deep reasoning failed: \(error)")
            #endif
            return nil
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
        CREATE TABLE IF NOT EXISTS cognitive_traces (
            id TEXT PRIMARY KEY,
            turn_id TEXT NOT NULL,
            user_input TEXT NOT NULL,
            hypotheses TEXT,
            risks TEXT,
            refined_intent TEXT,
            confidence REAL DEFAULT 0.5,
            should_clarify INTEGER DEFAULT 0,
            clarify_question TEXT,
            reasoning_notes TEXT,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_cognitive_traces_created ON cognitive_traces(created_at);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("Table creation failed")
        }
    }

    private func persist(_ trace: CognitiveTrace) {
        let sql = """
        INSERT OR REPLACE INTO cognitive_traces
        (id, turn_id, user_input, hypotheses, risks, refined_intent, confidence, should_clarify, clarify_question, reasoning_notes, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        let hypothesesJSON = (try? JSONSerialization.data(withJSONObject: trace.hypotheses))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let risksJSON = (try? JSONSerialization.data(withJSONObject: trace.risks))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        sqlite3_bind_text(stmt, 1, (trace.id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (trace.turnID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (trace.userInput as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (hypothesesJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (risksJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (trace.refinedIntent as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 7, trace.confidence)
        sqlite3_bind_int(stmt, 8, trace.shouldClarify ? 1 : 0)
        sqlite3_bind_text(stmt, 9, ((trace.clarifyQuestion ?? "") as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 10, (trace.reasoningNotes as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 11, trace.createdAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func decodeRow(_ stmt: OpaquePointer?) -> CognitiveTrace? {
        guard let stmt else { return nil }
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr) else { return nil }

        let turnID = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let userInput = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let hypothesesRaw = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "[]"
        let risksRaw = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "[]"
        let refinedIntent = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
        let confidence = sqlite3_column_double(stmt, 6)
        let shouldClarify = sqlite3_column_int(stmt, 7) == 1
        let clarifyQuestion = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let reasoningNotes = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))

        let hypotheses = (try? JSONSerialization.jsonObject(
            with: Data(hypothesesRaw.utf8)) as? [String]) ?? []
        let risks = (try? JSONSerialization.jsonObject(
            with: Data(risksRaw.utf8)) as? [String]) ?? []

        return CognitiveTrace(
            id: id, turnID: turnID, userInput: userInput,
            hypotheses: hypotheses, risks: risks,
            refinedIntent: refinedIntent, confidence: confidence,
            shouldClarify: shouldClarify, clarifyQuestion: clarifyQuestion,
            reasoningNotes: reasoningNotes, createdAt: createdAt
        )
    }
}
