import Foundation

/// Result of executing a full plan.
struct PlanExecutionResult: Sendable {
    let spokenText: String
    let outputItems: [OutputItem]
    let toolCalls: [String]
}

/// Walks Plan.steps sequentially: executes tools, collects speech, handles ask/delegate.
final class PlanExecutor: @unchecked Sendable {
    private let toolRegistry: any ToolRegistryProtocol
    private let memoryStore: any MemoryStoreProtocol

    init(toolRegistry: any ToolRegistryProtocol, memoryStore: any MemoryStoreProtocol) {
        self.toolRegistry = toolRegistry
        self.memoryStore = memoryStore
    }

    func execute(plan: Plan) async -> PlanExecutionResult {
        var spokenParts: [String] = []
        var outputItems: [OutputItem] = []
        var toolCalls: [String] = []

        // If plan has a top-level say, include it
        if let say = plan.say, !say.isEmpty {
            spokenParts.append(say)
        }

        for step in plan.steps {
            switch step {
            case .talk(let say):
                spokenParts.append(say)

            case .tool(let name, _, let say):
                let args = step.toolArgsAsStrings
                toolCalls.append(name)

                // Resolve tool
                let resolvedName = toolRegistry.normalizeToolName(name) ?? name
                if let tool = toolRegistry.get(resolvedName) {
                    let result = await tool.execute(args: args)
                    if let output = result.output {
                        outputItems.append(output)
                    }
                    if let spoken = result.spokenText {
                        spokenParts.append(spoken)
                    }
                    if let error = result.error {
                        spokenParts.append("Tool error: \(error)")
                    }
                } else {
                    spokenParts.append("I don't have a tool called \(name).")
                }

                if let say, !say.isEmpty {
                    spokenParts.append(say)
                }

            case .ask(_, let prompt):
                spokenParts.append(prompt)

            case .delegate(let task, _, let say):
                if let say, !say.isEmpty {
                    spokenParts.append(say)
                } else {
                    spokenParts.append("I'll need to handle: \(task)")
                }
            }
        }

        // Per ARCHITECTURE.md: talk entries win — speech is success
        let finalText = spokenParts.joined(separator: " ")

        return PlanExecutionResult(
            spokenText: finalText,
            outputItems: outputItems,
            toolCalls: toolCalls
        )
    }
}
