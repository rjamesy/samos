import Foundation

@MainActor
final class TurnRoutingServiceAdapter: RoutingService {
    private let pipeline: TurnPipeline

    init(pipeline: TurnPipeline) {
        self.pipeline = pipeline
    }

    func route(turn: RoutingTurnContext) async throws -> RouteResult {
        await pipeline.execute(turn: turn)
    }
}
