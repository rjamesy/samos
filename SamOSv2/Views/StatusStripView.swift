import SwiftUI

struct StatusStripView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 16) {
            // Mic toggle
            Button {
                appState.isListeningEnabled.toggle()
            } label: {
                Image(systemName: appState.isListeningEnabled ? "mic.fill" : "mic.slash.fill")
                    .foregroundStyle(appState.isListeningEnabled ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle voice listening")

            // Mute toggle
            Button {
                appState.isMuted.toggle()
            } label: {
                Image(systemName: appState.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(appState.isMuted ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .help("Toggle speech output")

            Spacer()

            // Status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(appState.status.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let latency = appState.lastLatencyMs {
                Text("\(latency)ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Settings
            Button {
                appState.showSettings = true
            } label: {
                Image(systemName: "gear")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusColor: Color {
        switch appState.status {
        case .idle: return .green
        case .listening: return .blue
        case .capturing: return .orange
        case .thinking: return .yellow
        case .speaking: return .purple
        }
    }
}
