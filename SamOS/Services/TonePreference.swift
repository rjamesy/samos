import Foundation

struct TonePreferenceProfile: Codable, Equatable {
    var enabled: Bool
    var lastUpdated: Date?

    var directness: Double
    var warmth: Double
    var humor: Double
    var curiosity: Double
    var reassurance: Double
    var formality: Double
    var hedging: Double

    var avoidCheerfulWhenUpset: Bool
    var avoidTherapyLanguage: Bool
    var preferBulletSteps: Bool
    var preferShortOpeners: Bool
    var preferOneQuestionMax: Bool

    static var neutralDefaults: TonePreferenceProfile {
        TonePreferenceProfile(
            enabled: false,
            lastUpdated: nil,
            directness: 0.5,
            warmth: 0.5,
            humor: 0.3,
            curiosity: 0.6,
            reassurance: 0.5,
            formality: 0.4,
            hedging: 0.5,
            avoidCheerfulWhenUpset: true,
            avoidTherapyLanguage: true,
            preferBulletSteps: true,
            preferShortOpeners: true,
            preferOneQuestionMax: false
        )
    }

    mutating func clampKnobs() {
        directness = TonePreferenceProfile.clamp01(directness)
        warmth = TonePreferenceProfile.clamp01(warmth)
        humor = TonePreferenceProfile.clamp01(humor)
        curiosity = TonePreferenceProfile.clamp01(curiosity)
        reassurance = TonePreferenceProfile.clamp01(reassurance)
        formality = TonePreferenceProfile.clamp01(formality)
        hedging = TonePreferenceProfile.clamp01(hedging)
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

struct TonePreferencePersistedState: Codable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var profile: TonePreferenceProfile
    var learningUpdateHistory: [Date]
    var lastUpdateReason: String?

    static var defaultState: TonePreferencePersistedState {
        TonePreferencePersistedState(
            schemaVersion: schemaVersion,
            profile: .neutralDefaults,
            learningUpdateHistory: [],
            lastUpdateReason: nil
        )
    }
}

struct TonePreferenceLearningOutcome {
    let source: String
    let reason: String
    let deltaSummary: String
    let profile: TonePreferenceProfile
    let isToneRepair: Bool
    let toneRepairCue: String?
}

@MainActor
final class TonePreferenceStore {
    static let shared = TonePreferenceStore()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager = FileManager.default
    private var cachedState: TonePreferencePersistedState?

    private init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadProfile() -> TonePreferenceProfile {
        loadState().profile
    }

    func updateEnabled(_ enabled: Bool) -> TonePreferenceProfile {
        var state = loadState()
        state.profile.enabled = enabled
        persist(state)
        return state.profile
    }

    @discardableResult
    func saveProfile(_ profile: TonePreferenceProfile) -> TonePreferenceProfile {
        var state = loadState()
        var clamped = profile
        clamped.clampKnobs()
        state.profile = clamped
        persist(state)
        return state.profile
    }

    @discardableResult
    func applyLearningOutcome(_ outcome: TonePreferenceLearningOutcome, at now: Date) -> TonePreferenceProfile {
        var state = loadState()
        var updated = outcome.profile
        updated.lastUpdated = now
        updated.clampKnobs()
        state.profile = updated
        state.learningUpdateHistory = trimmedHistory(state.learningUpdateHistory + [now], now: now)
        state.lastUpdateReason = outcome.reason
        persist(state)
        return state.profile
    }

    func updatesInLast24Hours(now: Date = Date()) -> Int {
        let history = loadState().learningUpdateHistory
        return history.filter { now.timeIntervalSince($0) <= (24 * 60 * 60) }.count
    }

    func updatesToday(now: Date = Date()) -> Int {
        updatesInLast24Hours(now: now)
    }

    func debugLastUpdateReason() -> String? {
        loadState().lastUpdateReason
    }

    @discardableResult
    func resetProfile() -> TonePreferenceProfile {
        var state = loadState()
        let isEnabled = state.profile.enabled
        state = .defaultState
        state.profile.enabled = isEnabled
        persist(state)
        return state.profile
    }

    func replaceProfileForTesting(_ profile: TonePreferenceProfile,
                                  learningUpdateHistory: [Date] = [],
                                  lastUpdateReason: String? = nil) {
        var clamped = profile
        clamped.clampKnobs()
        let state = TonePreferencePersistedState(
            schemaVersion: TonePreferencePersistedState.schemaVersion,
            profile: clamped,
            learningUpdateHistory: learningUpdateHistory,
            lastUpdateReason: lastUpdateReason
        )
        persist(state)
    }

    private func loadState() -> TonePreferencePersistedState {
        if let cachedState {
            return cachedState
        }

        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? decoder.decode(TonePreferencePersistedState.self, from: data),
              decoded.schemaVersion == TonePreferencePersistedState.schemaVersion else {
            let fallback = TonePreferencePersistedState.defaultState
            persist(fallback)
            return fallback
        }

        var sanitized = decoded
        sanitized.profile.clampKnobs()
        sanitized.learningUpdateHistory = trimmedHistory(sanitized.learningUpdateHistory, now: Date())
        cachedState = sanitized
        return sanitized
    }

    private func persist(_ state: TonePreferencePersistedState) {
        var mutable = state
        mutable.profile.clampKnobs()
        do {
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(mutable)
            try data.write(to: storageURL, options: .atomic)
            cachedState = mutable
        } catch {
            cachedState = mutable
        }
    }

    private func trimmedHistory(_ history: [Date], now: Date) -> [Date] {
        history.filter { now.timeIntervalSince($0) <= (7 * 24 * 60 * 60) }
    }

    private var storageDirectory: URL {
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fallback
        return base.appendingPathComponent("SamOS", isDirectory: true)
    }

    private var storageURL: URL {
        storageDirectory.appendingPathComponent("tone_preferences.json", isDirectory: false)
    }
}

enum TonePreferenceLearner {
    private static let explicitDelta = 0.15
    private static let implicitDelta = 0.05
    private static let maxUpdatesPer24Hours = 3
    private static let medicalMarkers = [
        "chest pain", "chest tightness", "fever", "vomit", "vomiting", "diarrhea",
        "nausea", "bleeding", "blood", "faint", "can't breathe", "cant breathe", "symptom"
    ]
    private static let crisisMarkers = [
        "suicidal", "suicide", "self harm", "kill myself", "hopeless", "panic attack", "crisis"
    ]
    private static let confessionMarkers = [
        "i feel worthless", "i am worthless", "my trauma", "i was abused", "grieving",
        "i cheated", "deeply personal"
    ]

    static func learn(from userInput: String,
                      mode: ConversationMode,
                      affect: AffectMetadata,
                      profile: TonePreferenceProfile,
                      useEmotionalTone: Bool,
                      updatesInLast24Hours: Int) -> TonePreferenceLearningOutcome? {
        guard profile.enabled, useEmotionalTone else { return nil }
        guard updatesInLast24Hours < maxUpdatesPer24Hours else { return nil }

        let lower = normalized(userInput)
        guard !lower.isEmpty else { return nil }
        _ = affect
        guard !containsClinicalOrCrisisLanguageInNormalized(lower, mode: mode) else { return nil }

        if let explicit = explicitUpdate(for: lower, profile: profile) {
            return explicit
        }

        if shouldSkipImplicitLearning(for: lower, mode: mode) {
            return nil
        }
        if let implicit = implicitUpdate(for: lower, profile: profile) {
            return implicit
        }
        return nil
    }

    static func containsClinicalOrCrisisLanguage(_ input: String, mode: ConversationMode) -> Bool {
        containsClinicalOrCrisisLanguageInNormalized(normalized(input), mode: mode)
    }

    private static func explicitUpdate(for lower: String,
                                       profile: TonePreferenceProfile) -> TonePreferenceLearningOutcome? {
        if let toneRepairReason = toneRepairReason(for: lower) {
            var updated = profile
            var deltas: [String] = []
            applyKnob(&updated.directness, explicitDelta)
            deltas.append("directness+0.15")
            applyKnob(&updated.warmth, -0.10)
            deltas.append("warmth-0.10")
            applyKnob(&updated.reassurance, -0.10)
            deltas.append("reassurance-0.10")
            updated.preferOneQuestionMax = true
            deltas.append("preferOneQuestionMax=true")

            switch toneRepairReason {
            case "no_therapy_language":
                updated.avoidTherapyLanguage = true
                deltas.append("avoidTherapyLanguage=true")
            case "avoid_cheerful":
                updated.avoidCheerfulWhenUpset = true
                applyKnob(&updated.humor, -0.10)
                deltas.append("avoidCheerfulWhenUpset=true")
                deltas.append("humor-0.10")
            case "more_direct":
                applyKnob(&updated.hedging, -0.10)
                deltas.append("hedging-0.10")
            default:
                break
            }

            return outcome(source: "explicit_feedback",
                           reason: toneRepairReason,
                           deltas: deltas,
                           isToneRepair: true,
                           toneRepairCue: toneRepairAcknowledgement(for: toneRepairReason),
                           updated: updated)
        }

        if hasAny(lower, [
            "stop asking so many questions",
            "don't ask so many questions",
            "dont ask so many questions",
            "don't ask so many questions anymore",
            "dont ask so many questions anymore",
            "ask fewer questions",
            "less questions"
        ]) {
            var updated = profile
            applyKnob(&updated.curiosity, -explicitDelta)
            updated.preferOneQuestionMax = true
            return outcome(source: "explicit_feedback",
                           reason: "stop_questions",
                           deltas: ["curiosity-0.15", "preferOneQuestionMax=true"],
                           updated: updated)
        }

        if hasAny(lower, ["don't patronize me", "dont patronize me", "don't do the sympathy thing", "dont do the sympathy thing"]) {
            var updated = profile
            applyKnob(&updated.warmth, -0.15)
            applyKnob(&updated.reassurance, -0.10)
            updated.avoidCheerfulWhenUpset = true
            return outcome(source: "explicit_feedback",
                           reason: "avoid_patronizing_tone",
                           deltas: ["warmth-0.15", "reassurance-0.10", "avoidCheerfulWhenUpset=true"],
                           updated: updated)
        }

        if hasAny(lower, ["be warmer", "be nicer", "more reassurance when anxious"]) {
            var updated = profile
            applyKnob(&updated.warmth, explicitDelta)
            applyKnob(&updated.reassurance, 0.10)
            return outcome(source: "explicit_feedback",
                           reason: "increase_warmth",
                           deltas: ["warmth+0.15", "reassurance+0.10"],
                           updated: updated)
        }

        if hasAny(lower, ["stop being so robotic"]) {
            var updated = profile
            applyKnob(&updated.warmth, 0.10)
            applyKnob(&updated.formality, -0.10)
            return outcome(source: "explicit_feedback",
                           reason: "less_robotic",
                           deltas: ["warmth+0.10", "formality-0.10"],
                           updated: updated)
        }

        if hasAny(lower, ["more detail"]) {
            var updated = profile
            applyKnob(&updated.directness, -0.10)
            applyKnob(&updated.curiosity, 0.05)
            return outcome(source: "explicit_feedback",
                           reason: "more_detail",
                           deltas: ["directness-0.10", "curiosity+0.05"],
                           updated: updated)
        }

        if hasAny(lower, ["less detail"]) {
            var updated = profile
            applyKnob(&updated.directness, explicitDelta)
            return outcome(source: "explicit_feedback",
                           reason: "less_detail",
                           deltas: ["directness+0.15"],
                           updated: updated)
        }

        if hasAny(lower, ["use humor lightly"]) {
            var updated = profile
            applyKnob(&updated.humor, 0.10)
            return outcome(source: "explicit_feedback",
                           reason: "light_humor",
                           deltas: ["humor+0.10"],
                           updated: updated)
        }

        return nil
    }

    private static func implicitUpdate(for lower: String,
                                       profile: TonePreferenceProfile) -> TonePreferenceLearningOutcome? {
        if hasAny(lower, ["too long", "too much"]) {
            var updated = profile
            applyKnob(&updated.directness, implicitDelta)
            applyKnob(&updated.hedging, -0.05)
            return outcome(source: "implicit_feedback",
                           reason: "too_long",
                           deltas: ["directness+0.05", "hedging-0.05"],
                           updated: updated)
        }

        if hasAny(lower, ["that's not what i meant", "thats not what i meant"]) {
            var updated = profile
            applyKnob(&updated.curiosity, implicitDelta)
            return outcome(source: "implicit_feedback",
                           reason: "clarification_miss",
                           deltas: ["curiosity+0.05"],
                           updated: updated)
        }

        if hasAny(lower, ["just tell me what to do"]) {
            var updated = profile
            applyKnob(&updated.directness, implicitDelta)
            applyKnob(&updated.curiosity, -implicitDelta)
            return outcome(source: "implicit_feedback",
                           reason: "just_tell_me",
                           deltas: ["directness+0.05", "curiosity-0.05"],
                           updated: updated)
        }

        return nil
    }

    private static func shouldSkipImplicitLearning(for lower: String, mode: ConversationMode) -> Bool {
        if containsClinicalOrCrisisLanguageInNormalized(lower, mode: mode) {
            return true
        }
        return hasAny(lower, confessionMarkers)
    }

    private static func containsClinicalOrCrisisLanguageInNormalized(_ lower: String, mode: ConversationMode) -> Bool {
        if mode.domain == .health && mode.intent == .problemReport {
            return true
        }
        return hasAny(lower, medicalMarkers) || hasAny(lower, crisisMarkers)
    }

    private static func outcome(source: String,
                                reason: String,
                                deltas: [String],
                                isToneRepair: Bool = false,
                                toneRepairCue: String? = nil,
                                updated: TonePreferenceProfile) -> TonePreferenceLearningOutcome {
        var profile = updated
        profile.clampKnobs()
        return TonePreferenceLearningOutcome(
            source: source,
            reason: reason,
            deltaSummary: deltas.joined(separator: " "),
            profile: profile,
            isToneRepair: isToneRepair,
            toneRepairCue: toneRepairCue
        )
    }

    private static func toneRepairReason(for lower: String) -> String? {
        if hasAny(lower, ["no, don't be so cheerful", "no, dont be so cheerful", "don't be so cheerful", "dont be so cheerful"]) {
            return "avoid_cheerful"
        }
        if hasAny(lower, ["that's too emotional", "thats too emotional", "stop the empathy", "less warmth please", "less warm please"]) {
            return "less_warmth"
        }
        if hasAny(lower, ["be more direct", "more direct please", "more direct"]) {
            return "more_direct"
        }
        if hasAny(lower, ["don't talk like a therapist", "dont talk like a therapist", "stop the therapy tone"]) {
            return "no_therapy_language"
        }
        return nil
    }

    private static func toneRepairAcknowledgement(for reason: String) -> String {
        switch reason {
        case "avoid_cheerful":
            return "Understood - I'll keep it grounded."
        case "less_warmth":
            return "Got it - I'll keep this more practical."
        case "more_direct":
            return "Understood - I'll keep it more direct."
        case "no_therapy_language":
            return "Thanks for the feedback - I'll keep it practical and direct."
        default:
            return "Understood - I'll adjust the tone."
        }
    }

    private static func applyKnob(_ value: inout Double, _ delta: Double) {
        value = min(1.0, max(0.0, value + delta))
    }

    private static func normalized(_ input: String) -> String {
        input
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
