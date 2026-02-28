import Foundation

/// A single part of a multipart LLM message content.
enum LLMContentPart: Equatable, Sendable {
    case text(String)
    case imageURL(String)    // "data:image/jpeg;base64,..." data URI
}

/// Content of an LLM message — plain text or multipart (text + images).
enum LLMMessageContent: Equatable, Sendable {
    case text(String)
    case multipart([LLMContentPart])

    var textValue: String {
        switch self {
        case .text(let s): return s
        case .multipart(let parts):
            return parts.compactMap {
                if case .text(let t) = $0 { return t }
                return nil
            }.joined(separator: "\n")
        }
    }
}

/// A message in an LLM conversation.
struct LLMMessage: Equatable, Sendable {
    let role: String
    let content: LLMMessageContent

    init(role: String, content: LLMMessageContent) {
        self.role = role
        self.content = content
    }

    /// Convenience: wraps a plain String as `.text(content)`.
    init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
    }
}

/// Response format for LLM requests.
enum LLMResponseFormat: Sendable, Equatable {
    case jsonObject
    case text
    case jsonSchema(name: String, schema: [String: Any])

    static func == (lhs: LLMResponseFormat, rhs: LLMResponseFormat) -> Bool {
        switch (lhs, rhs) {
        case (.jsonObject, .jsonObject): return true
        case (.text, .text): return true
        case (.jsonSchema(let a, _), .jsonSchema(let b, _)): return a == b
        default: return false
        }
    }
}

/// A tool definition for native OpenAI function calling.
struct ToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: [String: Any] // JSON Schema object

    init(name: String, description: String, parameters: [String: Any] = [:]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A tool call returned by the LLM.
struct ToolCall: Sendable {
    let id: String
    let name: String
    let arguments: [String: String]

    init(id: String = UUID().uuidString, name: String, arguments: [String: String]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// A request to an LLM provider.
struct LLMRequest: Sendable {
    let system: String?
    let messages: [LLMMessage]
    let model: String?
    let maxTokens: Int?
    let temperature: Double?
    let responseFormat: LLMResponseFormat?
    let tools: [ToolDefinition]?
    let toolChoice: String?

    init(
        system: String? = nil,
        messages: [LLMMessage],
        model: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        responseFormat: LLMResponseFormat? = nil,
        tools: [ToolDefinition]? = nil,
        toolChoice: String? = nil
    ) {
        self.system = system
        self.messages = messages
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.responseFormat = responseFormat
        self.tools = tools
        self.toolChoice = toolChoice
    }
}

/// The result from an LLM completion.
struct LLMResponse: Sendable {
    let text: String
    let model: String
    let latencyMs: Int
    let promptTokens: Int?
    let completionTokens: Int?
    let toolCalls: [ToolCall]?

    init(
        text: String,
        model: String,
        latencyMs: Int,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        toolCalls: [ToolCall]? = nil
    ) {
        self.text = text
        self.model = model
        self.latencyMs = latencyMs
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.toolCalls = toolCalls
    }
}

/// Protocol for LLM providers.
protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse

    /// Stream tokens from the LLM. Default implementation falls back to complete().
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
}

extension LLMClient {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await complete(request)
                    continuation.yield(response.text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
