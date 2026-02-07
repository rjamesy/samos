import Foundation

// MARK: - Skill Specification

/// Codable definition of a learned skill. Stored as JSON documents in the Skills directory.
struct SkillSpec: Codable, Identifiable {
    let id: String              // e.g. "alarm_v1"
    let name: String            // e.g. "Alarm"
    let version: Int
    let triggerPhrases: [String]
    let slots: [SlotDef]
    let steps: [StepDef]
    let onTrigger: OnTriggerDef?

    var status: String?       // "active", "inactive", etc. nil = legacy/unreviewed
    var approvedAt: Date?     // When user approved this skill. nil = never approved
    var disabledAt: Date?     // When disabled. nil = not disabled

    struct SlotDef: Codable {
        let name: String
        let type: SlotType
        let required: Bool
        let prompt: String?
    }

    enum SlotType: String, Codable {
        case date
        case string
        case number
    }

    struct StepDef: Codable {
        let action: String      // e.g. "schedule_task", "talk"
        let args: [String: String]  // supports {{slotName}} interpolation
    }

    struct OnTriggerDef: Codable {
        let say: String?
        let sound: String?      // macOS system sound name, e.g. "Funk"
        let showCard: Bool?
    }
}
