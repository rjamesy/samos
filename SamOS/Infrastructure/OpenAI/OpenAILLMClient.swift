import Foundation

final class OpenAILLMClient: LLMClient {
    private let router: OpenAIRouter

    init(router: OpenAIRouter = OpenAIRouter(parser: OllamaRouter())) {
        self.router = router
    }

    func complete(prompt: LLMRequest) async throws -> LLMResult {
        let input = prompt.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let startedAt = Date()
        let plan = try await router.routePlan(input, history: [], pendingSlot: nil, reason: .other)

        let text = extractedText(from: plan)
        let ms = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        return LLMResult(
            text: text,
            model: prompt.model ?? OpenAISettings.generalModel,
            latencyMs: ms
        )
    }

    private func extractedText(from plan: Plan) -> String {
        if let say = plan.say?.trimmingCharacters(in: .whitespacesAndNewlines), !say.isEmpty {
            return say
        }
        for step in plan.steps {
            if case .talk(let say) = step {
                let trimmed = say.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return ""
    }
}
