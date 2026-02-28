import Foundation

/// A skill definition that can be matched, stored, and executed.
struct SkillSpec: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let triggerPhrases: [String]
    let parameters: [SkillParameter]?
    let steps: [SkillStep]
    var approvedByGPT: Bool
    var approvedByUser: Bool
    var createdAt: Date
    var usageCount: Int
    var lastUsedAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String,
        triggerPhrases: [String],
        parameters: [SkillParameter]? = nil,
        steps: [SkillStep],
        approvedByGPT: Bool = false,
        approvedByUser: Bool = false,
        createdAt: Date = Date(),
        usageCount: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.triggerPhrases = triggerPhrases
        self.parameters = parameters
        self.steps = steps
        self.approvedByGPT = approvedByGPT
        self.approvedByUser = approvedByUser
        self.createdAt = createdAt
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
    }
}

struct SkillParameter: Codable, Sendable {
    let name: String
    let type: String
    let required: Bool
    let defaultValue: String?

    enum CodingKeys: String, CodingKey {
        case name, type, required
        case defaultValue = "default"
    }
}

/// A single step within a skill execution.
struct SkillStep: Codable, Sendable {
    let step: String
    let name: String?
    let args: [String: String]?
    let say: String?
    let slot: String?
    let prompt: String?
    let task: String?
    let context: String?
}

/// Job tracking for in-progress skill builds.
struct SkillForgeJob: Identifiable, Sendable {
    let id: String
    let goal: String
    var status: ForgeStatus
    var skillId: String?
    var errorMessage: String?
    let createdAt: Date
    var updatedAt: Date

    enum ForgeStatus: String, Sendable {
        case queued, planning, building, validating, simulating
        case awaitingApproval = "awaiting_approval"
        case installed, failed
    }

    init(
        id: String = UUID().uuidString,
        goal: String,
        status: ForgeStatus = .queued,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.goal = goal
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}
