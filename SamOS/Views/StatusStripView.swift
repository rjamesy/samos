import SwiftUI

struct StatusStripView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var ambientService = AmbientListeningService.shared

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

            // Ambient listening indicator with audio level bar
            if M2Settings.alwaysListeningEnabled && ambientService.isRunning {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.purple)
                        .frame(width: 6, height: 6)
                    Text("Ambient")
                        .font(.caption)
                        .foregroundColor(.purple)
                    // Audio level bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.purple.opacity(0.15))
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(levelColor)
                                .frame(width: geo.size.width * CGFloat(ambientService.audioLevel), height: 6)
                                .animation(.linear(duration: 0.1), value: ambientService.audioLevel)
                        }
                    }
                    .frame(width: 60, height: 6)
                    if ambientService.storedCount > 0 {
                        Text("\(ambientService.storedCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.purple.opacity(0.7)))
                    }
                }
                .help("Always Listening — \(ambientService.storedCount) memories stored this session")
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

    private var levelColor: Color {
        let level = ambientService.audioLevel
        if level > 0.7 { return .red }
        if level > 0.4 { return .orange }
        return .purple
    }
}
