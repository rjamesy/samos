import Foundation

@MainActor
final class TurnPipeline {
    private let orchestrator: TurnOrchestrating
    private let routePlanner: RoutePlanner
    private let presenter: ResponsePresenter
    private let clock: Clock
    private let settingsStore: SettingsStore

    init(orchestrator: TurnOrchestrating,
         routePlanner: RoutePlanner,
         presenter: ResponsePresenter,
         clock: Clock,
         settingsStore: SettingsStore) {
        self.orchestrator = orchestrator
        self.routePlanner = routePlanner
        self.presenter = presenter
        self.clock = clock
        self.settingsStore = settingsStore
    }

    func execute(turn: RoutingTurnContext) async -> RouteResult {
        let snapshot = settingsStore.snapshot
        _ = routePlanner.plannedProviders(snapshot: snapshot)

        let startedAt = clock.now
        let result = await orchestrator.processTurn(turn.text, history: turn.history, inputMode: .text)
        let finishedAt = clock.now
        return presenter.present(turnResult: result, startedAt: startedAt, finishedAt: finishedAt)
    }
}
