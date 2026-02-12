import Foundation

// MARK: - Tools Runtime Protocol

/// Abstraction over tool execution so tests can inject a mock.
protocol ToolsRuntimeProtocol {
    func execute(_ toolAction: ToolAction) -> OutputItem?
    func toolExists(_ name: String) -> Bool
}

extension ToolsRuntimeProtocol {
    /// Default: all tools exist (mocks that don't override this will allow any tool name).
    func toolExists(_ name: String) -> Bool { true }
}

// MARK: - Tools Runtime

/// Executes tool actions by dispatching to the ToolRegistry.
final class ToolsRuntime: ToolsRuntimeProtocol {
    static let shared = ToolsRuntime()

    private let registry = ToolRegistry.shared

    private init() {}

    func toolExists(_ name: String) -> Bool {
        if let canonical = registry.normalizeToolName(name),
           registry.get(canonical) != nil {
            return true
        }
        if matchInstalledSkill(named: name) != nil { return true }
        return false
    }

    /// Execute a ToolAction and return the resulting OutputItem.
    /// Returns nil if the tool is not found.
    func execute(_ toolAction: ToolAction) -> OutputItem? {
        if let canonical = registry.normalizeToolName(toolAction.name),
           let tool = registry.get(canonical) {
            return tool.execute(args: toolAction.args)
        }

        if let output = executeInstalledSkill(named: toolAction.name, args: toolAction.args) {
            return output
        }

        return OutputItem(
            kind: .markdown,
            payload: "**Error:** Unknown tool `\(toolAction.name)`."
        )
    }

    private func executeInstalledSkill(named toolName: String, args: [String: String]) -> OutputItem? {
        guard let skill = matchInstalledSkill(named: toolName) else { return nil }

        let slots = resolvedSlots(for: skill, args: args)
        let actions = SkillEngine(forTesting: true).execute(skill: skill, slots: slots)
        if actions.isEmpty {
            return OutputItem(kind: .markdown, payload: "_Skill `\(skill.name)` had no executable steps._")
        }

        var spokenLines: [String] = []
        var outputItems: [OutputItem] = []

        for action in actions {
            switch action {
            case .talk(let talk):
                let line = talk.say.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    spokenLines.append(line)
                }
            case .tool(let nestedToolAction):
                guard let canonicalName = registry.normalizeToolName(nestedToolAction.name),
                      let nestedTool = registry.get(canonicalName) else {
                    outputItems.append(OutputItem(
                        kind: .markdown,
                        payload: "**Error:** Skill `\(skill.name)` references unknown tool `\(nestedToolAction.name)`."
                    ))
                    continue
                }
                outputItems.append(nestedTool.execute(args: nestedToolAction.args))
            case .delegateOpenAI, .capabilityGap:
                continue
            }
        }

        guard let first = outputItems.first else {
            let spoken = spokenLines.last ?? "Done."
            return OutputItem(kind: .markdown, payload: spoken)
        }

        if spokenLines.isEmpty || first.kind != .markdown {
            return first
        }

        return structuredTextOutput(spoken: spokenLines.last ?? "Done.", formatted: first.payload)
    }

    private func matchInstalledSkill(named toolName: String) -> SkillSpec? {
        let normalizedToolName = normalizeIdentifier(toolName)
        let installedSkills = SkillStore.shared.loadInstalled()

        for skill in installedSkills {
            if normalizeIdentifier(skill.id) == normalizedToolName {
                return skill
            }
            if normalizeIdentifier(skill.name) == normalizedToolName {
                return skill
            }
            if skill.triggerPhrases.contains(where: { normalizeIdentifier($0) == normalizedToolName }) {
                return skill
            }
        }
        return nil
    }

    private func resolvedSlots(for skill: SkillSpec, args: [String: String]) -> [String: String] {
        var slots = args
        let aliasValues = [
            args["query"],
            args["q"],
            args["search"],
            args["searchTerm"],
            args["search_term"],
            args["term"],
            args["topic"],
            args["input"],
            args["text"],
            args["place"]
        ].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        for slot in skill.slots where slots[slot.name] == nil {
            if let alias = aliasValues.first {
                slots[slot.name] = alias
            }
        }
        return slots
    }

    private func structuredTextOutput(spoken: String, formatted: String) -> OutputItem {
        let payload: [String: String] = [
            "spoken": spoken,
            "formatted": formatted
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return OutputItem(kind: .markdown, payload: formatted)
        }
        return OutputItem(kind: .markdown, payload: json)
    }

    private func normalizeIdentifier(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let pieces = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return pieces.joined()
    }
}
