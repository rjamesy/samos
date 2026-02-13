import Foundation

private struct LocalKnowledgeContext {
    let items: [KnowledgeSourceSnippet]

    var hasMemoryHints: Bool {
        items.contains { $0.kind == .memory }
    }
}

enum ConversationIntent: String, CaseIterable, Codable {
    case greeting
    case problemReport = "problem_report"
    case howto
    case taskRequest = "task_request"
    case decisionHelp = "decision_help"
    case creative
    case memoryRecall = "memory_recall"
    case other
}

enum ConversationDomain: String, CaseIterable, Codable {
    case health
    case vehicle
    case tech
    case home
    case work
    case relationship
    case general
    case unknown
}

enum ConversationUrgency: String, CaseIterable, Codable {
    case low
    case medium
    case high
}

enum ConversationAffect: String, CaseIterable, Codable {
    case neutral
    case frustrated
    case anxious
    case sad
    case angry
    case excited
}

struct AffectMetadata: Codable, Equatable {
    let affect: ConversationAffect
    let intensity: Int

    var guidance: String {
        switch affect {
        case .neutral:
            return "Keep responses direct and solution-focused."
        case .frustrated:
            return "Acknowledge briefly, stay calm, ask clarifiers."
        case .anxious:
            return "Be calming and steady. Avoid alarmist language. Ask safety clarifiers when relevant."
        case .sad:
            return "Be warm and gentle. Offer a choice between talking and practical next steps."
        case .angry:
            return "Acknowledge intensity without matching it. De-escalate and redirect."
        case .excited:
            return "Match positive energy while maintaining momentum and clarity."
        }
    }

    var clampedIntensity: Int {
        min(3, max(0, intensity))
    }

    static let neutral = AffectMetadata(affect: .neutral, intensity: 0)
}

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

private struct TonePreferencePersistedState: Codable {
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

enum UserGoalHint: String, CaseIterable, Codable {
    case quickFix = "quick_fix"
    case understand
    case stepByStep = "step_by_step"
    case unknown
}

struct ConversationMode: Codable, Equatable {
    let intent: ConversationIntent
    let domain: ConversationDomain
    let urgency: ConversationUrgency
    let needsClarification: Bool
    let userGoalHint: UserGoalHint

    static let fallback = ConversationMode(
        intent: .other,
        domain: .unknown,
        urgency: .low,
        needsClarification: false,
        userGoalHint: .unknown
    )
}

struct ResponseLengthBudget: Codable, Equatable {
    let maxOutputTokens: Int
    let chatMinTokens: Int
    let chatMaxTokens: Int
    let preferCanvasForLongResponses: Bool

    static let `default` = ResponseLengthBudget(
        maxOutputTokens: 320,
        chatMinTokens: 120,
        chatMaxTokens: 350,
        preferCanvasForLongResponses: true
    )
}

struct PromptRuntimeContext: Equatable {
    let mode: ConversationMode
    let affect: AffectMetadata
    let tonePreferences: TonePreferenceProfile?
    let toneRepairCue: String?
    let sessionSummary: String
    let interactionStateJSON: String
    let identityContextLine: String?
    let responseBudget: ResponseLengthBudget

    init(mode: ConversationMode,
         affect: AffectMetadata,
         tonePreferences: TonePreferenceProfile?,
         toneRepairCue: String?,
         sessionSummary: String,
         interactionStateJSON: String,
         identityContextLine: String? = nil,
         responseBudget: ResponseLengthBudget) {
        self.mode = mode
        self.affect = affect
        self.tonePreferences = tonePreferences
        self.toneRepairCue = toneRepairCue
        self.sessionSummary = sessionSummary
        self.interactionStateJSON = interactionStateJSON
        self.identityContextLine = identityContextLine
        self.responseBudget = responseBudget
    }
}

private struct RecentFact {
    let text: String
    let expiresAt: Date
}

private final class IntentRepetitionTracker {
    private struct Event {
        let intent: ConversationIntent
        let date: Date
    }

    private var events: [Event] = []

    func record(_ intent: ConversationIntent, at date: Date = Date()) {
        prune(now: date)
        events.append(Event(intent: intent, date: date))
    }

    func count(for intent: ConversationIntent, within seconds: TimeInterval = 30 * 60, now: Date = Date()) -> Int {
        prune(now: now, window: seconds)
        return events.reduce(0) { partial, event in
            partial + (event.intent == intent ? 1 : 0)
        }
    }

    func countsByIntent(within seconds: TimeInterval = 30 * 60, now: Date = Date()) -> [String: Int] {
        prune(now: now, window: seconds)
        var counts: [String: Int] = [:]
        for event in events {
            counts[event.intent.rawValue, default: 0] += 1
        }
        return counts
    }

    private func prune(now: Date, window: TimeInterval = 30 * 60) {
        events.removeAll { now.timeIntervalSince($0.date) > window }
    }
}

private final class SessionSummaryService {
    private var cachedSummary: String = ""
    private var lastMessageCountAtRefresh = 0
    private let refreshMessageDelta = 10
    private let refreshTokenEstimateThreshold = 900

    func currentSummary(history: [ChatMessage],
                        currentMode: ConversationMode,
                        latestUserTurn: String) -> String {
        let nonSystem = history.filter { $0.role != .system }
        let normalizedLatest = normalizedSummaryLine(latestUserTurn)
        guard !nonSystem.isEmpty else {
            if !cachedSummary.isEmpty {
                cachedSummary = refreshVolatileBullets(
                    in: cachedSummary,
                    currentMode: currentMode,
                    latestUserTurn: normalizedLatest
                )
            }
            return cachedSummary
        }

        let shouldRefresh = needsRefresh(nonSystem)
        if shouldRefresh {
            let generated = generateSummary(
                nonSystem,
                currentMode: currentMode,
                latestUserTurn: normalizedLatest
            )
            if !generated.isEmpty {
                cachedSummary = generated
                lastMessageCountAtRefresh = nonSystem.count
            }
        }
        if !cachedSummary.isEmpty {
            cachedSummary = refreshVolatileBullets(
                in: cachedSummary,
                currentMode: currentMode,
                latestUserTurn: normalizedLatest
            )
        }
        return cachedSummary
    }

    private func needsRefresh(_ messages: [ChatMessage]) -> Bool {
        if cachedSummary.isEmpty { return messages.count >= 10 }
        if messages.count - lastMessageCountAtRefresh >= refreshMessageDelta { return true }
        let tokenEstimate = messages.reduce(0) { $0 + max(1, $1.text.count / 4) }
        return tokenEstimate >= refreshTokenEstimateThreshold
    }

    private func generateSummary(_ messages: [ChatMessage],
                                 currentMode: ConversationMode,
                                 latestUserTurn: String) -> String {
        let clipped = Array(messages.suffix(40))
        guard !clipped.isEmpty else { return cachedSummary }

        var bullets: [String] = []

        let topic = "\(currentMode.intent.rawValue)/\(currentMode.domain.rawValue)"
        bullets.append("- Active topic: \(topic)")

        if let goal = latestUserGoal(in: clipped) {
            bullets.append("- User goal: \(goal)")
        }

        let constraints = extractConstraints(from: clipped)
        if !constraints.isEmpty {
            bullets.append("- Constraints: \(constraints.joined(separator: "; "))")
        }

        if let qa = lastQuestionAnswerPair(in: clipped) {
            bullets.append("- Last Q/A: Q=\(qa.question) A=\(qa.answer)")
        }

        if let earlyDetail = earlyKeyDetail(in: clipped) {
            bullets.append("- Earlier key detail: \(earlyDetail)")
        }

        let recentUser = !latestUserTurn.isEmpty
            ? latestUserTurn
            : (clipped.reversed().first(where: { $0.role == .user })?.text ?? "")
        let normalizedRecentUser = normalizedSummaryLine(recentUser)
        if !normalizedRecentUser.isEmpty {
            bullets.append("- Latest user turn: \(clipLine(normalizedRecentUser, max: 120))")
        }

        return Array(bullets.prefix(8)).joined(separator: "\n")
    }

    private func refreshVolatileBullets(in summary: String,
                                        currentMode: ConversationMode,
                                        latestUserTurn: String) -> String {
        var lines = summary
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !lines.isEmpty else { return summary }

        let topicLine = "- Active topic: \(currentMode.intent.rawValue)/\(currentMode.domain.rawValue)"
        let latestLine = latestUserTurn.isEmpty ? "" : "- Latest user turn: \(clipLine(latestUserTurn, max: 120))"

        var hasTopic = false
        var hasLatest = false
        for idx in lines.indices {
            if lines[idx].hasPrefix("- Active topic:") {
                lines[idx] = topicLine
                hasTopic = true
            } else if lines[idx].hasPrefix("- Latest user turn:") {
                if !latestLine.isEmpty {
                    lines[idx] = latestLine
                    hasLatest = true
                }
            }
        }

        if !hasTopic {
            lines.insert(topicLine, at: 0)
        }
        if !latestLine.isEmpty && !hasLatest {
            lines.append(latestLine)
        }

        return lines.joined(separator: "\n")
    }

    private func normalizedSummaryLine(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !single.isEmpty else { return "" }
        return single.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func latestUserGoal(in messages: [ChatMessage]) -> String? {
        let users = messages.reversed().filter { $0.role == .user }
        for user in users {
            let text = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let lower = text.lowercased()
            if lower.contains("quick") || lower.contains("fast") || lower.contains("fix") {
                return "quick fix"
            }
            if lower.contains("step by step") || lower.contains("walk me through") {
                return "step-by-step guidance"
            }
            if lower.contains("why") || lower.contains("understand") {
                return "understand root cause"
            }
            return clipLine(text, max: 90)
        }
        return nil
    }

    private func extractConstraints(from messages: [ChatMessage]) -> [String] {
        var items: [String] = []
        for message in messages where message.role == .user {
            let text = message.text.lowercased()
            if text.contains("can't") || text.contains("cannot") {
                items.append("reported limitation")
            }
            if text.contains("deadline") || text.contains("today") || text.contains("tomorrow") {
                items.append("time-sensitive")
            }
            if text.contains("budget") || text.contains("cheap") {
                items.append("budget-sensitive")
            }
        }
        return Array(Set(items)).sorted()
    }

    private func lastQuestionAnswerPair(in messages: [ChatMessage]) -> (question: String, answer: String)? {
        for index in stride(from: messages.count - 1, through: 0, by: -1) {
            let message = messages[index]
            guard message.role == .assistant else { continue }
            let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSuffix("?") else { continue }
            let answer = messages[(index + 1)...].first(where: { $0.role == .user })?.text ?? ""
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return (clipLine(trimmed, max: 100), clipLine(answer, max: 100))
        }
        return nil
    }

    private func earlyKeyDetail(in messages: [ChatMessage]) -> String? {
        for message in messages where message.role == .user {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 12 else { continue }
            let lower = text.lowercased()
            if lower.contains("my ") || lower.contains("i need") || lower.contains("i have") {
                return clipLine(text, max: 110)
            }
        }
        return nil
    }

    private func clipLine(_ text: String, max: Int) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard single.count > max else { return single }
        return String(single.prefix(max - 3)) + "..."
    }
}

private enum ConversationModeClassifier {
    static func classify(_ input: String) -> ConversationMode {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .fallback }
        let lower = normalized.lowercased()

        let domain = detectDomain(lower)
        let intent = detectIntent(lower)
        let urgency = detectUrgency(lower, intent: intent, domain: domain)
        let needsClarification = detectNeedsClarification(lower, intent: intent)
        let goalHint = detectGoalHint(lower)

        return ConversationMode(
            intent: intent,
            domain: domain,
            urgency: urgency,
            needsClarification: needsClarification,
            userGoalHint: goalHint
        )
    }

    private static func detectIntent(_ lower: String) -> ConversationIntent {
        if isGreeting(lower) { return .greeting }
        if isMemoryRecall(lower) { return .memoryRecall }
        if isCreative(lower) { return .creative }
        if isDecisionHelp(lower) { return .decisionHelp }
        if isHowTo(lower) { return .howto }
        if isTaskRequest(lower) { return .taskRequest }
        if isProblemReport(lower) { return .problemReport }
        return .other
    }

    private static func detectDomain(_ lower: String) -> ConversationDomain {
        let padded = " \(lower) "
        if hasAny(lower, [
            "tummy", "stomach", "abdomen", "abdominal", "pain", "sore", "nausea", "vomit",
            "diarrhea", "fever", "blood", "faint", "dizzy", "hydration", "headache", "chest pain"
        ]) || hasAny(lower, [
            "dont feel well", "don't feel well", "feel unwell", "not feeling well"
        ]) { return .health }
        if hasAny(lower, [
            "car", "engine", "vehicle", "brake", "oil", "transmission", "accelerat", "overheat",
            "smoke", "fuel smell", "dashboard", "warning light", "tire", "battery"
        ]) { return .vehicle }
        if hasAny(lower, [
            "wifi", "wi-fi", "internet", "router", "nbn", "computer", "macbook", "laptop", "phone",
            "software", "error", "bug", "crash", "network", "password", "hacked", "malware"
        ]) || padded.contains(" app ") { return .tech }
        if hasAny(lower, [
            "house", "home", "leak", "plumbing", "heater", "ac ", "aircon", "fridge", "electric",
            "power outage", "roof", "mold", "appliance", "kitchen"
        ]) { return .home }
        if hasAny(lower, [
            "work", "job", "deadline", "meeting", "manager", "boss", "coworker", "project", "client"
        ]) { return .work }
        if hasAny(lower, [
            "partner", "relationship", "boyfriend", "girlfriend", "spouse", "friend", "family conflict"
        ]) { return .relationship }
        if hasAny(lower, ["general", "anything", "topic"]) { return .general }
        return .unknown
    }

    private static func detectUrgency(_ lower: String, intent: ConversationIntent, domain: ConversationDomain) -> ConversationUrgency {
        if hasAny(lower, [
            "urgent", "right now", "immediately", "severe", "worst", "can't breathe", "fainting",
            "black stool", "blood", "persistent vomiting", "rigid abdomen",
            "oil pressure", "overheating", "smoke", "strong fuel smell", "loss of power", "knocking",
            "data loss", "security breach", "hacked"
        ]) {
            return .high
        }
        if intent == .problemReport {
            if domain == .health || domain == .vehicle || domain == .tech {
                return .medium
            }
        }
        return .low
    }

    private static func detectNeedsClarification(_ lower: String, intent: ConversationIntent) -> Bool {
        switch intent {
        case .problemReport, .decisionHelp, .howto:
            return true
        case .taskRequest:
            return lower.contains("set ") || lower.contains("schedule ")
        default:
            return false
        }
    }

    private static func detectGoalHint(_ lower: String) -> UserGoalHint {
        if hasAny(lower, ["quick", "quickly", "fast", "asap", "right now", "quick fix", "fix now"]) {
            return .quickFix
        }
        if hasAny(lower, ["step by step", "walk me through", "guide me", "how do i"]) {
            return .stepByStep
        }
        if hasAny(lower, ["why", "understand", "what causes", "explain"]) {
            return .understand
        }
        return .unknown
    }

    private static func isGreeting(_ lower: String) -> Bool {
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let simpleGreetings = [
            "hi", "hello", "hey", "yo", "hiya", "good morning", "good afternoon", "good evening",
            "how are you", "how are you doing", "what's up", "whats up"
        ]
        if simpleGreetings.contains(trimmed) { return true }
        if trimmed.count <= 30 && hasAny(trimmed, ["hi ", "hello", "hey ", "hey!"]) {
            return true
        }
        return false
    }

    private static func isProblemReport(_ lower: String) -> Bool {
        if hasAny(lower, [
            "don't feel well", "dont feel well", "feel unwell", "not feeling well", "sore", "hurts",
            "pain", "issue", "problem", "not working", "broken", "keeps", "won't", "wont", "dropping out",
            "funny noise", "strange noise", "engine noise", "warning light", "oil pressure light", "came on",
            "overheating", "crashing", "failing", "leak", "leaking", "disconnects", "hacked", "stopped working",
            "deadline", "changed", "conflict", "fighting"
        ]) {
            return true
        }
        return lower.hasPrefix("my ") && hasAny(lower, ["is ", "keeps ", "won't", "not"])
    }

    private static func isHowTo(_ lower: String) -> Bool {
        hasAny(lower, ["how do i", "how to", "walk me through", "step by step", "tutorial", "instructions"])
    }

    private static func isTaskRequest(_ lower: String) -> Bool {
        if hasAny(lower, ["set an alarm", "set a timer", "remind me", "schedule", "create", "send", "open", "find"]) {
            return true
        }
        let imperativePrefixes = ["set ", "remind ", "schedule ", "open ", "create ", "send "]
        return imperativePrefixes.contains { lower.hasPrefix($0) }
    }

    private static func isDecisionHelp(_ lower: String) -> Bool {
        hasAny(lower, ["should i", "which should", "which is better", "pros and cons", "compare", "decision"])
    }

    private static func isCreative(_ lower: String) -> Bool {
        hasAny(lower, ["write a", "poem", "story", "joke", "brainstorm", "ideas for"])
    }

    private static func isMemoryRecall(_ lower: String) -> Bool {
        hasAny(lower, [
            "what did i say", "what do you remember", "remember what", "my dog's name was",
            "my dog’s name was", "do you remember", "what was my", "what do you know about me"
        ])
    }

    private static func hasAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

private enum ConversationAffectClassifier {
    private struct AffectSignals {
        var weak = 0
        var strong = 0
    }

    private static let frustratedKeywords = [
        "frustrat",
        "fed up",
        "annoyed",
        "sick of",
        "ridiculous",
        "tired of",
        "again?"
    ]
    private static let anxiousKeywords = [
        "worried",
        "nervous",
        "scared",
        "anxious",
        "uneasy",
        "stressed",
        "panic"
    ]
    private static let angryPhrases = [
        "this is bullshit",
        "i'm pissed",
        "im pissed",
        "i am pissed",
        "so angry"
    ]
    private static let strongSwears = [
        "bullshit",
        "fucking",
        "fuck",
        "shit",
        "goddamn",
        "damn it"
    ]
    private static let excitedKeywords = [
        "yay",
        "awesome",
        "amazing",
        "so excited",
        "can't wait",
        "cant wait"
    ]

    static func classify(_ input: String, history: [ChatMessage]) -> AffectMetadata {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .neutral }
        let lower = trimmed.lowercased()

        let repetitionSignal = hasRepetitionSignal(lower, history: history)
        let capsSignal = hasAllCapsSegment(in: trimmed)
        let strongLanguageSignal = hasAny(lower, strongSwears) || hasAny(lower, angryPhrases)

        let frustrated = detectFrustratedSignals(lower, repetitionSignal: repetitionSignal)
        let anxious = detectAnxiousSignals(lower)
        let sad = detectSadSignals(lower)
        let angry = detectAngrySignals(lower, capsSignal: capsSignal, strongLanguageSignal: strongLanguageSignal)
        let excited = detectExcitedSignals(lower)

        let ranked: [(ConversationAffect, AffectSignals)] = [
            (.frustrated, frustrated),
            (.anxious, anxious),
            (.sad, sad),
            (.angry, angry),
            (.excited, excited)
        ]

        let affectPriority: [ConversationAffect] = [.angry, .anxious, .sad, .frustrated, .excited]
        guard let best = ranked.max(by: { lhs, rhs in
            let lhsScore = weightedScore(lhs.1)
            let rhsScore = weightedScore(rhs.1)
            if lhsScore == rhsScore {
                let lhsPriority = affectPriority.firstIndex(of: lhs.0) ?? affectPriority.count
                let rhsPriority = affectPriority.firstIndex(of: rhs.0) ?? affectPriority.count
                return lhsPriority > rhsPriority
            }
            return lhsScore < rhsScore
        }), weightedScore(best.1) > 0 else {
            return .neutral
        }

        let intensity = intensityForSignals(
            best.1,
            capsSignal: capsSignal,
            strongLanguageSignal: strongLanguageSignal,
            repetitionSignal: repetitionSignal
        )
        return AffectMetadata(affect: best.0, intensity: intensity)
    }

    private static func detectFrustratedSignals(_ lower: String, repetitionSignal: Bool) -> AffectSignals {
        var signals = AffectSignals()
        signals.weak += countMatches(lower, frustratedKeywords)
        if lower.contains("why does this always") || lower.contains("why is this always") {
            signals.strong += 1
        }
        if lower.contains("again") && (lower.contains("why") || lower.contains("always") || lower.contains("keeps")) {
            signals.weak += 1
        }
        if repetitionSignal {
            signals.weak += 1
        }
        return signals
    }

    private static func detectAnxiousSignals(_ lower: String) -> AffectSignals {
        var signals = AffectSignals()
        signals.weak += countMatches(lower, anxiousKeywords)
        if lower.contains("panic attack") {
            signals.strong += 1
        }
        return signals
    }

    private static func detectSadSignals(_ lower: String) -> AffectSignals {
        var signals = AffectSignals()
        let emotionalFrame = hasAny(lower, [
            "i feel",
            "i'm feeling",
            "im feeling",
            "i am feeling",
            "i don't feel",
            "i dont feel",
            "i'm",
            "im ",
            "i am "
        ])

        if lower.contains("don't feel like") || lower.contains("dont feel like") {
            signals.strong += 1
        }
        if emotionalFrame {
            if lower.contains(" sad") || lower.hasPrefix("sad") {
                signals.weak += 1
            }
            if lower.contains(" lonely") || lower.hasPrefix("lonely") {
                signals.weak += 1
            }
            if lower.contains(" empty") || lower.hasPrefix("empty") {
                signals.weak += 1
            }
            if lower.contains("feeling down") || lower.contains("feel down") || lower.contains("i'm down") || lower.contains("im down") {
                signals.weak += 1
            }
            if lower.contains(" exhausted") || lower.hasPrefix("exhausted") {
                signals.weak += 1
            }
        }
        return signals
    }

    private static func detectAngrySignals(_ lower: String,
                                           capsSignal: Bool,
                                           strongLanguageSignal: Bool) -> AffectSignals {
        var signals = AffectSignals()
        if capsSignal {
            signals.strong += 1
        }
        if hasAny(lower, angryPhrases) {
            signals.strong += 1
        }
        if strongLanguageSignal {
            signals.strong += 1
        }
        return signals
    }

    private static func detectExcitedSignals(_ lower: String) -> AffectSignals {
        var signals = AffectSignals()
        signals.weak += countMatches(lower, excitedKeywords)
        if lower.contains("!!!") {
            signals.strong += 1
        }
        return signals
    }

    private static func weightedScore(_ signals: AffectSignals) -> Int {
        signals.weak + (signals.strong * 2)
    }

    private static func intensityForSignals(_ signals: AffectSignals,
                                            capsSignal: Bool,
                                            strongLanguageSignal: Bool,
                                            repetitionSignal: Bool) -> Int {
        let total = signals.weak + signals.strong
        if total == 0 {
            return 0
        }

        var intensity = 1
        if total >= 2 || signals.strong > 0 {
            intensity = 2
        }
        if capsSignal && strongLanguageSignal && repetitionSignal {
            intensity = 3
        }
        return min(3, max(0, intensity))
    }

    private static func hasRepetitionSignal(_ lower: String, history: [ChatMessage]) -> Bool {
        if hasAny(lower, ["why does this always", "again?", "again", "still", "every time"]) {
            return true
        }

        let recentUserTurns = history.reversed()
            .filter { $0.role == .user }
            .prefix(3)
            .map { $0.text.lowercased() }
        guard !recentUserTurns.isEmpty else { return false }

        let complaintAnchors = [
            "not working",
            "keeps",
            "dropping",
            "broken",
            "issue",
            "problem"
        ]

        for anchor in complaintAnchors where lower.contains(anchor) {
            if recentUserTurns.contains(where: { $0.contains(anchor) }) {
                return true
            }
        }
        return false
    }

    private static func hasAllCapsSegment(in input: String) -> Bool {
        input.range(of: #"\b[A-Z]{2,}(?:\s+[A-Z]{2,})+\b"#, options: .regularExpression) != nil
    }

    private static func countMatches(_ haystack: String, _ needles: [String]) -> Int {
        needles.reduce(0) { partial, needle in
            partial + (haystack.contains(needle) ? 1 : 0)
        }
    }

    private static func hasAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

@MainActor
protocol TurnOrchestrating: AnyObject {
    var pendingSlot: PendingSlot? { get set }
    func processTurn(_ text: String, history: [ChatMessage], inputMode: TurnInputMode) async -> TurnResult
}

enum TurnInputMode {
    case voice
    case text
    case unspecified
}

enum VisionQueryIntent: Equatable {
    case none
    case describe
    case visualQA(question: String)
    case findObject(query: String)
}

enum RoutedIntent: String, CaseIterable, Codable {
    case greeting
    case recipe
    case webRequest = "web_request"
    case visionDescribe = "vision_describe"
    case visionQA = "vision_qa"
    case visionFindObject = "vision_find_object"
    case automationRequest = "automation_request"
    case generalQnA = "general_qna"
    case identityResponse = "identity_response"
    case settingsCommand = "settings_command"
    case unknown
}

struct IntentClassifierInput: Equatable, Sendable {
    let userText: String
    let cameraRunning: Bool
    let faceKnown: Bool
    let pendingSlot: String?
    let lastAssistantLine: String?
}

struct IntentClassification: Codable, Equatable, Sendable {
    let intent: RoutedIntent
    let confidence: Double
    let notes: String
    let autoCaptureHint: Bool
    let needsWeb: Bool

    enum CodingKeys: String, CodingKey { case intent, confidence, notes, autoCaptureHint, needsWeb }
}

enum IntentClassificationProvider: String {
    case rule
    case ollama
    case openai
}

struct IntentClassificationResult: Equatable, Sendable {
    let classification: IntentClassification
    let provider: IntentClassificationProvider
    let attemptedLocal: Bool
    let attemptedOpenAI: Bool
    let localSkipReason: String?
    let intentRouterMsLocal: Int?
    let intentRouterMsOpenAI: Int?
    let localConfidence: Double?
    let openAIConfidence: Double?
    let confidenceThreshold: Double
    let localTimeoutSeconds: Double?
    let escalationReason: String?
}

struct IntentLLMCallOutput: Sendable {
    let rawText: String
    let model: String?
    let endpoint: String?
    let prompt: String
}

actor IntentInferenceExecutor {
    func run<T: Sendable>(priority: TaskPriority = .userInitiated,
                          _ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        try await Task.detached(priority: priority) {
            try await operation()
        }.value
    }
}

struct IntentClassifier {
    private let localClassifier: (@Sendable (IntentClassifierInput) async throws -> IntentLLMCallOutput)?
    private let openAIClassifier: (@Sendable (IntentClassifierInput) async throws -> IntentLLMCallOutput)?
    private let localInferenceExecutor: IntentInferenceExecutor?
    private let confidenceThreshold: Double
    private let localTimeoutSeconds: Double?
    private let openAITimeoutSeconds: Double?

    init(localClassifier: (@Sendable (IntentClassifierInput) async throws -> IntentLLMCallOutput)?,
         openAIClassifier: (@Sendable (IntentClassifierInput) async throws -> IntentLLMCallOutput)?,
         localInferenceExecutor: IntentInferenceExecutor? = nil,
         confidenceThreshold: Double = 0.70,
         localTimeoutSeconds: Double? = nil,
         openAITimeoutSeconds: Double? = nil) {
        self.localClassifier = localClassifier
        self.openAIClassifier = openAIClassifier
        self.localInferenceExecutor = localInferenceExecutor
        self.confidenceThreshold = confidenceThreshold
        self.localTimeoutSeconds = localTimeoutSeconds
        self.openAITimeoutSeconds = openAITimeoutSeconds
    }

    func classify(_ input: IntentClassifierInput,
                  useLocalFirst: Bool,
                  allowOpenAIFallback: Bool) async -> IntentClassificationResult {
        enum AttemptFailureKind: String {
            case timeout
            case transport
            case parseFail = "parse_fail"
        }

        struct AttemptOutcome {
            let call: IntentLLMCallOutput?
            let classification: IntentClassification?
            let parseError: String?
            let elapsedMs: Int?
            let failureKind: AttemptFailureKind?
            let failureDetail: String?
        }

        func outcomeReason(_ outcome: AttemptOutcome?) -> String? {
            guard let outcome else { return nil }
            if let kind = outcome.failureKind {
                return kind.rawValue
            }
            if let confidence = outcome.classification?.confidence, confidence < confidenceThreshold {
                return "low_conf"
            }
            return nil
        }

        func confidenceString(_ value: Double?) -> String {
            guard let value else { return "nil" }
            return String(format: "%.2f", value)
        }

        func msString(_ value: Int?) -> String {
            guard let value else { return "nil" }
            return "\(value)"
        }

        func timeoutString(_ value: Double?) -> String {
            guard let value else { return "nil" }
            return String(format: "%.2f", value)
        }

        func parsedJSONString(_ classification: IntentClassification) -> String {
            """
            {"intent":"\(classification.intent.rawValue)","confidence":\(String(format: "%.2f", classification.confidence)),"autoCaptureHint":\(classification.autoCaptureHint),"needsWeb":\(classification.needsWeb),"notes":"\(classification.notes)"}
            """
        }

        func debugDumpAttempt(_ label: String, outcome: AttemptOutcome?) {
            #if DEBUG
            guard let outcome else { return }
            if let call = outcome.call {
                print("[INTENT_\(label)_REQUEST] model=\(call.model ?? "unknown") endpoint=\(call.endpoint ?? "unknown")")
                print("[INTENT_\(label)_PROMPT_BEGIN]\n\(call.prompt)\n[INTENT_\(label)_PROMPT_END]")
                print("[INTENT_\(label)_RAW] \(call.rawText)")
            }
            if let classification = outcome.classification {
                print("[INTENT_\(label)_PARSED] \(parsedJSONString(classification))")
            } else {
                print("[INTENT_\(label)_PARSE_FAIL] detail=\(outcome.parseError ?? outcome.failureDetail ?? "unknown")")
            }
            #endif
        }

        func runAttempt(_ label: String,
                        classifier: @escaping @Sendable (IntentClassifierInput) async throws -> IntentLLMCallOutput,
                        timeout: Double?,
                        runOnLocalExecutor: Bool = false) async -> AttemptOutcome {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let attemptOperation: @Sendable () async throws -> AttemptOutcome = {
                let call: IntentLLMCallOutput
                if let timeout {
                    call = try await withTimeout(timeout) { try await classifier(input) }
                } else {
                    call = try await classifier(input)
                }
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                switch Self.decodeStrictJSON(call.rawText) {
                case .success(let payload):
                    return AttemptOutcome(
                        call: call,
                        classification: payload,
                        parseError: nil,
                        elapsedMs: elapsedMs,
                        failureKind: nil,
                        failureDetail: nil
                    )
                case .failure(let parseError):
                    return AttemptOutcome(
                        call: call,
                        classification: nil,
                        parseError: parseError,
                        elapsedMs: elapsedMs,
                        failureKind: .parseFail,
                        failureDetail: parseError
                    )
                }
            }

            func executeAttemptOperation() async throws -> AttemptOutcome {
                if runOnLocalExecutor, let localInferenceExecutor {
                    return try await localInferenceExecutor.run(priority: .userInitiated, attemptOperation)
                } else {
                    return try await attemptOperation()
                }
            }

            let result = await Task(priority: .userInitiated) {
                do {
                    return Result<AttemptOutcome, Error>.success(try await executeAttemptOperation())
                } catch {
                    return Result<AttemptOutcome, Error>.failure(error)
                }
            }.value

            switch result {
            case .success(let outcome):
                return outcome
            case .failure(let error):
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                if error is RouterTimeout {
                    return AttemptOutcome(
                        call: nil,
                        classification: nil,
                        parseError: nil,
                        elapsedMs: elapsedMs,
                        failureKind: .timeout,
                        failureDetail: "local timeout exceeded"
                    )
                }
                return AttemptOutcome(
                    call: nil,
                    classification: nil,
                    parseError: nil,
                    elapsedMs: elapsedMs,
                    failureKind: .transport,
                    failureDetail: error.localizedDescription
                )
            }
        }

        func buildResult(_ classification: IntentClassification,
                         provider: IntentClassificationProvider,
                         attemptedLocal: Bool,
                         attemptedOpenAI: Bool,
                         localSkipReason: String?,
                         localOutcome: AttemptOutcome?,
                         openAIOutcome: AttemptOutcome?,
                         escalationReason: String?) -> IntentClassificationResult {
            let result = IntentClassificationResult(
                classification: classification,
                provider: provider,
                attemptedLocal: attemptedLocal,
                attemptedOpenAI: attemptedOpenAI,
                localSkipReason: localSkipReason,
                intentRouterMsLocal: localOutcome?.elapsedMs,
                intentRouterMsOpenAI: openAIOutcome?.elapsedMs,
                localConfidence: localOutcome?.classification?.confidence,
                openAIConfidence: openAIOutcome?.classification?.confidence,
                confidenceThreshold: confidenceThreshold,
                localTimeoutSeconds: localTimeoutSeconds,
                escalationReason: escalationReason
            )

            #if DEBUG
            print("[INTENT_DECISION] intent_provider_selected=\(result.provider.rawValue) local_attempted=\(result.attemptedLocal) openai_attempted=\(result.attemptedOpenAI) local_confidence=\(confidenceString(result.localConfidence)) openai_confidence=\(confidenceString(result.openAIConfidence)) threshold=\(String(format: "%.2f", result.confidenceThreshold)) local_timeout_s=\(timeoutString(result.localTimeoutSeconds)) reason_for_escalation=\(result.escalationReason ?? "none") local_skip_reason=\(result.localSkipReason ?? "none") intent_router_ms_local=\(msString(result.intentRouterMsLocal)) intent_router_ms_openai=\(msString(result.intentRouterMsOpenAI))")
            #endif

            return result
        }

        var attemptedLocal = false
        var attemptedOpenAI = false
        var localSkipReason: String?
        var localOutcome: AttemptOutcome?
        var openAIOutcome: AttemptOutcome?
        var escalationReason: String?

        if useLocalFirst {
            if let localClassifier {
                attemptedLocal = true
                localOutcome = await runAttempt(
                    "LOCAL",
                    classifier: localClassifier,
                    timeout: localTimeoutSeconds,
                    runOnLocalExecutor: true
                )
                debugDumpAttempt("LOCAL", outcome: localOutcome)
                if let local = localOutcome?.classification,
                   local.confidence >= confidenceThreshold {
                    return buildResult(
                        local,
                        provider: .ollama,
                        attemptedLocal: attemptedLocal,
                        attemptedOpenAI: false,
                        localSkipReason: nil,
                        localOutcome: localOutcome,
                        openAIOutcome: nil,
                        escalationReason: nil
                    )
                }
                escalationReason = outcomeReason(localOutcome)
            } else {
                localSkipReason = "classifier_nil"
                escalationReason = "classifier_nil"
            }
        } else {
            localSkipReason = "policy_disabled"
            escalationReason = "policy_disabled"
        }

        if allowOpenAIFallback, let openAIClassifier {
            attemptedOpenAI = true
            openAIOutcome = await runAttempt("OPENAI", classifier: openAIClassifier, timeout: openAITimeoutSeconds)
            debugDumpAttempt("OPENAI", outcome: openAIOutcome)
            if let openAI = openAIOutcome?.classification,
               openAI.confidence >= confidenceThreshold {
                return buildResult(
                    openAI,
                    provider: .openai,
                    attemptedLocal: attemptedLocal,
                    attemptedOpenAI: attemptedOpenAI,
                    localSkipReason: localSkipReason,
                    localOutcome: localOutcome,
                    openAIOutcome: openAIOutcome,
                    escalationReason: escalationReason
                )
            }
            escalationReason = outcomeReason(openAIOutcome) ?? escalationReason
        }

        let ruleFallback = deterministicClassification(for: input)
        if ruleFallback.intent != .unknown {
            return buildResult(
                ruleFallback,
                provider: .rule,
                attemptedLocal: attemptedLocal,
                attemptedOpenAI: attemptedOpenAI,
                localSkipReason: localSkipReason,
                localOutcome: localOutcome,
                openAIOutcome: openAIOutcome,
                escalationReason: escalationReason
            )
        }

        return buildResult(
            IntentClassification(
                intent: .unknown,
                confidence: 0.20,
                notes: "",
                autoCaptureHint: false,
                needsWeb: false,
            ),
            provider: .rule,
            attemptedLocal: attemptedLocal,
            attemptedOpenAI: attemptedOpenAI,
            localSkipReason: localSkipReason,
            localOutcome: localOutcome,
            openAIOutcome: openAIOutcome,
            escalationReason: escalationReason
        )
    }

    private enum IntentDecodeOutcome {
        case success(IntentClassification)
        case failure(String)
    }

    private func deterministicClassification(for input: IntentClassifierInput) -> IntentClassification {
        let trimmed = input.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.isEmpty {
            return IntentClassification(
                intent: .unknown,
                confidence: 0.20,
                notes: "",
                autoCaptureHint: false,
                needsWeb: false
            )
        }

        // Rules are emergency brakes only: conservative and low confidence.
        if lower.hasPrefix("turn on ")
            || lower.hasPrefix("turn off ")
            || lower.hasPrefix("enable ")
            || lower.hasPrefix("disable ")
            || lower == "settings" {
            return IntentClassification(
                intent: .settingsCommand,
                confidence: 0.68,
                notes: "",
                autoCaptureHint: false,
                needsWeb: false
            )
        }

        if lower.range(of: #"^[\p{P}\p{S}\s]{1,12}$"#, options: .regularExpression) != nil {
            return IntentClassification(
                intent: .unknown,
                confidence: 0.25,
                notes: "",
                autoCaptureHint: false,
                needsWeb: false
            )
        }

        return IntentClassification(
            intent: .unknown,
            confidence: 0.30,
            notes: "",
            autoCaptureHint: false,
            needsWeb: false
        )
    }

    private static func decodeStrictJSON(_ text: String) -> IntentDecodeOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("empty_response") }
        guard trimmed.first == "{", trimmed.last == "}",
              let data = trimmed.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = jsonObject as? [String: Any] else {
            return .failure("not_single_json_object")
        }
        let allowedKeys: Set<String> = ["intent", "confidence", "autoCaptureHint", "needsWeb", "notes"]
        let actualKeys = Set(dictionary.keys)
        let extra = actualKeys.subtracting(allowedKeys).sorted().joined(separator: ",")
        guard extra.isEmpty else {
            return .failure("key_mismatch missing=[] extra=[\(extra)]")
        }

        guard let intentRaw = dictionary["intent"] as? String,
              let intent = RoutedIntent(rawValue: intentRaw) else {
            return .failure("decode_failed_missing_or_invalid_intent")
        }
        guard let confidenceValue = dictionary["confidence"] as? NSNumber else {
            return .failure("decode_failed_missing_or_invalid_confidence")
        }

        let notes = (dictionary["notes"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let autoCaptureHint = dictionary["autoCaptureHint"] as? Bool ?? false
        let clamped = min(1.0, max(0.0, confidenceValue.doubleValue))

        let payload = IntentClassification(
            intent: intent,
            confidence: clamped,
            notes: notes,
            autoCaptureHint: autoCaptureHint,
            needsWeb: intent == .webRequest
        )
        return .success(payload)
    }

}

private struct PlanRoutePolicy {
    let useOllama: Bool
    let preferOpenAIPlans: Bool
    let openAIStatus: OpenAISettings.APIKeyStatus

    var localFirst: Bool { routeOrder.first == .ollama }
    var openAIFallback: Bool { routeOrder.contains(.openai) }

    var routeOrder: [LLMProvider] {
        switch openAIStatus {
        case .ready:
            guard useOllama else { return [.openai] }
            return preferOpenAIPlans ? [.openai, .ollama] : [.ollama, .openai]
        case .invalid:
            return useOllama ? [.ollama] : [.none]
        case .missing:
            return useOllama ? [.ollama] : [.none]
        }
    }
}

extension TurnOrchestrating {
    func processTurn(_ text: String, history: [ChatMessage]) async -> TurnResult {
        await processTurn(text, history: history, inputMode: .unspecified)
    }
}

// MARK: - Timeout Helper

enum RouterTimeout: Error { case exceeded }

func withTimeout<T: Sendable>(_ seconds: Double, _ op: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RouterTimeout.exceeded
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// The ONLY brain for processing user input.
/// Calls LLM, validates structure, executes plan steps.
/// Uses a deterministic intent classifier with optional LLM fallback, then executes plan steps.
@MainActor
final class TurnOrchestrator {
    private let ollamaRouter: OllamaRouter
    private let openAIRouter: OpenAIRouter
    private let openAIProvider: OpenAIProviderRouting
    private let tonePreferenceStore: TonePreferenceStore
    private let faceGreetingManager: FaceGreetingManager
    private let cameraVision: CameraVisionProviding
    private let intentClassifier: IntentClassifier
    private let summaryService = SessionSummaryService()
    private let intentRepetitionTracker = IntentRepetitionTracker()
    private let memoryAckCooldownTurns: Int
    private let followUpCooldownTurns: Int
    private var recentAssistantLines: [String] = []
    private var recentFacts: [RecentFact] = []
    private var lastAssistantQuestion: String?
    private var lastAssistantQuestionAnswered = false
    private var lastAssistantOpeners: [String] = []
    private var currentFaceIdentityContext: FaceIdentityContext = .none
    private var lastPromptContext: PromptRuntimeContext?
    private var lastFinalActionKind: String = "UNKNOWN"
    private var canvasConfirmationIndex = 0
    private let canvasConfirmations = [
        "I've put the details up here.",
        "Here's a clear breakdown for you.",
        "I've laid this out on screen."
    ]
    private let greetingFollowUpQuestion = "How can I help?"
    private static let numberedListRegex = try! NSRegularExpression(pattern: #"^\d+[\.)]\s"#, options: [])
    private static let coverageEntityRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z]{2,}\b"#, options: [])
    private static let coverageStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "also", "after", "while",
        "what", "when", "where", "why", "how", "is", "are", "was", "were", "be", "to",
        "for", "of", "in", "on", "at", "by", "with", "without", "from", "into", "about",
        "tell", "show", "check", "find", "learn", "need", "good", "time", "call", "me", "you",
        "should", "would", "could", "can",
        "your", "my", "it", "this", "that"
    ]
    private var turnCounter = 0
    private var lastMemoryAckTurn: Int?
    private var lastFollowUpTurn: Int?
    private static let sharedIntentInferenceExecutor = IntentInferenceExecutor()
    private let openAIRouteTimeoutSeconds: Double = 5.0
    private let intentLocalTimeoutSeconds: Double
    private let intentOpenAITimeoutSeconds: Double = 2.0
    private let openAITimeoutRetryMaxTokens: Int = 220
    private let openAIImageRepairTimeoutSeconds: Double = 3.0
    private let toolFeedbackLoopMaxDepth = 2
    private let maxRephraseBudgetMs = 700
    private let maxToolFeedbackBudgetMs = 3600
    private let openAIToolFeedbackTimeoutSeconds: Double = 2.2
    private let ollamaToolFeedbackTimeoutSeconds: Double = 1.2
    private let unknownToolPromptCooldownSeconds: TimeInterval = 300
    private let cameraBlindnessGraceWindowSeconds: TimeInterval = 10
    private let toolRunner: TurnToolRunning
    private let routerOverride: TurnRouting?
    private lazy var defaultRouter: TurnRouting = makeDefaultRouter()
    private var router: TurnRouting { routerOverride ?? defaultRouter }
    private var pendingCapabilityRequest: PendingCapabilityRequest?
    private var lastExternalSourcePromptAt: Date?
    private var currentIntentClassification: IntentClassificationResult?
    private var lastIntentClassification: IntentClassificationResult?
    private var currentTurnCaptureAfterReplyHint: Bool = false
    private var currentRoutingTask: Task<Void, Never>?

    var pendingSlot: PendingSlot? = nil

    // Production init
    init() {
        let ollama = OllamaRouter()
        let openAI = OpenAIRouter(parser: ollama)
        let provider = RetryingOpenAIProvider(openAIRouter: openAI)
        self.ollamaRouter = ollama
        self.openAIRouter = openAI
        self.openAIProvider = provider
        self.tonePreferenceStore = .shared
        self.faceGreetingManager = FaceGreetingManager()
        self.cameraVision = CameraVisionService.shared
        self.intentLocalTimeoutSeconds = TurnOrchestrator.sanitizedLocalIntentTimeout(M2Settings.localIntentTimeoutSeconds)
        self.intentClassifier = TurnOrchestrator.makeIntentClassifier(
            ollamaRouter: ollama,
            openAIProvider: provider,
            localTimeoutSeconds: intentLocalTimeoutSeconds,
            openAITimeoutSeconds: intentOpenAITimeoutSeconds
        )
        self.toolRunner = TurnToolRunner(planExecutor: .shared, toolsRuntime: ToolsRuntime.shared)
        self.routerOverride = nil
        self.memoryAckCooldownTurns = 20
        self.followUpCooldownTurns = 3
    }

    // Test init (injectable)
    init(ollamaRouter: OllamaRouter,
         openAIRouter: OpenAIRouter,
         faceGreetingManager: FaceGreetingManager? = nil,
         cameraVision: CameraVisionProviding = CameraVisionService.shared,
         localIntentTimeoutSeconds: Double? = nil,
         router: TurnRouting? = nil,
         openAIProvider: OpenAIProviderRouting? = nil,
         toolRunner: TurnToolRunning? = nil,
         memoryAckCooldownTurns: Int = 20,
         followUpCooldownTurns: Int = 3) {
        self.ollamaRouter = ollamaRouter
        self.openAIRouter = openAIRouter
        self.openAIProvider = openAIProvider ?? RetryingOpenAIProvider(
            openAIRouter: openAIRouter,
            intentRetryBackoffMs: 1,
            planRetryBackoffMs: 1
        )
        self.tonePreferenceStore = .shared
        self.faceGreetingManager = faceGreetingManager ?? FaceGreetingManager()
        self.cameraVision = cameraVision
        self.intentLocalTimeoutSeconds = TurnOrchestrator.sanitizedLocalIntentTimeout(localIntentTimeoutSeconds ?? M2Settings.localIntentTimeoutSeconds)
        self.intentClassifier = TurnOrchestrator.makeIntentClassifier(
            ollamaRouter: ollamaRouter,
            openAIProvider: self.openAIProvider,
            localTimeoutSeconds: intentLocalTimeoutSeconds,
            openAITimeoutSeconds: intentOpenAITimeoutSeconds
        )
        self.routerOverride = router
        self.toolRunner = toolRunner ?? TurnToolRunner(planExecutor: .shared, toolsRuntime: ToolsRuntime.shared)
        self.memoryAckCooldownTurns = max(1, memoryAckCooldownTurns)
        self.followUpCooldownTurns = max(1, followUpCooldownTurns)
    }

    // Backward-compatible initializer retained for existing callsites/tests.
    convenience init(ollamaRouter: OllamaRouter,
                     openAIRouter: OpenAIRouter,
                     faceGreetingManager: FaceGreetingManager? = nil,
                     localIntentTimeoutSeconds: Double? = nil,
                     router: TurnRouting? = nil,
                     openAIProvider: OpenAIProviderRouting? = nil,
                     toolRunner: TurnToolRunning? = nil,
                     memoryAckCooldownTurns: Int = 20,
                     followUpCooldownTurns: Int = 3) {
        self.init(ollamaRouter: ollamaRouter,
                  openAIRouter: openAIRouter,
                  faceGreetingManager: faceGreetingManager,
                  cameraVision: CameraVisionService.shared,
                  localIntentTimeoutSeconds: localIntentTimeoutSeconds,
                  router: router,
                  openAIProvider: openAIProvider,
                  toolRunner: toolRunner,
                  memoryAckCooldownTurns: memoryAckCooldownTurns,
                  followUpCooldownTurns: followUpCooldownTurns)
    }

    private func makeDefaultRouter() -> TurnRouting {
        TurnRouter(
            classifyIntent: { [intentClassifier] input, useLocalFirst, allowOpenAIFallback in
                await intentClassifier.classify(
                    input,
                    useLocalFirst: useLocalFirst,
                    allowOpenAIFallback: allowOpenAIFallback
                )
            },
            routePlan: { [weak self] request in
                guard let self else {
                    return RouteDecision(
                        plan: Plan(steps: [.talk(say: "Sorry — I had trouble generating a response. Please try again.")]),
                        provider: .none,
                        routerMs: 0,
                        aiModelUsed: nil,
                        routeReason: "router_deallocated",
                        planLocalWireMs: nil,
                        planLocalTotalMs: nil,
                        planOpenAIMs: nil
                    )
                }
                let routed = await self.routePlan(
                    request.text,
                    history: request.history,
                    pendingSlot: request.pendingSlot,
                    reason: request.reason,
                    promptContext: request.promptContext
                )
                return RouteDecision(
                    plan: routed.0,
                    provider: routed.1,
                    routerMs: routed.2,
                    aiModelUsed: routed.3,
                    routeReason: routed.4,
                    planLocalWireMs: routed.5,
                    planLocalTotalMs: routed.6,
                    planOpenAIMs: routed.7
                )
            },
            routeCombined: { [weak self] request in
                guard let self else {
                    let classification = IntentClassificationResult(
                        classification: IntentClassification(
                            intent: .unknown,
                            confidence: 0.2,
                            notes: "",
                            autoCaptureHint: false,
                            needsWeb: false
                        ),
                        provider: .rule,
                        attemptedLocal: false,
                        attemptedOpenAI: false,
                        localSkipReason: "router_deallocated",
                        intentRouterMsLocal: nil,
                        intentRouterMsOpenAI: nil,
                        localConfidence: nil,
                        openAIConfidence: nil,
                        confidenceThreshold: 0.7,
                        localTimeoutSeconds: nil,
                        escalationReason: "router_deallocated"
                    )
                    let route = RouteDecision(
                        plan: Plan(steps: [.talk(say: "Sorry — I had trouble generating a response. Please try again.")]),
                        provider: .none,
                        routerMs: 0,
                        aiModelUsed: nil,
                        routeReason: "router_deallocated",
                        planLocalWireMs: nil,
                        planLocalTotalMs: nil,
                        planOpenAIMs: nil
                    )
                    return CombinedRouteDecision(
                        classification: classification,
                        route: route,
                        localAttempted: false,
                        localOutcome: "router_deallocated",
                        localMs: nil,
                        openAIMs: nil
                    )
                }
                return await self.routeCombined(
                    request.text,
                    history: request.history,
                    pendingSlot: request.pendingSlot,
                    reason: request.reason,
                    promptContext: request.promptContext,
                    state: request.state
                )
            },
            nativeToolExists: { category in
                TurnOrchestrator.hasNativeTool(for: category)
            },
            normalizeToolName: { raw in
                ToolRegistry.shared.normalizeToolName(raw)
            },
            isAllowedTool: { name in
                ToolRegistry.shared.isAllowedTool(name)
            }
        )
    }

    private static func makeIntentClassifier(ollamaRouter: OllamaRouter,
                                             openAIProvider: OpenAIProviderRouting,
                                             localTimeoutSeconds: Double? = nil,
                                             openAITimeoutSeconds: Double? = nil) -> IntentClassifier {
        IntentClassifier(
            localClassifier: { input in
                try await ollamaRouter.classifyIntentWithTrace(input)
            },
            openAIClassifier: { input in
                try await openAIProvider.classifyIntentWithRetry(
                    input,
                    timeoutSeconds: openAITimeoutSeconds
                ).output
            },
            localInferenceExecutor: sharedIntentInferenceExecutor,
            localTimeoutSeconds: localTimeoutSeconds,
            openAITimeoutSeconds: nil
        )
    }

    private static func sanitizedLocalIntentTimeout(_ value: Double) -> Double {
        min(10.0, max(0.2, value))
    }

    private func resolvedVisionIntent(from classification: IntentClassification,
                                      userInput: String) -> VisionQueryIntent {
        switch classification.intent {
        case .visionDescribe:
            return .describe
        case .visionQA:
            return .visualQA(question: classification.notes.isEmpty ? userInput : classification.notes)
        case .visionFindObject:
            return .findObject(query: classification.notes.isEmpty ? userInput : classification.notes)
        default:
            return .none
        }
    }

    private func logIntentClassification(_ result: IntentClassificationResult) {
        #if DEBUG
        let confidence = String(format: "%.2f", result.classification.confidence)
        var line = "[INTENT] intent=\(result.classification.intent.rawValue) " +
            "conf=\(confidence) provider=\(result.provider.rawValue) " +
            "local_attempted=\(result.attemptedLocal) openai_attempted=\(result.attemptedOpenAI) " +
            "intent_router_ms_local=\(result.intentRouterMsLocal.map(String.init) ?? "nil") " +
            "intent_router_ms_openai=\(result.intentRouterMsOpenAI.map(String.init) ?? "nil") " +
            "local_timeout_s=\(result.localTimeoutSeconds.map { String(format: "%.2f", $0) } ?? "nil")"
        if let reason = result.localSkipReason {
            line += " local_skip_reason=\(reason)"
        }
        if let reason = result.escalationReason {
            line += " escalation_reason=\(reason)"
        }
        print(line)
        #endif
    }

    private func logIntentProviderSelection(_ provider: IntentClassificationProvider) {
        #if DEBUG
        print("[INTENT_PROVIDER] provider=\(provider.rawValue)")
        #endif
    }

    private func logPlanProviderSelection(provider: LLMProvider,
                                          routeReason: String,
                                          routerMs: Int,
                                          aiModelUsed: String?) {
        #if DEBUG
        print("[PLAN_PROVIDER] provider=\(provider.rawValue)")
        print("[PLAN] provider=\(provider.rawValue) route_reason=\(routeReason) router_ms=\(routerMs) model=\(aiModelUsed ?? "n/a")")
        #endif
    }

    private func logIntentAudioCorrelation(inputMode: TurnInputMode) {
        #if DEBUG
        let mode: String
        switch inputMode {
        case .voice:
            mode = "voice"
        case .text:
            mode = "text"
        case .unspecified:
            mode = "unspecified"
        }
        let snapshot = IntentAudioDiagnosticsStore.shared.snapshot()
        let capture = snapshot.captureMs.map(String.init) ?? "n/a"
        let stt = snapshot.sttMs.map(String.init) ?? "n/a"
        let error = snapshot.recentAudioError ?? "none"
        print("[INTENT_AUDIO] input_mode=\(mode) capture_ms=\(capture) stt_ms=\(stt) recent_audio_error=\(error) local_timeout_s=\(String(format: "%.2f", intentLocalTimeoutSeconds))")
        #endif
    }

    func processTurn(_ text: String, history: [ChatMessage], inputMode: TurnInputMode) async -> TurnResult {
        // Cancel any in-flight routing from a previous turn
        currentRoutingTask?.cancel()
        currentRoutingTask = nil
        turnCounter += 1
        defer {
            currentIntentClassification = nil
            currentTurnCaptureAfterReplyHint = false
        }
        let currentTurn = turnCounter
        let now = Date()
        let turnStartedAt = Date()
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let userText = sanitized.isEmpty ? text : sanitized
        let localKnowledgeContext = buildLocalKnowledgeContext(for: userText)
        let hasMemoryHints = localKnowledgeContext.hasMemoryHints
        let mode = ConversationModeClassifier.classify(userText)
        let identityDecision = faceGreetingManager.prepareTurn(
            userInput: userText,
            inputMode: inputMode,
            now: now,
            userInitiated: true
        )
        currentFaceIdentityContext = identityDecision.context
        let lastAssistantLine = history.reversed().first(where: { $0.role == .assistant })?.text
        let intentInput = IntentClassifierInput(
            userText: userText,
            cameraRunning: cameraVision.isRunning,
            faceKnown: !(identityDecision.context.recognizedUserName?.isEmpty ?? true),
            pendingSlot: pendingSlot?.slotName,
            lastAssistantLine: lastAssistantLine
        )
        OpenAISettings.preloadAPIKey()
        OpenAISettings.clearInvalidatedAPIKeyIfNeeded()
        let intentRoutePolicy = IntentRoutePolicy(useOllama: M2Settings.useOllama)
        let useCombinedRouting = (inputMode == .voice)
        var combinedRouteDecision: CombinedRouteDecision?
        let combinedPendingSlotSnapshot = pendingSlot
        #if DEBUG
        print("[INTENT_ROUTE_POLICY] local_first=\(intentRoutePolicy.localFirst) openai_fallback=\(intentRoutePolicy.openAIFallback) m2_useOllama=\(M2Settings.useOllama) openai_status=\(OpenAISettings.apiKeyStatus)")
        #endif
        logIntentAudioCorrelation(inputMode: inputMode)
        let intentClassification: IntentClassificationResult
        if useCombinedRouting {
            let combinedReason: LLMCallReason = pendingSlot == nil ? .userChat : .pendingSlotReply
            let combined = await router.routeCombined(
                TurnCombinedRouteRequest(
                    text: userText,
                    history: history,
                    pendingSlot: pendingSlot,
                    reason: combinedReason,
                    promptContext: nil,
                    state: TurnRouterState(
                        cameraRunning: intentInput.cameraRunning,
                        faceKnown: intentInput.faceKnown,
                        pendingSlot: intentInput.pendingSlot,
                        lastAssistantLine: intentInput.lastAssistantLine
                    )
                )
            )
            combinedRouteDecision = combined
            intentClassification = combined.classification
        } else {
            intentClassification = await router.classifyIntent(
                intentInput,
                policy: intentRoutePolicy
            )
        }
        currentIntentClassification = intentClassification
        lastIntentClassification = intentClassification
        currentTurnCaptureAfterReplyHint = intentClassification.classification.autoCaptureHint
        logIntentClassification(intentClassification)
        logIntentProviderSelection(intentClassification.provider)

        if case .enroll(let name, let confirmation, let providerNoneReason) = identityDecision.action {
            var immediate = immediateTalkTurnResult(message: confirmation)
            immediate.llmProvider = .none
            immediate.originProvider = .local
            immediate.executionProvider = .local
            immediate.originReason = providerNoneReason
            immediate.routerMs = 0
            immediate.executedToolSteps = [("enroll_camera_face", ["name": name])]
            applyResponsePolish(&immediate,
                                plan: Plan(steps: [.talk(say: immediate.spokenLines.first ?? "")]),
                                hasMemoryHints: hasMemoryHints,
                                turnIndex: currentTurn)
            updateAssistantState(after: immediate, mode: mode)
            rememberAssistantLines(immediate.appendedChat)
            logIdentityTurn(decision: identityDecision,
                            now: now,
                            provider: immediate.llmProvider,
                            routeReason: providerNoneReason,
                            routerMs: immediate.routerMs)
            applyRoutingAttribution(&immediate, planProvider: immediate.llmProvider, planRouterMs: immediate.routerMs)
            return immediate
        }

        let visionIntent = resolvedVisionIntent(
            from: intentClassification.classification,
            userInput: userText
        )
        if case .none = visionIntent {
            // Not a camera vision intent.
        } else {
            if !cameraVision.isRunning {
                var immediate = immediateTalkTurnResult(
                    message: "I need the camera on to see anything - turn it on and ask again."
                )
                immediate.llmProvider = .none
                immediate.originProvider = .local
                immediate.executionProvider = .local
                immediate.originReason = "vision_camera_off"
                immediate.routerMs = 0
                applyResponsePolish(
                    &immediate,
                    plan: Plan(steps: [.talk(say: immediate.spokenLines.first ?? "")]),
                    hasMemoryHints: hasMemoryHints,
                    turnIndex: currentTurn
                )
                updateAssistantState(after: immediate, mode: mode)
                rememberAssistantLines(immediate.appendedChat)
                logIdentityTurn(
                    decision: identityDecision,
                    now: now,
                    provider: immediate.llmProvider,
                    routeReason: "vision_camera_off",
                    routerMs: immediate.routerMs
                )
                applyRoutingAttribution(&immediate, planProvider: immediate.llmProvider, planRouterMs: immediate.routerMs)
                return immediate
            }

            if !cameraVision.health.isHealthy {
                var immediate = immediateTalkTurnResult(
                    message: "My camera feed is lagging or not updating right now - try toggling the camera off/on."
                )
                immediate.llmProvider = .none
                immediate.originProvider = .local
                immediate.executionProvider = .local
                immediate.originReason = "vision_camera_unhealthy"
                immediate.routerMs = 0
                applyResponsePolish(
                    &immediate,
                    plan: Plan(steps: [.talk(say: immediate.spokenLines.first ?? "")]),
                    hasMemoryHints: hasMemoryHints,
                    turnIndex: currentTurn
                )
                updateAssistantState(after: immediate, mode: mode)
                rememberAssistantLines(immediate.appendedChat)
                logIdentityTurn(
                    decision: identityDecision,
                    now: now,
                    provider: immediate.llmProvider,
                    routeReason: "vision_camera_unhealthy",
                    routerMs: immediate.routerMs
                )
                applyRoutingAttribution(&immediate, planProvider: immediate.llmProvider, planRouterMs: immediate.routerMs)
                return immediate
            }

            if shouldRunVisionToolFirst(for: visionIntent) {
                let visionResult = await runVisionToolFirstTurn(
                    intent: visionIntent,
                    text: userText,
                    history: history,
                    mode: mode,
                    localKnowledgeContext: localKnowledgeContext,
                    hasMemoryHints: hasMemoryHints,
                    turnIndex: currentTurn,
                    turnStartedAt: turnStartedAt,
                    identityDecision: identityDecision,
                    now: now
                )
                return visionResult
            }
        }

        if let capabilityResult = await handlePendingCapabilityRequestTurn(
            text: userText,
            history: history,
            mode: mode,
            localKnowledgeContext: localKnowledgeContext,
            hasMemoryHints: hasMemoryHints,
            turnIndex: currentTurn,
            turnStartedAt: turnStartedAt,
            identityDecision: identityDecision,
            now: now
        ) {
            return capabilityResult
        }

        if router.shouldEnterExternalSourceCapabilityGapFlow(
            CapabilityGapRouteInput(
                text: userText,
                classification: intentClassification.classification,
                provider: intentClassification.provider,
                pendingSlot: pendingSlot,
                pendingCapabilityRequest: pendingCapabilityRequest,
                confidenceThreshold: intentClassification.confidenceThreshold
            )
        ) {
            let sourcePlan = buildExternalSourceAskPlan(
                toolName: "external_source",
                userText: userText,
                now: now,
                prefersWebsiteURL: true
            )
            lastFinalActionKind = inferredActionKind(for: sourcePlan)
            var result = await executePlan(
                sourcePlan,
                originalInput: userText,
                history: history,
                provider: .none,
                aiModelUsed: nil,
                routerMs: 0,
                localKnowledgeContext: localKnowledgeContext,
                hasMemoryHints: hasMemoryHints,
                turnIndex: currentTurn,
                feedbackDepth: 0,
                turnStartedAt: turnStartedAt,
                mode: mode,
                affect: .neutral,
                originReason: "capability_gap_external_source_pre_route"
            )
            appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
            logIdentityTurn(
                decision: identityDecision,
                now: now,
                provider: .none,
                routeReason: "capability_gap_external_source_pre_route",
                routerMs: 0
            )
            return result
        }

        if let recipeResult = await runRecipeToolFirstTurnIfNeeded(
            text: userText,
            intent: intentClassification.classification.intent,
            history: history,
            mode: mode,
            localKnowledgeContext: localKnowledgeContext,
            hasMemoryHints: hasMemoryHints,
            turnIndex: currentTurn,
            turnStartedAt: turnStartedAt,
            identityDecision: identityDecision,
            now: now
        ) {
            return recipeResult
        }

        let rawAffect = ConversationAffectClassifier.classify(userText, history: history)
        let affectMirroringEnabled = M2Settings.affectMirroringEnabled
        let useEmotionalTone = M2Settings.useEmotionalTone
        let containsClinicalOrCrisis = TonePreferenceLearner.containsClinicalOrCrisisLanguage(userText, mode: mode)
        var toneProfile = tonePreferenceStore.loadProfile()
        var toneRepairCue: String?
        if let learningOutcome = TonePreferenceLearner.learn(
            from: userText,
            mode: mode,
            affect: rawAffect,
            profile: toneProfile,
            useEmotionalTone: useEmotionalTone,
            updatesInLast24Hours: tonePreferenceStore.updatesInLast24Hours(now: now)
        ) {
            toneProfile = tonePreferenceStore.applyLearningOutcome(learningOutcome, at: now)
            toneRepairCue = learningOutcome.toneRepairCue
            logToneLearning(outcome: learningOutcome, profile: toneProfile)
        }
        let effectiveToneProfile = (toneProfile.enabled && useEmotionalTone && !containsClinicalOrCrisis) ? toneProfile : nil
        let effectiveAffect: AffectMetadata = (affectMirroringEnabled && useEmotionalTone)
            ? rawAffect
            : .neutral
        logAffectClassification(raw: rawAffect,
                                effective: effectiveAffect,
                                featureEnabled: affectMirroringEnabled,
                                userToneEnabled: useEmotionalTone)
        intentRepetitionTracker.record(mode.intent, at: now)
        purgeExpiredFacts(now: now)
        updateRecentFacts(with: userText, mode: mode, now: now)
        updateQuestionAnswerState(with: userText)
        let sessionSummary = summaryService.currentSummary(
            history: history,
            currentMode: mode,
            latestUserTurn: userText
        )
        let promptContext = buildPromptRuntimeContext(
            mode: mode,
            affect: effectiveAffect,
            tonePreferences: effectiveToneProfile,
            toneRepairCue: toneRepairCue,
            userInput: userText,
            history: history,
            sessionSummary: sessionSummary,
            now: now,
            faceIdentityContext: currentFaceIdentityContext
        )
        lastPromptContext = promptContext

        // PendingSlot handling — always route through LLM
        let pendingSlotEvaluation = router.evaluatePendingSlot(
            pendingSlot,
            pendingCapabilityRequest: pendingCapabilityRequest,
            now: now
        )
        pendingSlot = pendingSlotEvaluation.pendingSlot
        pendingCapabilityRequest = pendingSlotEvaluation.pendingCapabilityRequest

        switch pendingSlotEvaluation.action {
        case .retryExhausted(let msg):
            var result = TurnResult()
            result.appendedChat.append(ChatMessage(role: .assistant, text: msg))
            result.spokenLines.append(msg)
            logIdentityTurn(decision: identityDecision,
                            now: now,
                            provider: .none,
                            routeReason: "pending_slot_retry_exhausted",
                            routerMs: nil)
            applyRoutingAttribution(&result, planProvider: LLMProvider.none, planRouterMs: nil)
            return result
        case .continueWithSlot(let slot):
            let reusedCombinedForPendingSlot = shouldReuseCombinedRouteDecision(
                combinedRouteDecision,
                requestedPendingSlot: slot,
                initialPendingSlot: combinedPendingSlotSnapshot,
                expectedReason: .pendingSlotReply
            )
            let routed: RouteDecision
            let combinedUsed: CombinedRouteDecision?
            if reusedCombinedForPendingSlot, let combined = combinedRouteDecision {
                routed = combined.route
                combinedUsed = combined
                combinedRouteDecision = nil
            } else {
                routed = await router.routePlan(TurnPlanRouteRequest(
                    text: userText,
                    history: history,
                    pendingSlot: slot,
                    reason: .pendingSlotReply,
                    promptContext: promptContext,
                    intentClassification: currentIntentClassification?.classification
                ))
                combinedUsed = nil
            }
            logPlanProviderSelection(provider: routed.provider,
                                     routeReason: routed.routeReason,
                                     routerMs: routed.routerMs,
                                     aiModelUsed: routed.aiModelUsed)
            let guardedPlan = enforceNoFalseBlindnessGuardrail(on: routed.plan, userInput: userText)
            let plan = await maybeRephraseRepeatedTalk(guardedPlan,
                                                       userInput: userText,
                                                       history: history,
                                                       mode: mode,
                                                       turnIndex: currentTurn,
                                                       turnStartedAt: turnStartedAt)
            let shapedPlan = enforceLengthPresentationPolicy(plan, mode: mode)

            let slotResolution = router.resolvePendingSlotAfterPlan(
                shapedPlan,
                previousSlot: slot,
                pendingCapabilityRequest: pendingCapabilityRequest
            )
            pendingSlot = slotResolution.pendingSlot
            pendingCapabilityRequest = slotResolution.pendingCapabilityRequest

            lastFinalActionKind = inferredActionKind(for: shapedPlan)
            var result = await executePlan(shapedPlan,
                                           originalInput: userText,
                                           history: history,
                                           provider: routed.provider,
                                           aiModelUsed: routed.aiModelUsed,
                                           routerMs: routed.routerMs,
                                           planLocalWireMs: routed.planLocalWireMs,
                                           planLocalTotalMs: routed.planLocalTotalMs,
                                           planOpenAIMs: routed.planOpenAIMs,
                                           localKnowledgeContext: localKnowledgeContext,
                                           hasMemoryHints: hasMemoryHints,
                                           turnIndex: currentTurn,
                                           feedbackDepth: 0,
                                           turnStartedAt: turnStartedAt,
                                           mode: mode,
                                           toneRepairCue: toneRepairCue,
                                           affect: effectiveAffect,
                                           originReason: routed.routeReason)
            applyCombinedRouteMetadata(&result, combinedDecision: combinedUsed)
            appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
            logIdentityTurn(decision: identityDecision,
                            now: now,
                            provider: routed.provider,
                            routeReason: routed.routeReason,
                            routerMs: routed.routerMs)
            return result
        case .none:
            break
        }

        // Normal LLM routing (no pending slot)
        let reusedCombinedForUserChat = shouldReuseCombinedRouteDecision(
            combinedRouteDecision,
            requestedPendingSlot: nil,
            initialPendingSlot: combinedPendingSlotSnapshot,
            expectedReason: .userChat
        )
        let routed: RouteDecision
        let combinedUsed: CombinedRouteDecision?
        if reusedCombinedForUserChat, let combined = combinedRouteDecision {
            routed = combined.route
            combinedUsed = combined
            combinedRouteDecision = nil
        } else {
            routed = await router.routePlan(TurnPlanRouteRequest(
                text: userText,
                history: history,
                pendingSlot: nil,
                reason: .userChat,
                promptContext: promptContext,
                intentClassification: currentIntentClassification?.classification
            ))
            combinedUsed = nil
        }
        logPlanProviderSelection(provider: routed.provider,
                                 routeReason: routed.routeReason,
                                 routerMs: routed.routerMs,
                                 aiModelUsed: routed.aiModelUsed)
        let guardedPlan = enforceNoFalseBlindnessGuardrail(on: routed.plan, userInput: userText)
        let plan = await maybeRephraseRepeatedTalk(guardedPlan,
                                                   userInput: userText,
                                                   history: history,
                                                   mode: mode,
                                                   turnIndex: currentTurn,
                                                   turnStartedAt: turnStartedAt)
        let shapedPlan = enforceLengthPresentationPolicy(plan, mode: mode)
        lastFinalActionKind = inferredActionKind(for: shapedPlan)
        var result = await executePlan(shapedPlan,
                                       originalInput: userText,
                                       history: history,
                                       provider: routed.provider,
                                       aiModelUsed: routed.aiModelUsed,
                                       routerMs: routed.routerMs,
                                       planLocalWireMs: routed.planLocalWireMs,
                                       planLocalTotalMs: routed.planLocalTotalMs,
                                       planOpenAIMs: routed.planOpenAIMs,
                                       localKnowledgeContext: localKnowledgeContext,
                                       hasMemoryHints: hasMemoryHints,
                                       turnIndex: currentTurn,
                                       feedbackDepth: 0,
                                       turnStartedAt: turnStartedAt,
                                       mode: mode,
                                       toneRepairCue: toneRepairCue,
                                       affect: effectiveAffect,
                                       originReason: routed.routeReason)
        applyCombinedRouteMetadata(&result, combinedDecision: combinedUsed)
        appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
        logIdentityTurn(decision: identityDecision,
                        now: now,
                        provider: routed.provider,
                        routeReason: routed.routeReason,
                        routerMs: routed.routerMs)
        return result
    }

    // MARK: - Brain Router Pipeline

    private enum CombinedLocalFailureKind: String {
        case timeout
        case schemaFail = "schema_fail"
        case other
    }

    private func routeCombined(_ text: String,
                               history: [ChatMessage],
                               pendingSlot: PendingSlot?,
                               reason: LLMCallReason,
                               promptContext: PromptRuntimeContext?,
                               state: TurnRouterState) async -> CombinedRouteDecision {
        OpenAISettings.preloadAPIKey()
        OpenAISettings.clearInvalidatedAPIKeyIfNeeded()

        if !M2Settings.useOllama {
            if OpenAISettings.apiKeyStatus == .ready {
                return await routeCombinedViaOpenAI(
                    text: text,
                    history: history,
                    pendingSlot: pendingSlot,
                    reason: reason,
                    promptContext: promptContext,
                    state: state,
                    localMs: nil,
                    localOutcome: "local_disabled",
                    localAttempted: false,
                    escalationReason: "local_disabled",
                    routeReason: "combined_local_disabled_openai"
                )
            }

            let classification = IntentClassificationResult(
                classification: IntentClassification(
                    intent: .unknown,
                    confidence: 0.2,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: false
                ),
                provider: .rule,
                attemptedLocal: false,
                attemptedOpenAI: false,
                localSkipReason: "local_disabled",
                intentRouterMsLocal: nil,
                intentRouterMsOpenAI: nil,
                localConfidence: nil,
                openAIConfidence: nil,
                confidenceThreshold: 0.7,
                localTimeoutSeconds: nil,
                escalationReason: "local_disabled"
            )
            let route = RouteDecision(
                plan: friendlyFallbackPlan(OpenAIRouter.OpenAIError.requestFailed("combined_local_disabled_no_openai")),
                provider: .none,
                routerMs: 0,
                aiModelUsed: nil,
                routeReason: "combined_local_disabled_no_openai",
                planLocalWireMs: nil,
                planLocalTotalMs: nil,
                planOpenAIMs: nil
            )
            return CombinedRouteDecision(
                classification: classification,
                route: route,
                localAttempted: false,
                localOutcome: "local_disabled",
                localMs: nil,
                openAIMs: nil
            )
        }

        let localStartedAt = CFAbsoluteTimeGetCurrent()
        do {
            let local = try await withTimeout(RouterTimeouts.localCombinedDeadlineSeconds) {
                try await self.ollamaRouter.routeCombinedWithTiming(
                    text,
                    history: history,
                    pendingSlot: pendingSlot,
                    promptContext: promptContext,
                    state: state,
                    wireDeadlineMs: RouterTimeouts.localCombinedDeadlineMs
                )
            }
            let localMs = max(0, Int((CFAbsoluteTimeGetCurrent() - localStartedAt) * 1000))
            let classification = IntentClassificationResult(
                classification: local.result.classification,
                provider: .ollama,
                attemptedLocal: true,
                attemptedOpenAI: false,
                localSkipReason: nil,
                intentRouterMsLocal: localMs,
                intentRouterMsOpenAI: nil,
                localConfidence: local.result.classification.confidence,
                openAIConfidence: nil,
                confidenceThreshold: 0.7,
                localTimeoutSeconds: RouterTimeouts.localCombinedDeadlineSeconds,
                escalationReason: nil
            )
            let route = RouteDecision(
                plan: local.result.plan,
                provider: .ollama,
                routerMs: localMs,
                aiModelUsed: nil,
                routeReason: "combined_local_success",
                planLocalWireMs: local.timing.wireMs,
                planLocalTotalMs: local.timing.totalMs,
                planOpenAIMs: nil
            )
            #if DEBUG
            print("[ROUTE_DECISION] turn=\(turnCounter) chosen=local reason=combined_local_success local_outcome=ok local_ms=\(localMs)")
            #endif
            return CombinedRouteDecision(
                classification: classification,
                route: route,
                localAttempted: true,
                localOutcome: "ok",
                localMs: localMs,
                openAIMs: nil
            )
        } catch {
            let localMs = max(0, Int((CFAbsoluteTimeGetCurrent() - localStartedAt) * 1000))
            let failureKind = classifyCombinedLocalFailure(error)
            if shouldFallbackToOpenAI(for: failureKind) {
                let routeReason = failureKind == .timeout
                    ? "combined_local_timeout_openai_fallback"
                    : "combined_local_schema_fail_openai_fallback"
                #if DEBUG
                print("[ROUTE_DECISION] turn=\(turnCounter) chosen=openai reason=\(routeReason) local_outcome=\(failureKind.rawValue) local_ms=\(localMs)")
                #endif
                return await routeCombinedViaOpenAI(
                    text: text,
                    history: history,
                    pendingSlot: pendingSlot,
                    reason: reason,
                    promptContext: promptContext,
                    state: state,
                    localMs: localMs,
                    localOutcome: failureKind.rawValue,
                    localAttempted: true,
                    escalationReason: failureKind.rawValue,
                    routeReason: routeReason
                )
            }

            let classification = IntentClassificationResult(
                classification: IntentClassification(
                    intent: .unknown,
                    confidence: 0.2,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: false
                ),
                provider: .rule,
                attemptedLocal: true,
                attemptedOpenAI: false,
                localSkipReason: nil,
                intentRouterMsLocal: localMs,
                intentRouterMsOpenAI: nil,
                localConfidence: nil,
                openAIConfidence: nil,
                confidenceThreshold: 0.7,
                localTimeoutSeconds: RouterTimeouts.localCombinedDeadlineSeconds,
                escalationReason: failureKind.rawValue
            )
            let route = RouteDecision(
                plan: friendlyFallbackPlan(error),
                provider: .ollama,
                routerMs: localMs,
                aiModelUsed: nil,
                routeReason: "combined_local_error_no_openai_fallback",
                planLocalWireMs: nil,
                planLocalTotalMs: localMs,
                planOpenAIMs: nil
            )
            return CombinedRouteDecision(
                classification: classification,
                route: route,
                localAttempted: true,
                localOutcome: failureKind.rawValue,
                localMs: localMs,
                openAIMs: nil
            )
        }
    }

    private func classifyCombinedLocalFailure(_ error: Error) -> CombinedLocalFailureKind {
        if error is RouterTimeout { return .timeout }
        if let ollamaError = error as? OllamaRouter.OllamaError {
            switch ollamaError {
            case .wireDeadlineExceeded:
                return .timeout
            case .schemaMismatch, .jsonParseFailed, .validationFailure:
                return .schemaFail
            default:
                return .other
            }
        }
        return .other
    }

    private func shouldFallbackToOpenAI(for failureKind: CombinedLocalFailureKind) -> Bool {
        guard OpenAISettings.apiKeyStatus == .ready else { return false }
        return failureKind == .timeout || failureKind == .schemaFail
    }

    private func routeCombinedViaOpenAI(text: String,
                                        history: [ChatMessage],
                                        pendingSlot: PendingSlot?,
                                        reason: LLMCallReason,
                                        promptContext: PromptRuntimeContext?,
                                        state: TurnRouterState,
                                        localMs: Int?,
                                        localOutcome: String?,
                                        localAttempted: Bool,
                                        escalationReason: String,
                                        routeReason: String) async -> CombinedRouteDecision {
        let openAIStartedAt = CFAbsoluteTimeGetCurrent()
        #if DEBUG
        print("[OPENAI_TASK] started turn=\(turnCounter) reason=\(routeReason)")
        #endif
        do {
            try Task.checkCancellation()
            let openAIIntent = try await openAIProvider.classifyIntentWithRetry(
                IntentClassifierInput(
                    userText: text,
                    cameraRunning: state.cameraRunning,
                    faceKnown: state.faceKnown,
                    pendingSlot: state.pendingSlot,
                    lastAssistantLine: state.lastAssistantLine
                ),
                timeoutSeconds: openAIRouteTimeoutSeconds
            )
            guard let parsedClassification = parseIntentClassificationPayload(openAIIntent.output.rawText) else {
                throw OpenAIRouter.OpenAIError.requestFailed("combined intent parse failure")
            }

            let selectedModel = selectOpenAIModel(for: text, reason: reason)
            let planDecision = try await openAIProvider.routePlanWithRetry(
                OpenAIPlanRequest(
                    input: text,
                    history: history,
                    pendingSlot: pendingSlot,
                    promptContext: promptContext,
                    modelOverride: selectedModel,
                    reason: .plan,
                    timeoutSeconds: openAIRouteTimeoutSeconds,
                    retryMaxOutputTokens: openAITimeoutRetryMaxTokens
                )
            )
            let openAIMs = max(0, Int((CFAbsoluteTimeGetCurrent() - openAIStartedAt) * 1000))
            #if DEBUG
            print("[OPENAI_TASK] completed turn=\(turnCounter) ms=\(openAIMs)")
            #endif
            let classification = IntentClassificationResult(
                classification: parsedClassification,
                provider: .openai,
                attemptedLocal: localAttempted,
                attemptedOpenAI: true,
                localSkipReason: localAttempted ? nil : "local_disabled",
                intentRouterMsLocal: localMs,
                intentRouterMsOpenAI: openAIMs,
                localConfidence: nil,
                openAIConfidence: parsedClassification.confidence,
                confidenceThreshold: 0.7,
                localTimeoutSeconds: localAttempted ? RouterTimeouts.localCombinedDeadlineSeconds : nil,
                escalationReason: escalationReason
            )
            let route = RouteDecision(
                plan: planDecision.plan,
                provider: .openai,
                routerMs: openAIMs,
                aiModelUsed: selectedModel,
                routeReason: routeReason,
                planLocalWireMs: nil,
                planLocalTotalMs: localMs,
                planOpenAIMs: openAIMs
            )
            return CombinedRouteDecision(
                classification: classification,
                route: route,
                localAttempted: localAttempted,
                localOutcome: localOutcome,
                localMs: localMs,
                openAIMs: openAIMs
            )
        } catch {
            let openAIMs = max(0, Int((CFAbsoluteTimeGetCurrent() - openAIStartedAt) * 1000))
            #if DEBUG
            print("[OPENAI_TASK] failed turn=\(turnCounter) ms=\(openAIMs) error=\(error.localizedDescription.prefix(80))")
            #endif
            let classification = IntentClassificationResult(
                classification: IntentClassification(
                    intent: .unknown,
                    confidence: 0.2,
                    notes: "",
                    autoCaptureHint: false,
                    needsWeb: false
                ),
                provider: .rule,
                attemptedLocal: localAttempted,
                attemptedOpenAI: true,
                localSkipReason: localAttempted ? nil : "local_disabled",
                intentRouterMsLocal: localMs,
                intentRouterMsOpenAI: openAIMs,
                localConfidence: nil,
                openAIConfidence: nil,
                confidenceThreshold: 0.7,
                localTimeoutSeconds: localAttempted ? RouterTimeouts.localCombinedDeadlineSeconds : nil,
                escalationReason: "openai_fallback_failed"
            )
            let route = RouteDecision(
                plan: friendlyFallbackPlan(error),
                provider: .openai,
                routerMs: openAIMs,
                aiModelUsed: nil,
                routeReason: "combined_openai_fallback_error",
                planLocalWireMs: nil,
                planLocalTotalMs: localMs,
                planOpenAIMs: openAIMs
            )
            return CombinedRouteDecision(
                classification: classification,
                route: route,
                localAttempted: localAttempted,
                localOutcome: localOutcome,
                localMs: localMs,
                openAIMs: openAIMs
            )
        }
    }

    private func parseIntentClassificationPayload(_ raw: String) -> IntentClassification? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intentRaw = dict["intent"] as? String,
              let intent = RoutedIntent(rawValue: intentRaw),
              let confidenceNumber = dict["confidence"] as? NSNumber else {
            return nil
        }
        let notes = (dict["notes"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let autoCaptureHint = dict["autoCaptureHint"] as? Bool ?? false
        let needsWeb = dict["needsWeb"] as? Bool ?? (intent == .webRequest)
        return IntentClassification(
            intent: intent,
            confidence: min(1.0, max(0.0, confidenceNumber.doubleValue)),
            notes: notes,
            autoCaptureHint: autoCaptureHint,
            needsWeb: needsWeb
        )
    }

    private func shouldReuseCombinedRouteDecision(_ decision: CombinedRouteDecision?,
                                                  requestedPendingSlot: PendingSlot?,
                                                  initialPendingSlot: PendingSlot?,
                                                  expectedReason: LLMCallReason) -> Bool {
        guard decision != nil else { return false }
        switch expectedReason {
        case .userChat:
            return requestedPendingSlot == nil && initialPendingSlot == nil
        case .pendingSlotReply:
            guard let requestedPendingSlot, let initialPendingSlot else { return false }
            return requestedPendingSlot.slotName.caseInsensitiveCompare(initialPendingSlot.slotName) == .orderedSame
        default:
            return false
        }
    }

    private func applyCombinedRouteMetadata(_ result: inout TurnResult,
                                            combinedDecision: CombinedRouteDecision?) {
        guard let combinedDecision else { return }
        result.routeLocalOutcome = combinedDecision.localOutcome
        if result.intentRouterMsLocal == nil {
            result.intentRouterMsLocal = combinedDecision.classification.intentRouterMsLocal
        }
        if result.intentRouterMsOpenAI == nil {
            result.intentRouterMsOpenAI = combinedDecision.classification.intentRouterMsOpenAI
        }
        if result.planLocalTotalMs == nil {
            result.planLocalTotalMs = combinedDecision.localMs
        }
        if result.planOpenAIMs == nil {
            result.planOpenAIMs = combinedDecision.openAIMs
        }
    }

    /// Routes plans through PlanRoutePolicy.
    /// Default policy: Ollama first, then OpenAI fallback when available.
    /// Dev override `preferOpenAIPlans` can flip to OpenAI-first when a key is ready.
    private func routePlan(_ text: String, history: [ChatMessage],
                           pendingSlot: PendingSlot? = nil,
                           reason: LLMCallReason = .userChat,
                           promptContext: PromptRuntimeContext? = nil) async -> (Plan, LLMProvider, Int, String?, String, Int?, Int?, Int?) {
        OpenAISettings.preloadAPIKey()
        OpenAISettings.clearInvalidatedAPIKeyIfNeeded()
        let planRoutePolicy = PlanRoutePolicy(
            useOllama: M2Settings.useOllama,
            preferOpenAIPlans: M2Settings.preferOpenAIPlans,
            openAIStatus: OpenAISettings.apiKeyStatus
        )
        #if DEBUG
        print("[PLAN_ROUTE_POLICY] local_first=\(planRoutePolicy.localFirst) openai_fallback=\(planRoutePolicy.openAIFallback) m2_useOllama=\(M2Settings.useOllama) prefer_openai_plans=\(M2Settings.preferOpenAIPlans) openai_status=\(planRoutePolicy.openAIStatus)")
        #endif

        var ollamaLocalFirstFailKind: String?
        var localWireMs: Int?
        var localTotalMs: Int?
        var openAIMs: Int?

        // Local-first: attempt Ollama before OpenAI when both are available
        if planRoutePolicy.routeOrder.first == .ollama && planRoutePolicy.routeOrder.contains(.openai) {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let routed = try await self.ollamaRouter.routePlanWithTiming(
                    text,
                    history: history,
                    pendingSlot: pendingSlot,
                    promptContext: promptContext,
                    skipRepairRetry: true,
                    wireDeadlineMs: RouterTimeouts.localCombinedDeadlineMs
                )
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                localWireMs = routed.timing.wireMs
                localTotalMs = routed.timing.totalMs
                routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: true)
                return (routed.plan, .ollama, ms, nil, "ollama_local_first_success", localWireMs, localTotalMs, nil)
            } catch {
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                let failInfo = classifyOllamaFailure(error)
                routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: false)
                #if DEBUG
                print("[OLLAMA_PLAN_FAIL] kind=\(failInfo.kind) reasons=\(failInfo.reasonCount) ms=\(ms) detail=\(failInfo.detail)")
                #endif
                // Fall through to OpenAI with specific fallback reason
                ollamaLocalFirstFailKind = failInfo.kind
            }
        }

        if planRoutePolicy.routeOrder.contains(.openai) {
            let start = CFAbsoluteTimeGetCurrent()
            let selectedModel = selectOpenAIModel(for: text, reason: reason)
            do {
                let timeoutSeconds = openAIRouteTimeoutSecondsFor(input: text, reason: reason)
                let planDecision = try await self.openAIProvider.routePlanWithRetry(
                    OpenAIPlanRequest(
                        input: text,
                        history: history,
                        pendingSlot: pendingSlot,
                        promptContext: promptContext,
                        modelOverride: selectedModel,
                        reason: .plan,
                        timeoutSeconds: timeoutSeconds,
                        retryMaxOutputTokens: openAITimeoutRetryMaxTokens
                    )
                )
                let plan = planDecision.plan
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                openAIMs = ms
                routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: true)
                if let failKind = ollamaLocalFirstFailKind {
                    return (plan, .openai, ms, selectedModel, "ollama_\(failKind)_fallback", localWireMs, localTotalMs, openAIMs)
                }
                let routeReason = planDecision.didRetry ? "openai_success_timeout_retry" : "openai_success"
                return (plan, .openai, ms, selectedModel, routeReason, localWireMs, localTotalMs, openAIMs)
            } catch {
                if let validationFailure = routerValidationFailure(from: error) {
                    let (plan, routeReason) = planForRouterValidationFailure(
                        validationFailure,
                        userText: text,
                        now: Date()
                    )
                    let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: false)
                    openAIMs = ms
                    return (plan, .openai, ms, selectedModel, routeReason, localWireMs, localTotalMs, openAIMs)
                }

                if isTimeoutLikeOpenAIError(error) {
                    let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: false)
                    openAIMs = ms
                    return (friendlyFallbackPlan(error), .openai, ms, selectedModel, "openai_timeout_retry_failed", localWireMs, localTotalMs, openAIMs)
                }

                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: false)
                openAIMs = ms
                return (friendlyFallbackPlan(error), .openai, ms, selectedModel, "openai_error_fallback", localWireMs, localTotalMs, openAIMs)
            }
        }

        if planRoutePolicy.routeOrder.first == LLMProvider.none,
           planRoutePolicy.openAIStatus == .invalid || OpenAISettings.authFailureStatusCode == 401 || OpenAISettings.authFailureStatusCode == 403 {
            return (friendlyFallbackPlan(OpenAIRouter.OpenAIError.invalidAPIKey), .none, 0, nil, "openai_invalid_key", localWireMs, localTotalMs, openAIMs)
        }

        if planRoutePolicy.routeOrder.first == .ollama {
            return await ollamaFallback(text, history: history, pendingSlot: pendingSlot, reason: reason, promptContext: promptContext)
        }

        return (friendlyFallbackPlan(OpenAIRouter.OpenAIError.notConfigured), .none, 0, nil, "no_provider_configured", localWireMs, localTotalMs, openAIMs)
    }

    /// Ollama attempt — single call, no validation repair.
    private func ollamaFallback(_ text: String, history: [ChatMessage],
                                pendingSlot: PendingSlot?,
                                reason: LLMCallReason,
                                promptContext: PromptRuntimeContext?) async -> (Plan, LLMProvider, Int, String?, String, Int?, Int?, Int?) {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let routed = try await self.ollamaRouter.routePlanWithTiming(
                text,
                history: history,
                pendingSlot: pendingSlot,
                promptContext: promptContext,
                skipRepairRetry: false,
                wireDeadlineMs: RouterTimeouts.localCombinedDeadlineMs
            )
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: true)
            return (routed.plan, .ollama, ms, nil, "ollama_success", routed.timing.wireMs, routed.timing.totalMs, nil)
        } catch {
            if let validationFailure = routerValidationFailure(from: error) {
                let (plan, routeReason) = planForRouterValidationFailure(
                    validationFailure,
                    userText: text,
                    now: Date()
                )
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: false)
                return (plan, .none, ms, nil, routeReason, nil, nil, nil)
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: false)
            return (friendlyFallbackPlan(error), .ollama, ms, nil, "ollama_error_fallback", nil, nil, nil)
        }
    }

    // MARK: - Execute Plan

    private func executePlan(_ plan: Plan,
                             originalInput: String,
                             history: [ChatMessage],
                             provider: LLMProvider,
                             aiModelUsed: String?,
                             routerMs: Int,
                             planLocalWireMs: Int? = nil,
                             planLocalTotalMs: Int? = nil,
                             planOpenAIMs: Int? = nil,
                             localKnowledgeContext: LocalKnowledgeContext,
                             hasMemoryHints: Bool,
                             turnIndex: Int,
                             feedbackDepth: Int,
                             turnStartedAt: Date,
                             mode: ConversationMode,
                             toneRepairCue: String? = nil,
                             affect: AffectMetadata = .neutral,
                             originReason: String? = nil) async -> TurnResult {
        let exec = await toolRunner.executePlan(plan, originalInput: originalInput, pendingSlotName: pendingSlot?.slotName)

        var result = TurnResult()
        result.llmProvider = provider
        result.aiModelUsed = aiModelUsed
        result.executedToolSteps = exec.executedToolSteps
        result.toolMsTotal = exec.toolMsTotal
        result.planExecutionMs = exec.executionMs
        result.speechSelectionMs = exec.speechSelectionMs
        result.routerMs = routerMs
        result.planLocalWireMs = planLocalWireMs
        result.planLocalTotalMs = planLocalTotalMs
        result.planOpenAIMs = planOpenAIMs
        result.originProvider = originProvider(for: provider)
        result.executionProvider = executionProvider(for: provider, hasToolExecution: !exec.executedToolSteps.isEmpty)
        result.originReason = originReason

        // Stamp provider on assistant messages
        result.appendedChat = exec.chatMessages.map { msg in
            if msg.role == .assistant {
                var stamped = msg
                stamped.llmProvider = provider
                stamped.originProvider = result.originProvider
                stamped.executionProvider = result.executionProvider
                stamped.originReason = result.originReason
                return stamped
            }
            return msg
        }
        result.spokenLines = exec.spokenLines
        result.appendedOutputs = exec.outputItems
        result.triggerFollowUpCapture = exec.triggerFollowUpCapture
        result.usedMemoryHints = hasMemoryHints && provider != .none

        // Auto-repair: image_url slot means the image probe failed.
        // Retry once via LLM without bothering the user.
        if let req = exec.pendingSlotRequest, req.slot == "image_url" {
            #if DEBUG
            print("[TurnOrchestrator] Image probe failed — auto-repair retry")
            #endif
            let retryResult = await autoRepairImage(originalInput: originalInput,
                                                    history: history,
                                                    failureReason: req.prompt,
                                                    aiModelUsed: aiModelUsed,
                                                    localKnowledgeContext: localKnowledgeContext,
                                                    hasMemoryHints: hasMemoryHints,
                                                    turnIndex: turnIndex,
                                                    feedbackDepth: feedbackDepth,
                                                    turnStartedAt: turnStartedAt,
                                                    originReason: originReason)
            if let retryResult = retryResult {
                return retryResult
            }
            return result
        }

        // Handle pendingSlot from executor result (non-image)
        if let req = exec.pendingSlotRequest {
            pendingSlot = PendingSlot(slotName: req.slot, prompt: req.prompt, originalUserText: originalInput)
            result.triggerFollowUpCapture = true
        }

        let shouldNarrateProgress = shouldNarrateToolProgress(for: originalInput, plan: plan)
        let forceToolFeedback = shouldForceToolFeedback(for: originalInput, plan: plan)
        if shouldNarrateProgress {
            prependAssistantProgressLines(toolProgressLines(from: plan), into: &result, provider: provider)
        }

        await applyToolResultFeedbackLoop(
            &result,
            originalInput: originalInput,
            history: history,
            provider: provider,
            aiModelUsed: aiModelUsed,
            force: forceToolFeedback,
            allowFeedback: shouldAllowToolFeedback(for: plan),
            depth: feedbackDepth,
            turnStartedAt: turnStartedAt
        )
        result.executionProvider = executionProvider(for: provider, hasToolExecution: !result.executedToolSteps.isEmpty)
        applyCanvasPresentationPolicy(&result)
        applyResponsePolish(&result, plan: plan, hasMemoryHints: hasMemoryHints, turnIndex: turnIndex)
        applyAffectMirroringResponsePolicy(&result, affect: affect)
        applyToneRepairResponsePolicy(&result, cue: toneRepairCue)
        applyFollowUpQuestionPolicy(&result, turnIndex: turnIndex)
        if currentTurnCaptureAfterReplyHint, !result.triggerFollowUpCapture {
            result.triggerQuestionAutoListen = true
        }
        applyKnowledgeAttribution(&result,
                                  userInput: originalInput,
                                  provider: provider,
                                  aiModelUsed: aiModelUsed,
                                  localKnowledgeContext: localKnowledgeContext)
        applyRoutingAttribution(&result, planProvider: provider, planRouterMs: nil)
        applyOriginMetadata(&result)
        updateAssistantState(after: result, mode: mode)
        rememberAssistantLines(result.appendedChat)
        return result
    }

    // MARK: - Image Auto-Repair

    /// Retries the LLM once with repair context when image URLs fail the probe.
    /// Uses same provider logic as routePlan: OpenAI only when configured, Ollama only as standalone.
    private func autoRepairImage(originalInput: String,
                                 history: [ChatMessage],
                                 failureReason: String,
                                 aiModelUsed: String?,
                                 localKnowledgeContext: LocalKnowledgeContext,
                                 hasMemoryHints: Bool,
                                 turnIndex: Int,
                                 feedbackDepth: Int,
                                 turnStartedAt: Date,
                                 originReason: String?) async -> TurnResult? {
        let repairReasons = [
            "The image URLs you provided are dead or don't serve image content. \(failureReason)",
            "Return 3 NEW direct image URLs from upload.wikimedia.org (preferred), images.unsplash.com, or images.pexels.com. URLs MUST end in .jpg, .png, .gif, or .webp. NEVER use example.com or placeholder domains."
        ]

        if OpenAISettings.isConfigured {
            #if DEBUG
            print("[ROUTER] imageRepair via openai")
            #endif
            do {
                let plan = try await withTimeout(openAIImageRepairTimeoutSeconds) {
                    try await self.openAIRouter.routePlan(
                        originalInput,
                        history: [],
                        repairReasons: repairReasons,
                        modelOverride: aiModelUsed,
                        reason: .rewrite
                    )
                }
                return await executeImageRepair(plan,
                                                originalInput: originalInput,
                                                history: history,
                                                provider: .openai,
                                                aiModelUsed: aiModelUsed,
                                                localKnowledgeContext: localKnowledgeContext,
                                                hasMemoryHints: hasMemoryHints,
                                                turnIndex: turnIndex,
                                                feedbackDepth: feedbackDepth,
                                                turnStartedAt: turnStartedAt,
                                                originReason: originReason ?? "openai_image_repair")
            } catch {
                #if DEBUG
                print("[ROUTER] imageRepair openai failed: \(error.localizedDescription)")
                #endif
            }
        } else if M2Settings.useOllama {
            #if DEBUG
            print("[ROUTER] imageRepair via ollama")
            #endif
            do {
                let plan = try await withTimeout(4.0) {
                    try await self.ollamaRouter.routePlan(originalInput, history: [], repairReasons: repairReasons)
                }
                return await executeImageRepair(plan,
                                                originalInput: originalInput,
                                                history: history,
                                                provider: .ollama,
                                                aiModelUsed: nil,
                                                localKnowledgeContext: localKnowledgeContext,
                                                hasMemoryHints: hasMemoryHints,
                                                turnIndex: turnIndex,
                                                feedbackDepth: feedbackDepth,
                                                turnStartedAt: turnStartedAt,
                                                originReason: originReason ?? "ollama_image_repair")
            } catch {
                #if DEBUG
                print("[ROUTER] imageRepair ollama failed: \(error.localizedDescription)")
                #endif
            }
        }

        return nil
    }

    private func executeImageRepair(_ plan: Plan,
                                    originalInput: String,
                                    history: [ChatMessage],
                                    provider: LLMProvider,
                                    aiModelUsed: String?,
                                    localKnowledgeContext: LocalKnowledgeContext,
                                    hasMemoryHints: Bool,
                                    turnIndex: Int,
                                    feedbackDepth: Int,
                                    turnStartedAt: Date,
                                    originReason: String?) async -> TurnResult? {
        let exec = await toolRunner.executePlan(plan, originalInput: originalInput, pendingSlotName: nil)

        // If the retry ALSO produced an image_url failure, give up
        if let req = exec.pendingSlotRequest, req.slot == "image_url" {
            #if DEBUG
            print("[TurnOrchestrator] Image auto-repair also failed — giving up")
            #endif
            var result = TurnResult()
            result.llmProvider = provider
            result.aiModelUsed = aiModelUsed
            result.originProvider = originProvider(for: provider)
            result.executionProvider = executionProvider(for: provider, hasToolExecution: false)
            result.originReason = originReason
            let msg = "I couldn't find a working image for that - sorry about that."
            result.appendedChat = [ChatMessage(
                role: .assistant,
                text: msg,
                llmProvider: provider,
                originProvider: result.originProvider,
                executionProvider: result.executionProvider,
                originReason: result.originReason
            )]
            result.spokenLines = [msg]
            return result
        }

        var result = TurnResult()
        result.llmProvider = provider
        result.aiModelUsed = aiModelUsed
        result.originProvider = originProvider(for: provider)
        result.executionProvider = executionProvider(for: provider, hasToolExecution: !exec.executedToolSteps.isEmpty)
        result.originReason = originReason
        result.appendedChat = exec.chatMessages.map { msg in
            if msg.role == .assistant {
                var stamped = msg
                stamped.llmProvider = provider
                stamped.originProvider = result.originProvider
                stamped.executionProvider = result.executionProvider
                stamped.originReason = result.originReason
                return stamped
            }
            return msg
        }
        result.spokenLines = exec.spokenLines
        result.appendedOutputs = exec.outputItems
        result.triggerFollowUpCapture = exec.triggerFollowUpCapture
        result.usedMemoryHints = hasMemoryHints && provider != .none

        if let req = exec.pendingSlotRequest {
            pendingSlot = PendingSlot(slotName: req.slot, prompt: req.prompt, originalUserText: originalInput)
            result.triggerFollowUpCapture = true
        }

        let shouldNarrateProgress = shouldNarrateToolProgress(for: originalInput, plan: plan)
        let forceToolFeedback = shouldForceToolFeedback(for: originalInput, plan: plan)
        if shouldNarrateProgress {
            prependAssistantProgressLines(toolProgressLines(from: plan), into: &result, provider: provider)
        }

        await applyToolResultFeedbackLoop(
            &result,
            originalInput: originalInput,
            history: history,
            provider: provider,
            aiModelUsed: aiModelUsed,
            force: forceToolFeedback,
            allowFeedback: shouldAllowToolFeedback(for: plan),
            depth: feedbackDepth,
            turnStartedAt: turnStartedAt
        )
        result.executionProvider = executionProvider(for: provider, hasToolExecution: !result.executedToolSteps.isEmpty)
        applyCanvasPresentationPolicy(&result)
        applyResponsePolish(&result, plan: plan, hasMemoryHints: hasMemoryHints, turnIndex: turnIndex)
        applyFollowUpQuestionPolicy(&result, turnIndex: turnIndex)
        if currentTurnCaptureAfterReplyHint, !result.triggerFollowUpCapture {
            result.triggerQuestionAutoListen = true
        }
        applyKnowledgeAttribution(&result,
                                  userInput: originalInput,
                                  provider: provider,
                                  aiModelUsed: aiModelUsed,
                                  localKnowledgeContext: localKnowledgeContext)
        applyRoutingAttribution(&result, planProvider: provider, planRouterMs: nil)
        applyOriginMetadata(&result)
        updateAssistantState(after: result, mode: ConversationModeClassifier.classify(originalInput))
        rememberAssistantLines(result.appendedChat)
        return result
    }

    private func immediateIdentityTurnResult(for resolution: FaceIdentityConfirmationResolution) -> TurnResult {
        let message: String
        switch resolution {
        case .enrolled(_, let enrolledMessage):
            message = enrolledMessage
        case .declined(let declinedMessage):
            message = declinedMessage
        case .requestName(let requestMessage):
            message = requestMessage
        }

        return immediateTalkTurnResult(message: message)
    }

    private func immediateTalkTurnResult(message: String) -> TurnResult {
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: message)]
        result.spokenLines = [message]
        applyRoutingAttribution(&result, planProvider: result.llmProvider, planRouterMs: result.routerMs)
        return result
    }

    private func appendIdentityPromptIfNeeded(_ prompt: String?, to result: inout TurnResult) {
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return }
        guard !result.triggerFollowUpCapture else { return }

        let alreadyContainsIdentityPrompt = result.appendedChat.contains { message in
            guard message.role == .assistant else { return false }
            return isIdentityPromptLike(message.text)
        }
        if alreadyContainsIdentityPrompt {
            return
        }

        result.appendedChat.append(
            ChatMessage(
                role: .assistant,
                text: prompt,
                llmProvider: result.llmProvider,
                originProvider: result.originProvider,
                executionProvider: result.executionProvider,
                originReason: result.originReason
            )
        )
        result.spokenLines.append(prompt)
    }

    private func isIdentityPromptLike(_ text: String) -> Bool {
        let normalized = normalizeForComparison(text)
        if normalized.contains("what s your name") || normalized.contains("what is your name") {
            return true
        }
        if normalized.contains("remember you") && normalized.contains("name") {
            return true
        }
        if normalized.contains("recognize you next time") {
            return true
        }
        return false
    }

    private func logIdentityTurn(decision: IdentityTurnDecision,
                                 now: Date,
                                 provider: LLMProvider,
                                 routeReason: String,
                                 routerMs: Int?) {
        #if DEBUG
        let shouldPrompt = decision.shouldPromptIdentity ? "yes" : "no"
        let msLabel = routerMs.map(String.init) ?? "n/a"
        print(
            "[IDENTITY] before=\(decision.stateBefore.debugSummary(reference: now)) " +
            "after=\(decision.stateAfter.debugSummary(reference: now)) " +
            "recognition=\(decision.recognitionSummary) " +
            "shouldPromptIdentity=\(shouldPrompt) " +
            "promptReason=\(decision.promptReason) " +
            "provider=\(provider.rawValue) route_reason=\(routeReason) router_ms=\(msLabel)"
        )
        #endif
    }

    // MARK: - Helpers

    private func shouldRunVisionToolFirst(for intent: VisionQueryIntent) -> Bool {
        guard isVisionToolingEnabled else { return false }
        if case .none = intent { return false }
        return true
    }

    private var isVisionToolingEnabled: Bool {
        guard cameraVision.isRunning else { return false }
        guard cameraVision.health.isHealthy else { return false }
        return hasVisionToolsRegistered
    }

    private var hasVisionToolsRegistered: Bool {
        let registry = ToolRegistry.shared
        return registry.get("describe_camera_view") != nil
            && registry.get("camera_visual_qa") != nil
            && registry.get("find_camera_objects") != nil
    }

    private func hasRecentCameraFrame(within seconds: TimeInterval) -> Bool {
        guard let latestFrameAt = cameraVision.latestFrameAt else { return false }
        return Date().timeIntervalSince(latestFrameAt) <= seconds
    }

    private func runVisionToolFirstTurn(intent: VisionQueryIntent,
                                        text: String,
                                        history: [ChatMessage],
                                        mode: ConversationMode,
                                        localKnowledgeContext: LocalKnowledgeContext,
                                        hasMemoryHints: Bool,
                                        turnIndex: Int,
                                        turnStartedAt: Date,
                                        identityDecision: IdentityTurnDecision,
                                        now: Date) async -> TurnResult {
        let plan = visionToolPlan(for: intent, preface: nil)
        lastFinalActionKind = inferredActionKind(for: plan)
        var result = await executePlan(
            plan,
            originalInput: text,
            history: history,
            provider: .none,
            aiModelUsed: nil,
            routerMs: 0,
            localKnowledgeContext: localKnowledgeContext,
            hasMemoryHints: hasMemoryHints,
            turnIndex: turnIndex,
            feedbackDepth: 0,
            turnStartedAt: turnStartedAt,
            mode: mode,
            affect: .neutral,
            originReason: "vision_tool_first"
        )
        ensureVisionAssistantSummary(intent: intent, result: &result)
        appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
        logIdentityTurn(
            decision: identityDecision,
            now: now,
            provider: .none,
            routeReason: "vision_tool_first",
            routerMs: 0
        )
        return result
    }

    private func ensureVisionAssistantSummary(intent: VisionQueryIntent, result: inout TurnResult) {
        let assistantLines = result.appendedChat
            .filter { $0.role == .assistant }
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if assistantLines.contains(where: containsVisionSummaryPhrase) {
            return
        }

        let fallback = extractVisionSpokenSummary(from: result.appendedOutputs)
            ?? defaultVisionSpokenSummary(for: intent)
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !assistantLines.contains(trimmed) else { return }

        result.appendedChat.append(
            ChatMessage(
                role: .assistant,
                text: trimmed,
                llmProvider: result.llmProvider,
                originProvider: result.originProvider,
                executionProvider: result.executionProvider,
                originReason: result.originReason
            )
        )
        result.spokenLines.append(trimmed)
    }

    private func containsVisionSummaryPhrase(_ text: String) -> Bool {
        let normalized = normalizeForComparison(text)
        if normalized.contains("what i can see") || normalized.contains("i can see") {
            return true
        }
        if normalized.contains("checked the camera") || normalized.contains("looked at the camera") {
            return true
        }
        return false
    }

    private func extractVisionSpokenSummary(from outputs: [OutputItem]) -> String? {
        for output in outputs where output.kind == .markdown {
            guard let data = output.payload.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let spoken = dict["spoken"] as? String else {
                continue
            }
            let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func defaultVisionSpokenSummary(for intent: VisionQueryIntent) -> String {
        switch intent {
        case .describe, .none:
            return "Here's what I can see right now."
        case .visualQA:
            return "I checked the camera and answered that."
        case .findObject:
            return "I checked the camera and found what I could."
        }
    }

    private func visionToolPlan(for intent: VisionQueryIntent, preface: String?) -> Plan {
        let spokenPrefix = preface?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch intent {
        case .describe, .none:
            return Plan(
                steps: [.tool(name: "describe_camera_view", args: [:], say: nil)],
                say: spokenPrefix?.isEmpty == false ? spokenPrefix : nil
            )
        case .visualQA(let question):
            return Plan(
                steps: [.tool(name: "camera_visual_qa", args: ["question": .string(question)], say: nil)],
                say: spokenPrefix?.isEmpty == false ? spokenPrefix : nil
            )
        case .findObject(let query):
            return Plan(
                steps: [.tool(name: "find_camera_objects", args: ["query": .string(query)], say: nil)],
                say: spokenPrefix?.isEmpty == false ? spokenPrefix : nil
            )
        }
    }

    private func runRecipeToolFirstTurnIfNeeded(text: String,
                                                intent: RoutedIntent,
                                                history: [ChatMessage],
                                                mode: ConversationMode,
                                                localKnowledgeContext: LocalKnowledgeContext,
                                                hasMemoryHints: Bool,
                                                turnIndex: Int,
                                                turnStartedAt: Date,
                                                identityDecision: IdentityTurnDecision,
                                                now: Date) async -> TurnResult? {
        guard intent == .recipe else { return nil }
        guard let query = recipeToolFirstQuery(from: text) else { return nil }

        let recipePlan = Plan(steps: [
            .tool(name: "find_recipe", args: ["query": .string(query)], say: nil)
        ])

        lastFinalActionKind = inferredActionKind(for: recipePlan)
        var result = await executePlan(
            recipePlan,
            originalInput: text,
            history: history,
            provider: .none,
            aiModelUsed: nil,
            routerMs: 0,
            localKnowledgeContext: localKnowledgeContext,
            hasMemoryHints: hasMemoryHints,
            turnIndex: turnIndex,
            feedbackDepth: 0,
            turnStartedAt: turnStartedAt,
            mode: mode,
            affect: .neutral,
            originReason: "recipe_tool_first"
        )

        if recipeToolOutputLooksFailed(result), OpenAISettings.apiKeyStatus == .ready {
            let (rawPlan, provider, routerMs, aiModelUsed, routeProviderReason, planLocalWireMs, planLocalTotalMs, planOpenAIMs) = await routePlan(
                text,
                history: history,
                reason: .userChat,
                promptContext: nil
            )
            let guardedPlan = enforceNoFalseBlindnessGuardrail(on: rawPlan, userInput: text)
            let fallbackPlan = await maybeRephraseRepeatedTalk(
                guardedPlan,
                userInput: text,
                history: history,
                mode: mode,
                turnIndex: turnIndex,
                turnStartedAt: turnStartedAt
            )
            let shapedPlan = enforceLengthPresentationPolicy(fallbackPlan, mode: mode)
            lastFinalActionKind = inferredActionKind(for: shapedPlan)
            result = await executePlan(
                shapedPlan,
                originalInput: text,
                history: history,
                provider: provider,
                aiModelUsed: aiModelUsed,
                routerMs: routerMs,
                planLocalWireMs: planLocalWireMs,
                planLocalTotalMs: planLocalTotalMs,
                planOpenAIMs: planOpenAIMs,
                localKnowledgeContext: localKnowledgeContext,
                hasMemoryHints: hasMemoryHints,
                turnIndex: turnIndex,
                feedbackDepth: 0,
                turnStartedAt: turnStartedAt,
                mode: mode,
                affect: .neutral,
                originReason: routeProviderReason
            )
            appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
            logIdentityTurn(
                decision: identityDecision,
                now: now,
                provider: provider,
                routeReason: routeProviderReason,
                routerMs: routerMs
            )
            return result
        }

        appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
        logIdentityTurn(
            decision: identityDecision,
            now: now,
            provider: .none,
            routeReason: "recipe_tool_first",
            routerMs: 0
        )
        return result
    }

    private func recipeToolFirstQuery(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        let recipeMarkers = [
            "recipe",
            "how to make",
            "how do i make",
            "ingredients",
            "cook",
            "cooking",
            "bake",
            "baking"
        ]
        guard recipeMarkers.contains(where: { lower.contains($0) }) else { return nil }

        var query = trimmed
        let patterns = [
            #"(?i)\b(find|show|get)\s+(me\s+)?(a\s+)?recipe\s+for\s+"#,
            #"(?i)\brecipe\s+for\s+"#,
            #"(?i)\bhow\s+to\s+make\s+"#,
            #"(?i)\bhow\s+do\s+i\s+make\s+"#
        ]
        for pattern in patterns {
            query = query.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        query = query.replacingOccurrences(
            of: #"(?i)\s+(and|&)\s+(show|find|get).*$"#,
            with: "",
            options: .regularExpression
        )
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? trimmed : query
    }

    private func recipeToolOutputLooksFailed(_ result: TurnResult) -> Bool {
        let merged = result.appendedOutputs
            .filter { $0.kind == .markdown }
            .map(\.payload)
            .joined(separator: "\n")
            .lowercased()

        if merged.isEmpty { return true }
        return merged.contains("couldn't fetch a reliable recipe page")
            || merged.contains("recipe search")
                && merged.contains("couldn't")
    }

    private func handlePendingCapabilityRequestTurn(text: String,
                                                    history: [ChatMessage],
                                                    mode: ConversationMode,
                                                    localKnowledgeContext: LocalKnowledgeContext,
                                                    hasMemoryHints: Bool,
                                                    turnIndex: Int,
                                                    turnStartedAt: Date,
                                                    identityDecision: IdentityTurnDecision,
                                                    now: Date) async -> TurnResult? {
        _ = history
        _ = localKnowledgeContext
        _ = turnStartedAt
        let resolution = router.resolvePendingCapabilityInput(
            PendingCapabilityInput(
                pendingRequest: pendingCapabilityRequest,
                text: text,
                now: now
            )
        )
        switch resolution {
        case .none:
            return nil
        case .learnSource(let url, let focus, let memoryContent, let successMessage):
            pendingSlot = nil
            pendingCapabilityRequest = nil

            let learnArgs = ["url": url, "focus": focus]
            let learnAction = ToolAction(name: "learn_website", args: learnArgs, say: nil)
            let learnOutput = toolRunner.executeTool(learnAction)

            let memoryArgs = [
                "type": "preference",
                "content": memoryContent,
                "source": "capability_gap_external_source"
            ]
            let memoryAction = ToolAction(name: "save_memory", args: memoryArgs, say: nil)
            _ = toolRunner.executeTool(memoryAction)

            var result = immediateTalkTurnResult(message: successMessage)
            result.llmProvider = .none
            result.originProvider = .local
            result.executionProvider = .local
            result.originReason = "capability_gap_source_learned"
            result.routerMs = 0
            result.executedToolSteps = [
                (learnAction.name, learnAction.args),
                (memoryAction.name, memoryAction.args)
            ]
            if let learnOutput {
                result.appendedOutputs.append(learnOutput)
            }

            applyResponsePolish(
                &result,
                plan: Plan(steps: [.talk(say: result.spokenLines.first ?? "")]),
                hasMemoryHints: hasMemoryHints,
                turnIndex: turnIndex
            )
            updateAssistantState(after: result, mode: mode)
            rememberAssistantLines(result.appendedChat)
            logIdentityTurn(
                decision: identityDecision,
                now: now,
                provider: .none,
                routeReason: "capability_gap_source_learned",
                routerMs: 0
            )
            return result
        case .askForSource(let prompt, let pendingSlotValue, let updatedRequest):
            pendingCapabilityRequest = updatedRequest
            lastExternalSourcePromptAt = now
            pendingSlot = pendingSlotValue

            var result = immediateTalkTurnResult(message: prompt)
            result.llmProvider = .none
            result.originProvider = .local
            result.executionProvider = .local
            result.originReason = "capability_gap_need_exact_url"
            result.routerMs = 0
            result.triggerFollowUpCapture = true

            applyResponsePolish(
                &result,
                plan: Plan(steps: [.ask(slot: "source_url_or_site", prompt: prompt)]),
                hasMemoryHints: hasMemoryHints,
                turnIndex: turnIndex
            )
            updateAssistantState(after: result, mode: mode)
            rememberAssistantLines(result.appendedChat)
            logIdentityTurn(
                decision: identityDecision,
                now: now,
                provider: .none,
                routeReason: "capability_gap_need_exact_url",
                routerMs: 0
            )
            return result
        case .drop(let message):
            pendingSlot = nil
            pendingCapabilityRequest = nil

            var result = immediateTalkTurnResult(message: message)
            result.llmProvider = .none
            result.originProvider = .local
            result.executionProvider = .local
            result.originReason = "capability_gap_source_url_missing_drop"
            result.routerMs = 0
            applyResponsePolish(
                &result,
                plan: Plan(steps: [.talk(say: result.spokenLines.first ?? "")]),
                hasMemoryHints: hasMemoryHints,
                turnIndex: turnIndex
            )
            updateAssistantState(after: result, mode: mode)
            rememberAssistantLines(result.appendedChat)
            logIdentityTurn(
                decision: identityDecision,
                now: now,
                provider: .none,
                routeReason: "capability_gap_source_url_missing_drop",
                routerMs: 0
            )
            return result
        }
    }

    private func planForRouterValidationFailure(_ failure: RouterValidationFailure,
                                                userText: String,
                                                now: Date) -> (Plan, String) {
        switch failure.kind {
        case .unknownTool:
            if let canonicalEnrollmentPlan = canonicalEnrollmentPlanIfNeeded(
                toolName: failure.toolName,
                rawPlanPrefix: failure.rawPlanPrefix,
                userText: userText
            ) {
                return (canonicalEnrollmentPlan, "unknown_tool_enrollment_normalized")
            }
            let classification = classifyUnknownToolFailure(
                toolName: failure.toolName,
                userText: userText
            )
            switch classification {
            case .externalSource:
                let plan = buildExternalSourceAskPlan(
                    toolName: failure.toolName,
                    userText: userText,
                    now: now,
                    prefersWebsiteURL: prefersWebsiteURLForUnknownTool()
                )
                let routeReason: String
                if plan.steps.contains(where: { step in
                    if case .ask = step { return true }
                    return false
                }) {
                    routeReason = "unknown_tool_external_source_ask"
                } else {
                    routeReason = "unknown_tool_external_source_reminder"
                }
                return (plan, routeReason)
            case .capabilityBuild:
                let plan = buildExternalSourceAskPlan(
                    toolName: failure.toolName,
                    userText: userText,
                    now: now,
                    prefersWebsiteURL: false
                )
                return (plan, "unknown_tool_source_ask_generic")
            }
        }
    }

    private func buildExternalSourceAskPlan(toolName: String,
                                            userText: String,
                                            now: Date,
                                            prefersWebsiteURL: Bool) -> Plan {
        let reminderLine = prefersWebsiteURL
            ? "Still need the link to the listings page."
            : "Still need a source (URL/app/site) so I know where to get that info."
        if let lastAsked = lastExternalSourcePromptAt,
           now.timeIntervalSince(lastAsked) < unknownToolPromptCooldownSeconds {
            pendingCapabilityRequest = PendingCapabilityRequest(
                kind: .externalSource,
                desiredToolName: toolName,
                originalUserGoal: userText,
                prefersWebsiteURL: prefersWebsiteURL,
                createdAt: pendingCapabilityRequest?.createdAt ?? now,
                lastAskedAt: lastAsked,
                reminderCount: pendingCapabilityRequest?.reminderCount ?? 0
            )
            return Plan(steps: [.talk(say: reminderLine)])
        }

        let prompt: String
        if prefersWebsiteURL {
            prompt = "I don't have a built-in way to do that yet. Where do you normally check it? Paste the URL (for example, the Event Cinemas page) and I'll learn it."
        } else {
            prompt = "I don't have a built-in way to do that yet. Where should I get that info from? Share the URL, app, or site and I'll learn it."
        }
        pendingCapabilityRequest = PendingCapabilityRequest(
            kind: .externalSource,
            desiredToolName: toolName,
            originalUserGoal: userText,
            prefersWebsiteURL: prefersWebsiteURL,
            createdAt: now,
            lastAskedAt: now,
            reminderCount: 0
        )
        lastExternalSourcePromptAt = now
        return Plan(steps: [.ask(slot: "source_url_or_site", prompt: prompt)])
    }

    private func classifyUnknownToolFailure(toolName: String, userText: String) -> CapabilityGapRequestKind {
        if prefersWebsiteURLForUnknownTool() {
            return .externalSource
        }
        if let intent = currentIntentClassification?.classification.intent,
           intent == .automationRequest {
            return .capabilityBuild
        }
        return .externalSource
    }

    private func prefersWebsiteURLForUnknownTool() -> Bool {
        guard let classification = currentIntentClassification?.classification else { return true }
        if classification.needsWeb {
            return true
        }
        return classification.intent == .webRequest
    }

    private func canonicalEnrollmentPlanIfNeeded(toolName: String,
                                                 rawPlanPrefix: String,
                                                 userText: String) -> Plan? {
        guard isEnrollmentToolAlias(toolName) else { return nil }
        guard let name = extractEnrollmentName(from: rawPlanPrefix) ?? extractEnrollmentName(from: userText) else {
            return nil
        }
        return Plan(steps: [
            .tool(name: "enroll_camera_face", args: ["name": .string(name)], say: nil)
        ])
    }

    private func isEnrollmentToolAlias(_ toolName: String) -> Bool {
        let normalized = toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
        let aliases: Set<String> = [
            "enrollfacetool",
            "enrollface",
            "enrollcameraface",
            "enrolluserface",
            "enrollfacerecognition"
        ]
        return aliases.contains(normalized)
    }

    private func extractEnrollmentName(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let regex = try? NSRegularExpression(pattern: #""name"\s*:\s*"([^"]{1,48})""#, options: .caseInsensitive) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               match.numberOfRanges >= 2,
               let nameRange = Range(match.range(at: 1), in: trimmed),
               let name = sanitizedEnrollmentName(String(trimmed[nameRange])) {
                return name
            }
        }

        return sanitizedEnrollmentName(trimmed)
    }

    private func sanitizedEnrollmentName(_ text: String) -> String? {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[.!?,]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.contains("?") else { return nil }

        var candidate = normalized
        let prefixes = ["i am ", "i'm ", "im ", "my name is ", "name is ", "this is "]
        if let prefix = prefixes.first(where: { candidate.hasPrefix($0) }) {
            candidate.removeFirst(prefix.count)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let words = candidate.split(separator: " ").map(String.init)
        guard (1...3).contains(words.count) else { return nil }
        guard words.allSatisfy({ $0.range(of: #"^[a-z][a-z'\-]{0,31}$"#, options: .regularExpression) != nil }) else {
            return nil
        }

        let disallowed: Set<String> = [
            "yes", "yeah", "yep", "yup", "no", "nope", "nah",
            "help", "weather", "time", "what", "where", "when", "why", "how",
            "remember", "recognize", "enroll"
        ]
        guard !words.contains(where: { disallowed.contains($0) }) else { return nil }

        return words.map { token in
            guard let first = token.first else { return "" }
            return String(first).uppercased() + token.dropFirst()
        }.joined(separator: " ")
    }

    private func routerValidationFailure(from error: Error) -> RouterValidationFailure? {
        if let openAIError = error as? OpenAIRouter.OpenAIError,
           case .validationFailure(let failure) = openAIError {
            return failure
        }
        if let ollamaError = error as? OllamaRouter.OllamaError,
           case .validationFailure(let failure) = ollamaError {
            return failure
        }
        return nil
    }

    private func enforceNoFalseBlindnessGuardrail(on plan: Plan, userInput: String) -> Plan {
        guard planContainsFalseBlindnessClaim(plan) else { return plan }
        guard cameraVision.isRunning else { return plan }
        guard hasRecentCameraFrame(within: cameraBlindnessGraceWindowSeconds) else { return plan }

        guard cameraVision.health.isHealthy, hasVisionToolsRegistered else {
            return Plan(steps: [
                .talk(say: "My camera feed is lagging or not updating right now - try turning the camera off/on.")
            ])
        }

        let intent = resolvedVisionIntent(
            from: currentIntentClassification?.classification ?? IntentClassification(
                intent: .unknown,
                confidence: 0.0,
                notes: "",
                autoCaptureHint: false,
                needsWeb: false
            ),
            userInput: userInput
        )
        guard case .none = intent else {
            #if DEBUG
            print("[VISION_GUARD] Replacing blind-claim response with camera tool plan")
            #endif
            return visionToolPlan(for: intent, preface: "Let me take a look.")
        }

        #if DEBUG
        print("[VISION_GUARD] Replacing blind-claim response with non-vision camera status message")
        #endif
        return Plan(steps: [
            .talk(say: "My camera feed is lagging or not updating right now - try turning the camera off/on.")
        ])
    }

    private func planContainsFalseBlindnessClaim(_ plan: Plan) -> Bool {
        let talkLines = plan.steps.compactMap { step -> String? in
            if case .talk(let say) = step { return say }
            return nil
        }
        if let topLevel = plan.say, !topLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isBlindnessClaim(topLevel) { return true }
        }
        return talkLines.contains(where: isBlindnessClaim)
    }

    private func isBlindnessClaim(_ text: String) -> Bool {
        let normalized = normalizeForComparison(text)
        let phrases = [
            "i can t see",
            "i cannot see",
            "i don t have the ability to see",
            "i do not have the ability to see",
            "i can t recognize images",
            "i cannot recognize images",
            "i m unable to see",
            "i am unable to see",
            "i can t view",
            "i cannot view",
            "i have no visual",
            "i don t have visual",
            "i lack the ability to see",
            "i m not able to see",
            "i am not able to see",
            "i can t look at",
            "i cannot look at",
            "i don t have eyes",
            "i do not have eyes",
            "i can t perceive"
        ]
        return phrases.contains(where: { normalized.contains($0) })
    }

    private func maybeRephraseRepeatedTalk(_ plan: Plan,
                                           userInput: String,
                                           history: [ChatMessage],
                                           mode: ConversationMode,
                                           turnIndex: Int,
                                           turnStartedAt: Date) async -> Plan {
        guard elapsedMs(since: turnStartedAt) < maxRephraseBudgetMs else { return plan }
        guard let original = singleTalkLine(from: plan) else { return plan }
        let repetitionCount = intentRepetitionTracker.count(for: mode.intent)

        if mode.intent == .greeting {
            if let identityGreeting = faceGreetingManager.greetingOverride(
                for: mode,
                repetitionCount: repetitionCount,
                turnIndex: turnIndex
            ) {
                currentFaceIdentityContext = faceGreetingManager.currentIdentityContext
                return Plan(steps: [.talk(say: identityGreeting)], say: plan.say)
            }
            if repetitionCount >= 4 {
                let meta = "You've asked that a few times - testing variation, or checking in?"
                return Plan(steps: [.talk(say: meta)], say: plan.say)
            }
            guard isGreetingLikeAssistantLine(original) else { return plan }
            let variant = variedGreeting(for: repetitionCount)
            return Plan(steps: [.talk(say: variant)], say: plan.say)
        }

        let previous = latestAssistantLine(from: history)
        let similarity = semanticSimilarity(original, previous)
        if similarity >= 0.86 || repetitionCount >= 5 {
            let shifted = modeShiftedLine(original, repetitionCount: repetitionCount)
            if normalizeForComparison(shifted) != normalizeForComparison(original) {
                return Plan(steps: [.talk(say: shifted)], say: plan.say)
            }
        }

        return plan
    }

    private func singleTalkLine(from plan: Plan) -> String? {
        guard plan.steps.count == 1 else { return nil }
        guard case .talk(let say) = plan.steps[0] else { return nil }
        return say
    }

    private func variedGreeting(for repetitionCount: Int) -> String {
        let options = [
            "Hey! What's up?",
            "Hi there. How's your day going?",
            "Hey hey. What are we tackling?",
            "Good to hear from you. What do you need?"
        ]
        let idx = max(0, min(options.count - 1, repetitionCount - 1))
        return options[idx]
    }

    private func isGreetingLikeAssistantLine(_ line: String) -> Bool {
        let normalized = normalizeForComparison(line)
        if normalized.isEmpty { return false }
        let greetingPhrases = [
            "hey there",
            "hi there",
            "hello",
            "what s up",
            "how s your day",
            "good to hear from you"
        ]
        return greetingPhrases.contains { normalized.contains($0) }
    }

    private func latestAssistantLine(from history: [ChatMessage]) -> String {
        history.reversed().first(where: { $0.role == .assistant })?.text ?? ""
    }

    private func semanticSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(normalizeForComparison(lhs).split(separator: " ").map(String.init))
        let b = Set(normalizeForComparison(rhs).split(separator: " ").map(String.init))
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        let overlap = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(overlap) / Double(union)
    }

    private func modeShiftedLine(_ line: String, repetitionCount: Int) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return line }
        let shifts = [
            "Quick take: ",
            "Another angle: ",
            "Short version: ",
            "Meta note: "
        ]
        let prefix = shifts[repetitionCount % shifts.count]
        if trimmed.hasPrefix(prefix) {
            return trimmed
        }
        return prefix + trimmed
    }

    private func buildPromptRuntimeContext(mode: ConversationMode,
                                           affect: AffectMetadata,
                                           tonePreferences: TonePreferenceProfile?,
                                           toneRepairCue: String?,
                                           userInput: String,
                                           history: [ChatMessage],
                                           sessionSummary: String,
                                           now: Date,
                                           faceIdentityContext: FaceIdentityContext) -> PromptRuntimeContext {
        let repetition = intentRepetitionTracker.countsByIntent(now: now)
        let activeTopic: String
        if let pendingCapabilityRequest, pendingCapabilityRequest.kind == .externalSource {
            activeTopic = "capability_gap:external_source"
        } else {
            activeTopic = "\(mode.intent.rawValue):\(mode.domain.rawValue)"
        }
        let facts = recentFacts
            .filter { $0.expiresAt > now }
            .map(\.text)
            .prefix(3)
        var compactState: [String: Any] = [
            "active_topic": activeTopic,
            "last_assistant_question": lastAssistantQuestion ?? "",
            "last_question_answered": lastAssistantQuestionAnswered,
            "affect": [
                "affect": affect.affect.rawValue,
                "intensity": affect.clampedIntensity,
                "guidance": affect.guidance
            ],
            "tone_repair_cue": toneRepairCue ?? "",
            "repetition_by_intent": repetition,
            "last_assistant_openers": Array(lastAssistantOpeners.suffix(2)),
            "recent_facts_ttl": Array(facts)
        ]
        if let name = faceIdentityContext.recognizedUserName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            compactState["recognized_user_name"] = name
        }
        if let confidence = faceIdentityContext.faceConfidence {
            compactState["face_confidence"] = Double((confidence * 100).rounded() / 100)
        }
        if faceIdentityContext.unrecognizedUserPresent {
            compactState["unrecognized_user_present"] = true
        }
        if faceIdentityContext.awaitingIdentityConfirmation {
            compactState["awaiting_identity_confirmation"] = true
        }
        let interactionStateJSON = compactJSONString(from: compactState) ?? "{}"
        return PromptRuntimeContext(
            mode: mode,
            affect: affect,
            tonePreferences: tonePreferences,
            toneRepairCue: toneRepairCue,
            sessionSummary: sessionSummary,
            interactionStateJSON: interactionStateJSON,
            identityContextLine: faceIdentityContext.identityPromptContextLine,
            responseBudget: responseLengthBudget(for: mode, userInput: userInput, history: history)
        )
    }

    private func compactJSONString(from value: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if text.count <= 620 {
            return text
        }
        return String(text.prefix(620))
    }

    private func responseLengthBudget(for mode: ConversationMode,
                                      userInput: String,
                                      history: [ChatMessage]) -> ResponseLengthBudget {
        let lower = userInput.lowercased()
        if mode.intent == .problemReport {
            return ResponseLengthBudget(
                maxOutputTokens: 560,
                chatMinTokens: 250,
                chatMaxTokens: 600,
                preferCanvasForLongResponses: true
            )
        }

        let isTechnicalDeep = mode.domain == .tech
            && (lower.contains("step by step")
                || lower.contains("architecture")
                || lower.contains("debug")
                || lower.contains("implementation")
                || userInput.count > 220
                || history.count > 14)
        if isTechnicalDeep {
            return ResponseLengthBudget(
                maxOutputTokens: 900,
                chatMinTokens: 500,
                chatMaxTokens: 1000,
                preferCanvasForLongResponses: true
            )
        }

        if mode.intent == .greeting {
            return ResponseLengthBudget(
                maxOutputTokens: 220,
                chatMinTokens: 20,
                chatMaxTokens: 120,
                preferCanvasForLongResponses: false
            )
        }

        return .default
    }

    private func enforceLengthPresentationPolicy(_ plan: Plan, mode: ConversationMode) -> Plan {
        guard let talk = singleTalkLine(from: plan) else { return plan }
        let trimmed = talk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return plan }
        guard trimmed.count > 240 else { return plan }

        if mode.intent == .problemReport || shouldUseVisualDetail(for: trimmed) {
            let spoken = spokenSummary(from: trimmed)
            return Plan(steps: [
                .talk(say: spoken),
                .tool(name: "show_text", args: ["markdown": .string(trimmed)], say: nil)
            ], say: plan.say)
        }
        return plan
    }

    private func spokenSummary(from text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let first = lines.first, first.count <= 150 {
            return first.hasSuffix(".") ? first : first + "."
        }
        let fallback = String(text.prefix(140)).trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.hasSuffix(".") ? fallback : fallback + "."
    }

    private func purgeExpiredFacts(now: Date) {
        recentFacts.removeAll { $0.expiresAt <= now }
    }

    private func updateRecentFacts(with userInput: String, mode: ConversationMode, now: Date) {
        guard mode.intent != .other else { return }
        let ttl: TimeInterval = 120
        let lower = userInput.lowercased()

        func appendFact(_ text: String) {
            if recentFacts.contains(where: { $0.text == text }) { return }
            recentFacts.append(RecentFact(text: text, expiresAt: now.addingTimeInterval(ttl)))
        }

        if mode.intent == .problemReport {
            appendFact("user reported \(mode.domain.rawValue) issue")
            if mode.domain == .health && lower.contains("tummy") {
                appendFact("asked about tummy pain")
            }
            if mode.domain == .tech && lower.contains("wifi") {
                appendFact("user has wifi connectivity issue")
            }
        }
    }

    private func updateQuestionAnswerState(with userInput: String) {
        guard let lastQuestion = lastAssistantQuestion,
              !lastQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastAssistantQuestionAnswered = false
            return
        }
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            lastAssistantQuestionAnswered = false
            return
        }
        lastAssistantQuestionAnswered = !trimmed.hasSuffix("?")
    }

    private func updateAssistantState(after result: TurnResult, mode: ConversationMode) {
        let assistantMessages = result.appendedChat.filter { $0.role == .assistant }
        guard !assistantMessages.isEmpty else { return }

        for message in assistantMessages {
            let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let firstSentence = firstSentence(of: trimmed) {
                lastAssistantOpeners.append(firstSentence)
            }
            if trimmed.hasSuffix("?") {
                lastAssistantQuestion = trimmed
            }
        }
        if lastAssistantOpeners.count > 6 {
            lastAssistantOpeners.removeFirst(lastAssistantOpeners.count - 6)
        }

        if mode.intent != .problemReport {
            lastAssistantQuestionAnswered = false
        }
    }

    private func firstSentence(of text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let range = normalized.range(of: #"[.!?]\s"#, options: .regularExpression) {
            return String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }

    private func inferredActionKind(for plan: Plan) -> String {
        if plan.steps.count == 1 {
            switch plan.steps[0] {
            case .talk:
                return "TALK"
            case .tool:
                return "TOOL"
            case .ask, .delegate:
                return "PLAN"
            }
        }
        return "PLAN"
    }

    #if DEBUG
    func debugLastPromptContext() -> PromptRuntimeContext? {
        lastPromptContext
    }

    func debugLastFinalActionKind() -> String {
        lastFinalActionKind
    }

    func debugClassify(_ input: String) -> ConversationMode {
        ConversationModeClassifier.classify(input)
    }

    func debugLastIntentClassification() -> IntentClassificationResult? {
        lastIntentClassification
    }

    func debugDetectAffect(_ input: String, history: [ChatMessage] = []) -> AffectMetadata {
        ConversationAffectClassifier.classify(input, history: history)
    }

    func debugToneProfile() -> TonePreferenceProfile {
        tonePreferenceStore.loadProfile()
    }
    #endif

    private func normalizeForComparison(_ text: String) -> String {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.joined(separator: " ")
    }

    private func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let maxLen = max(a.count, b.count)
        guard maxLen >= 8 else { return false }
        let distance = levenshteinDistance(a, b)
        let similarity = 1.0 - (Double(distance) / Double(maxLen))
        return similarity >= 0.90
    }

    private func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var previous = Array(0...b.count)
        for (i, charA) in a.enumerated() {
            var current = [i + 1]
            for (j, charB) in b.enumerated() {
                let insertCost = current[j] + 1
                let deleteCost = previous[j + 1] + 1
                let replaceCost = previous[j] + (charA == charB ? 0 : 1)
                current.append(min(insertCost, deleteCost, replaceCost))
            }
            previous = current
        }
        return previous[b.count]
    }

    private func applyCanvasPresentationPolicy(_ result: inout TurnResult) {
        // Answer shaping safety net: dense/structured TALK becomes short spoken summary + detailed canvas content.
        if result.appendedOutputs.isEmpty,
           !result.triggerFollowUpCapture {
            let assistantIndices = result.appendedChat.indices.filter { result.appendedChat[$0].role == .assistant }
            if assistantIndices.count == 1 {
                let idx = assistantIndices[0]
                let message = result.appendedChat[idx]
                if shouldUseVisualDetail(for: message.text) {
                    result.appendedOutputs.append(OutputItem(kind: .markdown, payload: message.text))
                    let confirmation = nextCanvasConfirmation()
                    result.appendedChat[idx] = ChatMessage(
                        id: message.id,
                        ts: message.ts,
                        role: .assistant,
                        text: confirmation,
                        llmProvider: message.llmProvider,
                        usedMemory: message.usedMemory,
                        usedLocalKnowledge: message.usedLocalKnowledge
                    )
                    result.spokenLines = [confirmation]
                }
            }
        }

        // Silent tools can produce canvas output without chat; add a short confirmation bubble.
        let hasAssistantChat = result.appendedChat.contains { $0.role == .assistant }
        if !result.appendedOutputs.isEmpty && !hasAssistantChat && !result.triggerFollowUpCapture {
            let confirmation = nextCanvasConfirmation()
            result.appendedChat.append(ChatMessage(role: .assistant, text: confirmation, llmProvider: result.llmProvider))
            result.spokenLines.append(confirmation)
        }
    }

    private func shouldUseVisualDetail(for text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count > 200 { return true }
        if trimmed.contains("```") { return true } // markdown block

        let lines = trimmed.components(separatedBy: .newlines)
        return lines.contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("# ") ||
                line.hasPrefix("## ") ||
                line.hasPrefix("### ") ||
                line.hasPrefix("- ") ||
                line.hasPrefix("* ") ||
                Self.isNumberedListLine(line)
        }
    }

    private static func isNumberedListLine(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: line.utf16.count)
        return numberedListRegex.firstMatch(in: line, options: [], range: range) != nil
    }

    private func nextCanvasConfirmation() -> String {
        guard !canvasConfirmations.isEmpty else { return "Done." }
        let value = canvasConfirmations[canvasConfirmationIndex % canvasConfirmations.count]
        canvasConfirmationIndex = (canvasConfirmationIndex + 1) % canvasConfirmations.count
        return value
    }

    private func rememberAssistantLines(_ messages: [ChatMessage]) {
        for message in messages where message.role == .assistant {
            recentAssistantLines.append(message.text)
        }
        if recentAssistantLines.count > 3 {
            recentAssistantLines.removeFirst(recentAssistantLines.count - 3)
        }
    }

    private func applyToolResultFeedbackLoop(_ result: inout TurnResult,
                                             originalInput: String,
                                             history: [ChatMessage],
                                             provider: LLMProvider,
                                             aiModelUsed: String?,
                                             force: Bool,
                                             allowFeedback: Bool,
                                             depth: Int,
                                             turnStartedAt: Date) async {
        guard depth < toolFeedbackLoopMaxDepth else { return }

        var loopDepth = depth
        var seenPlanFingerprints: Set<String> = []
        var pendingCoverageTokens = force ? requiredCoverageTokens(for: originalInput) : []
        var deferredTalkLine: String?
        var committedTalk = false

        while loopDepth < toolFeedbackLoopMaxDepth {
            guard elapsedMs(since: turnStartedAt) < maxToolFeedbackBudgetMs else { break }
            guard shouldRunToolFeedbackLoop(result, force: force, allowFeedback: allowFeedback) else { break }
            guard let feedbackPlan = await synthesizeToolAwarePlan(
                from: result,
                originalInput: originalInput,
                history: history,
                provider: provider,
                aiModelUsed: aiModelUsed,
                requiredCoverageTokens: pendingCoverageTokens
            ) else { break }

            let fingerprint = feedbackPlanFingerprint(feedbackPlan)
            guard seenPlanFingerprints.insert(fingerprint).inserted else { break }

            if let talk = talkOnlyLine(from: feedbackPlan) {
                if force, !pendingCoverageTokens.isEmpty {
                    let missing = missingCoverageTokens(in: talk, required: pendingCoverageTokens)
                    if !missing.isEmpty {
                        deferredTalkLine = deferredTalkLine ?? talk
                        pendingCoverageTokens = missing
                        loopDepth += 1
                        continue
                    }
                }
                upsertToolFeedbackTalkLine(talk, result: &result, provider: provider)
                committedTalk = true
                break
            }

            let hasToolStep = feedbackPlan.steps.contains { step in
                if case .tool = step { return true }
                return false
            }
            guard hasToolStep else { break }

            let exec = await toolRunner.executePlan(
                feedbackPlan,
                originalInput: originalInput,
                pendingSlotName: pendingSlot?.slotName
            )

            mergeToolFeedbackExecution(exec, into: &result, provider: provider, originalInput: originalInput)
            if result.triggerFollowUpCapture {
                break
            }
            loopDepth += 1
        }

        if force,
           !committedTalk,
           pendingCoverageTokens.isEmpty,
           let deferredTalkLine {
            upsertToolFeedbackTalkLine(deferredTalkLine, result: &result, provider: provider)
        }
    }

    private func shouldRunToolFeedbackLoop(_ result: TurnResult, force: Bool, allowFeedback: Bool) -> Bool {
        guard allowFeedback || force else { return false }
        guard !result.executedToolSteps.isEmpty else { return false }
        guard !result.triggerFollowUpCapture else { return false }
        guard !result.appendedOutputs.isEmpty else { return false }
        guard !containsToolErrorOutput(result) else { return false }

        let assistantLines = result.appendedChat
            .filter { $0.role == .assistant }
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if force { return true }
        if assistantLines.isEmpty { return true }
        return assistantLines.allSatisfy(isLikelyCanvasConfirmation)
    }

    private func shouldForceToolFeedback(for userInput: String, plan: Plan) -> Bool {
        let hasOnlyToolSteps = !plan.steps.isEmpty && plan.steps.allSatisfy { step in
            if case .tool = step { return true }
            return false
        }
        guard hasOnlyToolSteps else { return false }
        if plan.steps.count > 1 { return true }
        return isMultiClauseRequest(userInput)
    }

    private func shouldAllowToolFeedback(for plan: Plan) -> Bool {
        let allowlist: Set<String> = ["get_weather", "get_time", "find_files", "learn_website"]
        for step in plan.steps {
            guard case .tool(let name, let args, _) = step else { continue }
            if allowlist.contains(name) { return true }
            if let marker = args["needs_reasoning"]?.stringValue.lowercased(),
               marker == "true" || marker == "1" || marker == "yes" {
                return true
            }
        }
        return false
    }

    private func containsToolErrorOutput(_ result: TurnResult) -> Bool {
        result.appendedOutputs.contains { output in
            let lower = output.payload.lowercased()
            if lower.contains("\"kind\":\"error\"") { return true }
            if lower.hasPrefix("error:") { return true }
            if lower.contains("i couldn't") { return true }
            return false
        }
    }

    private func shouldNarrateToolProgress(for userInput: String, plan: Plan) -> Bool {
        let toolSteps = plan.steps.filter { step in
            if case .tool = step { return true }
            return false
        }
        guard !toolSteps.isEmpty else { return false }
        guard !plan.steps.contains(where: {
            if case .ask = $0 { return true }
            return false
        }) else {
            return false
        }
        if toolSteps.count > 1 { return true }
        return shouldForceToolFeedback(for: userInput, plan: plan)
    }

    private func isMultiClauseRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [" then ", " and ", " also ", " after ", " while ", " if ", ", then ", ";"]
        if markers.contains(where: { lower.contains($0) }) { return true }
        let questionCount = lower.filter { $0 == "?" }.count
        if questionCount > 1 { return true }
        return lower.count > 80
    }

    private func toolProgressLines(from plan: Plan) -> [String] {
        var lines: [String] = []
        var seen: Set<String> = []
        for step in plan.steps {
            if case .tool(_, _, let say) = step,
               let line = say?.trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                let normalized = normalizeForComparison(line)
                guard !normalized.isEmpty else { continue }
                if seen.insert(normalized).inserted {
                    lines.append(line)
                }
            }
        }
        return lines
    }

    private func prependAssistantProgressLines(_ lines: [String],
                                               into result: inout TurnResult,
                                               provider: LLMProvider) {
        guard !lines.isEmpty else { return }

        for line in lines.reversed() {
            let normalized = normalizeForComparison(line)
            guard !normalized.isEmpty else { continue }
            if result.appendedChat.contains(where: { $0.role == .assistant && normalizeForComparison($0.text) == normalized }) {
                continue
            }
            let progress = ChatMessage(role: .assistant, text: line, llmProvider: provider)
            result.appendedChat.insert(progress, at: 0)
            result.spokenLines.insert(line, at: 0)
        }
    }

    private func isLikelyCanvasConfirmation(_ text: String) -> Bool {
        let normalized = normalizeForComparison(text)
        guard !normalized.isEmpty else { return false }

        let canned = canvasConfirmations.map(normalizeForComparison)
        if canned.contains(normalized) { return true }

        let genericStarts = [
            "here you go",
            "done",
            "i ve put the details up here",
            "i ve laid this out on screen",
            "i ll find",
            "i ll check",
            "i ll look"
        ]
        if genericStarts.contains(where: { normalized.hasPrefix($0) }) && normalized.count <= 80 {
            return true
        }
        return false
    }

    private func synthesizeToolAwarePlan(from result: TurnResult,
                                         originalInput: String,
                                         history: [ChatMessage],
                                         provider: LLMProvider,
                                         aiModelUsed: String?,
                                         requiredCoverageTokens: [String]) async -> Plan? {
        let toolLines = result.executedToolSteps.map { step in
            let argsPreview = step.args
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            return "- \(step.name)(\(argsPreview))"
        }.joined(separator: "\n")

        let outputLines = result.appendedOutputs.enumerated().map { index, item in
            let clipped = item.payload.replacingOccurrences(of: "\n", with: " ")
            let preview = clipped.count > 460 ? String(clipped.prefix(457)) + "..." : clipped
            return "- output[\(index + 1)] kind=\(item.kind.rawValue): \(preview)"
        }.joined(separator: "\n")

        let assistantLines = result.appendedChat
            .filter { $0.role == .assistant }
            .map { "- \($0.text.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")

        let coverageGuidance: String
        if requiredCoverageTokens.isEmpty {
            coverageGuidance = "- (none)"
        } else {
            let joined = requiredCoverageTokens.joined(separator: ", ")
            coverageGuidance = """
            - This is a multi-part user request.
            - Final TALK must explicitly address these entities/topics: \(joined)
            - If current tool outputs are insufficient to address all required topics, run another concrete tool step first.
            """
        }

        let synthesisPrompt = """
        [TOOL_RESULT_FEEDBACK]
        User request: \(originalInput)
        Executed tools:
        \(toolLines.isEmpty ? "- (none)" : toolLines)
        Tool outputs:
        \(outputLines.isEmpty ? "- (none)" : outputLines)
        Current assistant lines:
        \(assistantLines.isEmpty ? "- (none)" : assistantLines)

        Decide the best next action using the tool results above.
        Coverage requirements:
        \(coverageGuidance)
        - If there is enough information, return TALK with one concise final answer.
        - If one more tool call is required, return a PLAN with concrete tool step(s).
        - For comparative or decision-style user requests, provide an explicit recommendation or judgment.
        - Do NOT repeat an identical tool call that already ran with the same args.
        - Never return CAPABILITY_GAP in this feedback pass.
        Output valid JSON only.
        """

        let plan: Plan?
        switch provider {
        case .openai:
            let openAIPlan = try? await withTimeout(toolFeedbackTimeoutSeconds(requiredCoverageTokens: requiredCoverageTokens)) {
                try await self.openAIRouter.routePlan(
                    synthesisPrompt,
                    history: history,
                    modelOverride: aiModelUsed,
                    reason: .polish
                )
            }
            if let openAIPlan {
                plan = openAIPlan
                break
            }
            if M2Settings.useOllama {
                plan = try? await withTimeout(ollamaToolFeedbackTimeoutSeconds) {
                    try await self.ollamaRouter.routePlan(synthesisPrompt, history: history)
                }
            } else {
                plan = nil
            }
        case .ollama:
            plan = try? await withTimeout(ollamaToolFeedbackTimeoutSeconds) {
                try await self.ollamaRouter.routePlan(synthesisPrompt, history: history)
            }
        case .none:
            if M2Settings.useOllama {
                plan = try? await withTimeout(ollamaToolFeedbackTimeoutSeconds) {
                    try await self.ollamaRouter.routePlan(synthesisPrompt, history: history)
                }
            } else {
                plan = nil
            }
        }

        return plan
    }

    private func toolFeedbackTimeoutSeconds(requiredCoverageTokens: [String]) -> Double {
        if !requiredCoverageTokens.isEmpty {
            return openAIToolFeedbackTimeoutSeconds
        }
        return 1.2
    }

    private func feedbackPlanFingerprint(_ plan: Plan) -> String {
        plan.steps.map { step in
            switch step {
            case .talk(let say):
                return "talk:\(normalizeForComparison(say))"
            case .ask(let slot, let prompt):
                return "ask:\(slot.lowercased()):\(normalizeForComparison(prompt))"
            case .delegate(let task, let context, let say):
                return "delegate:\(normalizeForComparison(task)):\(normalizeForComparison(context ?? "")):\(normalizeForComparison(say ?? ""))"
            case .tool(let name, let args, let say):
                let orderedArgs = args
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value.stringValue)" }
                    .joined(separator: ",")
                return "tool:\(name.lowercased()){\(orderedArgs)}:\(normalizeForComparison(say ?? ""))"
            }
        }.joined(separator: "|")
    }

    private func mergeToolFeedbackExecution(_ exec: PlanExecutionResult,
                                            into result: inout TurnResult,
                                            provider: LLMProvider,
                                            originalInput: String) {
        let stampedChat = exec.chatMessages.map { msg -> ChatMessage in
            guard msg.role == .assistant else { return msg }
            var stamped = msg
            stamped.llmProvider = provider
            stamped.originProvider = result.originProvider
            stamped.executionProvider = result.executionProvider
            stamped.originReason = result.originReason
            return stamped
        }
        result.appendedChat.append(contentsOf: stampedChat)
        result.spokenLines.append(contentsOf: exec.spokenLines)
        result.appendedOutputs.append(contentsOf: exec.outputItems)
        result.executedToolSteps.append(contentsOf: exec.executedToolSteps)
        result.toolMsTotal = (result.toolMsTotal ?? 0) + exec.toolMsTotal
        result.triggerFollowUpCapture = result.triggerFollowUpCapture || exec.triggerFollowUpCapture

        if let req = exec.pendingSlotRequest {
            pendingSlot = PendingSlot(slotName: req.slot, prompt: req.prompt, originalUserText: originalInput)
            result.triggerFollowUpCapture = true
        }
    }

    private func upsertToolFeedbackTalkLine(_ line: String,
                                            result: inout TurnResult,
                                            provider: LLMProvider) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalized = normalizeForComparison(trimmed)
        let assistantIndices = result.appendedChat.indices.filter { result.appendedChat[$0].role == .assistant }
        if assistantIndices.contains(where: { normalizeForComparison(result.appendedChat[$0].text) == normalized }) {
            return
        }

        if let lastIndex = assistantIndices.last,
           isLikelyCanvasConfirmation(result.appendedChat[lastIndex].text) {
            let prior = result.appendedChat[lastIndex].text
            result.appendedChat[lastIndex] = ChatMessage(
                id: result.appendedChat[lastIndex].id,
                ts: result.appendedChat[lastIndex].ts,
                role: .assistant,
                text: trimmed,
                llmProvider: provider,
                isEphemeral: result.appendedChat[lastIndex].isEphemeral,
                usedMemory: result.appendedChat[lastIndex].usedMemory,
                usedLocalKnowledge: result.appendedChat[lastIndex].usedLocalKnowledge
            )
            if let spokenIndex = result.spokenLines.lastIndex(of: prior) {
                result.spokenLines[spokenIndex] = trimmed
            } else {
                result.spokenLines.append(trimmed)
            }
            return
        }

        result.appendedChat.append(ChatMessage(role: .assistant, text: trimmed, llmProvider: provider))
        result.spokenLines.append(trimmed)
    }

    private func talkOnlyLine(from plan: Plan) -> String? {
        if plan.steps.count == 1, case .talk(let say) = plan.steps[0] {
            return say.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let talkLines = plan.steps.compactMap { step -> String? in
            guard case .talk(let say) = step else { return nil }
            return say.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        guard talkLines.count == 1 else { return nil }
        return talkLines[0]
    }

    private func requiredCoverageTokens(for userInput: String) -> [String] {
        let entities = capitalizedEntityTokens(in: userInput)
        if entities.count >= 2 {
            return Array(entities.prefix(4))
        }

        let lower = userInput.lowercased()
        let markers = [" then ", " and ", " also ", " after ", " while ", " if ", ", then ", ";"]
        let tail: String
        if let range = markers
            .compactMap({ marker in lower.range(of: marker) })
            .min(by: { $0.lowerBound < $1.lowerBound }) {
            tail = String(lower[range.upperBound...])
        } else {
            tail = lower
        }

        let tailTokens = coverageTokens(from: tail)
            .filter { !Self.coverageStopwords.contains($0) }
            .filter { $0.count >= 4 }

        let merged = entities + tailTokens.filter { !entities.contains($0) }
        if !merged.isEmpty {
            return Array(merged.prefix(4))
        }
        return Array(tailTokens.prefix(2))
    }

    private func missingCoverageTokens(in talk: String, required: [String]) -> [String] {
        let present = Set(coverageTokens(from: talk))
        return required.filter { !present.contains($0) }
    }

    private func coverageTokens(from text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func capitalizedEntityTokens(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = Self.coverageEntityRegex.matches(in: text, range: range)
        var output: [String] = []
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let token = text[matchRange].lowercased()
            guard !Self.coverageStopwords.contains(token) else { continue }
            if !output.contains(token) {
                output.append(token)
            }
        }
        return output
    }

    private func applyResponsePolish(_ result: inout TurnResult, plan: Plan, hasMemoryHints: Bool, turnIndex: Int) {
        guard !result.appendedChat.isEmpty else { return }

        let shouldModulateConfidence = isTalkOnlyPlan(plan)
        let assistantIndices = result.appendedChat.indices.filter { result.appendedChat[$0].role == .assistant }

        for idx in assistantIndices {
            let original = result.appendedChat[idx]
            var updatedText = ResponsePolish.stripQuickDetailedPrompt(from: original.text)

            if shouldModulateConfidence {
                updatedText = ResponsePolish.applyConfidenceModulation(to: updatedText)
            }

            if M2Settings.disableAutoClosePrompts,
               currentIntentClassification?.classification.intent != .greeting {
                updatedText = ResponsePolish.stripAutoClosePrompt(from: updatedText)
            }

            if ResponsePolish.containsMemoryAcknowledgement(updatedText) {
                let onCooldown = isMemoryAckOnCooldown(turnIndex)
                if !hasMemoryHints || onCooldown {
                    updatedText = ResponsePolish.stripLeadingMemoryAcknowledgement(from: updatedText)
                } else {
                    lastMemoryAckTurn = turnIndex
                }
            }

            if updatedText != original.text {
                result.appendedChat[idx] = ChatMessage(
                    id: original.id,
                    ts: original.ts,
                    role: original.role,
                    text: updatedText,
                    llmProvider: original.llmProvider,
                    isEphemeral: original.isEphemeral,
                    usedMemory: original.usedMemory,
                    usedLocalKnowledge: original.usedLocalKnowledge
                )
                if let spokenIdx = result.spokenLines.firstIndex(of: original.text) {
                    result.spokenLines[spokenIdx] = updatedText
                }
            }
        }
    }

    private func applyToneRepairResponsePolicy(_ result: inout TurnResult, cue: String?) {
        guard let cue = cue?.trimmingCharacters(in: .whitespacesAndNewlines), !cue.isEmpty else { return }
        guard let idx = result.appendedChat.firstIndex(where: { $0.role == .assistant }) else { return }

        let original = result.appendedChat[idx]
        let originalTrimmed = original.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalTrimmed.isEmpty else { return }

        let lower = originalTrimmed.lowercased()
        let acknowledgementMarkers = [
            "understood",
            "got it",
            "thanks for the feedback",
            "i'll keep it",
            "i will keep it"
        ]
        if acknowledgementMarkers.contains(where: { lower.contains($0) }) {
            return
        }

        let replacement: String
        let transientFailureMarkers = [
            "had trouble generating a response",
            "had trouble processing that",
            "took too long",
            "please try again"
        ]
        if transientFailureMarkers.contains(where: { lower.contains($0) }) {
            replacement = cue
        } else {
            replacement = "\(cue) \(originalTrimmed)"
        }

        result.appendedChat[idx] = ChatMessage(
            id: original.id,
            ts: original.ts,
            role: original.role,
            text: replacement,
            llmProvider: original.llmProvider,
            isEphemeral: original.isEphemeral,
            usedMemory: original.usedMemory,
            usedLocalKnowledge: original.usedLocalKnowledge
        )

        if let spokenIdx = result.spokenLines.firstIndex(of: original.text) {
            result.spokenLines[spokenIdx] = replacement
        } else if result.spokenLines.isEmpty {
            result.spokenLines.append(replacement)
        }
    }

    private func applyAffectMirroringResponsePolicy(_ result: inout TurnResult, affect: AffectMetadata) {
        guard affect.affect != .neutral else { return }
        guard let idx = result.appendedChat.firstIndex(where: { $0.role == .assistant }) else { return }

        let original = result.appendedChat[idx]
        let originalTrimmed = original.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalTrimmed.isEmpty else { return }

        let opening = firstSentence(of: originalTrimmed)?.lowercased() ?? originalTrimmed.lowercased()
        if hasAffectAcknowledgement(opening: opening, affect: affect.affect) {
            return
        }

        let acknowledgement = affectAcknowledgement(for: affect.affect)
        let replacement = "\(acknowledgement) \(originalTrimmed)"

        result.appendedChat[idx] = ChatMessage(
            id: original.id,
            ts: original.ts,
            role: original.role,
            text: replacement,
            llmProvider: original.llmProvider,
            isEphemeral: original.isEphemeral,
            usedMemory: original.usedMemory,
            usedLocalKnowledge: original.usedLocalKnowledge
        )

        if let spokenIdx = result.spokenLines.firstIndex(of: original.text) {
            result.spokenLines[spokenIdx] = replacement
        } else if result.spokenLines.isEmpty {
            result.spokenLines.append(replacement)
        }
    }

    private func affectAcknowledgement(for affect: ConversationAffect) -> String {
        switch affect {
        case .neutral:
            return ""
        case .frustrated:
            return "That sounds frustrating."
        case .anxious:
            return "I get why that feels worrying."
        case .sad:
            return "I'm sorry, that sounds heavy."
        case .angry:
            return "I can tell this is really intense."
        case .excited:
            return "That's awesome!"
        }
    }

    private func hasAffectAcknowledgement(opening: String, affect: ConversationAffect) -> Bool {
        let markers: [String]
        switch affect {
        case .neutral:
            return true
        case .frustrated:
            markers = ["frustrat", "annoy", "i get why", "i can see why", "sorry you're", "sorry you’re"]
        case .anxious:
            markers = ["worr", "nervous", "unsettling", "normal to feel", "understandable"]
        case .sad:
            markers = ["sorry", "tough", "heavy", "i hear you"]
        case .angry:
            markers = ["intense", "let's slow", "lets slow", "frustrat", "sorry you're", "sorry you’re"]
        case .excited:
            markers = ["awesome", "great", "nice", "excited", "love that energy"]
        }
        return markers.contains { opening.contains($0) }
    }

    private func isMemoryAckOnCooldown(_ turnIndex: Int) -> Bool {
        guard let last = lastMemoryAckTurn else { return false }
        return (turnIndex - last) <= memoryAckCooldownTurns
    }

    private func isTalkOnlyPlan(_ plan: Plan) -> Bool {
        guard plan.steps.count == 1 else { return false }
        if case .talk = plan.steps[0] { return true }
        return false
    }

    private func applyFollowUpQuestionPolicy(_ result: inout TurnResult, turnIndex: Int) {
        guard !M2Settings.disableAutoClosePrompts else { return }
        guard !result.triggerFollowUpCapture else { return } // pending slots/asks are separate flows
        guard !isFollowUpQuestionOnCooldown(turnIndex) else { return }
        guard currentIntentClassification?.classification.intent == .greeting else { return }

        guard let idx = result.appendedChat.lastIndex(where: { $0.role == .assistant }) else { return }
        let original = result.appendedChat[idx]
        let trimmed = original.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return }
        guard !trimmed.contains("?") else { return } // don't stack questions
        guard let lastChar = trimmed.last, ".!".contains(lastChar) else { return }
        guard trimmed.count >= 30 else { return } // keep short replies snappy
        guard trimmed.count <= 240 else { return } // long answers should not add follow-up chatter

        let followUp = nextFollowUpQuestion()
        let combined = combineAnswer(trimmed, withFollowUp: followUp)
        guard isSingleTrailingQuestion(combined) else { return }

        result.appendedChat[idx] = ChatMessage(
            id: original.id,
            ts: original.ts,
            role: original.role,
            text: combined,
            llmProvider: original.llmProvider,
            isEphemeral: original.isEphemeral,
            usedMemory: original.usedMemory,
            usedLocalKnowledge: original.usedLocalKnowledge
        )

        if let spokenIdx = result.spokenLines.firstIndex(of: original.text) {
            result.spokenLines[spokenIdx] = combined
        } else {
            result.spokenLines.append(combined)
        }

        result.triggerQuestionAutoListen = true
        lastFollowUpTurn = turnIndex
    }

    private func combineAnswer(_ answer: String, withFollowUp followUp: String) -> String {
        let needsSpacer = !(answer.hasSuffix(" ") || answer.hasSuffix("\n"))
        return needsSpacer ? "\(answer) \(followUp)" : "\(answer)\(followUp)"
    }

    private func nextFollowUpQuestion() -> String {
        greetingFollowUpQuestion
    }

    private func isFollowUpQuestionOnCooldown(_ turnIndex: Int) -> Bool {
        guard let last = lastFollowUpTurn else { return false }
        return (turnIndex - last) < followUpCooldownTurns
    }

    private func isSingleTrailingQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?") else { return false }
        return trimmed.filter { $0 == "?" }.count == 1
    }

    private func applyKnowledgeAttribution(_ result: inout TurnResult,
                                           userInput: String,
                                           provider: LLMProvider,
                                           aiModelUsed: String?,
                                           localKnowledgeContext: LocalKnowledgeContext) {
        guard provider != .none else {
            result.knowledgeAttribution = KnowledgeAttribution(
                localKnowledgePercent: 0,
                openAIFillPercent: 0,
                matchedLocalItems: 0,
                consideredLocalItems: 0,
                provider: provider,
                aiModelUsed: aiModelUsed,
                evidence: []
            )
            return
        }

        guard let assistantText = result.appendedChat.last(where: { $0.role == .assistant })?.text else {
            return
        }

        let attribution = KnowledgeAttributionScorer.score(
            userInput: userInput,
            assistantText: assistantText,
            provider: provider,
            aiModelUsed: aiModelUsed,
            localSnippets: localKnowledgeContext.items
        )
        result.knowledgeAttribution = attribution

        guard attribution.usedLocalKnowledge else { return }
        for idx in result.appendedChat.indices where result.appendedChat[idx].role == .assistant {
            result.appendedChat[idx].usedLocalKnowledge = true
        }
    }

    private func buildLocalKnowledgeContext(for input: String) -> LocalKnowledgeContext {
        let memoryRows = fastMemoryHints(for: input, maxItems: 4, maxChars: 500)
        let memoryItems = memoryRows.map { row in
            KnowledgeSourceSnippet(
                kind: .memory,
                id: row.shortID,
                label: "Memory (\(row.type.rawValue))",
                text: row.content,
                url: nil
            )
        }
        return LocalKnowledgeContext(items: dedupeKnowledgeSnippets(memoryItems))
    }

    private func fastMemoryHints(for query: String, maxItems: Int, maxChars: Int) -> [MemoryRow] {
        MemoryStore.shared.memoryContext(
            query: query,
            maxItems: max(1, maxItems),
            maxChars: max(120, maxChars)
        )
    }

    private func relevantWebsiteKnowledgeSnippets(query: String, maxItems: Int) -> [KnowledgeSourceSnippet] {
        let records = WebsiteLearningStore.shared.allRecords()
        guard !records.isEmpty else { return [] }
        let ranked = LocalKnowledgeRetriever.rank(
            query: query,
            items: records,
            text: { record in
                "\(record.title) \(record.summary) \(record.highlights.joined(separator: " ")) \(record.host)"
            },
            recencyDate: { $0.updatedAt },
            extraBoost: { record in
                min(0.08, Double(record.highlights.count) * 0.02)
            },
            limit: max(1, maxItems * 4),
            minScore: 0.08
        )

        var selected: [KnowledgeSourceSnippet] = []
        for entry in ranked {
            let record = entry.item
            guard selected.count < max(1, maxItems) else { break }
            selected.append(
                KnowledgeSourceSnippet(
                    kind: .website,
                    id: String(record.id.uuidString.prefix(8)).lowercased(),
                    label: record.title,
                    text: record.summary,
                    url: record.url
                )
            )
        }

        return selected
    }

    private func relevantSelfLearningSnippets(query: String, maxItems: Int, maxChars: Int) -> [KnowledgeSourceSnippet] {
        let lessons = SelfLearningStore.shared.allLessons()
        guard !lessons.isEmpty else { return [] }
        let ranked = LocalKnowledgeRetriever.rank(
            query: query,
            items: lessons,
            text: { "[\($0.category.rawValue)] \($0.text)" },
            recencyDate: { $0.lastUpdatedAt },
            extraBoost: { lesson in
                let confidence = lesson.confidence * 0.20
                let observedBoost = min(0.14, log2(Double(max(1, lesson.observedCount)) + 1.0) * 0.05)
                let appliedBoost = min(0.10, log2(Double(max(1, lesson.appliedCount)) + 1.0) * 0.04)
                return confidence + observedBoost + appliedBoost
            },
            limit: max(1, maxItems * 4),
            minScore: 0.08
        )

        var items: [KnowledgeSourceSnippet] = []
        var usedChars = 0
        let cappedItems = max(1, maxItems)

        for entry in ranked {
            let lesson = entry.item
            guard items.count < cappedItems else { break }
            let line = String(lesson.text.prefix(220)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let nextChars = usedChars + line.count
            if !items.isEmpty && nextChars > maxChars { break }
            if items.isEmpty && line.count > maxChars { continue }
            items.append(
                KnowledgeSourceSnippet(
                    kind: .selfLearning,
                    id: String(lesson.id.uuidString.prefix(8)).lowercased(),
                    label: "Lesson (\(lesson.category.rawValue))",
                    text: line,
                    url: nil
                )
            )
            usedChars = nextChars
        }

        return items
    }

    private func dedupeKnowledgeSnippets(_ snippets: [KnowledgeSourceSnippet]) -> [KnowledgeSourceSnippet] {
        var seen: Set<String> = []
        var output: [KnowledgeSourceSnippet] = []
        for snippet in snippets {
            let trimmed = snippet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = "\(snippet.kind.rawValue)|\(snippet.id ?? "")|\(snippet.url ?? "")|\(trimmed.lowercased())"
            if seen.contains(key) { continue }
            seen.insert(key)
            output.append(
                KnowledgeSourceSnippet(
                    kind: snippet.kind,
                    id: snippet.id,
                    label: snippet.label,
                    text: trimmed,
                    url: snippet.url
                )
            )
        }
        return output
    }

    private func originProvider(for provider: LLMProvider) -> MessageOriginProvider {
        MessageOriginProvider.from(llmProvider: provider)
    }

    private func executionProvider(for provider: LLMProvider, hasToolExecution: Bool) -> MessageOriginProvider {
        if hasToolExecution { return .local }
        return originProvider(for: provider)
    }

    private func applyRoutingAttribution(_ result: inout TurnResult,
                                         planProvider: LLMProvider? = nil,
                                         planRouterMs: Int? = nil) {
        let resolvedIntent = currentIntentClassification ?? lastIntentClassification
        result.intentProviderSelected = resolvedIntent?.provider ?? .rule
        result.intentRouterMsLocal = resolvedIntent?.intentRouterMsLocal
        result.intentRouterMsOpenAI = resolvedIntent?.intentRouterMsOpenAI
        result.planProviderSelected = planProvider ?? result.llmProvider
        if let planRouterMs {
            result.planRouterMs = planRouterMs
        } else if result.planRouterMs == nil {
            result.planRouterMs = result.routerMs
        }
    }

    private func applyOriginMetadata(_ result: inout TurnResult) {
        applyRoutingAttribution(&result)
        for idx in result.appendedChat.indices where result.appendedChat[idx].role == .assistant {
            result.appendedChat[idx].llmProvider = result.llmProvider
            result.appendedChat[idx].originProvider = result.originProvider
            result.appendedChat[idx].executionProvider = result.executionProvider
            if result.appendedChat[idx].originReason == nil {
                result.appendedChat[idx].originReason = result.originReason
            }
        }
    }

    private func routerLog(provider: String, reason: String, ms: Int, ok: Bool) {
        #if DEBUG
        print("[ROUTER] provider=\(provider) reason=\(reason) ms=\(ms) ok=\(ok)")
        #endif
    }

    private func classifyOllamaFailure(_ error: Error) -> (kind: String, reasonCount: Int, detail: String) {
        if error is RouterTimeout {
            return ("timeout", 0, "exceeded local-first deadline")
        }
        if let e = error as? OllamaRouter.OllamaError {
            switch e {
            case .jsonParseFailed(let raw):
                return ("json_parse", 0, String(raw.prefix(120)))
            case .schemaMismatch(_, let reasons):
                return ("schema", reasons.count, reasons.joined(separator: "; "))
            case .validationFailure(let f):
                return ("unknown_tool", 0, f.toolName)
            case .unreachable(let msg):
                return ("transport", 0, String(msg.prefix(120)))
            case .invalidResponse:
                return ("transport", 0, "invalid HTTP response")
            case .wireDeadlineExceeded(let wireMs, let deadlineMs):
                return ("timeout", 0, "wire deadline exceeded \(wireMs)ms > \(deadlineMs)ms")
            }
        }
        return ("unknown", 0, String(describing: error).prefix(120).description)
    }

    private func isTimeoutLikeOpenAIError(_ error: Error) -> Bool {
        if error is RouterTimeout {
            return true
        }
        if let openAIError = error as? OpenAIRouter.OpenAIError {
            switch openAIError {
            case .requestFailed(let message):
                let lower = message.lowercased()
                return lower.contains("timed out")
                    || lower.contains("timeout")
                    || lower.contains("-1001")
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }
        let lower = error.localizedDescription.lowercased()
        return lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("-1001")
    }

    nonisolated private static func hasNativeTool(for category: CapabilityRequestCategory) -> Bool {
        let candidateNames: [String]
        switch category {
        case .weather:
            candidateNames = ["get_weather", "weather"]
        case .news:
            candidateNames = ["get_news", "news"]
        case .sportsScores:
            candidateNames = ["get_scores", "sports_scores"]
        case .time:
            candidateNames = ["get_time", "time"]
        case .otherWeb:
            candidateNames = []
        }
        guard !candidateNames.isEmpty else { return false }
        for candidate in candidateNames {
            guard let canonical = ToolRegistry.shared.normalizeToolName(candidate) else { continue }
            if ToolRegistry.shared.isAllowedTool(canonical) {
                return true
            }
        }
        return false
    }

    private func logAffectClassification(raw: AffectMetadata,
                                         effective: AffectMetadata,
                                         featureEnabled: Bool,
                                         userToneEnabled: Bool) {
        #if DEBUG
        print(
            "[AFFECT] raw=\(raw.affect.rawValue):\(raw.clampedIntensity) " +
            "effective=\(effective.affect.rawValue):\(effective.clampedIntensity) " +
            "feature=\(featureEnabled) user_tone=\(userToneEnabled)"
        )
        #endif
    }

    private func logToneLearning(outcome: TonePreferenceLearningOutcome, profile: TonePreferenceProfile) {
        #if DEBUG
        print("[TONE_LEARN] reason=\(outcome.source).\(outcome.reason) delta=\(outcome.deltaSummary)")
        print(
            "[TONE_PROFILE] directness=\(formatToneValue(profile.directness)) " +
            "warmth=\(formatToneValue(profile.warmth)) humor=\(formatToneValue(profile.humor)) " +
            "curiosity=\(formatToneValue(profile.curiosity)) reassurance=\(formatToneValue(profile.reassurance)) " +
            "formality=\(formatToneValue(profile.formality)) hedging=\(formatToneValue(profile.hedging))"
        )
        #endif
    }

    private func formatToneValue(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private func normalizedSlotSet(from raw: String) -> Set<String> {
        let values = raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return Set(values)
    }

    private func selectOpenAIModel(for input: String, reason: LLMCallReason) -> String {
        let general = OpenAISettings.generalModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackGeneral = general.isEmpty ? "gpt-4o-mini" : general
        let escalation = OpenAISettings.escalationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackEscalation = escalation.isEmpty ? "gpt-4o" : escalation
        guard shouldUseEscalationModel(for: input, reason: reason) else {
            return fallbackGeneral
        }
        return fallbackEscalation
    }

    private func shouldUseEscalationModel(for input: String, reason: LLMCallReason) -> Bool {
        switch reason {
        case .alarmTriggered, .alarmRepeat, .snoozeExpired:
            return false
        default:
            break
        }

        if isMultiClauseRequest(input) { return true }
        if input.count > 120 { return true }

        let lower = input.lowercased()
        let complexityMarkers = [
            "step by step",
            "compare",
            "analyze",
            "analyse",
            "tradeoff",
            "pros and cons",
            "plan",
            "design",
            "architecture",
            "debug",
            "investigate",
            "why"
        ]
        if complexityMarkers.contains(where: { lower.contains($0) }) { return true }

        let sentenceBreaks = input.filter { $0 == "." || $0 == "?" || $0 == "!" }.count
        if sentenceBreaks >= 2 && input.count > 70 { return true }
        return false
    }

    private func openAIRouteTimeoutSecondsFor(input: String, reason: LLMCallReason) -> Double {
        guard reason == .userChat else { return openAIRouteTimeoutSeconds }
        if isMultiClauseRequest(input) {
            return 6.8
        }
        if input.count > 120 {
            return 6.2
        }
        return openAIRouteTimeoutSeconds
    }

    private func friendlyFallbackPlan(_ error: Error? = nil) -> Plan {
        let msg: String
        if let error, isTimeoutLikeOpenAIError(error) {
            msg = "Sorry — that took too long. Please try again."
        } else if let e = error as? OpenAIRouter.OpenAIError {
            switch e {
            case .notConfigured:
                msg = missingOpenAIKeyMessage()
            case .invalidAPIKey:
                msg = rejectedOpenAIKeyMessage(statusCode: OpenAISettings.authFailureStatusCode)
            case .badResponse(let code):
                if code == 401 || code == 403 {
                    OpenAISettings.markAPIKeyRejected(statusCode: code)
                    msg = rejectedOpenAIKeyMessage(statusCode: code)
                } else {
                    msg = "OpenAI returned an error (HTTP \(code)). Please try again."
                }
            case .validationFailure(let failure):
                switch failure.kind {
                case .unknownTool:
                    msg = "I can't pull that data yet. Can you share the source URL?"
                }
            case .requestFailed(let detail):
                if detail.lowercased().contains("timed out") || detail.lowercased().contains("-1001") {
                    msg = "Sorry — OpenAI timed out twice, so I used a local fallback. Please try again."
                } else {
                    msg = "I couldn't reach OpenAI. Check your connection and try again."
                }
            }
        } else {
            msg = "Sorry — I had trouble generating a response. Please try again."
        }
        #if DEBUG
        if let error = error {
            print("[ROUTER] fallback reason: \(error.localizedDescription)")
        }
        #endif
        return Plan(steps: [.talk(say: msg)])
    }

    private func missingOpenAIKeyMessage() -> String {
        "OpenAI API key isn't set. Open SamOS Settings -> OpenAI and paste your key."
    }

    private func rejectedOpenAIKeyMessage(statusCode: Int?) -> String {
        let statusText: String
        if let statusCode, statusCode == 401 || statusCode == 403 {
            statusText = "\(statusCode)"
        } else {
            statusText = "401/403"
        }
        return "OpenAI rejected the request (\(statusText)). Please check your API key in Settings -> OpenAI (it may be missing, invalid, expired, or revoked)."
    }

    // fallbackResult() removed — dead code; all error paths use friendlyFallbackPlan().
}

extension TurnOrchestrator: TurnOrchestrating {}

struct TTSPacing {
    let preSpeakDelayMs: Int
    let ttsText: String

    var preSpeakDelayNs: UInt64 {
        UInt64(max(0, preSpeakDelayMs)) * 1_000_000
    }
}

enum ResponsePolish {

    private static let uncertaintyMarkers: [String] = [
        "i think", "maybe", "not sure", "likely", "might", "could be", "approximately",
        "can't confirm", "cannot confirm", "i don't have access", "unknown"
    ]

    private static let strongHedges: [String] = [
        "i'm not 100% sure", "i am not 100% sure", "not sure", "maybe", "i think"
    ]

    private static let memoryAckMarkers: [String] = [
        "i remember you mentioned", "i remember you said", "if i'm remembering right",
        "if i’m remembering right", "i recall you mentioned", "as you mentioned earlier",
        "you mentioned earlier"
    ]

    static func applyConfidenceModulation(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard isUncertain(trimmed) else { return text }
        guard !isStronglyHedged(trimmed) else { return text }
        guard !trimmed.lowercased().contains("double-check") else { return text }
        return "\(trimmed) (If you want, I can double-check.)"
    }

    static func ttsPacing(for text: String, mode: SpeechMode) -> TTSPacing {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, mode == .answer else {
            return TTSPacing(preSpeakDelayMs: 0, ttsText: trimmed)
        }

        let longResponse = trimmed.count > 120 || sentenceCount(in: trimmed) >= 3
        guard longResponse else {
            return TTSPacing(preSpeakDelayMs: 0, ttsText: trimmed)
        }

        return TTSPacing(preSpeakDelayMs: 250, ttsText: addSentencePauses(to: trimmed))
    }

    static func containsMemoryAcknowledgement(_ text: String) -> Bool {
        let firstSentence = leadingSentence(text).lowercased()
        return memoryAckMarkers.contains { firstSentence.contains($0) }
    }

    static func stripLeadingMemoryAcknowledgement(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsMemoryAcknowledgement(trimmed) else { return trimmed }

        if let punctuationRange = trimmed.range(of: #"[.!?]\s+"#, options: .regularExpression) {
            let remainder = String(trimmed[punctuationRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? trimmed : remainder
        }
        return trimmed
    }

    static func stripQuickDetailedPrompt(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let patterns = [
            #"\s*want\s+the\s+quick\s+version\s+or\s+more\s+detail\??\s*$"#,
            #"\s*want\s+me\s+to\s+keep\s+it\s+brief\s+or\s+expand\??\s*$"#,
            #"\s*quick\s+version\s+or\s+detailed?\s+version\??\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            let stripped = regex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped != trimmed {
                return stripped
            }
        }
        return trimmed
    }

    static func stripAutoClosePrompt(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let patterns = [
            #"\s*(anything\s+else\s+i\s+can\s+help\s+with\??)\s*$"#,
            #"\s*(anything\s+else\s+you(?:'d|\s+would)?\s+like\s+to\s+know\??)\s*$"#,
            #"\s*(let\s+me\s+know\s+if\s+you\s+need\s+anything\s+else\.?)\s*$"#,
            #"\s*(let\s+me\s+know\s+if\s+you(?:'d|\s+would)?\s+like\s+to\s+know\s+more\.?)\s*$"#,
            #"\s*(how\s+else\s+can\s+i\s+help\??)\s*$"#,
            #"\s*(need\s+anything\s+else\s+on\s+this\??)\s*$"#,
            #"\s*(want\s+me\s+to\s+continue\s+on\s+this\??)\s*$"#,
            #"\s*(should\s+i\s+add\s+anything\s+else\??)\s*$"#,
            #"\s*(what\s+else\s+can\s+i\s+help\s+with\??)\s*$"#,
            #"\s*((?:want|would\s+you\s+like)\s+to\s+know\s+more\??)\s*$"#
        ]

        var output = trimmed
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if output.isEmpty {
            return "Done."
        }
        return output
    }

    private static func isUncertain(_ text: String) -> Bool {
        let lower = text.lowercased()
        return uncertaintyMarkers.contains { lower.contains($0) }
    }

    private static func isStronglyHedged(_ text: String) -> Bool {
        let lower = text.lowercased()
        return strongHedges.contains { lower.contains($0) }
    }

    private static func leadingSentence(_ text: String) -> String {
        if let punctuationRange = text.range(of: #"[.!?]\s+"#, options: .regularExpression) {
            return String(text[..<punctuationRange.lowerBound])
        }
        return text
    }

    private static func sentenceCount(in text: String) -> Int {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.count
    }

    private static func addSentencePauses(to text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"([.!?])\s+"#, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1\n")
    }
}
