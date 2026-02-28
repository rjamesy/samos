import Foundation

// MARK: - Chat Attachment

struct ChatAttachment: Identifiable, Equatable, Sendable {
    let id: String
    let filename: String
    let mimeType: String
    let data: Data
    var isImage: Bool { mimeType.hasPrefix("image/") }

    init(id: String = UUID().uuidString, filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

// MARK: - Message Role

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

// MARK: - ChatMessage

/// A single message in the conversation. Simplified from v1 — no Ollama provider refs.
struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let ts: Date
    let role: MessageRole
    let text: String
    var latencyMs: Int?
    var provider: String?
    var isEphemeral: Bool
    var usedMemory: Bool
    var attachments: [ChatAttachment] = []

    private enum CodingKeys: String, CodingKey {
        case id, ts, role, text, latencyMs, provider, isEphemeral, usedMemory
    }

    init(
        id: UUID = UUID(),
        ts: Date = Date(),
        role: MessageRole,
        text: String,
        latencyMs: Int? = nil,
        provider: String? = nil,
        isEphemeral: Bool = false,
        usedMemory: Bool = false
    ) {
        self.id = id
        self.ts = ts
        self.role = role
        self.text = text
        self.latencyMs = latencyMs
        self.provider = provider
        self.isEphemeral = isEphemeral
        self.usedMemory = usedMemory
    }
}
