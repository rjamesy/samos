import Foundation

enum LLMProvider: String, Equatable {
    case openai, ollama, none
}

enum MessageOriginProvider: String, Equatable {
    case openai
    case ollama
    case local

    static func from(llmProvider: LLMProvider) -> MessageOriginProvider {
        switch llmProvider {
        case .openai:
            return .openai
        case .ollama:
            return .ollama
        case .none:
            return .local
        }
    }
}

enum AssistantResponseMode: String, Equatable {
    case samGateway

    var shortLabel: String {
        switch self {
        case .samGateway:
            return "Sam Agent (GPT-5.2)"
        }
    }

    var pipelineLabel: String {
        switch self {
        case .samGateway:
            return "Sam Gateway + ElevenLabs TTS"
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
    var originProvider: MessageOriginProvider
    var executionProvider: MessageOriginProvider?
    var originReason: String?
    var isEphemeral: Bool
    var usedMemory: Bool
    var usedLocalKnowledge: Bool
    var assistantResponseMode: AssistantResponseMode?

    init(id: UUID = UUID(),
         ts: Date = Date(),
         role: MessageRole,
         text: String,
         llmProvider: LLMProvider = .none,
         originProvider: MessageOriginProvider? = nil,
         executionProvider: MessageOriginProvider? = nil,
         originReason: String? = nil,
         isEphemeral: Bool = false,
         usedMemory: Bool = false,
         usedLocalKnowledge: Bool = false) {
        self.id = id
        self.ts = ts
        self.role = role
        self.text = text
        self.latencyMs = nil
        self.llmProvider = llmProvider
        let resolvedOrigin = originProvider ?? Self.defaultOriginProvider(role: role, llmProvider: llmProvider)
        self.originProvider = resolvedOrigin
        self.executionProvider = executionProvider ?? resolvedOrigin
        self.originReason = originReason
        self.isEphemeral = isEphemeral
        self.usedMemory = usedMemory
        self.usedLocalKnowledge = usedLocalKnowledge
        self.assistantResponseMode = nil
    }

    // Backward-compatible initializer retained for existing callsites/tests.
    init(id: UUID = UUID(),
         ts: Date = Date(),
         role: MessageRole,
         text: String,
         llmProvider: LLMProvider = .none,
         isEphemeral: Bool = false,
         usedMemory: Bool = false,
         usedLocalKnowledge: Bool = false) {
        self.init(id: id,
                  ts: ts,
                  role: role,
                  text: text,
                  llmProvider: llmProvider,
                  originProvider: nil,
                  executionProvider: nil,
                  originReason: nil,
                  isEphemeral: isEphemeral,
                  usedMemory: usedMemory,
                  usedLocalKnowledge: usedLocalKnowledge)
    }

    init(id: UUID = UUID(),
         ts: Date = Date(),
         role: MessageRole,
         text: String,
         llmProvider: LLMProvider = .none,
         originProvider: MessageOriginProvider? = nil,
         executionProvider: MessageOriginProvider? = nil,
         originReason: String? = nil,
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
        let resolvedOrigin = originProvider ?? Self.defaultOriginProvider(role: role, llmProvider: llmProvider)
        self.originProvider = resolvedOrigin
        self.executionProvider = executionProvider ?? resolvedOrigin
        self.originReason = originReason
        self.isEphemeral = isEphemeral
        self.usedMemory = usedMemory
        self.usedLocalKnowledge = usedLocalKnowledge
        self.assistantResponseMode = nil
    }

    // Backward-compatible initializer retained for existing callsites/tests.
    init(id: UUID = UUID(),
         ts: Date = Date(),
         role: MessageRole,
         text: String,
         llmProvider: LLMProvider = .none,
         isEphemeral: Bool = false,
         usedMemory: Bool = false,
         usedLocalKnowledge: Bool = false,
         latencyMs: Int?) {
        self.init(id: id,
                  ts: ts,
                  role: role,
                  text: text,
                  llmProvider: llmProvider,
                  originProvider: nil,
                  executionProvider: nil,
                  originReason: nil,
                  isEphemeral: isEphemeral,
                  usedMemory: usedMemory,
                  usedLocalKnowledge: usedLocalKnowledge,
                  latencyMs: latencyMs)
    }

    private static func defaultOriginProvider(role: MessageRole, llmProvider: LLMProvider) -> MessageOriginProvider {
        guard role == .assistant else { return .local }
        return .from(llmProvider: llmProvider)
    }
}

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}
