import Foundation

// MARK: - CodableValue

/// Decodes arbitrary JSON values from LLM output and coerces to String.
/// Reusable for Plan args where LLM may return numbers, bools, etc.
enum CodableValue: Codable, Equatable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if container.decodeNil() { self = .null }
        else { self = .string("") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        }
    }

    var description: String { stringValue }
}

// MARK: - PlanStep

/// A single step in a multi-step plan returned by the LLM.
enum PlanStep: Decodable, Equatable {
    case talk(say: String)
    case tool(name: String, args: [String: CodableValue], say: String?)
    case ask(slot: String, prompt: String)
    case delegate(task: String, context: String?, say: String?)

    private enum CodingKeys: String, CodingKey {
        case step, say, name, args, slot, prompt, task, context
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stepType = try container.decode(String.self, forKey: .step).lowercased()

        switch stepType {
        case "talk":
            let say = try container.decode(String.self, forKey: .say)
            self = .talk(say: say)
        case "tool":
            let name = try container.decode(String.self, forKey: .name)
            let args = try container.decodeIfPresent([String: CodableValue].self, forKey: .args) ?? [:]
            let say = try container.decodeIfPresent(String.self, forKey: .say)
            self = .tool(name: name, args: args, say: say)
        case "ask":
            let slot = try container.decode(String.self, forKey: .slot)
            let prompt = try container.decode(String.self, forKey: .prompt)
            self = .ask(slot: slot, prompt: prompt)
        case "delegate":
            let task = try container.decode(String.self, forKey: .task)
            let context = try container.decodeIfPresent(String.self, forKey: .context)
            let say = try container.decodeIfPresent(String.self, forKey: .say)
            self = .delegate(task: task, context: context, say: say)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .step, in: container,
                debugDescription: "Unknown step type: \(stepType)"
            )
        }
    }

    /// Bridges CodableValue args to [String: String] for ToolsRuntime compatibility.
    var toolArgsAsStrings: [String: String] {
        guard case .tool(_, let args, _) = self else { return [:] }
        return args.mapValues { $0.stringValue }
    }
}

// MARK: - Plan

/// A multi-step plan returned by the LLM. Preferred format for tool usage.
struct Plan: Decodable, Equatable {
    let steps: [PlanStep]
    let say: String?

    private enum CodingKeys: String, CodingKey {
        case action, steps, say
    }

    init(steps: [PlanStep], say: String? = nil) {
        self.steps = steps
        self.say = say
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.steps = try container.decode([PlanStep].self, forKey: .steps)
        self.say = try container.decodeIfPresent(String.self, forKey: .say)
    }

    /// Wraps a legacy Action into a synthetic Plan for backward compatibility.
    static func fromAction(_ action: Action) -> Plan {
        switch action {
        case .talk(let talk):
            return Plan(steps: [.talk(say: talk.say)])
        case .tool(let toolAction):
            let args = toolAction.args.mapValues { CodableValue.string($0) }
            return Plan(steps: [.tool(name: toolAction.name, args: args, say: toolAction.say)])
        case .delegateOpenAI(let d):
            return Plan(steps: [.delegate(task: d.task, context: d.context, say: d.say)])
        case .capabilityGap(let gap):
            // Map capability gap to a talk step with the say message,
            // plus a delegate step to signal the gap
            var steps: [PlanStep] = []
            if let say = gap.say {
                steps.append(.talk(say: say))
            }
            steps.append(.delegate(
                task: "capability_gap: \(gap.goal)",
                context: "missing: \(gap.missing)",
                say: nil
            ))
            return Plan(steps: steps)
        }
    }
}
