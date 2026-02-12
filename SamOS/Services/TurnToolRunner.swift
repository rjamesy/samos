import Foundation

@MainActor
final class TurnToolRunner: TurnToolRunning {
    private let planExecutor: PlanExecutor
    private let toolsRuntime: ToolsRuntimeProtocol

    init(planExecutor: PlanExecutor,
         toolsRuntime: ToolsRuntimeProtocol) {
        self.planExecutor = planExecutor
        self.toolsRuntime = toolsRuntime
    }

    func executePlan(_ plan: Plan,
                     originalInput: String,
                     pendingSlotName: String?) async -> ToolRunResult {
        var result = await planExecutor.execute(plan, originalInput: originalInput, pendingSlotName: pendingSlotName)
        result.outputItems = result.outputItems.compactMap { normalizeToolOutput($0) }
        return result
    }

    func executeTool(_ action: ToolAction) -> OutputItem? {
        normalizeToolOutput(toolsRuntime.execute(action))
    }

    private func normalizeToolOutput(_ output: OutputItem?) -> OutputItem? {
        guard let output else { return nil }
        let trimmed = output.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == output.payload { return output }
        return OutputItem(id: output.id, ts: output.ts, kind: output.kind, payload: trimmed)
    }
}
