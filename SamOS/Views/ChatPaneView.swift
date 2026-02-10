import SwiftUI
import Foundation
import AppKit

struct ChatPaneView: View {
    @EnvironmentObject var appState: AppState
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Transcript
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.chatMessages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }

                        if appState.isThinkingIndicatorVisible {
                            ThinkingIndicatorRow()
                                .id("thinking-indicator")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: appState.chatMessages.count) { _, _ in
                    if let last = appState.chatMessages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: appState.isThinkingIndicatorVisible) { _, visible in
                    guard visible else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("thinking-indicator", anchor: .bottom)
                    }
                }
            }

            if appState.pendingSlot != nil {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("Waiting for your reply\u{2026}")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Input bar
            HStack(spacing: 8) {
                TextEditor(text: $inputText)
                    .font(.body)
                    .focused($isInputFocused)
                    .frame(minHeight: 72, maxHeight: 132)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Ask Sam anything…")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .padding(.top, 14)
                                .padding(.leading, 11)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(12)
        }
        .onAppear { isInputFocused = true }
    }

    private func sendMessage() {
        let text = inputText
        inputText = ""
        appState.send(text)
    }
}

struct ThinkingIndicatorRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .cornerRadius(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Thinking indicator")
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage
    @State private var copied = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(message.text)
                    .font(.body)
                    .padding(10)
                    .background(bubbleColor)
                    .foregroundColor(textColor)
                    .cornerRadius(12)
                    .opacity(message.isEphemeral ? 0.72 : 1.0)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Button(action: copyMessageText) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help(copied ? "Copied" : "Copy message")

                    if copied {
                        Text("Copied")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if message.llmProvider == .openai {
                    if let mode = message.assistantResponseMode {
                        Text(mode.shortLabel)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(mode.pipelineLabel)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("OpenAI")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if let latencyMs = message.latencyMs {
                    Text(latencyLabel(latencyMs))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if message.usedLocalKnowledge {
                    Text("Local knowledge used")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if message.usedMemory {
                    Text("Memory used")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Sam"
        case .system: return "System"
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant:
            if message.usedLocalKnowledge { return .blue.opacity(0.85) }
            if message.llmProvider == .openai { return .red.opacity(0.85) }
            return Color(nsColor: .controlBackgroundColor)
        case .system: return Color.yellow.opacity(0.2)
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user: return .white
        case .assistant where message.usedLocalKnowledge: return .white
        case .assistant where message.llmProvider == .openai: return .white
        default: return .primary
        }
    }

    private func latencyLabel(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        return String(format: "%.3fs (%dms)", seconds, max(0, ms))
    }

    private func copyMessageText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            copied = false
        }
    }
}
