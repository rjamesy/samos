import Foundation
import SQLite3

// MARK: - Theory of Mind Types

struct PersonProfile: Codable {
    let personID: String
    let name: String
    let role: String               // boss, partner, friend, parent, colleague, etc.
    let relationship: String       // user's relationship to this person
    var communicationStyle: String  // direct, passive-aggressive, warm, formal, etc.
    var values: [String]           // what they care about
    var emotionalPatterns: [String] // how they typically react
    var summary: String            // GPT-generated psychological summary
    var confidence: Double         // 0.0-1.0 how well Sam knows this person
    var memoryCount: Int
    var lastUpdated: Date
}

// MARK: - Theory of Mind Engine

/// Models other people's beliefs, motivations, and likely reactions.
/// Maintains cognitive profiles per person mentioned in conversation.
/// Uses Ollama for fast person detection, GPT-5.2 for deep profiling and reaction prediction.
@MainActor
final class TheoryOfMindEngine {

    static let shared = TheoryOfMindEngine()

    private var db: OpaquePointer?
    private(set) var isAvailable = false

    /// Cache profiles in memory for fast access
    private var profileCache: [String: PersonProfile] = [:]

    private init() {
        do {
            try openDatabase()
            try createTables()
            isAvailable = true
            loadCachedProfiles()
        } catch {
            #if DEBUG
            print("[TOM] DB init failed: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Process conversation: detect people mentions, record interactions, update profiles.
    func processConversation(turnID: String, userText: String) async {
        guard isAvailable else { return }

        // Stage 1: Fast person detection via Ollama
        let mentions = await detectPeopleMentions(userText: userText)
        guard !mentions.isEmpty else { return }

        for mention in mentions {
            let personID = ensurePerson(name: mention.name, role: mention.role, relationship: mention.relationship)
            recordMemory(personID: personID, excerpt: userText, inferredTraits: mention.inferredTraits)

            // Update profile if enough new memories accumulated
            let memCount = memoryCount(for: personID)
            let existing = profileCache[personID]
            if memCount >= 3 && (existing == nil || existing!.confidence < 0.7 || memCount % 5 == 0) {
                await updateProfile(personID: personID)
            }
        }
    }

    /// Predict how a person would react to a situation. Returns nil if unknown person.
    func predictReaction(personName: String, situation: String) async -> String? {
        guard isAvailable else { return nil }
        guard let profile = findProfile(name: personName), profile.confidence >= 0.3 else { return nil }

        let systemPrompt = """
        You are role-playing as \(profile.name), a \(profile.role) who is \(profile.communicationStyle).
        Their values: \(profile.values.joined(separator: ", ")).
        Their emotional patterns: \(profile.emotionalPatterns.joined(separator: ", ")).
        Profile: \(profile.summary)
        Predict how this person would REACT to the described situation. Stay in character.
        Return ONLY valid JSON: {"reaction": "their likely response (2-3 sentences)", "emotion": "primary emotion", "confidence": 0.0-1.0}
        """
        let userPrompt = "Situation: \(situation)"

        do {
            let raw = try await IntelligenceLLMClient.openAIJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 400
            )
            if let parsed = IntelligenceLLMClient.parseJSON(raw) {
                return parsed["reaction"] as? String
            }
        } catch {
            #if DEBUG
            print("[TOM] reaction prediction failed: \(error)")
            #endif
        }
        return nil
    }

    /// Build social context block for prompt injection.
    func socialContextBlock(for userText: String) -> String {
        let lower = userText.lowercased()
        let relevantProfiles = profileCache.values.filter { profile in
            lower.contains(profile.name.lowercased()) || lower.contains(profile.role.lowercased())
        }
        guard !relevantProfiles.isEmpty else { return "" }

        var lines = ["People Sam knows about:"]
        for profile in relevantProfiles.prefix(3) {
            lines.append("- \(profile.name) (\(profile.role)): \(profile.communicationStyle). Values: \(profile.values.prefix(3).joined(separator: ", ")). \(profile.summary)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Person Detection (Ollama — fast)

    private struct PersonMention {
        let name: String
        let role: String
        let relationship: String
        let inferredTraits: String
    }

    private func detectPeopleMentions(userText: String) async -> [PersonMention] {
        let systemPrompt = """
        Extract mentions of OTHER PEOPLE (not the user) from the text.
        Return ONLY valid JSON: {"people": [{"name": "...", "role": "...", "relationship": "...", "inferred_traits": "..."}]}
        role = boss, partner, friend, parent, sibling, child, colleague, neighbor, doctor, etc.
        relationship = how the user relates to them.
        inferred_traits = any personality traits you can infer from context.
        If no people are mentioned, return {"people": []}.
        """
        let userPrompt = "Text: \"\(userText)\""

        do {
            let raw = try await IntelligenceLLMClient.engineJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 400
            )
            guard let parsed = IntelligenceLLMClient.parseJSON(raw),
                  let people = parsed["people"] as? [[String: Any]] else { return [] }

            return people.compactMap { p in
                guard let name = p["name"] as? String, !name.isEmpty else { return nil }
                return PersonMention(
                    name: name,
                    role: p["role"] as? String ?? "unknown",
                    relationship: p["relationship"] as? String ?? "",
                    inferredTraits: p["inferred_traits"] as? String ?? ""
                )
            }
        } catch {
            #if DEBUG
            print("[TOM] person detection failed: \(error)")
            #endif
            return []
        }
    }

    // MARK: - Profile Building (GPT-5.2)

    private func updateProfile(personID: String) async {
        let memories = loadMemories(personID: personID, limit: 20)
        guard !memories.isEmpty else { return }

        let existing = profileCache[personID]
        let memoriesText = memories.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        let systemPrompt = """
        You are building a psychological profile of a person based on conversation excerpts.
        Analyze the excerpts and produce a comprehensive profile.
        Return ONLY valid JSON:
        {
          "communication_style": "how they communicate (1-3 words)",
          "values": ["what they care about"],
          "emotional_patterns": ["how they typically react emotionally"],
          "summary": "2-3 sentence psychological profile",
          "confidence": 0.0-1.0
        }
        """
        let userPrompt = """
        Person: \(existing?.name ?? "Unknown") (role: \(existing?.role ?? "unknown"))
        Conversation excerpts mentioning them:
        \(memoriesText)
        """

        do {
            let raw = try await IntelligenceLLMClient.openAIJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 600
            )
            guard let parsed = IntelligenceLLMClient.parseJSON(raw) else { return }

            let commStyle = parsed["communication_style"] as? String ?? existing?.communicationStyle ?? "unknown"
            let values = parsed["values"] as? [String] ?? existing?.values ?? []
            let patterns = parsed["emotional_patterns"] as? [String] ?? existing?.emotionalPatterns ?? []
            let summary = parsed["summary"] as? String ?? existing?.summary ?? ""
            let confidence = (parsed["confidence"] as? NSNumber)?.doubleValue ?? 0.5

            persistProfile(personID: personID, communicationStyle: commStyle, values: values,
                          emotionalPatterns: patterns, summary: summary, confidence: confidence)

            if var cached = profileCache[personID] {
                cached.communicationStyle = commStyle
                cached.values = values
                cached.emotionalPatterns = patterns
                cached.summary = summary
                cached.confidence = confidence
                cached.lastUpdated = Date()
                profileCache[personID] = cached
            }

            #if DEBUG
            print("[TOM] profile updated: \(existing?.name ?? personID) confidence=\(String(format: "%.2f", confidence))")
            #endif
        } catch {
            #if DEBUG
            print("[TOM] profile update failed: \(error)")
            #endif
        }
    }

    // MARK: - Persistence

    private func ensurePerson(name: String, role: String, relationship: String) -> String {
        let canonical = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = profileCache.values.first(where: { $0.name.lowercased() == canonical }) {
            return existing.personID
        }

        let personID = UUID().uuidString
        let sql = "INSERT OR IGNORE INTO tom_persons (id, name, role, relationship, created_at) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return personID }
        sqlite3_bind_text(stmt, 1, (personID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (role as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (relationship as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_step(stmt)

        profileCache[personID] = PersonProfile(
            personID: personID, name: name, role: role, relationship: relationship,
            communicationStyle: "unknown", values: [], emotionalPatterns: [],
            summary: "", confidence: 0.0, memoryCount: 0, lastUpdated: Date()
        )
        return personID
    }

    private func recordMemory(personID: String, excerpt: String, inferredTraits: String) {
        let sql = "INSERT INTO tom_memories (id, person_id, excerpt, inferred_traits, created_at) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (UUID().uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (personID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (excerpt as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (inferredTraits as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func memoryCount(for personID: String) -> Int {
        let sql = "SELECT COUNT(*) FROM tom_memories WHERE person_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, (personID as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func loadMemories(personID: String, limit: Int) -> [String] {
        let sql = "SELECT excerpt FROM tom_memories WHERE person_id = ? ORDER BY created_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, (personID as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) { results.append(String(cString: text)) }
        }
        return results
    }

    private func persistProfile(personID: String, communicationStyle: String, values: [String],
                                emotionalPatterns: [String], summary: String, confidence: Double) {
        let valuesJSON = (try? JSONSerialization.data(withJSONObject: values)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let patternsJSON = (try? JSONSerialization.data(withJSONObject: emotionalPatterns)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let sql = """
        INSERT OR REPLACE INTO tom_profiles (person_id, communication_style, values_json, emotional_patterns_json, summary, confidence, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (personID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (communicationStyle as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (valuesJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (patternsJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (summary as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 6, confidence)
        sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    private func findProfile(name: String) -> PersonProfile? {
        let canonical = name.lowercased()
        return profileCache.values.first { $0.name.lowercased() == canonical }
    }

    private func loadCachedProfiles() {
        let sql = """
        SELECT p.id, p.name, p.role, p.relationship, pr.communication_style, pr.values_json, pr.emotional_patterns_json, pr.summary, pr.confidence, pr.updated_at
        FROM tom_persons p LEFT JOIN tom_profiles pr ON p.id = pr.person_id;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let personID = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let role = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let relationship = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let commStyle = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "unknown"
            let valuesRaw = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "[]"
            let patternsRaw = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "[]"
            let summary = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            let confidence = sqlite3_column_double(stmt, 8)
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))

            let values = (try? JSONSerialization.jsonObject(with: Data(valuesRaw.utf8)) as? [String]) ?? []
            let patterns = (try? JSONSerialization.jsonObject(with: Data(patternsRaw.utf8)) as? [String]) ?? []

            profileCache[personID] = PersonProfile(
                personID: personID, name: name, role: role, relationship: relationship,
                communicationStyle: commStyle, values: values, emotionalPatterns: patterns,
                summary: summary, confidence: confidence, memoryCount: 0, lastUpdated: updatedAt
            )
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
        CREATE TABLE IF NOT EXISTS tom_persons (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT, relationship TEXT, created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tom_profiles (
            person_id TEXT PRIMARY KEY, communication_style TEXT, values_json TEXT, emotional_patterns_json TEXT,
            summary TEXT, confidence REAL DEFAULT 0.0, updated_at REAL,
            FOREIGN KEY(person_id) REFERENCES tom_persons(id)
        );
        CREATE TABLE IF NOT EXISTS tom_memories (
            id TEXT PRIMARY KEY, person_id TEXT NOT NULL, excerpt TEXT NOT NULL, inferred_traits TEXT,
            created_at REAL NOT NULL, FOREIGN KEY(person_id) REFERENCES tom_persons(id)
        );
        CREATE INDEX IF NOT EXISTS idx_tom_memories_person ON tom_memories(person_id);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("TOM tables creation failed")
        }
    }
}
