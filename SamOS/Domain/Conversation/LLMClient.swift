import Foundation

struct LLMMessage: Equatable {
    let role: String
    let content: String
}

struct LLMRequest {
    let system: String?
    let messages: [LLMMessage]
    let model: String?
}

struct LLMResult {
    let text: String
    let model: String
    let latencyMs: Int
}

protocol LLMClient {
    func complete(prompt: LLMRequest) async throws -> LLMResult
}
