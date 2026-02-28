import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                #if DEBUG
                DebugPanelView()
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                #endif

                ChatPaneView()
                    .frame(minWidth: 300, idealWidth: 400)

                OutputCanvasView()
                    .frame(minWidth: 300, idealWidth: 500)
            }

            Divider()

            StatusStripView()
        }
        .sheet(isPresented: Bindable(appState).showSettings) {
            SettingsView()
                .environment(appState)
        }
    }
}
