import XCTest
@testable import SamOS

@MainActor
final class AppContainerWiringTests: XCTestCase {

    func testContainerConstructsAndRegistersCoreTools() {
        let container = AppContainer(orchestrator: ArchitectureFakeTurnOrchestrator())

        XCTAssertFalse(container.toolRegistry.allTools.isEmpty)

        let toolNames = Set(container.toolRegistry.allTools.map(\.name))
        XCTAssertTrue(toolNames.contains("show_text"))
        XCTAssertTrue(toolNames.contains("get_weather"))
        XCTAssertTrue(toolNames.contains("start_skillforge"))
    }
}

@MainActor
private final class ArchitectureFakeTurnOrchestrator: TurnOrchestrating {
    var pendingSlot: PendingSlot?

    func processTurn(_ text: String, history: [ChatMessage], inputMode: TurnInputMode) async -> TurnResult {
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "ok")]
        return result
    }
}
