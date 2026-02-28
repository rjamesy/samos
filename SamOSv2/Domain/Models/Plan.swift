import Foundation

// MARK: - PlanStep

/// A single step in a multi-step plan returned by the LLM.
enum PlanStep: Decodable, Equatable, Sendable {
    case talk(say: String)
    case tool(name: String, args: [String: CodableValue], say: String?)
    case ask(slot: String, prompt: String)
    case delegate(task: String, context: String?, say: String?)

    private enum CodingKeys: String, CodingKey {
        case step, say, name, args, slot, slots, prompt, task, context
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
            let slot = try Self.decodeAskSlot(from: container)
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

    /// Bridges CodableValue args to [String: String] for tool execution.
    var toolArgsAsStrings: [String: String] {
        guard case .tool(_, let args, _) = self else { return [:] }
        return args.mapValues { $0.stringValue }
    }

    private static func decodeAskSlot(from container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        let single = try container.decodeIfPresent(String.self, forKey: .slot) ?? ""
        let list = try container.decodeIfPresent([String].self, forKey: .slots) ?? []

        let normalizedList = list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !normalizedList.isEmpty {
            return normalizedList.joined(separator: ",")
        }

        let splitSingle = single.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !splitSingle.isEmpty {
            return splitSingle.joined(separator: ",")
        }

        throw DecodingError.dataCorruptedError(
            forKey: .slot,
            in: container,
            debugDescription: "Ask step requires non-empty slot or slots."
        )
    }
}

// MARK: - Plan

/// A multi-step plan returned by the LLM. Preferred format for tool usage.
struct Plan: Decodable, Equatable, Sendable {
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

    /// Converts native tool_calls from the LLM into a Plan.
    static func fromToolCalls(_ toolCalls: [ToolCall], spokenText: String?) -> Plan {
        var steps: [PlanStep] = []
        // If there's spoken text, add a talk step first
        if let text = spokenText, !text.isEmpty {
            steps.append(.talk(say: text))
        }
        for call in toolCalls {
            let args = call.arguments.mapValues { CodableValue.string($0) }
            steps.append(.tool(name: call.name, args: args, say: nil))
        }
        return Plan(steps: steps)
    }

    /// Wraps a legacy Action into a synthetic Plan for backward compatibility.
    static func fromAction(_ action: Action) -> Plan {
        switch action {
        case .talk(let talk):
            return Plan(steps: [.talk(say: talk.say)])
        case .tool(let toolAction):
            let args = toolAction.args.mapValues { CodableValue.string($0) }
            return Plan(
                steps: [.tool(name: toolAction.name, args: args, say: nil)],
                say: toolAction.say
            )
        case .delegateOpenAI(let d):
            return Plan(steps: [.delegate(task: d.task, context: d.context, say: d.say)])
        case .capabilityGap(let gap):
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
