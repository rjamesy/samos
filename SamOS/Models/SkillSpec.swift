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

        private enum CodingKeys: String, CodingKey {
            case name, type, required, prompt
        }

        init(name: String, type: SlotType, required: Bool, prompt: String?) {
            self.name = name
            self.type = type
            self.required = required
            self.prompt = prompt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decode(SlotType.self, forKey: .type)
            // OpenAI often omits "required" for slot objects. Default to true.
            required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
            prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        }
    }

    enum SlotType: String, Codable {
        case date
        case string
        case number
    }

    struct StepDef: Codable {
        let action: String      // e.g. "schedule_task", "talk"
        let args: [String: String]  // supports {{slotName}} interpolation

        private enum CodingKeys: String, CodingKey {
            case action, args
        }

        init(action: String, args: [String: String]) {
            self.action = action
            self.args = args
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)

            if let stringArgs = try? container.decode([String: String].self, forKey: .args) {
                args = stringArgs
            } else {
                let rawArgs = try container.decode([String: StepArgValue].self, forKey: .args)
                args = rawArgs.mapValues(\.stringValue)
            }
        }
    }

    struct OnTriggerDef: Codable {
        let say: String?
        let sound: String?      // macOS system sound name, e.g. "Funk"
        let showCard: Bool?
    }
}

private enum StepArgValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            self = .string("")
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return ""
        }
    }
}
