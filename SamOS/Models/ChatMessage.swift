import Foundation

enum LLMProvider: String, Equatable {
    case openai, ollama, none
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let ts: Date
    let role: MessageRole
    let text: String
    var llmProvider: LLMProvider

    init(id: UUID = UUID(), ts: Date = Date(), role: MessageRole, text: String, llmProvider: LLMProvider = .none) {
        self.id = id
        self.ts = ts
        self.role = role
        self.text = text
        self.llmProvider = llmProvider
    }
}

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}
