import Foundation
import SQLite3

// MARK: - World Model Types

enum WorldEntityType: String, Codable, CaseIterable {
    case person, place, project, preference, habit, event, concept
}

enum WorldRelationshipType: String, Codable, CaseIterable {
    case knows, worksWith, locatedAt, interestedIn, dislikes, relatedTo, dependsOn

    var label: String {
        switch self {
        case .knows: return "knows"
        case .worksWith: return "works with"
        case .locatedAt: return "located at"
        case .interestedIn: return "interested in"
        case .dislikes: return "dislikes"
        case .relatedTo: return "related to"
        case .dependsOn: return "depends on"
        }
    }
}

struct WorldEntity: Codable {
    let id: UUID
    let name: String
    let canonicalName: String
    let type: WorldEntityType
    var metadata: [String: String]
    var mentionCount: Int
    var freshnessScore: Double
    var importanceScore: Double
    let firstSeenAt: Date
    var lastSeenAt: Date
    var isArchived: Bool
}

struct WorldRelationship: Codable {
    let id: UUID
    let sourceEntityID: UUID
    let targetEntityID: UUID
    let type: WorldRelationshipType
    var strength: Double
    var mentionCount: Int
    var metadata: [String: String]
    let firstSeenAt: Date
    var lastSeenAt: Date
}

// MARK: - Living World Model

/// Causal graph engine that models the user's world.
/// Entities (people, places, projects, preferences) and relationships are extracted
/// from conversation via LLM and persisted as a knowledge graph.
/// The graph is queried per-turn to inject relevant world context into prompts.
@MainActor
final class LivingWorldModel {

    static let shared = LivingWorldModel()

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    private init() {
        do {
            try openDatabase()
            try createTables()
            isAvailable = true
        } catch {
            #if DEBUG
            print("[WORLD_MODEL] DB init failed: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Extract entities and relationships from conversation text.
    /// Called after each turn to incrementally build the world graph.
    func processConversation(turnID: String, text: String) async {
        guard isAvailable else { return }

        let startedAt = CFAbsoluteTimeGetCurrent()

        do {
            let extraction = try await extractEntities(from: text)

            for entityPayload in extraction.entities {
                upsertEntity(entityPayload)
            }
            for relPayload in extraction.relationships {
                upsertRelationship(relPayload)
            }

            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            #if DEBUG
            print("[WORLD_MODEL] turn=\(turnID) entities=\(extraction.entities.count) rels=\(extraction.relationships.count) ms=\(elapsedMs)")
            #endif
        } catch {
            #if DEBUG
            print("[WORLD_MODEL] extraction failed: \(error)")
            #endif
        }
    }

    /// Query the world graph for entities relevant to a given input.
    /// Returns a formatted string for prompt injection.
    func worldContextBlock(for input: String, limit: Int = 5) -> String {
        guard isAvailable else { return "" }

        let entities = relevantEntities(for: input, limit: limit)
        guard !entities.isEmpty else { return "" }

        var lines: [String] = ["World context:"]
        let grouped = Dictionary(grouping: entities, by: { $0.type })

        for type in WorldEntityType.allCases {
            guard let group = grouped[type], !group.isEmpty else { continue }
            let header = type.rawValue.capitalized
            let items = group.map { entity in
                let rels = relationships(for: entity.id, limit: 3)
                let relStr = rels.isEmpty ? "" : " (\(rels.map { "\($0.type.label) \(entityName(for: $0.targetEntityID) ?? "?")" }.joined(separator: ", ")))"
                return "  - \(entity.name)\(relStr)"
            }
            lines.append("[\(header)]")
            lines.append(contentsOf: items)
        }

        return lines.joined(separator: "\n")
    }

    /// Apply exponential decay to freshness scores.
    /// Call periodically (e.g. daily) to fade stale entities.
    func decayFreshnessScores() {
        guard isAvailable else { return }
        // exp(-0.05 * days) ≈ 20-day half-life
        let sql = """
        UPDATE world_entities
        SET freshness_score = freshness_score * exp(-0.05 * (julianday('now') - julianday(last_seen_at, 'unixepoch')))
        WHERE is_archived = 0 AND freshness_score > 0.01;
        """
        sqlite3_exec(db, sql, nil, nil, nil)

        // Archive entities that have decayed below threshold
        let archiveSql = """
        UPDATE world_entities SET is_archived = 1
        WHERE freshness_score < 0.01 AND is_archived = 0;
        """
        sqlite3_exec(db, archiveSql, nil, nil, nil)
    }

    /// Total entity count (for diagnostics).
    func entityCount() -> Int {
        guard isAvailable else { return 0 }
        let sql = "SELECT COUNT(*) FROM world_entities WHERE is_archived = 0;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Entity Extraction (LLM)

    private struct ExtractionResult {
        let entities: [EntityPayload]
        let relationships: [RelationshipPayload]
    }

    private struct EntityPayload {
        let name: String
        let type: WorldEntityType
        let importance: Double
        let metadata: [String: String]
    }

    private struct RelationshipPayload {
        let sourceName: String
        let targetName: String
        let type: WorldRelationshipType
        let strength: Double
    }

    private func extractEntities(from text: String) async throws -> ExtractionResult {
        let systemPrompt = """
        You extract persistent world entities from conversation. Return JSON with:
        {"entities": [{"name": "...", "type": "person|place|project|preference|habit|event|concept", "importance": 0.0-2.0, "metadata": {}}],
         "relationships": [{"source": "...", "target": "...", "type": "knows|worksWith|locatedAt|interestedIn|dislikes|relatedTo|dependsOn", "strength": 0.0-1.0}]}
        Only extract entities that are persistent and meaningful — not transient mentions.
        """
        let userPrompt = "Extract entities and relationships from: \"\(text)\""

        let raw = try await IntelligenceLLMClient.hybridJSON(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            ollamaMaxTokens: 500,
            openAIMaxTokens: 1000
        )

        guard let parsed = IntelligenceLLMClient.parseJSON(raw) else {
            return ExtractionResult(entities: [], relationships: [])
        }

        let entityDicts = parsed["entities"] as? [[String: Any]] ?? []
        let relDicts = parsed["relationships"] as? [[String: Any]] ?? []

        let entities: [EntityPayload] = entityDicts.compactMap { dict in
            guard let name = dict["name"] as? String,
                  let typeStr = dict["type"] as? String,
                  let type = WorldEntityType(rawValue: typeStr) else { return nil }
            let importance = (dict["importance"] as? NSNumber)?.doubleValue ?? 1.0
            let metadata = dict["metadata"] as? [String: String] ?? [:]
            return EntityPayload(name: name, type: type, importance: min(2.0, max(0.0, importance)), metadata: metadata)
        }

        let relationships: [RelationshipPayload] = relDicts.compactMap { dict in
            guard let source = dict["source"] as? String,
                  let target = dict["target"] as? String,
                  let typeStr = dict["type"] as? String,
                  let type = WorldRelationshipType(rawValue: typeStr) else { return nil }
            let strength = (dict["strength"] as? NSNumber)?.doubleValue ?? 0.5
            return RelationshipPayload(sourceName: source, targetName: target, type: type, strength: min(1.0, max(0.0, strength)))
        }

        return ExtractionResult(entities: entities, relationships: relationships)
    }

    // MARK: - Graph Queries

    private func relevantEntities(for input: String, limit: Int) -> [WorldEntity] {
        guard isAvailable else { return [] }
        let keywords = input.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 2 }

        // Score = freshness * importance * log(mentions + 1), boosted by keyword match
        let sql = """
        SELECT id, name, canonical_name, type, metadata_json, mention_count,
               freshness_score, importance_score, first_seen_at, last_seen_at, is_archived
        FROM world_entities
        WHERE is_archived = 0
        ORDER BY (freshness_score * importance_score * (1 + log(mention_count + 1))) DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(limit * 3)) // Over-fetch for keyword filtering

        var candidates: [(entity: WorldEntity, score: Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let entity = decodeEntity(stmt) else { continue }
            let baseScore = entity.freshnessScore * entity.importanceScore * log(Double(entity.mentionCount + 1) + 1)
            let nameWords = entity.canonicalName.components(separatedBy: "_")
            let keywordBoost = keywords.contains(where: { kw in
                nameWords.contains(where: { $0.contains(kw) || kw.contains($0) })
            }) ? 2.0 : 1.0
            candidates.append((entity, baseScore * keywordBoost))
        }

        return candidates
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.entity)
    }

    private func relationships(for entityID: UUID, limit: Int = 5) -> [WorldRelationship] {
        guard isAvailable else { return [] }
        let sql = """
        SELECT id, source_entity_id, target_entity_id, type, strength,
               mention_count, metadata_json, first_seen_at, last_seen_at
        FROM world_relationships
        WHERE source_entity_id = ?
        ORDER BY strength DESC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, (entityID.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [WorldRelationship] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let rel = decodeRelationship(stmt) {
                results.append(rel)
            }
        }
        return results
    }

    private func entityName(for id: UUID) -> String? {
        guard isAvailable else { return nil }
        let sql = "SELECT name FROM world_entities WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    private func findEntity(canonicalName: String) -> WorldEntity? {
        guard isAvailable else { return nil }
        let sql = """
        SELECT id, name, canonical_name, type, metadata_json, mention_count,
               freshness_score, importance_score, first_seen_at, last_seen_at, is_archived
        FROM world_entities WHERE canonical_name = ? AND is_archived = 0;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (canonicalName as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeEntity(stmt)
    }

    // MARK: - Upsert

    private func upsertEntity(_ payload: EntityPayload) {
        let canonical = payload.name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: .punctuationCharacters)

        if let existing = findEntity(canonicalName: canonical) {
            // Update existing entity
            let sql = """
            UPDATE world_entities
            SET mention_count = mention_count + 1,
                freshness_score = 1.0,
                importance_score = MAX(importance_score, ?),
                last_seen_at = ?,
                metadata_json = ?
            WHERE id = ?;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            // Merge metadata
            var merged = existing.metadata
            for (k, v) in payload.metadata { merged[k] = v }
            let metaJSON = (try? JSONSerialization.data(withJSONObject: merged))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            sqlite3_bind_double(stmt, 1, payload.importance)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (metaJSON as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (existing.id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        } else {
            // Insert new entity
            let sql = """
            INSERT INTO world_entities
            (id, name, canonical_name, type, metadata_json, mention_count,
             freshness_score, importance_score, first_seen_at, last_seen_at, is_archived)
            VALUES (?, ?, ?, ?, ?, 1, 1.0, ?, ?, ?, 0);
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

            let id = UUID()
            let now = Date().timeIntervalSince1970
            let metaJSON = (try? JSONSerialization.data(withJSONObject: payload.metadata))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (payload.name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (canonical as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (payload.type.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (metaJSON as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 6, payload.importance)
            sqlite3_bind_double(stmt, 7, now)
            sqlite3_bind_double(stmt, 8, now)
            sqlite3_step(stmt)
        }
    }

    private func upsertRelationship(_ payload: RelationshipPayload) {
        let sourceCanonical = payload.sourceName.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: .punctuationCharacters)
        let targetCanonical = payload.targetName.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .trimmingCharacters(in: .punctuationCharacters)

        guard let source = findEntity(canonicalName: sourceCanonical),
              let target = findEntity(canonicalName: targetCanonical) else { return }

        // Check existing
        let checkSql = """
        SELECT id, mention_count FROM world_relationships
        WHERE source_entity_id = ? AND target_entity_id = ? AND type = ?;
        """
        var checkStmt: OpaquePointer?
        sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil)
        sqlite3_bind_text(checkStmt, 1, (source.id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(checkStmt, 2, (target.id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(checkStmt, 3, (payload.type.rawValue as NSString).utf8String, -1, nil)

        if sqlite3_step(checkStmt) == SQLITE_ROW {
            let existingID = String(cString: sqlite3_column_text(checkStmt, 0))
            sqlite3_finalize(checkStmt)

            let updateSql = """
            UPDATE world_relationships
            SET mention_count = mention_count + 1,
                strength = MIN(1.0, strength + 0.1),
                last_seen_at = ?
            WHERE id = ?;
            """
            var updateStmt: OpaquePointer?
            defer { sqlite3_finalize(updateStmt) }
            guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(updateStmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(updateStmt, 2, (existingID as NSString).utf8String, -1, nil)
            sqlite3_step(updateStmt)
        } else {
            sqlite3_finalize(checkStmt)

            let insertSql = """
            INSERT INTO world_relationships
            (id, source_entity_id, target_entity_id, type, strength,
             mention_count, metadata_json, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, 1, '{}', ?, ?);
            """
            var insertStmt: OpaquePointer?
            defer { sqlite3_finalize(insertStmt) }
            guard sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else { return }

            let id = UUID()
            let now = Date().timeIntervalSince1970
            sqlite3_bind_text(insertStmt, 1, (id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 2, (source.id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 3, (target.id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStmt, 4, (payload.type.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_double(insertStmt, 5, payload.strength)
            sqlite3_bind_double(insertStmt, 6, now)
            sqlite3_bind_double(insertStmt, 7, now)
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
        CREATE TABLE IF NOT EXISTS world_entities (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            canonical_name TEXT NOT NULL,
            type TEXT NOT NULL,
            metadata_json TEXT DEFAULT '{}',
            mention_count INTEGER DEFAULT 1,
            freshness_score REAL DEFAULT 1.0,
            importance_score REAL DEFAULT 1.0,
            first_seen_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            is_archived INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_world_entities_type ON world_entities(type);
        CREATE INDEX IF NOT EXISTS idx_world_entities_canonical ON world_entities(canonical_name);
        CREATE INDEX IF NOT EXISTS idx_world_entities_last_seen ON world_entities(last_seen_at);
        CREATE TABLE IF NOT EXISTS world_relationships (
            id TEXT PRIMARY KEY,
            source_entity_id TEXT NOT NULL,
            target_entity_id TEXT NOT NULL,
            type TEXT NOT NULL,
            strength REAL DEFAULT 0.5,
            mention_count INTEGER DEFAULT 1,
            metadata_json TEXT DEFAULT '{}',
            first_seen_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            FOREIGN KEY (source_entity_id) REFERENCES world_entities(id),
            FOREIGN KEY (target_entity_id) REFERENCES world_entities(id)
        );
        CREATE INDEX IF NOT EXISTS idx_world_rels_source ON world_relationships(source_entity_id);
        CREATE INDEX IF NOT EXISTS idx_world_rels_target ON world_relationships(target_entity_id);
        CREATE INDEX IF NOT EXISTS idx_world_rels_type ON world_relationships(type);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("World model table creation failed")
        }
    }

    // MARK: - Row Decoding

    private func decodeEntity(_ stmt: OpaquePointer?) -> WorldEntity? {
        guard let stmt else { return nil }
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr) else { return nil }

        let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let canonicalName = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let typeStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "concept"
        let type = WorldEntityType(rawValue: typeStr) ?? .concept
        let metaRaw = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "{}"
        let metadata = (try? JSONSerialization.jsonObject(with: Data(metaRaw.utf8)) as? [String: String]) ?? [:]
        let mentionCount = Int(sqlite3_column_int(stmt, 5))
        let freshnessScore = sqlite3_column_double(stmt, 6)
        let importanceScore = sqlite3_column_double(stmt, 7)
        let firstSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        let lastSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        let isArchived = sqlite3_column_int(stmt, 10) == 1

        return WorldEntity(
            id: id, name: name, canonicalName: canonicalName, type: type,
            metadata: metadata, mentionCount: mentionCount,
            freshnessScore: freshnessScore, importanceScore: importanceScore,
            firstSeenAt: firstSeenAt, lastSeenAt: lastSeenAt, isArchived: isArchived
        )
    }

    private func decodeRelationship(_ stmt: OpaquePointer?) -> WorldRelationship? {
        guard let stmt else { return nil }
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id = UUID(uuidString: idStr),
              let sourceStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
              let sourceID = UUID(uuidString: sourceStr),
              let targetStr = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
              let targetID = UUID(uuidString: targetStr) else { return nil }

        let typeStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "relatedTo"
        let type = WorldRelationshipType(rawValue: typeStr) ?? .relatedTo
        let strength = sqlite3_column_double(stmt, 4)
        let mentionCount = Int(sqlite3_column_int(stmt, 5))
        let metaRaw = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "{}"
        let metadata = (try? JSONSerialization.jsonObject(with: Data(metaRaw.utf8)) as? [String: String]) ?? [:]
        let firstSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let lastSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))

        return WorldRelationship(
            id: id, sourceEntityID: sourceID, targetEntityID: targetID,
            type: type, strength: strength, mentionCount: mentionCount,
            metadata: metadata, firstSeenAt: firstSeenAt, lastSeenAt: lastSeenAt
        )
    }
}
