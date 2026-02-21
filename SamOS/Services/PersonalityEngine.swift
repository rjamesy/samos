import Foundation
import SQLite3

// MARK: - Personality Types

/// Relationship depth between Sam and the user, evolving over interactions.
enum RelationshipDepth: String, Codable, CaseIterable {
    case stranger       // First few interactions
    case acquaintance   // 5-20 interactions, basic facts known
    case friend         // 20-100 interactions, shared history
    case confidant      // 100+ interactions, deep trust

    var next: RelationshipDepth {
        switch self {
        case .stranger: return .acquaintance
        case .acquaintance: return .friend
        case .friend: return .confidant
        case .confidant: return .confidant
        }
    }

    /// Minimum interaction count to reach this depth.
    var threshold: Int {
        switch self {
        case .stranger: return 0
        case .acquaintance: return 5
        case .friend: return 20
        case .confidant: return 100
        }
    }
}

/// Trait sliders that define Sam's personality profile.
struct PersonalityTraits: Codable {
    var warmth: Double       // 0.0 = clinical, 1.0 = deeply warm
    var playfulness: Double  // 0.0 = serious, 1.0 = playful/witty
    var directness: Double   // 0.0 = diplomatic, 1.0 = blunt
    var curiosity: Double    // 0.0 = reactive, 1.0 = deeply curious
    var sarcasm: Double      // 0.0 = earnest, 1.0 = sarcastic edge

    /// Default personality: warm, moderately playful, direct, curious, low sarcasm.
    static let `default` = PersonalityTraits(
        warmth: 0.75,
        playfulness: 0.5,
        directness: 0.65,
        curiosity: 0.7,
        sarcasm: 0.15
    )

    /// Generate a personality description for injection into the system prompt.
    func promptDescription(depth: RelationshipDepth) -> String {
        var lines: [String] = []

        // Warmth
        if warmth > 0.7 {
            lines.append("- You're genuinely warm. Show you care through specifics, not platitudes.")
        } else if warmth > 0.4 {
            lines.append("- You're friendly but grounded. Warm without being sappy.")
        } else {
            lines.append("- You're calm and measured. Warmth through competence, not effusiveness.")
        }

        // Playfulness
        if playfulness > 0.6 {
            lines.append("- You enjoy wordplay, light humor, and surprising the user. Be fun.")
        } else if playfulness > 0.3 {
            lines.append("- A touch of humor when it fits. Don't force it.")
        }

        // Directness
        if directness > 0.6 {
            lines.append("- Be direct. Say what you think. No hedging or over-qualifying.")
        } else {
            lines.append("- Be thoughtful in how you phrase things. Gentle honesty.")
        }

        // Curiosity
        if curiosity > 0.6 {
            lines.append("- You're genuinely curious about the user. Ask real questions, not performative ones.")
        }

        // Sarcasm
        if sarcasm > 0.4 {
            lines.append("- A bit of dry wit is welcome. The user appreciates edge.")
        }

        // Relationship depth modifiers
        switch depth {
        case .stranger:
            lines.append("- You're just meeting this person. Be warm but don't assume familiarity.")
        case .acquaintance:
            lines.append("- You're getting to know each other. Reference things you've learned. Build on past conversations.")
        case .friend:
            lines.append("- You know this person well. Be casual, reference shared history, have opinions about their life.")
        case .confidant:
            lines.append("- This person trusts you deeply. Be real with them. Challenge them when needed. Celebrate with them. You're in this together.")
        }

        return lines.joined(separator: "\n")
    }
}

/// Snapshot of Sam's current personality state.
struct PersonalityState: Codable {
    var traits: PersonalityTraits
    var depth: RelationshipDepth
    var interactionCount: Int
    var lastInteraction: Date
    var mood: String           // current energy: "neutral", "energized", "reflective", "playful"
    var userPreferredName: String?
}

// MARK: - Personality Engine

/// Tracks and evolves Sam's personality based on interactions.
/// Manages trait sliders, relationship depth, and personality context injection.
@MainActor
final class PersonalityEngine {

    static let shared = PersonalityEngine()

    private var db: OpaquePointer?
    private(set) var isAvailable = false
    private var cachedState: PersonalityState?

    /// EMA alpha for trait adaptation
    private let traitAlpha: Double = 0.1

    private init() {
        do {
            try openDatabase()
            try createTables()
            isAvailable = true
            cachedState = loadState()
        } catch {
            #if DEBUG
            print("[PERSONALITY] DB init failed: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Get the current personality state, initializing defaults if needed.
    func currentState() -> PersonalityState {
        if let cached = cachedState { return cached }
        let initial = PersonalityState(
            traits: .default,
            depth: .stranger,
            interactionCount: 0,
            lastInteraction: Date(),
            mood: "neutral",
            userPreferredName: nil
        )
        cachedState = initial
        persistState(initial)
        return initial
    }

    /// Record an interaction and evolve personality state.
    func recordInteraction(
        userText: String,
        signal: PersonalitySignal
    ) {
        guard isAvailable else { return }
        var state = currentState()
        state.interactionCount += 1
        state.lastInteraction = Date()

        // Evolve relationship depth based on interaction count
        for depth in RelationshipDepth.allCases.reversed() {
            if state.interactionCount >= depth.threshold {
                if state.depth != depth {
                    state.depth = depth
                    #if DEBUG
                    print("[PERSONALITY] relationship evolved to: \(depth.rawValue) at interaction \(state.interactionCount)")
                    #endif
                }
                break
            }
        }

        // Adapt traits based on signal
        state.traits = adaptTraits(current: state.traits, signal: signal)

        // Update mood based on user affect
        state.mood = deriveMood(from: signal)

        // Detect preferred name from user text
        if state.userPreferredName == nil {
            state.userPreferredName = detectPreferredName(userText)
        }

        cachedState = state
        persistState(state)

        #if DEBUG
        print("[PERSONALITY] interaction \(state.interactionCount) depth=\(state.depth.rawValue) mood=\(state.mood)")
        #endif
    }

    /// Generate the personality prompt block for injection into the system prompt.
    func personalityPromptBlock() -> String {
        let state = currentState()
        var block = state.traits.promptDescription(depth: state.depth)

        if let name = state.userPreferredName, !name.isEmpty {
            block += "\n- The user's name is \(name). Use it naturally, not every sentence."
        }

        if state.mood != "neutral" {
            block += "\n- Your current energy: \(state.mood). Let it color your responses subtly."
        }

        return block
    }

    /// Get relationship depth for external use.
    func relationshipDepth() -> RelationshipDepth {
        currentState().depth
    }

    /// Set the user's preferred name explicitly.
    func setPreferredName(_ name: String) {
        var state = currentState()
        state.userPreferredName = name
        cachedState = state
        persistState(state)
    }

    // MARK: - Trait Adaptation

    private func adaptTraits(current: PersonalityTraits, signal: PersonalitySignal) -> PersonalityTraits {
        var traits = current

        switch signal {
        case .userLaughed, .userPlayful:
            traits.playfulness = ema(old: traits.playfulness, new: min(1.0, traits.playfulness + 0.1))
        case .userSerious, .userFrustrated:
            traits.playfulness = ema(old: traits.playfulness, new: max(0.0, traits.playfulness - 0.1))
            traits.directness = ema(old: traits.directness, new: min(1.0, traits.directness + 0.05))
        case .userSharedPersonal:
            traits.warmth = ema(old: traits.warmth, new: min(1.0, traits.warmth + 0.05))
            traits.curiosity = ema(old: traits.curiosity, new: min(1.0, traits.curiosity + 0.05))
        case .userAskedOpinion:
            traits.directness = ema(old: traits.directness, new: min(1.0, traits.directness + 0.05))
        case .userCorrected:
            traits.directness = ema(old: traits.directness, new: max(0.0, traits.directness - 0.05))
        case .neutral:
            break
        }

        return traits
    }

    private func deriveMood(from signal: PersonalitySignal) -> String {
        switch signal {
        case .userLaughed, .userPlayful: return "playful"
        case .userSharedPersonal: return "reflective"
        case .userFrustrated: return "focused"
        case .userSerious: return "grounded"
        case .userAskedOpinion: return "energized"
        case .userCorrected: return "attentive"
        case .neutral: return "neutral"
        }
    }

    private func detectPreferredName(_ text: String) -> String? {
        let patterns = [
            "my name is ", "i'm ", "i am ", "call me ", "name's "
        ]
        let lower = text.lowercased()
        for pattern in patterns {
            if let range = lower.range(of: pattern) {
                let after = text[range.upperBound...]
                let words = after.split(separator: " ", maxSplits: 2)
                if let first = words.first {
                    let name = String(first).trimmingCharacters(in: .punctuationCharacters)
                    if name.count >= 2 && name.count <= 20 {
                        return name.capitalized
                    }
                }
            }
        }
        return nil
    }

    private func ema(old: Double, new: Double) -> Double {
        traitAlpha * new + (1 - traitAlpha) * old
    }

    // MARK: - Signal Detection

    /// Detect personality-relevant signals from user text.
    func detectSignal(userText: String) -> PersonalitySignal {
        let lower = userText.lowercased()

        // Playful/humorous signals
        let playfulMarkers = ["haha", "lol", "lmao", "😂", "🤣", "that's funny", "hilarious", "joke"]
        if playfulMarkers.contains(where: { lower.contains($0) }) {
            return .userLaughed
        }

        // Frustration signals
        let frustrationMarkers = ["frustrated", "annoying", "ugh", "come on", "not working", "broken", "stupid"]
        if frustrationMarkers.contains(where: { lower.contains($0) }) {
            return .userFrustrated
        }

        // Personal sharing signals
        let personalMarkers = ["i feel", "i've been", "honestly", "between us", "my family", "my partner",
                               "i'm worried", "i'm scared", "i miss", "i love", "i hate"]
        if personalMarkers.contains(where: { lower.contains($0) }) {
            return .userSharedPersonal
        }

        // Opinion request signals
        let opinionMarkers = ["what do you think", "your opinion", "what would you", "do you think",
                              "should i", "what's your take"]
        if opinionMarkers.contains(where: { lower.contains($0) }) {
            return .userAskedOpinion
        }

        // Correction signals
        let correctionMarkers = ["no that's wrong", "that's not right", "i said", "not what i meant",
                                 "wrong", "incorrect"]
        if correctionMarkers.contains(where: { lower.contains($0) }) {
            return .userCorrected
        }

        // Serious/business signals
        let seriousMarkers = ["urgent", "important", "deadline", "asap", "critical", "need to"]
        if seriousMarkers.contains(where: { lower.contains($0) }) {
            return .userSerious
        }

        return .neutral
    }

    // MARK: - Persistence

    private func persistState(_ state: PersonalityState) {
        let sql = """
        INSERT OR REPLACE INTO personality_state
        (id, traits_json, depth, interaction_count, last_interaction, mood, user_preferred_name)
        VALUES ('singleton', ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        let traitsJSON: String
        if let data = try? JSONEncoder().encode(state.traits),
           let str = String(data: data, encoding: .utf8) {
            traitsJSON = str
        } else {
            traitsJSON = "{}"
        }

        sqlite3_bind_text(stmt, 1, (traitsJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (state.depth.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(state.interactionCount))
        sqlite3_bind_double(stmt, 4, state.lastInteraction.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 5, (state.mood as NSString).utf8String, -1, nil)
        if let name = state.userPreferredName {
            sqlite3_bind_text(stmt, 6, (name as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_step(stmt)
    }

    private func loadState() -> PersonalityState? {
        let sql = "SELECT traits_json, depth, interaction_count, last_interaction, mood, user_preferred_name FROM personality_state WHERE id = 'singleton';"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let traitsJSON = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "{}"
        let depthStr = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "stranger"
        let interactionCount = Int(sqlite3_column_int(stmt, 2))
        let lastInteraction = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let mood = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "neutral"
        let preferredName = sqlite3_column_text(stmt, 5).map { String(cString: $0) }

        let traits: PersonalityTraits
        if let data = traitsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PersonalityTraits.self, from: data) {
            traits = decoded
        } else {
            traits = .default
        }

        return PersonalityState(
            traits: traits,
            depth: RelationshipDepth(rawValue: depthStr) ?? .stranger,
            interactionCount: interactionCount,
            lastInteraction: lastInteraction,
            mood: mood,
            userPreferredName: preferredName
        )
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
        CREATE TABLE IF NOT EXISTS personality_state (
            id TEXT PRIMARY KEY,
            traits_json TEXT NOT NULL,
            depth TEXT NOT NULL DEFAULT 'stranger',
            interaction_count INTEGER NOT NULL DEFAULT 0,
            last_interaction REAL NOT NULL,
            mood TEXT NOT NULL DEFAULT 'neutral',
            user_preferred_name TEXT
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IntelligenceLLMClient.LLMError.requestFailed("Personality table creation failed")
        }
    }
}

// MARK: - Personality Signals

enum PersonalitySignal: String, Codable {
    case userLaughed
    case userPlayful
    case userSerious
    case userFrustrated
    case userSharedPersonal
    case userAskedOpinion
    case userCorrected
    case neutral
}
