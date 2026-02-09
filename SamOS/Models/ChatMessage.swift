import Foundation

enum LLMProvider: String, Equatable {
    case openai, ollama, none
}

enum AssistantResponseMode: String, Equatable {
    case openAIClassic
    case realtimeAI

    var shortLabel: String {
        switch self {
        case .openAIClassic:
            return "OpenAI Classic"
        case .realtimeAI:
            return "Realtime AI"
        }
    }

    var pipelineLabel: String {
        switch self {
        case .openAIClassic:
            return "Classic STT + ElevenLabs TTS"
        case .realtimeAI:
            return "Realtime STT + ElevenLabs TTS"
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let ts: Date
    let role: MessageRole
    let text: String
    var latencyMs: Int?
    var llmProvider: LLMProvider
    var isEphemeral: Bool
    var usedMemory: Bool
    var usedLocalKnowledge: Bool
    var assistantResponseMode: AssistantResponseMode?

    init(id: UUID = UUID(),
         ts: Date = Date(),
         role: MessageRole,
         text: String,
         llmProvider: LLMProvider = .none,
         isEphemeral: Bool = false,
         usedMemory: Bool = false,
         usedLocalKnowledge: Bool = false) {
        self.id = id
        self.ts = ts
        self.role = role
        self.text = text
        self.latencyMs = nil
        self.llmProvider = llmProvider
        self.isEphemeral = isEphemeral
        self.usedMemory = usedMemory
        self.usedLocalKnowledge = usedLocalKnowledge
        self.assistantResponseMode = nil
    }

    init(id: UUID = UUID(),
         ts: Date = Date(),
         role: MessageRole,
         text: String,
         llmProvider: LLMProvider = .none,
         isEphemeral: Bool = false,
         usedMemory: Bool = false,
         usedLocalKnowledge: Bool = false,
         latencyMs: Int?) {
        self.id = id
        self.ts = ts
        self.role = role
        self.text = text
        self.latencyMs = latencyMs
        self.llmProvider = llmProvider
        self.isEphemeral = isEphemeral
        self.usedMemory = usedMemory
        self.usedLocalKnowledge = usedLocalKnowledge
        self.assistantResponseMode = nil
    }
}

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}
