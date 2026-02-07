import Foundation

/// Result of a single turn processed by the orchestrator.
struct TurnResult {
    var appendedChat: [ChatMessage] = []
    var appendedOutputs: [OutputItem] = []
    var spokenLines: [String] = []
    var triggerFollowUpCapture: Bool = false
    var llmProvider: LLMProvider = .none
}

// MARK: - Timeout Helper

enum RouterTimeout: Error { case exceeded }

func withTimeout<T: Sendable>(_ seconds: Double, _ op: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RouterTimeout.exceeded
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// The ONLY brain for processing user input.
/// Calls LLM, validates structure, executes plan steps.
/// No Swift heuristics for intent, reply-vs-new-topic, or approvals.
@MainActor
final class TurnOrchestrator {
    private let ollamaRouter: OllamaRouter
    private let openAIRouter: OpenAIRouter
    private let mockRouter = MockRouter()

    var pendingSlot: PendingSlot? = nil

    // Production init
    init() {
        let ollama = OllamaRouter()
        self.ollamaRouter = ollama
        self.openAIRouter = OpenAIRouter(parser: ollama)
    }

    // Test init (injectable)
    init(ollamaRouter: OllamaRouter, openAIRouter: OpenAIRouter) {
        self.ollamaRouter = ollamaRouter
        self.openAIRouter = openAIRouter
    }

    func processTurn(_ text: String, history: [ChatMessage]) async -> TurnResult {
        // PendingSlot handling — always route through LLM
        if var slot = pendingSlot {
            if slot.isExpired {
                pendingSlot = nil
                // Fall through to normal routing
            } else if slot.attempts >= 2 {
                pendingSlot = nil
                var result = TurnResult()
                let msg = "I'm not getting it — can you rephrase?"
                result.appendedChat.append(ChatMessage(role: .assistant, text: msg))
                result.spokenLines.append(msg)
                return result
            } else {
                // Route with pending slot context — LLM decides reply vs new topic
                let (plan, provider) = await routePlan(text, history: history, pendingSlot: slot, reason: .pendingSlotReply)

                // Check if returned plan has an ask step for the same slot
                let hasRepeatAsk = plan.steps.contains { step in
                    if case .ask(let stepSlot, _) = step, stepSlot == slot.slotName {
                        return true
                    }
                    return false
                }

                if hasRepeatAsk {
                    slot.attempts += 1
                    pendingSlot = slot
                } else {
                    pendingSlot = nil
                }

                return await executePlan(plan, originalInput: text, provider: provider)
            }
        }

        // Normal LLM routing (no pending slot)
        let (plan, provider) = await routePlan(text, history: history, reason: .userChat)
        return await executePlan(plan, originalInput: text, provider: provider)
    }

    // MARK: - Brain Router Pipeline

    /// Routes: OpenAI ONLY when configured → Ollama ONLY when OpenAI not configured → MockRouter.
    /// No provider hopping. If JSON parses, accept it. No validation repair loops.
    private func routePlan(_ text: String, history: [ChatMessage],
                           pendingSlot: PendingSlot? = nil,
                           reason: LLMCallReason = .userChat) async -> (Plan, LLMProvider) {

        // A) OpenAI ONLY (when configured — no Ollama fallback)
        if OpenAISettings.isConfigured {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let plan = try await withTimeout(8.0) {
                    try await self.openAIRouter.routePlan(text, history: history, pendingSlot: pendingSlot)
                }
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: true)
                return (plan, .openai)

            } catch {
                // OpenAI failed — do NOT fall back to Ollama (it poisons answers + doubles latency)
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: false)
                return (friendlyFallbackPlan(error), .none)
            }
        }

        // B) Ollama standalone (OpenAI not configured, useOllama enabled)
        if M2Settings.useOllama {
            return await ollamaFallback(text, history: history, pendingSlot: pendingSlot,
                                        reason: reason)
        }

        // C) Nothing configured — MockRouter
        let action = mockRouter.route(text)
        return (Plan.fromAction(action), .none)
    }

    /// Ollama attempt — single call, no validation repair.
    private func ollamaFallback(_ text: String, history: [ChatMessage],
                                pendingSlot: PendingSlot?,
                                reason: LLMCallReason) async -> (Plan, LLMProvider) {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let plan = try await withTimeout(4.0) {
                try await self.ollamaRouter.routePlan(text, history: history, pendingSlot: pendingSlot)
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: true)
            return (plan, .ollama)
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: false)
            return (friendlyFallbackPlan(error), .none)
        }
    }

    // MARK: - Execute Plan

    private func executePlan(_ plan: Plan, originalInput: String, provider: LLMProvider) async -> TurnResult {
        let exec = await PlanExecutor.shared.execute(plan, originalInput: originalInput, pendingSlotName: pendingSlot?.slotName)

        var result = TurnResult()
        result.llmProvider = provider

        // Stamp provider on assistant messages
        result.appendedChat = exec.chatMessages.map { msg in
            if msg.role == .assistant {
                var stamped = msg
                stamped.llmProvider = provider
                return stamped
            }
            return msg
        }
        result.spokenLines = exec.spokenLines
        result.appendedOutputs = exec.outputItems
        result.triggerFollowUpCapture = exec.triggerFollowUpCapture

        // Auto-repair: image_url slot means the image probe failed.
        // Retry once via LLM without bothering the user.
        if let req = exec.pendingSlotRequest, req.slot == "image_url" {
            #if DEBUG
            print("[TurnOrchestrator] Image probe failed — auto-repair retry")
            #endif
            let retryResult = await autoRepairImage(originalInput: originalInput, failureReason: req.prompt)
            if let retryResult = retryResult {
                return retryResult
            }
            return result
        }

        // Handle pendingSlot from executor result (non-image)
        if let req = exec.pendingSlotRequest {
            pendingSlot = PendingSlot(
                slotName: req.slot,
                prompt: req.prompt,
                originalUserText: originalInput
            )
            result.triggerFollowUpCapture = true
        }

        return result
    }

    // MARK: - Image Auto-Repair

    /// Retries the LLM once with repair context when image URLs fail the probe.
    /// Uses same provider logic as routePlan: OpenAI only when configured, Ollama only as standalone.
    private func autoRepairImage(originalInput: String, failureReason: String) async -> TurnResult? {
        let repairReasons = [
            "The image URLs you provided are dead or don't serve image content. \(failureReason)",
            "Provide different, verified direct image URLs. URLs must end in .jpg, .png, .gif, or .webp and serve image content-type."
        ]

        if OpenAISettings.isConfigured {
            #if DEBUG
            print("[ROUTER] imageRepair via openai")
            #endif
            do {
                let plan = try await withTimeout(8.0) {
                    try await self.openAIRouter.routePlan(originalInput, history: [], repairReasons: repairReasons)
                }
                return await executeImageRepair(plan, originalInput: originalInput, provider: .openai)
            } catch {
                #if DEBUG
                print("[ROUTER] imageRepair openai failed: \(error.localizedDescription)")
                #endif
            }
        } else if M2Settings.useOllama {
            #if DEBUG
            print("[ROUTER] imageRepair via ollama")
            #endif
            do {
                let plan = try await withTimeout(4.0) {
                    try await self.ollamaRouter.routePlan(originalInput, history: [], repairReasons: repairReasons)
                }
                return await executeImageRepair(plan, originalInput: originalInput, provider: .ollama)
            } catch {
                #if DEBUG
                print("[ROUTER] imageRepair ollama failed: \(error.localizedDescription)")
                #endif
            }
        }

        return nil
    }

    private func executeImageRepair(_ plan: Plan, originalInput: String, provider: LLMProvider) async -> TurnResult? {
        let exec = await PlanExecutor.shared.execute(plan, originalInput: originalInput)

        // If the retry ALSO produced an image_url failure, give up
        if let req = exec.pendingSlotRequest, req.slot == "image_url" {
            #if DEBUG
            print("[TurnOrchestrator] Image auto-repair also failed — giving up")
            #endif
            var result = TurnResult()
            result.llmProvider = provider
            let msg = "I couldn't find a working image for that — sorry about that."
            result.appendedChat = [ChatMessage(role: .assistant, text: msg, llmProvider: provider)]
            result.spokenLines = [msg]
            return result
        }

        var result = TurnResult()
        result.llmProvider = provider
        result.appendedChat = exec.chatMessages.map { msg in
            if msg.role == .assistant {
                var stamped = msg
                stamped.llmProvider = provider
                return stamped
            }
            return msg
        }
        result.spokenLines = exec.spokenLines
        result.appendedOutputs = exec.outputItems
        result.triggerFollowUpCapture = exec.triggerFollowUpCapture

        if let req = exec.pendingSlotRequest {
            pendingSlot = PendingSlot(
                slotName: req.slot,
                prompt: req.prompt,
                originalUserText: originalInput
            )
            result.triggerFollowUpCapture = true
        }

        return result
    }

    // MARK: - Helpers

    private func routerLog(provider: String, reason: String, ms: Int, ok: Bool) {
        #if DEBUG
        print("[ROUTER] provider=\(provider) reason=\(reason) ms=\(ms) ok=\(ok)")
        #endif
    }

    private func friendlyFallbackPlan(_ error: Error? = nil) -> Plan {
        let msg: String
        if error is RouterTimeout {
            msg = "Sorry — that took too long. Please try again."
        } else if let e = error as? OpenAIRouter.OpenAIError {
            switch e {
            case .notConfigured:
                msg = "OpenAI isn't configured. Add your API key in Settings."
            case .badResponse(let code):
                msg = "OpenAI returned an error (HTTP \(code)). Please try again."
            case .requestFailed:
                msg = "I couldn't reach OpenAI. Check your connection and try again."
            }
        } else {
            msg = "Sorry — I had trouble generating a response. Please try again."
        }
        #if DEBUG
        if let error = error {
            print("[ROUTER] fallback reason: \(error.localizedDescription)")
        }
        #endif
        return Plan(steps: [.talk(say: msg)])
    }

    private func fallbackResult(_ error: Error) -> TurnResult {
        var result = TurnResult()
        let msg = "Sorry, I ran into an issue: \(error.localizedDescription)"
        result.appendedChat.append(ChatMessage(role: .assistant, text: msg))
        result.spokenLines.append(msg)
        return result
    }
}
