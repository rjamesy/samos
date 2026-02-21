import Foundation
import SQLite3

// MARK: - Narrative Types

struct NarrativeThread: Codable {
    let id: String
    let theme: String            // career_growth, relationship, health_journey, project, etc.
    let title: String            // "Caravan renovation", "Job search", "Fitness journey"
    var summary: String
    var occurrenceCount: Int
    var lastMentionedAt: Date
    var status: String           // active, resolved, recurring, stalled
    var createdAt: Date
}

// MARK: - Narrative Coherence Engine

/// Tracks life themes, narrative arcs, and story threads across conversations.
/// Detects when current input connects to an ongoing narrative.
/// Notices contradictions and repeating unresolved patterns.
@MainActor
final class NarrativeCoherenceEngine {

    static let shared = NarrativeCoherenceEngine()

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    /// In-memory cache of active threads
    private var threadCache: [NarrativeThread] = []

    /// Cooldown: only extract themes every N turns
    private var turnsSinceExtraction: Int = 0
    private let extractionInterval: Int = 5

    private init() {
        do {
            try openDatabase()
            try createTables()
            isAvailable = true
            loadThreadCache()
        } catch {
            #if DEBUG
            print("[NARRATIVE] DB init failed: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Process a conversation turn: match threads, record mentions, extract themes periodically.
    func processConversation(turnID: String, userText: String) async {
        guard isAvailable else { return }

        // Fast: match against existing threads
        let matchedThreads = matchThreads(userText: userText)
        for thread in matchedThreads {
            recordMention(threadID: thread.id, turnID: turnID, excerpt: userText)
        }

        // Periodic: deep theme extraction via GPT
        turnsSinceExtraction += 1
        if turnsSinceExtraction >= extractionInterval {
            turnsSinceExtraction = 0
            await extractThemes(turnID: turnID, userText: userText)
        }
    }

    /// Detect contradictions or repeated patterns.
    func detectPatterns(userText: String) -> String? {
        let lower = userText.lowercased()

        for thread in threadCache where thread.status == "recurring" && thread.occurrenceCount >= 3 {
            let keywords = thread.title.lowercased().split(separator: " ")
            if keywords.contains(where: { lower.contains(String($0)) }) {
                return "Pattern: \"\(thread.title)\" has come up \(thread.occurrenceCount) times. \(thread.summary)"
            }
        }
        return nil
    }

    /// Build narrative context block for prompt injection.
    func narrativeContextBlock(for userText: String) -> String {
        let lower = userText.lowercased()

        // Find threads relevant to this input
        let relevant = threadCache.filter { thread in
            let keywords = thread.title.lowercased().split(separator: " ").filter { $0.count > 3 }
            return keywords.contains(where: { lower.contains(String($0)) })
        }.prefix(3)

        guard !relevant.isEmpty else { return "" }

        var lines = ["Life narrative threads Sam knows about:"]
        for thread in relevant {
            let status = thread.status == "recurring" ? " (recurring pattern - \(thread.occurrenceCount)x)" : ""
            lines.append("- \(thread.title)\(status): \(thread.summary)")
        }

        // Check for pattern warnings
        if let pattern = detectPatterns(userText: userText) {
            lines.append("NOTE: \(pattern)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Thread Matching (fast, local)

    private func matchThreads(userText: String) -> [NarrativeThread] {
        let lower = userText.lowercased()
        return threadCache.filter { thread in
            let keywords = thread.title.lowercased().split(separator: " ").filter { $0.count > 3 }
            return keywords.contains(where: { lower.contains(String($0)) })
        }
    }

    // MARK: - Theme Extraction (GPT-5.2, periodic)

    private func extractThemes(turnID: String, userText: String) async {
        let existingThreadsSummary = threadCache.prefix(10).map { "- \($0.title) (\($0.theme)): \($0.summary)" }.joined(separator: "\n")

        let systemPrompt = """
        You analyze conversation text to identify life themes and narrative threads.
        Existing threads the user has:
        \(existingThreadsSummary.isEmpty ? "(none yet)" : existingThreadsSummary)

        Return ONLY valid JSON:
        {
          "threads": [
            {
              "title": "short descriptive title",
              "theme": "career/relationship/health/project/hobby/finance/personal_growth",
              "summary": "1-2 sentence description of this thread",
              "is_new": true/false,
              "status": "active/resolved/recurring/stalled"
            }
          ],
          "contradiction": "if the user contradicted something they said before, describe it here, else empty string"
        }
        """
        let userPrompt = "User said: \"\(userText)\""

        do {
            let raw = try await IntelligenceLLMClient.hybridJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                ollamaMaxTokens: 600,
                openAIMaxTokens: 600
            )
            guard let parsed = IntelligenceLLMClient.parseJSON(raw),
                  let threads = parsed["threads"] as? [[String: Any]] else { return }

            for t in threads {
                let title = t["title"] as? String ?? ""
                let theme = t["theme"] as? String ?? "other"
                let summary = t["summary"] as? String ?? ""
                let isNew = t["is_new"] as? Bool ?? true
                let status = t["status"] as? String ?? "active"

                guard !title.isEmpty else { continue }

                if isNew {
                    // Check if we already have a similar thread
                    let titleLower = title.lowercased()
                    if threadCache.contains(where: { $0.title.lowercased() == titleLower }) { continue }
                    let threadID = createThread(theme: theme, title: title, summary: summary, status: status)
                    recordMention(threadID: threadID, turnID: turnID, excerpt: userText)
                } else {
                    // Update existing thread
                    if let existing = threadCache.first(where: { $0.title.lowercased() == title.lowercased() }) {
                        updateThread(id: existing.id, summary: summary, status: status)
                    }
                }
            }

            #if DEBUG
            let contradiction = parsed["contradiction"] as? String ?? ""
            if !contradiction.isEmpty {
                print("[NARRATIVE] contradiction detected: \(contradiction)")
            }
            #endif

        } catch {
            #if DEBUG
            print("[NARRATIVE] theme extraction failed: \(error)")
            #endif
        }
    }

    // MARK: - Persistence

    private func createThread(theme: String, title: String, summary: String, status: String) -> String {
        let threadID = UUID().uuidString
        let now = Date()
        let sql = "INSERT INTO narrative_threads (id, theme, title, summary, occurrence_count, last_mentioned_at, status, created_at) VALUES (?, ?, ?, ?, 1, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return threadID }
        sqlite3_bind_text(stmt, 1, (threadID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (theme as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (summary as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 6, (status as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 7, now.timeIntervalSince1970)
        sqlite3_step(stmt)

        let thread = NarrativeThread(id: threadID, theme: theme, title: title, summary: summary,
                                     occurrenceCount: 1, lastMentionedAt: now, status: status, createdAt: now)
        threadCache.append(thread)

        #if DEBUG
        print("[NARRATIVE] new thread: \(title) (\(theme))")
        #endif
        return threadID
    }

    private func updateThread(id: String, summary: String, status: String) {
        let sql = "UPDATE narrative_threads SET summary = ?, status = ?, occurrence_count = occurrence_count + 1, last_mentioned_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (summary as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (status as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 4, (id as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)

        if let idx = threadCache.firstIndex(where: { $0.id == id }) {
            threadCache[idx].summary = summary
            threadCache[idx].status = status
            threadCache[idx].occurrenceCount += 1
            threadCache[idx].lastMentionedAt = Date()
        }
    }

    private func recordMention(threadID: String, turnID: String, excerpt: String) {
        let sql = "INSERT INTO narrative_mentions (id, thread_id, turn_id, excerpt, created_at) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (UUID().uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (threadID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (turnID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (excerpt.prefix(500) as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func loadThreadCache() {
        let sql = "SELECT id, theme, title, summary, occurrence_count, last_mentioned_at, status, created_at FROM narrative_threads ORDER BY last_mentioned_at DESC LIMIT 50;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let thread = NarrativeThread(
                id: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
                theme: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                title: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                summary: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                occurrenceCount: Int(sqlite3_column_int(stmt, 4)),
                lastMentionedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                status: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "active",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            )
            threadCache.append(thread)
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
        CREATE TABLE IF NOT EXISTS narrative_threads (
            id TEXT PRIMARY KEY, theme TEXT NOT NULL, title TEXT NOT NULL, summary TEXT,
            occurrence_count INTEGER DEFAULT 1, last_mentioned_at REAL, status TEXT DEFAULT 'active', created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_narrative_threads_mentioned ON narrative_threads(last_mentioned_at);
        CREATE TABLE IF NOT EXISTS narrative_mentions (
            id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, excerpt TEXT, created_at REAL NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES narrative_threads(id)
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("Narrative tables creation failed")
        }
    }
}
