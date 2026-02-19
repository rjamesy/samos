import XCTest
@testable import SamOS

@MainActor
final class RoutingServiceContractTests: XCTestCase {
    func testRoutingServiceReturnsRouteResultForCannedOrchestrator() async throws {
        let fake = CountingTurnOrchestrator()
        let container = AppContainer(orchestrator: fake)

        let routeResult = try await container.routingService.route(
            turn: RoutingTurnContext(
                text: "hello",
                history: [ChatMessage(role: .user, text: "hello")]
            )
        )

        XCTAssertEqual(fake.callCount, 1)
        XCTAssertFalse(routeResult.sayText.isEmpty)
        XCTAssertGreaterThanOrEqual(routeResult.debug.routeDurationMs, 0)
    }
}

@MainActor
private final class CountingTurnOrchestrator: TurnOrchestrating {
    var pendingSlot: PendingSlot?
    private(set) var callCount: Int = 0

    func processTurn(_ text: String, history: [ChatMessage], inputMode: TurnInputMode) async -> TurnResult {
        callCount += 1
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "handled: \(text)")]
        result.executedToolSteps = [(name: "show_text", args: ["markdown": "ok"])]
        return result
    }
}
