import Foundation
@testable import SamOSv2

/// Deterministic LLM client for testing. Returns preconfigured responses.
final class MockLLMClient: LLMClient, @unchecked Sendable {
    var responses: [String] = []
    var callCount = 0
    var lastRequest: LLMRequest?
    var shouldThrow: LLMError?

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        lastRequest = request
        callCount += 1

        if let error = shouldThrow {
            throw error
        }

        let text = responses.isEmpty ? "{\"action\":\"TALK\",\"say\":\"Mock response\"}" : responses.removeFirst()
        return LLMResponse(
            text: text,
            model: "mock-model",
            latencyMs: 10,
            promptTokens: 100,
            completionTokens: 50
        )
    }
}
