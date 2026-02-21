import Foundation

struct LocalKnowledgeContext {
    let items: [KnowledgeSourceSnippet]
    let memoryPromptBlock: String
    let memoryShouldClarify: Bool
    let memoryClarificationPrompt: String?

    var hasMemoryHints: Bool {
        items.contains { $0.kind == .memory } || !memoryPromptBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    let relevantMemoriesBlock: String
    let responseBudget: ResponseLengthBudget
    let personalityBlock: String

    init(mode: ConversationMode,
         affect: AffectMetadata,
         tonePreferences: TonePreferenceProfile?,
         toneRepairCue: String?,
         sessionSummary: String,
         interactionStateJSON: String,
         identityContextLine: String? = nil,
         relevantMemoriesBlock: String = "",
         responseBudget: ResponseLengthBudget,
         personalityBlock: String = "") {
        self.mode = mode
        self.affect = affect
        self.tonePreferences = tonePreferences
        self.toneRepairCue = toneRepairCue
        self.sessionSummary = sessionSummary
        self.interactionStateJSON = interactionStateJSON
        self.identityContextLine = identityContextLine
        self.relevantMemoriesBlock = relevantMemoriesBlock
        self.responseBudget = responseBudget
        self.personalityBlock = personalityBlock
    }
}

struct RecentFact {
    let text: String
    let expiresAt: Date
}
