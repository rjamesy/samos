import Foundation

struct OpenAIIntentDecision {
    let output: IntentLLMCallOutput
    let didRetry: Bool
}

struct OpenAIPlanRequest {
    let input: String
    let history: [ChatMessage]
    let pendingSlot: PendingSlot?
    let promptContext: PromptRuntimeContext?
    let modelOverride: String?
    let reason: OpenAICallReason
    let timeoutSeconds: Double?
    let retryMaxOutputTokens: Int
}

struct OpenAIPlanDecision {
    let plan: Plan
    let didRetry: Bool
}

protocol OpenAIProviderRouting {
    func classifyIntentWithRetry(_ input: IntentClassifierInput,
                                 timeoutSeconds: Double?) async throws -> OpenAIIntentDecision
    func routePlanWithRetry(_ request: OpenAIPlanRequest) async throws -> OpenAIPlanDecision
}

final class RetryingOpenAIProvider: OpenAIProviderRouting {
    typealias SleepHandler = @Sendable (_ nanoseconds: UInt64) async -> Void

    private let openAIRouter: OpenAIRouter
    private let sleepHandler: SleepHandler
    private let intentRetryBackoffMs: UInt64
    private let planRetryBackoffMs: UInt64

    init(openAIRouter: OpenAIRouter,
         intentRetryBackoffMs: UInt64 = 250,
         planRetryBackoffMs: UInt64 = 750,
         sleepHandler: @escaping SleepHandler = { ns in
             try? await Task.sleep(nanoseconds: ns)
         }) {
        self.openAIRouter = openAIRouter
        self.intentRetryBackoffMs = intentRetryBackoffMs
        self.planRetryBackoffMs = planRetryBackoffMs
        self.sleepHandler = sleepHandler
    }

    func classifyIntentWithRetry(_ input: IntentClassifierInput,
                                 timeoutSeconds: Double?) async throws -> OpenAIIntentDecision {
        do {
            let output = try await performIntentAttempt(input, timeoutSeconds: timeoutSeconds)
            return OpenAIIntentDecision(output: output, didRetry: false)
        } catch {
            guard isTimeoutLikeError(error) else { throw error }
            await sleepHandler(intentRetryBackoffMs * 1_000_000)
            let output = try await performIntentAttempt(input, timeoutSeconds: timeoutSeconds)
            return OpenAIIntentDecision(output: output, didRetry: true)
        }
    }

    func routePlanWithRetry(_ request: OpenAIPlanRequest) async throws -> OpenAIPlanDecision {
        do {
            let plan = try await performPlanAttempt(request)
            return OpenAIPlanDecision(plan: plan, didRetry: false)
        } catch {
            guard isTimeoutLikeError(error) else { throw error }
            await sleepHandler(planRetryBackoffMs * 1_000_000)
            let retryRequest = OpenAIPlanRequest(
                input: request.input,
                history: request.history,
                pendingSlot: request.pendingSlot,
                promptContext: retryPromptContext(from: request.promptContext, maxOutputTokens: request.retryMaxOutputTokens),
                modelOverride: request.modelOverride,
                reason: request.reason,
                timeoutSeconds: request.timeoutSeconds,
                retryMaxOutputTokens: request.retryMaxOutputTokens
            )
            let plan = try await performPlanAttempt(retryRequest)
            return OpenAIPlanDecision(plan: plan, didRetry: true)
        }
    }

    private func performIntentAttempt(_ input: IntentClassifierInput,
                                      timeoutSeconds: Double?) async throws -> IntentLLMCallOutput {
        let turnID = TurnExecutionContext.turnID ?? "?"
        logOpenAIHTTP(turnID: turnID, reason: "intent", event: "started")
        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let result: IntentLLMCallOutput
            if let timeoutSeconds {
                result = try await withTimeout(timeoutSeconds) { [openAIRouter] in
                    try await openAIRouter.classifyIntentWithTrace(input, reason: .intent)
                }
            } else {
                result = try await openAIRouter.classifyIntentWithTrace(input, reason: .intent)
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            logOpenAIHTTP(turnID: turnID, reason: "intent", event: "completed", ms: ms)
            return result
        } catch is CancellationError {
            logOpenAIHTTP(turnID: turnID, reason: "intent", event: "cancelled")
            throw CancellationError()
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            logOpenAIHTTP(turnID: turnID, reason: "intent", event: "failed", ms: ms, error: error)
            throw error
        }
    }

    private func performPlanAttempt(_ request: OpenAIPlanRequest) async throws -> Plan {
        let turnID = TurnExecutionContext.turnID ?? "?"
        logOpenAIHTTP(turnID: turnID, reason: request.reason.rawValue, event: "started")
        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let result: Plan
            if let timeoutSeconds = request.timeoutSeconds {
                result = try await withTimeout(timeoutSeconds) { [openAIRouter] in
                    try await openAIRouter.routePlan(
                        request.input,
                        history: request.history,
                        pendingSlot: request.pendingSlot,
                        promptContext: request.promptContext,
                        modelOverride: request.modelOverride,
                        reason: request.reason
                    )
                }
            } else {
                result = try await openAIRouter.routePlan(
                    request.input,
                    history: request.history,
                    pendingSlot: request.pendingSlot,
                    promptContext: request.promptContext,
                    modelOverride: request.modelOverride,
                    reason: request.reason
                )
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            logOpenAIHTTP(turnID: turnID, reason: request.reason.rawValue, event: "completed", ms: ms)
            return result
        } catch is CancellationError {
            logOpenAIHTTP(turnID: turnID, reason: request.reason.rawValue, event: "cancelled")
            throw CancellationError()
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            logOpenAIHTTP(turnID: turnID, reason: request.reason.rawValue, event: "failed", ms: ms, error: error)
            throw error
        }
    }

    private func logOpenAIHTTP(turnID: String, reason: String, event: String,
                               ms: Int? = nil, error: Error? = nil) {
        #if DEBUG
        var parts = "[OPENAI_HTTP] turn=\(turnID) reason=\(reason) \(event)"
        if let ms { parts += " ms=\(ms)" }
        if let error { parts += " error=\(String(describing: error).prefix(80))" }
        print(parts)
        #endif
    }

    private func retryPromptContext(from context: PromptRuntimeContext?, maxOutputTokens: Int) -> PromptRuntimeContext? {
        guard let context else { return nil }
        let reducedBudget = ResponseLengthBudget(
            maxOutputTokens: min(maxOutputTokens, context.responseBudget.maxOutputTokens),
            chatMinTokens: min(context.responseBudget.chatMinTokens, 120),
            chatMaxTokens: min(context.responseBudget.chatMaxTokens, 220),
            preferCanvasForLongResponses: context.responseBudget.preferCanvasForLongResponses
        )
        return PromptRuntimeContext(
            mode: context.mode,
            affect: context.affect,
            tonePreferences: context.tonePreferences,
            toneRepairCue: context.toneRepairCue,
            sessionSummary: context.sessionSummary,
            interactionStateJSON: context.interactionStateJSON,
            identityContextLine: context.identityContextLine,
            responseBudget: reducedBudget
        )
    }

    private func isTimeoutLikeError(_ error: Error) -> Bool {
        if error is RouterTimeout {
            return true
        }

        if let openAIError = error as? OpenAIRouter.OpenAIError {
            switch openAIError {
            case .requestFailed(let message):
                let lower = message.lowercased()
                return lower.contains("timed out")
                    || lower.contains("timeout")
                    || lower.contains("-1001")
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }

        let lower = error.localizedDescription.lowercased()
        return lower.contains("timed out")
            || lower.contains("timeout")
            || lower.contains("-1001")
    }
}
