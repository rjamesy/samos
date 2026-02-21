import Foundation

final class IntentRepetitionTracker {
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

final class SessionSummaryService {
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

enum ConversationModeClassifier {
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

enum ConversationAffectClassifier {
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
