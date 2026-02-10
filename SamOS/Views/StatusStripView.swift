import SwiftUI

struct StatusStripView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(appState.status.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Error display
            if let error = appState.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Forge queue indicator
            if let current = SkillForgeQueueService.shared.currentJob {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                    Text("Learning...")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .help("Forging: \(current.goal)")
            }

            Spacer()

            // Mute toggle
            Button(action: { appState.toggleMute() }) {
                Image(systemName: appState.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundColor(appState.isMuted ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(appState.isMuted ? "Unmute Voice" : "Mute Voice")

            // Settings
            Button(action: { appState.showSettings.toggle() }) {
                Image(systemName: "gear")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusColor: Color {
        switch appState.status {
        case .idle: return .gray
        case .listening: return .green
        case .capturing: return .orange
        case .thinking: return .orange
        case .speaking: return .blue
        }
    }
}
