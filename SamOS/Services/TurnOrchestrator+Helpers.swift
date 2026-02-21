import Foundation

// MARK: - Canvas Policy & Utility Helpers

extension TurnOrchestrator {

    func applyCanvasPresentationPolicy(_ result: inout TurnResult) {
        // Answer shaping safety net: dense/structured TALK becomes short spoken summary + detailed canvas content.
        if result.appendedOutputs.isEmpty,
           !result.triggerFollowUpCapture {
            let assistantIndices = result.appendedChat.indices.filter { result.appendedChat[$0].role == .assistant }
            if assistantIndices.count == 1 {
                let idx = assistantIndices[0]
                let message = result.appendedChat[idx]
                if shouldUseVisualDetail(for: message.text) {
                    result.appendedOutputs.append(OutputItem(kind: .markdown, payload: message.text))
                    let confirmation = nextCanvasConfirmation()
                    result.appendedChat[idx] = ChatMessage(
                        id: message.id,
                        ts: message.ts,
                        role: .assistant,
                        text: confirmation,
                        llmProvider: message.llmProvider,
                        usedMemory: message.usedMemory,
                        usedLocalKnowledge: message.usedLocalKnowledge
                    )
                    result.spokenLines = [confirmation]
                }
            }
        }

        // Silent tools can produce canvas output without chat; add a short confirmation bubble.
        let hasAssistantChat = result.appendedChat.contains { $0.role == .assistant }
        if !result.appendedOutputs.isEmpty && !hasAssistantChat && !result.triggerFollowUpCapture {
            let confirmation = nextCanvasConfirmation()
            result.appendedChat.append(ChatMessage(role: .assistant, text: confirmation, llmProvider: result.llmProvider))
            result.spokenLines.append(confirmation)
        }
    }

    func shouldUseVisualDetail(for text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count > 200 { return true }
        if trimmed.contains("```") { return true } // markdown block

        let lines = trimmed.components(separatedBy: .newlines)
        return lines.contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("# ") ||
                line.hasPrefix("## ") ||
                line.hasPrefix("### ") ||
                line.hasPrefix("- ") ||
                line.hasPrefix("* ") ||
                Self.isNumberedListLine(line)
        }
    }

    static func isNumberedListLine(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: line.utf16.count)
        return numberedListRegex.firstMatch(in: line, options: [], range: range) != nil
    }

    func nextCanvasConfirmation() -> String {
        guard !canvasConfirmations.isEmpty else { return "Done." }
        let value = canvasConfirmations[canvasConfirmationIndex % canvasConfirmations.count]
        canvasConfirmationIndex = (canvasConfirmationIndex + 1) % canvasConfirmations.count
        return value
    }

    func rememberAssistantLines(_ messages: [ChatMessage]) {
        for message in messages where message.role == .assistant {
            recentAssistantLines.append(message.text)
        }
        if recentAssistantLines.count > 3 {
            recentAssistantLines.removeFirst(recentAssistantLines.count - 3)
        }
    }

}
