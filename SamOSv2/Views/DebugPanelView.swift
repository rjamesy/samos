import SwiftUI

struct DebugPanelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status section
            GroupBox("System") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(appState.status.rawValue.capitalized)
                            .font(.caption)
                    }

                    if let latency = appState.lastLatencyMs {
                        HStack {
                            Text("Last latency:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(latency)ms")
                                .font(.caption2.monospacedDigit())
                        }
                    }

                    HStack {
                        Text("Session:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(appState.sessionId.prefix(8)))
                            .font(.caption2.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Stats section
            GroupBox("Stats") {
                VStack(alignment: .leading, spacing: 4) {
                    statRow("Messages", value: "\(appState.chatMessages.count)")
                    statRow("Canvas Items", value: "\(appState.outputItems.count)")
                    statRow("Mic", value: appState.isListeningEnabled ? "On" : "Off")
                    statRow("Muted", value: appState.isMuted ? "Yes" : "No")
                    statRow("Camera", value: appState.isCameraEnabled ? "On" : "Off")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Tool log
            if !appState.toolLog.isEmpty {
                GroupBox("Tool Calls") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(appState.toolLog.suffix(10), id: \.self) { entry in
                                Text(entry)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                }
            }

            // Intelligence engines log
            if !appState.engineLog.isEmpty {
                GroupBox("Intelligence Engines") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(appState.engineLog.suffix(10), id: \.self) { entry in
                                Text(entry)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
            }

            if let error = appState.lastError {
                GroupBox("Last Error") {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Debug log
            GroupBox("Log") {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(appState.debugLog.suffix(50).enumerated()), id: \.offset) { idx, entry in
                                Text(entry)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .id(idx)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .onChange(of: appState.debugLog.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo(appState.debugLog.suffix(50).count - 1)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(8)
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

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption2.monospacedDigit())
        }
    }
}
