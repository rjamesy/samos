import Foundation

struct RoutingTurnContext {
    let text: String
    let history: [ChatMessage]
}

struct ToolCall: Equatable {
    let name: String
    let args: [String: String]
}

struct TimingInfo: Equatable {
    let startedAt: Date
    let finishedAt: Date
    let routeDurationMs: Int
}

struct RouteResult {
    let sayText: String
    let uiBlocks: [OutputItem]
    let debug: TimingInfo
    let toolCalls: [ToolCall]
}

protocol RoutingService {
    func route(turn: RoutingTurnContext) async throws -> RouteResult
}
