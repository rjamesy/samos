import SwiftUI

@main
struct SamOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let container: AppContainer
    @StateObject private var appState: AppState

    init() {
        let container = AppContainer()
        self.container = container
        _appState = StateObject(wrappedValue: AppState(container: container))
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                #if DEBUG
                .frame(minWidth: 1020, minHeight: 500)
                #else
                .frame(minWidth: 800, minHeight: 500)
                #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive || newPhase == .background {
                appState.flushSemanticMemoryForLifecycle()
            }
        }
        .windowStyle(.titleBar)
        #if DEBUG
        .defaultSize(width: 1400, height: 700)
        #else
        .defaultSize(width: 1100, height: 700)
        #endif
    }
}
