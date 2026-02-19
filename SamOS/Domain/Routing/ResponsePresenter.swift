import Foundation

struct ResponsePresenter {
    func present(turnResult: TurnResult, startedAt: Date, finishedAt: Date) -> RouteResult {
        let sayText = preferredSpokenText(from: turnResult)
        let toolCalls = turnResult.executedToolSteps.map { ToolCall(name: $0.name, args: $0.args) }
        return RouteResult(
            sayText: sayText,
            uiBlocks: turnResult.appendedOutputs,
            debug: TimingInfo(
                startedAt: startedAt,
                finishedAt: finishedAt,
                routeDurationMs: max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000))
            ),
            toolCalls: toolCalls
        )
    }

    private func preferredSpokenText(from turnResult: TurnResult) -> String {
        if let lastAssistant = turnResult.appendedChat.last(where: { $0.role == .assistant })?.text,
           !lastAssistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lastAssistant
        }
        if let firstSpoken = turnResult.spokenLines.first,
           !firstSpoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return firstSpoken
        }
        return ""
    }
}
