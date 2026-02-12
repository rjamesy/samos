import Foundation

@MainActor
final class TurnToolRunner: TurnToolRunning {
    private let planExecutor: PlanExecutor
    private let toolsRuntime: ToolsRuntimeProtocol
    private let toolNameNormalizer: ToolNameNormalizing

    private static let unknownToolPrompt =
        "I couldn't run that request because the requested tool isn't available locally. Please rephrase your request."

    init(planExecutor: PlanExecutor,
         toolsRuntime: ToolsRuntimeProtocol,
         toolNameNormalizer: ToolNameNormalizing = ToolRegistry.shared) {
        self.planExecutor = planExecutor
        self.toolsRuntime = toolsRuntime
        self.toolNameNormalizer = toolNameNormalizer
    }

    func executePlan(_ plan: Plan,
                     originalInput: String,
                     pendingSlotName: String?) async -> ToolRunResult {
        switch normalizePlan(plan) {
        case .rejected(let raw):
            logToolReject(raw: raw, normalized: nil, reason: "unknown_tool")
            return rejectedToolResult(rawToolName: raw)
        case .normalized(let normalizedPlan):
            var result = await planExecutor.execute(
                normalizedPlan,
                originalInput: originalInput,
                pendingSlotName: pendingSlotName
            )
            result.outputItems = result.outputItems.compactMap { normalizeToolOutput($0) }
            return result
        }
    }

    func executeTool(_ action: ToolAction) -> OutputItem? {
        guard let normalized = normalizedToolName(for: action.name) else {
            logToolReject(raw: action.name, normalized: nil, reason: "unknown_tool")
            return OutputItem(kind: .markdown, payload: Self.unknownToolPrompt)
        }
        let canonicalAction = ToolAction(name: normalized, args: action.args, say: action.say)
        return normalizeToolOutput(toolsRuntime.execute(canonicalAction))
    }

    private enum PlanNormalizationResult {
        case normalized(Plan)
        case rejected(rawToolName: String)
    }

    private func normalizePlan(_ plan: Plan) -> PlanNormalizationResult {
        var normalizedSteps: [PlanStep] = []
        normalizedSteps.reserveCapacity(plan.steps.count)

        for step in plan.steps {
            switch step {
            case .tool(let rawName, let args, let say):
                guard let normalized = normalizedToolName(for: rawName) else {
                    return .rejected(rawToolName: rawName)
                }
                normalizedSteps.append(.tool(name: normalized, args: args, say: say))
            default:
                normalizedSteps.append(step)
            }
        }

        return .normalized(Plan(steps: normalizedSteps, say: plan.say))
    }

    private func normalizedToolName(for rawName: String) -> String? {
        guard let normalized = toolNameNormalizer.normalizeToolName(rawName) else { return nil }
        guard toolNameNormalizer.isAllowedTool(normalized) else { return nil }
        guard toolsRuntime.toolExists(normalized) else { return nil }
        return normalized
    }

    private func rejectedToolResult(rawToolName: String) -> ToolRunResult {
        var result = ToolRunResult()
        let message = Self.unknownToolPrompt
        result.chatMessages = [ChatMessage(role: .assistant, text: message)]
        result.spokenLines = [message]
        result.executedToolSteps = [(name: "tool_reject", args: ["unknown_tool": rawToolName])]
        return result
    }

    private func logToolReject(raw: String, normalized: String?, reason: String) {
        #if DEBUG
        print("[TOOL_REJECT] raw=\(raw) normalized=\(normalized ?? "nil") reason=\(reason)")
        #endif
    }

    private func normalizeToolOutput(_ output: OutputItem?) -> OutputItem? {
        guard let output else { return nil }
        let trimmed = output.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == output.payload { return output }
        return OutputItem(id: output.id, ts: output.ts, kind: output.kind, payload: trimmed)
    }
}
