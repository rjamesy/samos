import Foundation

/// Composites PromptBuilder + OpenAIClient + ResponseParser into a single routing call.
final class OpenAIRouter: @unchecked Sendable {
    private let client: any LLMClient
    private let promptBuilder: PromptBuilder
    private let responseParser: ResponseParser

    init(client: any LLMClient, promptBuilder: PromptBuilder, responseParser: ResponseParser) {
        self.client = client
        self.promptBuilder = promptBuilder
        self.responseParser = responseParser
    }

    /// Route a user message through OpenAI and return a parsed Plan.
    func route(
        userText: String,
        history: [ChatMessage],
        memoryBlock: String,
        engineContext: String,
        toolManifest: String,
        currentState: String,
        temporalContext: String
    ) async throws -> (Plan, Int) {
        let systemPrompt = promptBuilder.buildSystemPrompt(
            memoryBlock: memoryBlock,
            engineContext: engineContext,
            toolManifest: toolManifest,
            conversationHistory: buildHistoryString(history),
            currentState: currentState,
            temporalContext: temporalContext
        )

        var messages: [LLMMessage] = []
        // Include recent history as messages
        let recentHistory = history.suffix(20)
        for msg in recentHistory {
            messages.append(LLMMessage(role: msg.role.rawValue, content: msg.text))
        }
        messages.append(LLMMessage(role: "user", content: userText))

        let request = LLMRequest(
            system: systemPrompt,
            messages: messages,
            responseFormat: .jsonObject
        )

        let response = try await client.complete(request)
        let plan = responseParser.parse(response.text)
        return (plan, response.latencyMs)
    }

    private func buildHistoryString(_ history: [ChatMessage]) -> String {
        let recent = history.suffix(10)
        return recent.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
    }
}
