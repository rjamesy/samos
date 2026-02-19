import Foundation
import SQLite3

enum SemanticMemoryRole: String, Codable {
    case user
    case assistant
}

enum SemanticMemoryType: String {
    case episode
    case profileFact = "profile_fact"
    case daily
}

struct SemanticMessageRecord: Equatable {
    let id: Int64
    let ts: Date
    let role: SemanticMemoryRole
    let text: String
    let sessionID: String
    let turnID: String?
    let metaJSON: String?
}

struct SemanticEpisodeEntities: Codable, Equatable {
    var people: [String]
    var orgs: [String]
    var places: [String]

    static let empty = SemanticEpisodeEntities(people: [], orgs: [], places: [])
}

struct SemanticEpisodeFacts: Codable, Equatable {
    var when: String?
    var whereValue: String?
    var who: [String]
    var details: [String: String]

    enum CodingKeys: String, CodingKey {
        case when
        case whereValue = "where"
        case who
        case details
    }

    static let empty = SemanticEpisodeFacts(when: nil, whereValue: nil, who: [], details: [:])
}

struct SemanticEpisodeDecision: Codable, Equatable {
    var decision: String
    var rationale: String?
}

struct SemanticEpisodeAction: Codable, Equatable {
    var task: String
    var owner: String
    var due: String?
}

struct SemanticEpisodePayload: Codable, Equatable {
    var title: String
    var summary: String
    var entities: SemanticEpisodeEntities
    var facts: SemanticEpisodeFacts
    var decisions: [SemanticEpisodeDecision]
    var actions: [SemanticEpisodeAction]
    var tags: [String]
    var importance: Double
    var confidence: Double
}

enum SemanticProfileFactKind: String, Codable, CaseIterable {
    case preference
    case identity
    case routine
    case constraint
    case contact
    case project
}

struct SemanticProfileFactPayload: Codable, Equatable {
    var kind: SemanticProfileFactKind
    var key: String
    var value: [String: String]
    var confidence: Double
    var shouldStore: Bool

    enum CodingKeys: String, CodingKey {
        case kind
        case key
        case value
        case confidence
        case shouldStore = "should_store"
    }
}

struct SemanticEpisodeRecord: Identifiable, Equatable {
    let id: String
    let createdAt: Date
    let updatedAt: Date
    let sessionID: String
    let payload: SemanticEpisodePayload
    let sourceMessageIDs: [Int64]
}

struct SemanticProfileFactRecord: Identifiable, Equatable {
    let id: String
    let createdAt: Date
    let updatedAt: Date
    let kind: SemanticProfileFactKind
    let key: String
    let value: [String: String]
    let confidence: Double
    let provenance: [String: String]
}

struct SemanticDailySummaryRecord: Equatable {
    let date: String
    let summary: String
    let episodeIDs: [String]
}

struct SemanticMemoryChunk: Equatable {
    let sessionID: String
    let messageIDs: [Int64]
    let createdAt: Date
}

struct SemanticRetrievalResult {
    let episodes: [SemanticEpisodeRecord]
    let profileFacts: [SemanticProfileFactRecord]
    let dailySummary: SemanticDailySummaryRecord?
    let hasConflict: Bool
    let hasLowConfidence: Bool
}

struct SemanticInjectionResult {
    let block: String
    let snippets: [KnowledgeSourceSnippet]
    let shouldClarify: Bool
    let clarificationPrompt: String?
}

enum SemanticMemoryValidationError: Error {
    case missingField(String)
    case invalidRange(String)
}

enum EpisodeSchemaValidator {
    static func validate(_ payload: SemanticEpisodePayload) throws {
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { throw SemanticMemoryValidationError.missingField("title") }
        if summary.isEmpty { throw SemanticMemoryValidationError.missingField("summary") }
        if payload.importance < 0 || payload.importance > 1 {
            throw SemanticMemoryValidationError.invalidRange("importance")
        }
        if payload.confidence < 0 || payload.confidence > 1 {
            throw SemanticMemoryValidationError.invalidRange("confidence")
        }
    }
}

enum ProfileFactSchemaValidator {
    static func validate(_ payload: SemanticProfileFactPayload) throws {
        let key = payload.key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { throw SemanticMemoryValidationError.missingField("key") }
        if payload.confidence < 0 || payload.confidence > 1 {
            throw SemanticMemoryValidationError.invalidRange("confidence")
        }
    }
}

protocol SemanticMemoryLLMClient {
    func completeJSON(systemPrompt: String, userPrompt: String) async throws -> String
}

enum SemanticMemoryLLMError: Error {
    case unavailable
}

struct HybridSemanticMemoryLLMClient: SemanticMemoryLLMClient {
    private let ollamaTransport: OllamaTransport

    init(ollamaTransport: OllamaTransport = RealOllamaTransport()) {
        self.ollamaTransport = ollamaTransport
    }

    func completeJSON(systemPrompt: String, userPrompt: String) async throws -> String {
        let messages = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt]
        ]

        if M2Settings.useOllama {
            do {
                return try await ollamaTransport.chat(
                    messages: messages,
                    model: M2Settings.ollamaModel,
                    maxOutputTokens: 900
                )
            } catch {
                // Fall through to OpenAI fallback below.
            }
        }

        guard OpenAISettings.apiKeyStatus == .ready else {
            throw SemanticMemoryLLMError.unavailable
        }

        return try await callOpenAI(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    private func callOpenAI(systemPrompt: String, userPrompt: String) async throws -> String {
        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        let preferred = OpenAISettings.generalModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = preferred.isEmpty ? OpenAISettings.defaultPreferredModel : preferred

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.0,
            "max_tokens": 900
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OpenAIRouter.OpenAIError.requestFailed("Memory LLM OpenAI request failed")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw OpenAIRouter.OpenAIError.requestFailed("Invalid response")
        }
        return content
    }
}

final class SemanticMemoryStore {
    static let shared = SemanticMemoryStore()

    private let queue = DispatchQueue(label: "SemanticMemoryStore.queue")
    private let queueSpecificKey = DispatchSpecificKey<UInt8>()
    private let logger: AppLogger
    private var db: OpaquePointer?
    private(set) var isAvailable = false

    init(dbPath: String? = nil, logger: AppLogger = JSONLineLogger()) {
        self.logger = logger
        queue.setSpecific(key: queueSpecificKey, value: 1)
        do {
            try openDatabase(pathOverride: dbPath)
            try migrate()
            isAvailable = true
        } catch {
            logger.error("semantic_memory_init_failed", metadata: ["error": error.localizedDescription])
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func syncOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return work()
        }
        return queue.sync(execute: work)
    }

    private func openDatabase(pathOverride: String?) throws {
        let path: String
        if let pathOverride {
            path = pathOverride
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("SamOS", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            path = dir.appendingPathComponent("memory.sqlite3").path
        }

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw NSError(domain: "SemanticMemoryStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
    }

    private func migrate() throws {
        guard let db else { return }
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                session_id TEXT NOT NULL,
                turn_id TEXT,
                meta_json TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS episodes (
                id TEXT PRIMARY KEY,
                created_ts REAL NOT NULL,
                updated_ts REAL NOT NULL,
                session_id TEXT NOT NULL,
                title TEXT NOT NULL,
                summary TEXT NOT NULL,
                entities_json TEXT NOT NULL,
                facts_json TEXT NOT NULL,
                decisions_json TEXT NOT NULL,
                actions_json TEXT NOT NULL,
                tags_json TEXT NOT NULL,
                importance REAL NOT NULL,
                confidence REAL NOT NULL,
                embedding_blob BLOB,
                source_span_json TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS profile_facts (
                id TEXT PRIMARY KEY,
                created_ts REAL NOT NULL,
                updated_ts REAL NOT NULL,
                kind TEXT NOT NULL,
                key TEXT NOT NULL,
                value_json TEXT NOT NULL,
                confidence REAL NOT NULL,
                provenance_json TEXT NOT NULL,
                embedding_blob BLOB
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS daily_summaries (
                date TEXT PRIMARY KEY,
                summary TEXT NOT NULL,
                episode_ids_json TEXT NOT NULL,
                embedding_blob BLOB
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS memory_links (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                memory_type TEXT NOT NULL,
                memory_id TEXT NOT NULL,
                message_id INTEGER NOT NULL,
                weight REAL NOT NULL,
                note TEXT
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_messages_session_ts ON messages(session_id, ts)",
            "CREATE INDEX IF NOT EXISTS idx_episodes_session_updated ON episodes(session_id, updated_ts)",
            "CREATE INDEX IF NOT EXISTS idx_profile_facts_kind_key ON profile_facts(kind, key)",
            "CREATE INDEX IF NOT EXISTS idx_memory_links_memory ON memory_links(memory_type, memory_id)"
        ]

        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(
                    domain: "SemanticMemoryStore",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
                )
            }
        }
    }

    @discardableResult
    func appendMessage(ts: Date = Date(),
                       role: SemanticMemoryRole,
                       text: String,
                       sessionID: String,
                       turnID: String?,
                       metaJSON: String?) -> Int64? {
        syncOnQueue {
            guard let db else { return nil }
            let sql = """
            INSERT INTO messages (ts, role, text, session_id, turn_id, meta_json)
            VALUES (?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, ts.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, role.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 4, sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let turnID {
                sqlite3_bind_text(stmt, 5, turnID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            if let metaJSON {
                sqlite3_bind_text(stmt, 6, metaJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(stmt, 6)
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func messages(ids: [Int64]) -> [SemanticMessageRecord] {
        syncOnQueue {
            guard let db, !ids.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let sql = """
            SELECT id, ts, role, text, session_id, turn_id, meta_json
            FROM messages
            WHERE id IN (\(placeholders))
            ORDER BY ts ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            for (idx, id) in ids.enumerated() {
                sqlite3_bind_int64(stmt, Int32(idx + 1), id)
            }

            var rows: [SemanticMessageRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard
                    let roleC = sqlite3_column_text(stmt, 2),
                    let textC = sqlite3_column_text(stmt, 3),
                    let sessionC = sqlite3_column_text(stmt, 4)
                else {
                    continue
                }
                let id = sqlite3_column_int64(stmt, 0)
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                let role = SemanticMemoryRole(rawValue: String(cString: roleC)) ?? .user
                let text = String(cString: textC)
                let sessionID = String(cString: sessionC)
                let turnID = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let metaJSON = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                rows.append(SemanticMessageRecord(id: id, ts: ts, role: role, text: text, sessionID: sessionID, turnID: turnID, metaJSON: metaJSON))
            }
            return rows
        }
    }

    func latestMessageTimestamp(sessionID: String) -> Date? {
        syncOnQueue {
            guard let db else { return nil }
            let sql = "SELECT ts FROM messages WHERE session_id = ? ORDER BY ts DESC LIMIT 1"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    func latestEpisode(sessionID: String) -> SemanticEpisodeRecord? {
        syncOnQueue {
            guard let db else { return nil }
            let sql = """
            SELECT id, created_ts, updated_ts, session_id, title, summary, entities_json, facts_json, decisions_json, actions_json, tags_json, importance, confidence, source_span_json
            FROM episodes
            WHERE session_id = ?
            ORDER BY updated_ts DESC
            LIMIT 1
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return decodeEpisodeRow(stmt)
        }
    }

    func listEpisodes(limit: Int = 80) -> [SemanticEpisodeRecord] {
        syncOnQueue {
            guard let db else { return [] }
            let sql = """
            SELECT id, created_ts, updated_ts, session_id, title, summary, entities_json, facts_json, decisions_json, actions_json, tags_json, importance, confidence, source_span_json
            FROM episodes
            ORDER BY updated_ts DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(max(1, limit)))
            var rows: [SemanticEpisodeRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let row = decodeEpisodeRow(stmt) {
                    rows.append(row)
                }
            }
            return rows
        }
    }

    func episodes(onLocalDate date: String) -> [SemanticEpisodeRecord] {
        let episodes = listEpisodes(limit: 400)
        return episodes.filter { Self.localDayString($0.createdAt) == date }
    }

    func upsertEpisode(id: String?,
                       sessionID: String,
                       payload: SemanticEpisodePayload,
                       sourceMessageIDs: [Int64],
                       now: Date = Date()) -> SemanticEpisodeRecord? {
        syncOnQueue {
            guard let db, !sourceMessageIDs.isEmpty else { return nil }
            guard let entitiesJSON = Self.encodeJSONString(payload.entities),
                  let factsJSON = Self.encodeJSONString(payload.facts),
                  let decisionsJSON = Self.encodeJSONString(payload.decisions),
                  let actionsJSON = Self.encodeJSONString(payload.actions),
                  let tagsJSON = Self.encodeJSONString(payload.tags),
                  let sourceSpanJSON = Self.encodeJSONString(sourceMessageIDs)
            else {
                return nil
            }

            if let id {
                let sql = """
                UPDATE episodes
                SET updated_ts = ?, title = ?, summary = ?, entities_json = ?, facts_json = ?, decisions_json = ?, actions_json = ?, tags_json = ?, importance = ?, confidence = ?, source_span_json = ?
                WHERE id = ?
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 2, payload.title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 3, payload.summary, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 4, entitiesJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 5, factsJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 6, decisionsJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 7, actionsJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 8, tagsJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_double(stmt, 9, payload.importance)
                sqlite3_bind_double(stmt, 10, payload.confidence)
                sqlite3_bind_text(stmt, 11, sourceSpanJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 12, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
                addMemoryLinks(memoryType: .episode, memoryID: id, messageIDs: sourceMessageIDs, weight: payload.confidence, note: "episode_update")
                return episode(id: id)
            }

            let newID = UUID().uuidString
            let sql = """
            INSERT INTO episodes
            (id, created_ts, updated_ts, session_id, title, summary, entities_json, facts_json, decisions_json, actions_json, tags_json, importance, confidence, source_span_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, newID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 5, payload.title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 6, payload.summary, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 7, entitiesJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 8, factsJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 9, decisionsJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 10, actionsJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 11, tagsJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 12, payload.importance)
            sqlite3_bind_double(stmt, 13, payload.confidence)
            sqlite3_bind_text(stmt, 14, sourceSpanJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            addMemoryLinks(memoryType: .episode, memoryID: newID, messageIDs: sourceMessageIDs, weight: payload.confidence, note: "episode_create")
            return episode(id: newID)
        }
    }

    func episode(id: String) -> SemanticEpisodeRecord? {
        syncOnQueue {
            guard let db else { return nil }
            let sql = """
            SELECT id, created_ts, updated_ts, session_id, title, summary, entities_json, facts_json, decisions_json, actions_json, tags_json, importance, confidence, source_span_json
            FROM episodes
            WHERE id = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return decodeEpisodeRow(stmt)
        }
    }

    @discardableResult
    func deleteEpisode(id: String) -> Bool {
        syncOnQueue {
            guard let db else { return false }
            var ok = false
            var stmt: OpaquePointer?
            let deleteEpisodeSQL = "DELETE FROM episodes WHERE id = ?"
            if sqlite3_prepare_v2(db, deleteEpisodeSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                ok = sqlite3_step(stmt) == SQLITE_DONE
                sqlite3_finalize(stmt)
            } else {
                sqlite3_finalize(stmt)
            }

            var linkStmt: OpaquePointer?
            let deleteLinksSQL = "DELETE FROM memory_links WHERE memory_type = ? AND memory_id = ?"
            if sqlite3_prepare_v2(db, deleteLinksSQL, -1, &linkStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(linkStmt, 1, SemanticMemoryType.episode.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(linkStmt, 2, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                _ = sqlite3_step(linkStmt)
                sqlite3_finalize(linkStmt)
            } else {
                sqlite3_finalize(linkStmt)
            }
            return ok
        }
    }

    func upsertProfileFact(payload: SemanticProfileFactPayload,
                           sourceMessageIDs: [Int64],
                           now: Date = Date()) -> SemanticProfileFactRecord? {
        syncOnQueue {
            guard let db, !sourceMessageIDs.isEmpty else { return nil }
            let normalizedKey = payload.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty else { return nil }
            guard let valueJSON = Self.encodeJSONString(payload.value) else { return nil }
            let provenance: [String: String] = [
                "source": "semantic_memory",
                "message_ids": sourceMessageIDs.map(String.init).joined(separator: ",")
            ]
            guard let provenanceJSON = Self.encodeJSONString(provenance) else { return nil }

            let existing = profileFacts(kind: payload.kind, key: normalizedKey)

            if let first = existing.first {
                let resolvedValue = resolveProfileValue(existing: first.value, incoming: payload.value, key: normalizedKey)
                let resolvedConfidence = max(first.confidence, payload.confidence)
                guard let resolvedValueJSON = Self.encodeJSONString(resolvedValue) else { return nil }
                let sql = """
                UPDATE profile_facts
                SET updated_ts = ?, value_json = ?, confidence = ?, provenance_json = ?
                WHERE id = ?
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 2, resolvedValueJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_double(stmt, 3, resolvedConfidence)
                sqlite3_bind_text(stmt, 4, provenanceJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 5, first.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
                addMemoryLinks(memoryType: .profileFact, memoryID: first.id, messageIDs: sourceMessageIDs, weight: resolvedConfidence, note: "profile_upsert")
                return profileFact(id: first.id)
            }

            let id = UUID().uuidString
            let sql = """
            INSERT INTO profile_facts
            (id, created_ts, updated_ts, kind, key, value_json, confidence, provenance_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, payload.kind.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 5, normalizedKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 6, valueJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 7, payload.confidence)
            sqlite3_bind_text(stmt, 8, provenanceJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            addMemoryLinks(memoryType: .profileFact, memoryID: id, messageIDs: sourceMessageIDs, weight: payload.confidence, note: "profile_create")
            return profileFact(id: id)
        }
    }

    func listProfileFacts(limit: Int = 200) -> [SemanticProfileFactRecord] {
        syncOnQueue {
            guard let db else { return [] }
            let sql = """
            SELECT id, created_ts, updated_ts, kind, key, value_json, confidence, provenance_json
            FROM profile_facts
            ORDER BY updated_ts DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(max(1, limit)))
            var rows: [SemanticProfileFactRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let row = decodeProfileRow(stmt) {
                    rows.append(row)
                }
            }
            return rows
        }
    }

    func profileFacts(kind: SemanticProfileFactKind, key: String) -> [SemanticProfileFactRecord] {
        syncOnQueue {
            guard let db else { return [] }
            let sql = """
            SELECT id, created_ts, updated_ts, kind, key, value_json, confidence, provenance_json
            FROM profile_facts
            WHERE kind = ? AND key = ?
            ORDER BY updated_ts DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, kind.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            var rows: [SemanticProfileFactRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let row = decodeProfileRow(stmt) {
                    rows.append(row)
                }
            }
            return rows
        }
    }

    func profileFact(id: String) -> SemanticProfileFactRecord? {
        syncOnQueue {
            guard let db else { return nil }
            let sql = """
            SELECT id, created_ts, updated_ts, kind, key, value_json, confidence, provenance_json
            FROM profile_facts
            WHERE id = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return decodeProfileRow(stmt)
        }
    }

    func upsertDailySummary(date: String,
                            summary: String,
                            episodeIDs: [String],
                            representativeMessageIDs: [Int64]) -> SemanticDailySummaryRecord? {
        syncOnQueue {
            guard let db, !episodeIDs.isEmpty else { return nil }
            guard let episodeIDsJSON = Self.encodeJSONString(episodeIDs) else { return nil }

            let sql = """
            INSERT INTO daily_summaries (date, summary, episode_ids_json)
            VALUES (?, ?, ?)
            ON CONFLICT(date) DO UPDATE SET
                summary = excluded.summary,
                episode_ids_json = excluded.episode_ids_json
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, date, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, summary, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, episodeIDsJSON, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }

            if !representativeMessageIDs.isEmpty {
                addMemoryLinks(memoryType: .daily, memoryID: date, messageIDs: representativeMessageIDs, weight: 0.8, note: "daily_summary")
            }
            return dailySummary(date: date)
        }
    }

    func dailySummary(date: String) -> SemanticDailySummaryRecord? {
        syncOnQueue {
            guard let db else { return nil }
            let sql = "SELECT date, summary, episode_ids_json FROM daily_summaries WHERE date = ? LIMIT 1"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, date, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard
                let dateC = sqlite3_column_text(stmt, 0),
                let summaryC = sqlite3_column_text(stmt, 1),
                let idsC = sqlite3_column_text(stmt, 2)
            else {
                return nil
            }
            let rowDate = String(cString: dateC)
            let summary = String(cString: summaryC)
            let idsJSON = String(cString: idsC)
            let episodeIDs: [String] = (try? Self.decodeJSON(idsJSON)) ?? []
            return SemanticDailySummaryRecord(date: rowDate, summary: summary, episodeIDs: episodeIDs)
        }
    }

    @discardableResult
    func addMemoryLinks(memoryType: SemanticMemoryType,
                        memoryID: String,
                        messageIDs: [Int64],
                        weight: Double,
                        note: String) -> Int {
        syncOnQueue {
            guard let db, !messageIDs.isEmpty else { return 0 }
            let sql = """
            INSERT INTO memory_links (memory_type, memory_id, message_id, weight, note)
            VALUES (?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }

            var count = 0
            for messageID in Set(messageIDs) {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, memoryType.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, memoryID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int64(stmt, 3, messageID)
                sqlite3_bind_double(stmt, 4, min(1.0, max(0.0, weight)))
                sqlite3_bind_text(stmt, 5, note, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                if sqlite3_step(stmt) == SQLITE_DONE {
                    count += 1
                }
            }
            return count
        }
    }

    func hasMemoryLinks(memoryType: SemanticMemoryType, memoryID: String) -> Bool {
        syncOnQueue {
            guard let db else { return false }
            let sql = "SELECT COUNT(*) FROM memory_links WHERE memory_type = ? AND memory_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, memoryType.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, memoryID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_int(stmt, 0) > 0
        }
    }

    func clearSemanticTables() {
        syncOnQueue {
            guard let db else { return }
            sqlite3_exec(db, "DELETE FROM memory_links", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM daily_summaries", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM profile_facts", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM episodes", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM messages", nil, nil, nil)
        }
    }

    func exportEpisodeJSON(id: String) -> String? {
        guard let episode = episode(id: id) else { return nil }
        let export: [String: Any] = [
            "id": episode.id,
            "created_ts": episode.createdAt.timeIntervalSince1970,
            "updated_ts": episode.updatedAt.timeIntervalSince1970,
            "session_id": episode.sessionID,
            "payload": (try? Self.dictionary(from: episode.payload)) ?? [:],
            "source_message_ids": episode.sourceMessageIDs
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: export, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func resolveProfileValue(existing: [String: String],
                                     incoming: [String: String],
                                     key: String) -> [String: String] {
        let multiValueKeys = ["likes_food", "favorite_foods", "pets", "contacts"]
        if multiValueKeys.contains(where: { key.contains($0) }) {
            let existingText = existing["text"] ?? ""
            let incomingText = incoming["text"] ?? ""
            let merged = [existingText, incomingText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            return ["text": merged]
        }
        return incoming.isEmpty ? existing : incoming
    }

    private func decodeEpisodeRow(_ stmt: OpaquePointer?) -> SemanticEpisodeRecord? {
        guard let stmt,
              let idC = sqlite3_column_text(stmt, 0),
              let sessionC = sqlite3_column_text(stmt, 3),
              let titleC = sqlite3_column_text(stmt, 4),
              let summaryC = sqlite3_column_text(stmt, 5),
              let entitiesC = sqlite3_column_text(stmt, 6),
              let factsC = sqlite3_column_text(stmt, 7),
              let decisionsC = sqlite3_column_text(stmt, 8),
              let actionsC = sqlite3_column_text(stmt, 9),
              let tagsC = sqlite3_column_text(stmt, 10),
              let sourceSpanC = sqlite3_column_text(stmt, 13)
        else {
            return nil
        }

        let id = String(cString: idC)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let sessionID = String(cString: sessionC)
        let title = String(cString: titleC)
        let summary = String(cString: summaryC)
        let entitiesJSON = String(cString: entitiesC)
        let factsJSON = String(cString: factsC)
        let decisionsJSON = String(cString: decisionsC)
        let actionsJSON = String(cString: actionsC)
        let tagsJSON = String(cString: tagsC)
        let importance = sqlite3_column_double(stmt, 11)
        let confidence = sqlite3_column_double(stmt, 12)
        let sourceSpanJSON = String(cString: sourceSpanC)

        let entities: SemanticEpisodeEntities = (try? Self.decodeJSON(entitiesJSON)) ?? .empty
        let facts: SemanticEpisodeFacts = (try? Self.decodeJSON(factsJSON)) ?? .empty
        let decisions: [SemanticEpisodeDecision] = (try? Self.decodeJSON(decisionsJSON)) ?? []
        let actions: [SemanticEpisodeAction] = (try? Self.decodeJSON(actionsJSON)) ?? []
        let tags: [String] = (try? Self.decodeJSON(tagsJSON)) ?? []
        let sourceIDs: [Int64] = (try? Self.decodeJSON(sourceSpanJSON)) ?? []

        let payload = SemanticEpisodePayload(
            title: title,
            summary: summary,
            entities: entities,
            facts: facts,
            decisions: decisions,
            actions: actions,
            tags: tags,
            importance: importance,
            confidence: confidence
        )
        return SemanticEpisodeRecord(id: id, createdAt: createdAt, updatedAt: updatedAt, sessionID: sessionID, payload: payload, sourceMessageIDs: sourceIDs)
    }

    private func decodeProfileRow(_ stmt: OpaquePointer?) -> SemanticProfileFactRecord? {
        guard let stmt,
              let idC = sqlite3_column_text(stmt, 0),
              let kindC = sqlite3_column_text(stmt, 3),
              let keyC = sqlite3_column_text(stmt, 4),
              let valueC = sqlite3_column_text(stmt, 5),
              let provenanceC = sqlite3_column_text(stmt, 7)
        else {
            return nil
        }
        let id = String(cString: idC)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let kindRaw = String(cString: kindC)
        guard let kind = SemanticProfileFactKind(rawValue: kindRaw) else { return nil }
        let key = String(cString: keyC)
        let valueJSON = String(cString: valueC)
        let confidence = sqlite3_column_double(stmt, 6)
        let provenanceJSON = String(cString: provenanceC)
        let value: [String: String] = (try? Self.decodeJSON(valueJSON)) ?? [:]
        let provenance: [String: String] = (try? Self.decodeJSON(provenanceJSON)) ?? [:]
        return SemanticProfileFactRecord(id: id, createdAt: createdAt, updatedAt: updatedAt, kind: kind, key: key, value: value, confidence: confidence, provenance: provenance)
    }

    static func encodeJSONString<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    static func decodeJSON<T: Decodable>(_ json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func dictionary<T: Encodable>(from value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    static func localDayString(_ date: Date) -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

final class MemoryCaptureService {
    struct SessionState {
        var pendingMessageIDs: [Int64] = []
        var pendingUserTurns: Int = 0
        var lastMessageAt: Date?
    }

    private let store: SemanticMemoryStore
    private let logger: AppLogger
    private let idleBoundarySeconds: TimeInterval
    private let maxUserTurnsPerChunk: Int
    private var stateBySession: [String: SessionState] = [:]

    init(store: SemanticMemoryStore,
         logger: AppLogger,
         idleBoundarySeconds: TimeInterval = 90,
         maxUserTurnsPerChunk: Int = 8) {
        self.store = store
        self.logger = logger
        self.idleBoundarySeconds = idleBoundarySeconds
        self.maxUserTurnsPerChunk = max(1, maxUserTurnsPerChunk)
    }

    func captureTurn(sessionID: String,
                     turnID: String?,
                     userMessage: String,
                     assistantMessage: String?,
                     inputSource: String,
                     sttConfidence: Double?,
                     now: Date = Date()) -> [SemanticMemoryChunk] {
        var outputs: [SemanticMemoryChunk] = []
        var state = stateBySession[sessionID] ?? SessionState()

        if let last = state.lastMessageAt,
           now.timeIntervalSince(last) > idleBoundarySeconds,
           !state.pendingMessageIDs.isEmpty {
            outputs.append(SemanticMemoryChunk(sessionID: sessionID, messageIDs: state.pendingMessageIDs, createdAt: now))
            state.pendingMessageIDs.removeAll()
            state.pendingUserTurns = 0
            logger.info("memory_chunk_created", metadata: [
                "reason": "idle_boundary",
                "session_id": sessionID
            ])
        }

        let trimmedUser = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUser.isEmpty {
            let metaJSON = SemanticMemoryStore.encodeJSONString([
                "source": inputSource,
                "stt_confidence": sttConfidence.map { String(format: "%.2f", $0) } ?? ""
            ])
            if let messageID = store.appendMessage(role: .user,
                                                   text: trimmedUser,
                                                   sessionID: sessionID,
                                                   turnID: turnID,
                                                   metaJSON: metaJSON) {
                state.pendingMessageIDs.append(messageID)
                state.pendingUserTurns += 1
            }
        }

        if let assistantMessage {
            let trimmedAssistant = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAssistant.isEmpty,
               let messageID = store.appendMessage(role: .assistant,
                                                  text: trimmedAssistant,
                                                  sessionID: sessionID,
                                                  turnID: turnID,
                                                  metaJSON: nil) {
                state.pendingMessageIDs.append(messageID)
            }
        }

        state.lastMessageAt = now

        if shouldCloseChunk(userMessage: trimmedUser) || state.pendingUserTurns >= maxUserTurnsPerChunk {
            if !state.pendingMessageIDs.isEmpty {
                outputs.append(SemanticMemoryChunk(sessionID: sessionID, messageIDs: state.pendingMessageIDs, createdAt: now))
                logger.info("memory_chunk_created", metadata: [
                    "reason": shouldCloseChunk(userMessage: trimmedUser) ? "explicit_boundary" : "turn_count_boundary",
                    "session_id": sessionID
                ])
            }
            state.pendingMessageIDs.removeAll()
            state.pendingUserTurns = 0
        }

        stateBySession[sessionID] = state
        return outputs
    }

    func flush(sessionID: String, now: Date = Date()) -> SemanticMemoryChunk? {
        var state = stateBySession[sessionID] ?? SessionState()
        defer {
            state.pendingMessageIDs.removeAll()
            state.pendingUserTurns = 0
            stateBySession[sessionID] = state
        }
        guard !state.pendingMessageIDs.isEmpty else { return nil }
        logger.info("memory_chunk_created", metadata: [
            "reason": "manual_flush",
            "session_id": sessionID
        ])
        return SemanticMemoryChunk(sessionID: sessionID, messageIDs: state.pendingMessageIDs, createdAt: now)
    }

    private func shouldCloseChunk(userMessage: String) -> Bool {
        guard !userMessage.isEmpty else { return false }
        let lower = userMessage.lowercased()
        let boundaries = [
            "that's all",
            "thats all",
            "done",
            "thanks",
            "thank you",
            "all good"
        ]
        return boundaries.contains { lower.contains($0) }
    }
}

final class EpisodeCompressor {
    private let llm: SemanticMemoryLLMClient
    private let logger: AppLogger

    init(llm: SemanticMemoryLLMClient, logger: AppLogger) {
        self.llm = llm
        self.logger = logger
    }

    func compress(messages: [SemanticMessageRecord],
                  confidenceScale: Double = 1.0) async -> SemanticEpisodePayload? {
        guard !messages.isEmpty else { return nil }

        let systemPrompt = """
        Return ONLY valid JSON matching this Episode schema:
        {
          "title":"string",
          "summary":"string",
          "entities":{"people":[],"orgs":[],"places":[]},
          "facts":{"when":"string?","where":"string?","who":[],"details":{}},
          "decisions":[{"decision":"string","rationale":"string?"}],
          "actions":[{"task":"string","owner":"user|sam|other","due":"string?"}],
          "tags":["string"],
          "importance":0.0,
          "confidence":0.0
        }
        No commentary. No markdown. JSON only.
        """

        let userPrompt = """
        Chunk messages:
        \(encodeMessages(messages))
        """

        let raw: String
        do {
            raw = try await llm.completeJSON(systemPrompt: systemPrompt, userPrompt: userPrompt)
        } catch {
            logger.error("episode_compress_failed", metadata: ["error": error.localizedDescription])
            return nil
        }

        if let parsed = decodeEpisode(from: raw, confidenceScale: confidenceScale) {
            return parsed
        }

        let fixSystem = "FIX JSON ONLY. Return valid Episode JSON, no commentary."
        let fixUser = "Invalid JSON payload:\n\(raw)"
        do {
            let fixed = try await llm.completeJSON(systemPrompt: fixSystem, userPrompt: fixUser)
            if let parsed = decodeEpisode(from: fixed, confidenceScale: confidenceScale) {
                return parsed
            }
        } catch {
            logger.error("episode_fix_failed", metadata: ["error": error.localizedDescription])
        }

        logger.error("episode_validation_dropped", metadata: ["reason": "unparseable_or_invalid"])
        return nil
    }

    private func decodeEpisode(from raw: String,
                               confidenceScale: Double) -> SemanticEpisodePayload? {
        let json = extractJSONObject(raw)
        guard let data = json.data(using: .utf8),
              var payload = try? JSONDecoder().decode(SemanticEpisodePayload.self, from: data)
        else {
            return nil
        }
        payload.confidence = min(1.0, max(0.0, payload.confidence * confidenceScale))
        do {
            try EpisodeSchemaValidator.validate(payload)
        } catch {
            return nil
        }
        return payload
    }

    private func encodeMessages(_ messages: [SemanticMessageRecord]) -> String {
        let payload = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private func extractJSONObject(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return text
        }
        return String(text[start...end])
    }
}

final class ProfileFactExtractor {
    private let llm: SemanticMemoryLLMClient
    private let logger: AppLogger

    init(llm: SemanticMemoryLLMClient, logger: AppLogger) {
        self.llm = llm
        self.logger = logger
    }

    func extract(messages: [SemanticMessageRecord],
                 confidenceScale: Double = 1.0) async -> [SemanticProfileFactPayload] {
        guard !messages.isEmpty else { return [] }
        let systemPrompt = """
        Extract only stable profile facts/preferences.
        If not stable, use should_store=false.
        Return ONLY a JSON array of objects:
        {
          "kind":"preference|identity|routine|constraint|contact|project",
          "key":"string",
          "value":{},
          "confidence":0.0,
          "should_store":true
        }
        No commentary. JSON only.
        """
        let userPrompt = "Messages:\n\(encodeMessages(messages))"

        let raw: String
        do {
            raw = try await llm.completeJSON(systemPrompt: systemPrompt, userPrompt: userPrompt)
        } catch {
            logger.error("profile_extract_failed", metadata: ["error": error.localizedDescription])
            return []
        }

        if let parsed = decodeFacts(from: raw, confidenceScale: confidenceScale) {
            return parsed
        }

        do {
            let fixed = try await llm.completeJSON(systemPrompt: "FIX JSON ONLY. Return array of profile facts.", userPrompt: raw)
            if let parsed = decodeFacts(from: fixed, confidenceScale: confidenceScale) {
                return parsed
            }
        } catch {
            logger.error("profile_fix_failed", metadata: ["error": error.localizedDescription])
        }

        logger.error("profile_validation_dropped", metadata: ["reason": "unparseable_or_invalid"])
        return []
    }

    private func decodeFacts(from raw: String,
                             confidenceScale: Double) -> [SemanticProfileFactPayload]? {
        let json = extractJSONArray(raw)
        guard let data = json.data(using: .utf8),
              let payloads = try? JSONDecoder().decode([SemanticProfileFactPayload].self, from: data) else {
            return nil
        }

        var output: [SemanticProfileFactPayload] = []
        for var payload in payloads {
            payload.confidence = min(1.0, max(0.0, payload.confidence * confidenceScale))
            do {
                try ProfileFactSchemaValidator.validate(payload)
            } catch {
                continue
            }
            if payload.shouldStore && payload.confidence >= 0.75 {
                output.append(payload)
            }
        }
        return output
    }

    private func encodeMessages(_ messages: [SemanticMessageRecord]) -> String {
        let payload = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private func extractJSONArray(_ text: String) -> String {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]") else {
            return text
        }
        return String(text[start...end])
    }
}

struct MemoryMerger {
    private let store: SemanticMemoryStore
    private let logger: AppLogger

    init(store: SemanticMemoryStore, logger: AppLogger) {
        self.store = store
        self.logger = logger
    }

    func mergeOrCreate(payload: SemanticEpisodePayload,
                       sessionID: String,
                       sourceMessageIDs: [Int64],
                       now: Date = Date()) -> SemanticEpisodeRecord? {
        if let latest = store.latestEpisode(sessionID: sessionID),
           shouldMerge(lhs: latest, rhs: payload, now: now) {
            let merged = mergedPayload(existing: latest.payload, incoming: payload)
            let sourceIDs = Array(Set(latest.sourceMessageIDs + sourceMessageIDs)).sorted()
            let row = store.upsertEpisode(
                id: latest.id,
                sessionID: sessionID,
                payload: merged,
                sourceMessageIDs: sourceIDs,
                now: now
            )
            if let row {
                logger.info("episode_updated", metadata: [
                    "episode_id": row.id,
                    "session_id": sessionID
                ])
            }
            return row
        }

        let row = store.upsertEpisode(
            id: nil,
            sessionID: sessionID,
            payload: payload,
            sourceMessageIDs: sourceMessageIDs,
            now: now
        )
        if let row {
            logger.info("episode_created", metadata: [
                "episode_id": row.id,
                "session_id": sessionID
            ])
        }
        return row
    }

    private func shouldMerge(lhs: SemanticEpisodeRecord,
                             rhs: SemanticEpisodePayload,
                             now: Date) -> Bool {
        let within2Hours = now.timeIntervalSince(lhs.updatedAt) <= 2 * 3600
        guard within2Hours else { return false }
        let titleOverlap = tokenOverlap(lhs.payload.title, rhs.title)
        let tagOverlap = setOverlap(Set(lhs.payload.tags.map { $0.lowercased() }),
                                    Set(rhs.tags.map { $0.lowercased() }))
        return titleOverlap >= 0.60 || tagOverlap >= 0.60
    }

    private func mergedPayload(existing: SemanticEpisodePayload,
                               incoming: SemanticEpisodePayload) -> SemanticEpisodePayload {
        var merged = existing
        merged.summary = incoming.summary.count >= existing.summary.count ? incoming.summary : existing.summary
        merged.entities.people = Array(Set(existing.entities.people + incoming.entities.people)).sorted()
        merged.entities.orgs = Array(Set(existing.entities.orgs + incoming.entities.orgs)).sorted()
        merged.entities.places = Array(Set(existing.entities.places + incoming.entities.places)).sorted()
        merged.facts.when = incoming.facts.when ?? existing.facts.when
        merged.facts.whereValue = incoming.facts.whereValue ?? existing.facts.whereValue
        merged.facts.who = Array(Set(existing.facts.who + incoming.facts.who)).sorted()
        merged.facts.details.merge(incoming.facts.details) { old, new in
            new.count >= old.count ? new : old
        }
        merged.decisions.append(contentsOf: incoming.decisions)
        merged.actions.append(contentsOf: incoming.actions)
        merged.tags = Array(Set(existing.tags + incoming.tags)).sorted()
        merged.importance = max(existing.importance, incoming.importance)
        merged.confidence = max(existing.confidence, incoming.confidence)
        return merged
    }

    private func tokenOverlap(_ a: String, _ b: String) -> Double {
        let lhs = Set(LocalKnowledgeRetriever.tokens(from: a))
        let rhs = Set(LocalKnowledgeRetriever.tokens(from: b))
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private func setOverlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}

struct MemoryRetrieverV1 {
    private let store: SemanticMemoryStore

    init(store: SemanticMemoryStore) {
        self.store = store
    }

    func retrieve(queryText: String,
                  now: Date = Date(),
                  maxEpisodes: Int = 4,
                  maxFacts: Int = 5,
                  includeTodaySummary: Bool = true) -> SemanticRetrievalResult {
        let queryTokens = Set(LocalKnowledgeRetriever.expandedQueryTokens(from: queryText))
        let preferenceCue = isPreferenceRecallQuery(queryText)
        let allEpisodes = store.listEpisodes(limit: 120)
        let allFacts = store.listProfileFacts(limit: 120)

        let scoredEpisodes: [(SemanticEpisodeRecord, Double)] = allEpisodes.compactMap { row in
            let joined = [
                row.payload.title,
                row.payload.summary,
                row.payload.tags.joined(separator: " "),
                row.payload.facts.when ?? "",
                row.payload.facts.whereValue ?? "",
                row.payload.facts.who.joined(separator: " "),
                row.payload.facts.details.values.joined(separator: " ")
            ].joined(separator: " ")
            let tokens = Set(LocalKnowledgeRetriever.expandedQueryTokens(from: joined))
            let overlap = overlapScore(lhs: queryTokens, rhs: tokens)
            guard overlap > 0 else { return nil }
            let recency = recencyBoost(row.updatedAt, now: now, horizonDays: 7)
            let weighted = overlap + recency + (row.payload.importance * 0.25) + (row.payload.confidence * 0.2)
            return (row, weighted)
        }

        let scoredFacts: [(SemanticProfileFactRecord, Double)] = allFacts.compactMap { row in
            let valueText = row.value
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key):\($0.value)" }
                .joined(separator: " ")
            let joined = "\(row.kind.rawValue) \(row.key) \(valueText)"
            let tokens = Set(LocalKnowledgeRetriever.expandedQueryTokens(from: joined))
            let overlap = overlapScore(lhs: queryTokens, rhs: tokens)
            let preferenceMatch = preferenceCue && row.kind == .preference
            guard overlap > 0 || preferenceMatch else { return nil }
            let recency = recencyBoost(row.updatedAt, now: now, horizonDays: 14)
            let weighted = max(overlap, preferenceMatch ? 0.15 : 0.0) + recency + (row.confidence * 0.3)
            return (row, weighted)
        }

        let episodeLimit = max(0, maxEpisodes)
        let topEpisodes = scoredEpisodes
            .sorted(by: { $0.1 > $1.1 })
            .prefix(episodeLimit)
            .map(\.0)

        let factLimit = max(0, maxFacts)
        let topFacts = scoredFacts
            .sorted(by: { $0.1 > $1.1 })
            .prefix(factLimit)
            .map(\.0)

        let hasLowConfidence = topEpisodes.contains { $0.payload.confidence < 0.70 } || topFacts.contains { $0.confidence < 0.70 }
        let hasConflict = hasProfileFactConflict(topFacts)

        let today = SemanticMemoryStore.localDayString(now)
        let summary: SemanticDailySummaryRecord?
        if includeTodaySummary, (!topEpisodes.isEmpty || !topFacts.isEmpty) {
            summary = store.dailySummary(date: today)
        } else {
            summary = nil
        }

        return SemanticRetrievalResult(
            episodes: topEpisodes,
            profileFacts: topFacts,
            dailySummary: summary,
            hasConflict: hasConflict,
            hasLowConfidence: hasLowConfidence
        )
    }

    private func isPreferenceRecallQuery(_ query: String) -> Bool {
        let lower = query.lowercased()
        let cues = [
            "i'm hungry",
            "im hungry",
            "hungry",
            "what should i eat",
            "what do i like to eat",
            "favorite food",
            "favourite food",
            "what food do i like"
        ]
        return cues.contains { lower.contains($0) }
    }

    private func overlapScore(lhs: Set<String>, rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let overlap = Double(lhs.intersection(rhs).count)
        let union = Double(lhs.union(rhs).count)
        guard union > 0 else { return 0 }
        return overlap / union
    }

    private func recencyBoost(_ date: Date, now: Date, horizonDays: Double) -> Double {
        let ageDays = max(0.0, now.timeIntervalSince(date) / 86_400.0)
        if ageDays >= horizonDays { return 0 }
        return (horizonDays - ageDays) / horizonDays * 0.2
    }

    private func hasProfileFactConflict(_ facts: [SemanticProfileFactRecord]) -> Bool {
        var byKey: [String: Set<String>] = [:]
        for fact in facts {
            let key = "\(fact.kind.rawValue)#\(fact.key)"
            let value = fact.value
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "|")
            byKey[key, default: []].insert(value)
        }
        return byKey.values.contains(where: { $0.count > 1 })
    }
}

struct MemoryConfidencePolicy {
    let threshold: Double

    init(threshold: Double = 0.70) {
        self.threshold = threshold
    }

    func shouldClarify(_ retrieval: SemanticRetrievalResult,
                       query: String) -> Bool {
        guard queryDependsOnMemory(query) else { return false }
        if retrieval.hasConflict { return true }
        if retrieval.hasLowConfidence { return true }
        return false
    }

    func clarificationPrompt(_ retrieval: SemanticRetrievalResult) -> String {
        if retrieval.hasConflict {
            return "I found conflicting memory details. Can you confirm which one is correct?"
        }
        return "I have a low-confidence memory for that. Can you confirm it before I act on it?"
    }

    private func queryDependsOnMemory(_ query: String) -> Bool {
        let lower = query.lowercased()
        let triggers = [
            "remember",
            "what do i like",
            "what's my",
            "whats my",
            "my name",
            "i'm hungry",
            "im hungry",
            "favorite",
            "favourite",
            "do i have"
        ]
        return triggers.contains { lower.contains($0) }
    }
}

struct MemoryInjectorV1 {
    private let logger: AppLogger
    private let confidencePolicy: MemoryConfidencePolicy
    private let maxChars: Int

    init(logger: AppLogger,
         confidencePolicy: MemoryConfidencePolicy = MemoryConfidencePolicy(),
         maxChars: Int = 2800) {
        self.logger = logger
        self.confidencePolicy = confidencePolicy
        self.maxChars = max(300, maxChars)
    }

    func inject(query: String, retrieval: SemanticRetrievalResult) -> SemanticInjectionResult {
        let hasAnyMemory = !retrieval.profileFacts.isEmpty || !retrieval.episodes.isEmpty || retrieval.dailySummary != nil
        guard hasAnyMemory else {
            logger.info("memory_injection_size", metadata: [
                "chars": "0",
                "line_count": "0"
            ])
            return SemanticInjectionResult(
                block: "",
                snippets: [],
                shouldClarify: false,
                clarificationPrompt: nil
            )
        }

        var lines: [String] = []
        lines.append("Relevant memories (local, compressed):")

        for fact in retrieval.profileFacts {
            let valueText = fact.value
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            lines.append(
                "fact [\(fact.kind.rawValue)#\(fact.key)] conf=\(format(fact.confidence)) date=\(SemanticMemoryStore.localDayString(fact.updatedAt)) value=\(valueText)"
            )
        }

        for episode in retrieval.episodes {
            let keyFacts = [
                episode.payload.facts.when,
                episode.payload.facts.whereValue,
                episode.payload.facts.who.joined(separator: ", ")
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
            let actions = episode.payload.actions.prefix(2).map(\.task).joined(separator: " | ")
            var line = "episode [\(episode.id.prefix(8))] conf=\(format(episode.payload.confidence)) date=\(SemanticMemoryStore.localDayString(episode.updatedAt)) title=\(episode.payload.title) summary=\(episode.payload.summary)"
            if !keyFacts.isEmpty {
                line += " facts=\(keyFacts)"
            }
            if !actions.isEmpty {
                line += " actions=\(actions)"
            }
            lines.append(line)
        }

        if let summary = retrieval.dailySummary {
            lines.append("daily [\(summary.date)] \(summary.summary)")
        }

        var outputLines: [String] = []
        var usedChars = 0
        for line in lines {
            let next = usedChars + line.count + 1
            if !outputLines.isEmpty && next > maxChars { break }
            if outputLines.isEmpty && line.count > maxChars { continue }
            outputLines.append(line)
            usedChars = next
        }

        let block = outputLines.joined(separator: "\n")
        logger.info("memory_injection_size", metadata: [
            "chars": String(block.count),
            "line_count": String(outputLines.count)
        ])

        let snippets = buildSnippets(from: retrieval)
        let clarify = confidencePolicy.shouldClarify(retrieval, query: query)
        let prompt = clarify ? confidencePolicy.clarificationPrompt(retrieval) : nil
        return SemanticInjectionResult(
            block: block,
            snippets: snippets,
            shouldClarify: clarify,
            clarificationPrompt: prompt
        )
    }

    private func buildSnippets(from retrieval: SemanticRetrievalResult) -> [KnowledgeSourceSnippet] {
        var items: [KnowledgeSourceSnippet] = []
        for fact in retrieval.profileFacts {
            let value = fact.value
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            items.append(
                KnowledgeSourceSnippet(
                    kind: .memory,
                    id: String(fact.id.prefix(8)).lowercased(),
                    label: "Profile \(fact.kind.rawValue)",
                    text: "\(fact.key): \(value)",
                    url: nil
                )
            )
        }
        for episode in retrieval.episodes {
            items.append(
                KnowledgeSourceSnippet(
                    kind: .memory,
                    id: String(episode.id.prefix(8)).lowercased(),
                    label: episode.payload.title,
                    text: episode.payload.summary,
                    url: nil
                )
            )
        }
        return items
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", min(1.0, max(0.0, value)))
    }
}

final class DailySummaryService {
    private let store: SemanticMemoryStore
    private let logger: AppLogger
    private var lastObservedDate: String?

    init(store: SemanticMemoryStore, logger: AppLogger) {
        self.store = store
        self.logger = logger
    }

    func tick(now: Date = Date()) {
        let day = SemanticMemoryStore.localDayString(now)
        if lastObservedDate == nil {
            lastObservedDate = day
            return
        }
        guard let previous = lastObservedDate, previous != day else { return }
        finalize(date: previous)
        lastObservedDate = day
    }

    func finalizeCurrentDay(now: Date = Date()) {
        let date = SemanticMemoryStore.localDayString(now)
        finalize(date: date)
        lastObservedDate = date
    }

    private func finalize(date: String) {
        let episodes = store.episodes(onLocalDate: date)
        guard !episodes.isEmpty else { return }

        var lines: [String] = []
        for (index, episode) in episodes.prefix(20).enumerated() {
            lines.append("\(index + 1). \(episode.payload.title): \(episode.payload.summary)")
        }
        let summary = lines.joined(separator: "\n")
        let episodeIDs = episodes.map(\.id)
        let representativeMessageIDs = episodes.compactMap { $0.sourceMessageIDs.first }
        _ = store.upsertDailySummary(
            date: date,
            summary: summary,
            episodeIDs: episodeIDs,
            representativeMessageIDs: representativeMessageIDs
        )
        logger.info("daily_summary_created", metadata: [
            "date": date,
            "episode_count": String(episodeIDs.count)
        ])
    }
}

@MainActor
final class SemanticMemoryPipeline {
    static var shared = SemanticMemoryPipeline()

    private let store: SemanticMemoryStore
    private let logger: AppLogger
    private let capture: MemoryCaptureService
    private let compressor: EpisodeCompressor
    private let profileExtractor: ProfileFactExtractor
    private let merger: MemoryMerger
    private let retriever: MemoryRetrieverV1
    private let injector: MemoryInjectorV1
    private let dailySummaryService: DailySummaryService

    private(set) var activeSessionID: String = "local_session"

    init(store: SemanticMemoryStore = .shared,
         llm: SemanticMemoryLLMClient = HybridSemanticMemoryLLMClient(),
         logger: AppLogger = JSONLineLogger()) {
        self.store = store
        self.logger = logger
        self.capture = MemoryCaptureService(store: store, logger: logger)
        self.compressor = EpisodeCompressor(llm: llm, logger: logger)
        self.profileExtractor = ProfileFactExtractor(llm: llm, logger: logger)
        self.merger = MemoryMerger(store: store, logger: logger)
        self.retriever = MemoryRetrieverV1(store: store)
        self.injector = MemoryInjectorV1(logger: logger)
        self.dailySummaryService = DailySummaryService(store: store, logger: logger)
    }

    func setActiveSessionID(_ sessionID: String) {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSessionID = trimmed.isEmpty ? "local_session" : trimmed
    }

    func processTurn(sessionID: String,
                     turnID: String?,
                     userMessage: String,
                     assistantMessage: String?,
                     inputSource: String,
                     sttConfidence: Double?,
                     now: Date = Date()) async {
        guard store.isAvailable else { return }
        setActiveSessionID(sessionID)
        dailySummaryService.tick(now: now)
        let chunks = capture.captureTurn(
            sessionID: activeSessionID,
            turnID: turnID,
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            inputSource: inputSource,
            sttConfidence: sttConfidence,
            now: now
        )
        for chunk in chunks {
            await compress(chunk: chunk, now: now)
        }
    }

    func flushForLifecycle(now: Date = Date()) async {
        if let chunk = capture.flush(sessionID: activeSessionID, now: now) {
            await compress(chunk: chunk, now: now)
        }
        dailySummaryService.finalizeCurrentDay(now: now)
    }

    func injectionContext(for query: String) -> SemanticInjectionResult {
        let retrieval = retriever.retrieve(
            queryText: query,
            now: Date(),
            maxEpisodes: 4,
            maxFacts: 5,
            includeTodaySummary: true
        )
        logger.info("memory_retrieval", metadata: [
            "session_id": activeSessionID,
            "episodes": String(retrieval.episodes.count),
            "facts": String(retrieval.profileFacts.count),
            "conflict": retrieval.hasConflict ? "true" : "false",
            "low_confidence": retrieval.hasLowConfidence ? "true" : "false"
        ])
        return injector.inject(query: query, retrieval: retrieval)
    }

    func listEpisodes(limit: Int = 80) -> [SemanticEpisodeRecord] {
        store.listEpisodes(limit: limit)
    }

    func episode(id: String) -> SemanticEpisodeRecord? {
        store.episode(id: id)
    }

    @discardableResult
    func deleteEpisode(id: String) -> Bool {
        store.deleteEpisode(id: id)
    }

    func exportEpisodeJSON(id: String) -> String? {
        store.exportEpisodeJSON(id: id)
    }

    func clearForTesting() {
        store.clearSemanticTables()
    }

    private func compress(chunk: SemanticMemoryChunk, now: Date) async {
        let startedAt = Date()
        let messages = store.messages(ids: chunk.messageIDs)
        guard !messages.isEmpty else { return }
        let confidenceScale = confidenceScaleFromMeta(messages)

        if let episodePayload = await compressor.compress(messages: messages, confidenceScale: confidenceScale),
           let episode = merger.mergeOrCreate(payload: episodePayload, sessionID: chunk.sessionID, sourceMessageIDs: chunk.messageIDs, now: now) {
            if !store.hasMemoryLinks(memoryType: .episode, memoryID: episode.id) {
                _ = store.addMemoryLinks(memoryType: .episode, memoryID: episode.id, messageIDs: chunk.messageIDs, weight: episode.payload.confidence, note: "episode_link_backfill")
            }
        }

        let profileFacts = await profileExtractor.extract(messages: messages, confidenceScale: confidenceScale)
        for fact in profileFacts {
            if let row = store.upsertProfileFact(payload: fact, sourceMessageIDs: chunk.messageIDs, now: now) {
                logger.info("profile_fact_upserted", metadata: [
                    "fact_id": row.id,
                    "kind": row.kind.rawValue,
                    "key": row.key
                ])
                if !store.hasMemoryLinks(memoryType: .profileFact, memoryID: row.id) {
                    _ = store.addMemoryLinks(memoryType: .profileFact, memoryID: row.id, messageIDs: chunk.messageIDs, weight: row.confidence, note: "profile_link_backfill")
                }
            }
        }

        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.info("memory_chunk_processed", metadata: [
            "session_id": chunk.sessionID,
            "message_count": String(messages.count),
            "latency_ms": String(latencyMs)
        ])
    }

    private func confidenceScaleFromMeta(_ messages: [SemanticMessageRecord]) -> Double {
        let sttScores = messages.compactMap { message -> Double? in
            guard let metaJSON = message.metaJSON,
                  let data = metaJSON.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let raw = dict["stt_confidence"],
                  let score = Double(raw),
                  score > 0 else {
                return nil
            }
            return score
        }
        guard let minScore = sttScores.min() else { return 1.0 }
        if minScore < 0.4 { return 0.55 }
        if minScore < 0.6 { return 0.70 }
        if minScore < 0.75 { return 0.85 }
        return 1.0
    }
}
