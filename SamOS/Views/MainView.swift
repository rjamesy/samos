import SwiftUI

struct MainView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Two-pane split
            HSplitView {
                #if DEBUG
                DebugPanelView()
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                #endif

                // Chat pane
                ChatPaneView()
                    .frame(minWidth: 300, idealWidth: 400)

                // Output Canvas
                OutputCanvasView()
                    .frame(minWidth: 300, idealWidth: 500)
            }

            Divider()

            // Bottom status strip
            StatusStripView()
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
