import SwiftUI

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
                    }
                    .padding(12)
                }
                .onChange(of: appState.chatMessages.count) { _ in
                    if let last = appState.chatMessages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
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
                TextField("Ask Sam anything…", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isInputFocused)
                    .onSubmit { sendMessage() }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
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

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage

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
                    .textSelection(.enabled)

                if message.llmProvider == .openai {
                    Text("OpenAI")
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
            if message.llmProvider == .openai { return .red.opacity(0.85) }
            return Color(nsColor: .controlBackgroundColor)
        case .system: return Color.yellow.opacity(0.2)
        }
    }

    private var textColor: Color {
        switch message.role {
        case .user: return .white
        case .assistant where message.llmProvider == .openai: return .white
        default: return .primary
        }
    }
}
