import Foundation

/// Matches user input to installed skills and executes them as Plans.
final class SkillEngine: @unchecked Sendable {
    private let skillStore: SkillStoreProtocol
    private let toolRegistry: ToolRegistryProtocol

    init(skillStore: SkillStoreProtocol, toolRegistry: ToolRegistryProtocol) {
        self.skillStore = skillStore
        self.toolRegistry = toolRegistry
    }

    /// Attempt to match and execute a skill for the given input.
    /// Returns nil if no skill matches.
    func tryExecute(input: String) async -> Plan? {
        guard let skill = await skillStore.match(input: input) else { return nil }
        guard skill.approvedByGPT && skill.approvedByUser else { return nil }

        // Fill slots from user input
        let filledArgs = fillSlots(input: input, parameters: skill.parameters ?? [])

        // Convert skill steps to plan steps
        let planSteps = skill.steps.map { skillStep -> PlanStep in
            switch skillStep.step {
            case "talk":
                let text = substituteArgs(skillStep.say ?? "", args: filledArgs)
                return .talk(say: text)
            case "tool":
                let toolName = skillStep.name ?? ""
                var args: [String: CodableValue] = [:]
                for (key, value) in skillStep.args ?? [:] {
                    args[key] = .string(substituteArgs(value, args: filledArgs))
                }
                return .tool(name: toolName, args: args, say: skillStep.say)
            case "ask":
                return .ask(slot: skillStep.slot ?? "", prompt: skillStep.prompt ?? "")
            case "delegate":
                return .delegate(task: skillStep.task ?? "", context: skillStep.context ?? "", say: skillStep.say)
            default:
                return .talk(say: skillStep.say ?? "")
            }
        }

        await skillStore.recordUsage(id: skill.id)
        return Plan(steps: planSteps)
    }

    private func fillSlots(input: String, parameters: [SkillParameter]) -> [String: String] {
        var filled: [String: String] = [:]
        let lower = input.lowercased()

        for param in parameters {
            if let range = lower.range(of: param.name.lowercased()) {
                let after = lower[range.upperBound...]
                let words = after.split(separator: " ").prefix(3)
                let value = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
                if !value.isEmpty {
                    filled[param.name] = value
                }
            } else if let defaultValue = param.defaultValue {
                filled[param.name] = defaultValue
            }
        }
        return filled
    }

    private func substituteArgs(_ template: String, args: [String: String]) -> String {
        var result = template
        for (key, value) in args {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}
