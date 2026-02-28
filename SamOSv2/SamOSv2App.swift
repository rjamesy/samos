import SwiftUI

@main
struct SamOSv2App: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appState)
                .task {
                    let container = await AppContainer.createDefault()
                    appState.container = container
                    appState.addDebug("[App] Container initialized")
                    appState.setupVoiceCallbacks()
                }
        }
    }
}
