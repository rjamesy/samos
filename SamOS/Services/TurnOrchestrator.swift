import Foundation

/// Result of a single turn processed by the orchestrator.
struct TurnResult {
    var appendedChat: [ChatMessage] = []
    var appendedOutputs: [OutputItem] = []
    var spokenLines: [String] = []
    var triggerFollowUpCapture: Bool = false
    var triggerQuestionAutoListen: Bool = false
    var usedMemoryHints: Bool = false
    var llmProvider: LLMProvider = .none
    var knowledgeAttribution: KnowledgeAttribution?
    var executedToolSteps: [(name: String, args: [String: String])] = []
    var routerMs: Int?
}

private struct LocalKnowledgeContext {
    let items: [KnowledgeSourceSnippet]

    var hasMemoryHints: Bool {
        items.contains { $0.kind == .memory }
    }
}

@MainActor
protocol TurnOrchestrating: AnyObject {
    var pendingSlot: PendingSlot? { get set }
    func processTurn(_ text: String, history: [ChatMessage]) async -> TurnResult
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
    private let memoryAckCooldownTurns: Int
    private let followUpCooldownTurns: Int
    private var recentAssistantLines: [String] = []
    private var canvasConfirmationIndex = 0
    private let canvasConfirmations = [
        "I've put the details up here.",
        "Here's a clear breakdown for you.",
        "I've laid this out on screen."
    ]
    private let followUpQuestions = [
        "Need anything else on this?",
        "Want me to continue on this?",
        "Should I add anything else?"
    ]
    private static let numberedListRegex = try! NSRegularExpression(pattern: #"^\d+[\.)]\s"#, options: [])
    private var turnCounter = 0
    private var lastMemoryAckTurn: Int?
    private var lastFollowUpTurn: Int?
    private var followUpQuestionIndex = 0
    private let openAIRouteTimeoutSeconds: Double = 5.0
    private let openAIImageRepairTimeoutSeconds: Double = 3.0
    private let toolFeedbackLoopMaxDepth = 1
    private let maxRephraseBudgetMs = 700
    private let maxToolFeedbackBudgetMs = 600

    var pendingSlot: PendingSlot? = nil

    // Production init
    init() {
        let ollama = OllamaRouter()
        self.ollamaRouter = ollama
        self.openAIRouter = OpenAIRouter(parser: ollama)
        self.memoryAckCooldownTurns = 20
        self.followUpCooldownTurns = 3
    }

    // Test init (injectable)
    init(ollamaRouter: OllamaRouter,
         openAIRouter: OpenAIRouter,
         memoryAckCooldownTurns: Int = 20,
         followUpCooldownTurns: Int = 3) {
        self.ollamaRouter = ollamaRouter
        self.openAIRouter = openAIRouter
        self.memoryAckCooldownTurns = max(1, memoryAckCooldownTurns)
        self.followUpCooldownTurns = max(1, followUpCooldownTurns)
    }

    func processTurn(_ text: String, history: [ChatMessage]) async -> TurnResult {
        turnCounter += 1
        let currentTurn = turnCounter
        let turnStartedAt = Date()
        let localKnowledgeContext = buildLocalKnowledgeContext(for: text)
        let hasMemoryHints = localKnowledgeContext.hasMemoryHints

        // PendingSlot handling — always route through LLM
        if var slot = pendingSlot {
            if slot.isExpired {
                pendingSlot = nil
                // Fall through to normal routing
            } else if slot.attempts >= 3 {
                pendingSlot = nil
                var result = TurnResult()
                let msg = "I'm not getting it — can you rephrase?"
                result.appendedChat.append(ChatMessage(role: .assistant, text: msg))
                result.spokenLines.append(msg)
                return result
            } else {
                // Route with pending slot context — LLM decides reply vs new topic
                let (rawPlan, provider, routerMs) = await routePlan(text, history: history, pendingSlot: slot, reason: .pendingSlotReply)
                let plan = await maybeRephraseRepeatedTalk(rawPlan,
                                                           userInput: text,
                                                           history: history,
                                                           provider: provider,
                                                           turnStartedAt: turnStartedAt)

                // Check if returned plan has an ask step for the same slot
                let hasRepeatAsk = plan.steps.contains { step in
                    if case .ask(let stepSlot, _) = step,
                       !normalizedSlotSet(from: stepSlot).isDisjoint(with: normalizedSlotSet(from: slot.slotName)) {
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

                return await executePlan(plan,
                                         originalInput: text,
                                         history: history,
                                         provider: provider,
                                         routerMs: routerMs,
                                         localKnowledgeContext: localKnowledgeContext,
                                         hasMemoryHints: hasMemoryHints,
                                         turnIndex: currentTurn,
                                         feedbackDepth: 0,
                                         turnStartedAt: turnStartedAt)
            }
        }

        // Normal LLM routing (no pending slot)
        let (rawPlan, provider, routerMs) = await routePlan(text, history: history, reason: .userChat)
        let plan = await maybeRephraseRepeatedTalk(rawPlan,
                                                   userInput: text,
                                                   history: history,
                                                   provider: provider,
                                                   turnStartedAt: turnStartedAt)
        return await executePlan(plan,
                                 originalInput: text,
                                 history: history,
                                 provider: provider,
                                 routerMs: routerMs,
                                 localKnowledgeContext: localKnowledgeContext,
                                 hasMemoryHints: hasMemoryHints,
                                 turnIndex: currentTurn,
                                 feedbackDepth: 0,
                                 turnStartedAt: turnStartedAt)
    }

    // MARK: - Brain Router Pipeline

    /// Routes: OpenAI ONLY when configured → Ollama ONLY when OpenAI not configured → MockRouter.
    /// No provider hopping. If JSON parses, accept it. No validation repair loops.
    private func routePlan(_ text: String, history: [ChatMessage],
                           pendingSlot: PendingSlot? = nil,
                           reason: LLMCallReason = .userChat) async -> (Plan, LLMProvider, Int) {

        // A) OpenAI ONLY (when configured — no Ollama fallback)
        if OpenAISettings.isConfigured {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let plan = try await withTimeout(openAIRouteTimeoutSeconds) {
                    try await self.openAIRouter.routePlan(text, history: history, pendingSlot: pendingSlot)
                }
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: true)
                return (plan, .openai, ms)

            } catch {
                // OpenAI failed — do NOT fall back to Ollama (it poisons answers + doubles latency)
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                routerLog(provider: "openai", reason: reason.rawValue, ms: ms, ok: false)
                return (friendlyFallbackPlan(error), .none, ms)
            }
        }

        // B) Ollama standalone (OpenAI not configured, useOllama enabled)
        if M2Settings.useOllama {
            return await ollamaFallback(text, history: history, pendingSlot: pendingSlot, reason: reason)
        }

        // C) Nothing configured — MockRouter
        let action = mockRouter.route(text)
        return (Plan.fromAction(action), .none, 0)
    }

    /// Ollama attempt — single call, no validation repair.
    private func ollamaFallback(_ text: String, history: [ChatMessage],
                                pendingSlot: PendingSlot?,
                                reason: LLMCallReason) async -> (Plan, LLMProvider, Int) {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let plan = try await withTimeout(4.0) {
                try await self.ollamaRouter.routePlan(text, history: history, pendingSlot: pendingSlot)
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: true)
            return (plan, .ollama, ms)
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            routerLog(provider: "ollama", reason: reason.rawValue, ms: ms, ok: false)
            return (friendlyFallbackPlan(error), .none, ms)
        }
    }

    // MARK: - Execute Plan

    private func executePlan(_ plan: Plan,
                             originalInput: String,
                             history: [ChatMessage],
                             provider: LLMProvider,
                             routerMs: Int,
                             localKnowledgeContext: LocalKnowledgeContext,
                             hasMemoryHints: Bool,
                             turnIndex: Int,
                             feedbackDepth: Int,
                             turnStartedAt: Date) async -> TurnResult {
        let exec = await PlanExecutor.shared.execute(plan, originalInput: originalInput, pendingSlotName: pendingSlot?.slotName)

        var result = TurnResult()
        result.llmProvider = provider
        result.executedToolSteps = exec.executedToolSteps
        result.routerMs = routerMs

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
        result.usedMemoryHints = hasMemoryHints

        // Auto-repair: image_url slot means the image probe failed.
        // Retry once via LLM without bothering the user.
        if let req = exec.pendingSlotRequest, req.slot == "image_url" {
            #if DEBUG
            print("[TurnOrchestrator] Image probe failed — auto-repair retry")
            #endif
            let retryResult = await autoRepairImage(originalInput: originalInput,
                                                    history: history,
                                                    failureReason: req.prompt,
                                                    localKnowledgeContext: localKnowledgeContext,
                                                    hasMemoryHints: hasMemoryHints,
                                                    turnIndex: turnIndex,
                                                    feedbackDepth: feedbackDepth,
                                                    turnStartedAt: turnStartedAt)
            if let retryResult = retryResult {
                return retryResult
            }
            return result
        }

        // Handle pendingSlot from executor result (non-image)
        if let req = exec.pendingSlotRequest {
            pendingSlot = PendingSlot(slotName: req.slot, prompt: req.prompt, originalUserText: originalInput)
            result.triggerFollowUpCapture = true
        }

        applyCanvasPresentationPolicy(&result)
        applyResponsePolish(&result, plan: plan, hasMemoryHints: hasMemoryHints, turnIndex: turnIndex)
        applyFollowUpQuestionPolicy(&result, turnIndex: turnIndex)
        applyKnowledgeAttribution(&result,
                                  userInput: originalInput,
                                  provider: provider,
                                  localKnowledgeContext: localKnowledgeContext)
        await applyToolResultFeedbackLoop(
            &result,
            originalInput: originalInput,
            history: history,
            provider: provider,
            depth: feedbackDepth,
            turnStartedAt: turnStartedAt
        )
        rememberAssistantLines(result.appendedChat)
        return result
    }

    // MARK: - Image Auto-Repair

    /// Retries the LLM once with repair context when image URLs fail the probe.
    /// Uses same provider logic as routePlan: OpenAI only when configured, Ollama only as standalone.
    private func autoRepairImage(originalInput: String,
                                 history: [ChatMessage],
                                 failureReason: String,
                                 localKnowledgeContext: LocalKnowledgeContext,
                                 hasMemoryHints: Bool,
                                 turnIndex: Int,
                                 feedbackDepth: Int,
                                 turnStartedAt: Date) async -> TurnResult? {
        let repairReasons = [
            "The image URLs you provided are dead or don't serve image content. \(failureReason)",
            "Return 3 NEW direct image URLs from upload.wikimedia.org (preferred), images.unsplash.com, or images.pexels.com. URLs MUST end in .jpg, .png, .gif, or .webp. NEVER use example.com or placeholder domains."
        ]

        if OpenAISettings.isConfigured {
            #if DEBUG
            print("[ROUTER] imageRepair via openai")
            #endif
            do {
                let plan = try await withTimeout(openAIImageRepairTimeoutSeconds) {
                    try await self.openAIRouter.routePlan(originalInput, history: [], repairReasons: repairReasons)
                }
                return await executeImageRepair(plan,
                                                originalInput: originalInput,
                                                history: history,
                                                provider: .openai,
                                                localKnowledgeContext: localKnowledgeContext,
                                                hasMemoryHints: hasMemoryHints,
                                                turnIndex: turnIndex,
                                                feedbackDepth: feedbackDepth,
                                                turnStartedAt: turnStartedAt)
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
                return await executeImageRepair(plan,
                                                originalInput: originalInput,
                                                history: history,
                                                provider: .ollama,
                                                localKnowledgeContext: localKnowledgeContext,
                                                hasMemoryHints: hasMemoryHints,
                                                turnIndex: turnIndex,
                                                feedbackDepth: feedbackDepth,
                                                turnStartedAt: turnStartedAt)
            } catch {
                #if DEBUG
                print("[ROUTER] imageRepair ollama failed: \(error.localizedDescription)")
                #endif
            }
        }

        return nil
    }

    private func executeImageRepair(_ plan: Plan,
                                    originalInput: String,
                                    history: [ChatMessage],
                                    provider: LLMProvider,
                                    localKnowledgeContext: LocalKnowledgeContext,
                                    hasMemoryHints: Bool,
                                    turnIndex: Int,
                                    feedbackDepth: Int,
                                    turnStartedAt: Date) async -> TurnResult? {
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
        result.usedMemoryHints = hasMemoryHints

        if let req = exec.pendingSlotRequest {
            pendingSlot = PendingSlot(slotName: req.slot, prompt: req.prompt, originalUserText: originalInput)
            result.triggerFollowUpCapture = true
        }

        applyCanvasPresentationPolicy(&result)
        applyResponsePolish(&result, plan: plan, hasMemoryHints: hasMemoryHints, turnIndex: turnIndex)
        applyFollowUpQuestionPolicy(&result, turnIndex: turnIndex)
        applyKnowledgeAttribution(&result,
                                  userInput: originalInput,
                                  provider: provider,
                                  localKnowledgeContext: localKnowledgeContext)
        await applyToolResultFeedbackLoop(
            &result,
            originalInput: originalInput,
            history: history,
            provider: provider,
            depth: feedbackDepth,
            turnStartedAt: turnStartedAt
        )
        rememberAssistantLines(result.appendedChat)
        return result
    }

    // MARK: - Helpers

    private func maybeRephraseRepeatedTalk(_ plan: Plan,
                                           userInput: String,
                                           history: [ChatMessage],
                                           provider: LLMProvider,
                                           turnStartedAt: Date) async -> Plan {
        guard elapsedMs(since: turnStartedAt) < maxRephraseBudgetMs else { return plan }
        guard let original = singleTalkLine(from: plan) else { return plan }
        guard isRepeatedAssistantLine(original, history: history) else { return plan }
        guard let rewritten = await requestRephrase(of: original, userInput: userInput, provider: provider) else {
            return plan
        }
        return Plan(steps: [.talk(say: rewritten)], say: plan.say)
    }

    private func requestRephrase(of line: String, userInput: String, provider: LLMProvider) async -> String? {
        let prompt = """
        Rephrase this assistant sentence to avoid repeating it verbatim.
        Keep the same meaning, tone, and length.
        Return TALK JSON only.
        User input: "\(userInput)"
        Original assistant sentence: "\(line)"
        """

        switch provider {
        case .openai:
            do {
                let plan = try await withTimeout(0.9) {
                    try await self.openAIRouter.routePlan(prompt, history: [])
                }
                guard let rewritten = singleTalkLine(from: plan) else { return nil }
                if normalizeForComparison(rewritten) == normalizeForComparison(line) {
                    return nil
                }
                return rewritten
            } catch {
                return nil
            }
        case .ollama:
            do {
                let plan = try await withTimeout(0.8) {
                    try await self.ollamaRouter.routePlan(prompt, history: [])
                }
                guard let rewritten = singleTalkLine(from: plan) else { return nil }
                if normalizeForComparison(rewritten) == normalizeForComparison(line) {
                    return nil
                }
                return rewritten
            } catch {
                return nil
            }
        case .none:
            return nil
        }
    }

    private func singleTalkLine(from plan: Plan) -> String? {
        guard plan.steps.count == 1 else { return nil }
        guard case .talk(let say) = plan.steps[0] else { return nil }
        return say
    }

    private func isRepeatedAssistantLine(_ line: String, history: [ChatMessage]) -> Bool {
        let normalized = normalizeForComparison(line)
        guard !normalized.isEmpty else { return false }

        let recentHistory = history.filter { $0.role == .assistant }.suffix(3).map(\.text)
        let candidates = recentHistory + Array(recentAssistantLines.suffix(3))
        for candidate in candidates {
            let other = normalizeForComparison(candidate)
            guard !other.isEmpty else { continue }
            if normalized == other { return true }
            if isNearDuplicate(normalized, other) { return true }
        }
        return false
    }

    private func normalizeForComparison(_ text: String) -> String {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.joined(separator: " ")
    }

    private func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let maxLen = max(a.count, b.count)
        guard maxLen >= 8 else { return false }
        let distance = levenshteinDistance(a, b)
        let similarity = 1.0 - (Double(distance) / Double(maxLen))
        return similarity >= 0.90
    }

    private func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var previous = Array(0...b.count)
        for (i, charA) in a.enumerated() {
            var current = [i + 1]
            for (j, charB) in b.enumerated() {
                let insertCost = current[j] + 1
                let deleteCost = previous[j + 1] + 1
                let replaceCost = previous[j] + (charA == charB ? 0 : 1)
                current.append(min(insertCost, deleteCost, replaceCost))
            }
            previous = current
        }
        return previous[b.count]
    }

    private func applyCanvasPresentationPolicy(_ result: inout TurnResult) {
        // Answer shaping safety net: dense/structured TALK becomes short spoken summary + detailed canvas content.
        if result.appendedOutputs.isEmpty,
           !result.triggerFollowUpCapture {
            let assistantIndices = result.appendedChat.indices.filter { result.appendedChat[$0].role == .assistant }
            if assistantIndices.count == 1 {
                let idx = assistantIndices[0]
                let message = result.appendedChat[idx]
                if shouldUseVisualDetail(for: message.text) {
                    result.appendedOutputs.append(OutputItem(kind: .markdown, payload: message.text))
                    let confirmation = nextCanvasConfirmation()
                    result.appendedChat[idx] = ChatMessage(
                        id: message.id,
                        ts: message.ts,
                        role: .assistant,
                        text: confirmation,
                        llmProvider: message.llmProvider,
                        usedMemory: message.usedMemory,
                        usedLocalKnowledge: message.usedLocalKnowledge
                    )
                    result.spokenLines = [confirmation]
                }
            }
        }

        // Silent tools can produce canvas output without chat; add a short confirmation bubble.
        let hasAssistantChat = result.appendedChat.contains { $0.role == .assistant }
        if !result.appendedOutputs.isEmpty && !hasAssistantChat && !result.triggerFollowUpCapture {
            let confirmation = nextCanvasConfirmation()
            result.appendedChat.append(ChatMessage(role: .assistant, text: confirmation, llmProvider: result.llmProvider))
            result.spokenLines.append(confirmation)
        }
    }

    private func shouldUseVisualDetail(for text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count > 200 { return true }
        if trimmed.contains("```") { return true } // markdown block

        let lines = trimmed.components(separatedBy: .newlines)
        return lines.contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("# ") ||
                line.hasPrefix("## ") ||
                line.hasPrefix("### ") ||
                line.hasPrefix("- ") ||
                line.hasPrefix("* ") ||
                Self.isNumberedListLine(line)
        }
    }

    private static func isNumberedListLine(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: line.utf16.count)
        return numberedListRegex.firstMatch(in: line, options: [], range: range) != nil
    }

    private func nextCanvasConfirmation() -> String {
        guard !canvasConfirmations.isEmpty else { return "Done." }
        let value = canvasConfirmations[canvasConfirmationIndex % canvasConfirmations.count]
        canvasConfirmationIndex = (canvasConfirmationIndex + 1) % canvasConfirmations.count
        return value
    }

    private func rememberAssistantLines(_ messages: [ChatMessage]) {
        for message in messages where message.role == .assistant {
            recentAssistantLines.append(message.text)
        }
        if recentAssistantLines.count > 3 {
            recentAssistantLines.removeFirst(recentAssistantLines.count - 3)
        }
    }

    private func applyToolResultFeedbackLoop(_ result: inout TurnResult,
                                             originalInput: String,
                                             history: [ChatMessage],
                                             provider: LLMProvider,
                                             depth: Int,
                                             turnStartedAt: Date) async {
        guard depth < toolFeedbackLoopMaxDepth else { return }
        guard elapsedMs(since: turnStartedAt) < maxToolFeedbackBudgetMs else { return }
        guard shouldRunToolFeedbackLoop(result) else { return }
        guard let synthesized = await synthesizeToolAwareAnswer(
            from: result,
            originalInput: originalInput,
            history: history,
            provider: provider
        ) else { return }

        let normalizedSynthesized = normalizeForComparison(synthesized)
        let existing = result.appendedChat
            .filter { $0.role == .assistant }
            .map(\.text)
            .map(normalizeForComparison)
        guard !existing.contains(normalizedSynthesized) else { return }

        let line = synthesized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        result.appendedChat.append(ChatMessage(role: .assistant, text: line, llmProvider: provider))
        result.spokenLines.append(line)
    }

    private func shouldRunToolFeedbackLoop(_ result: TurnResult) -> Bool {
        guard !result.executedToolSteps.isEmpty else { return false }
        guard !result.triggerFollowUpCapture else { return false }
        guard !result.appendedOutputs.isEmpty else { return false }

        let assistantLines = result.appendedChat
            .filter { $0.role == .assistant }
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard assistantLines.isEmpty else { return false }
        return true
    }

    private func synthesizeToolAwareAnswer(from result: TurnResult,
                                           originalInput: String,
                                           history: [ChatMessage],
                                           provider: LLMProvider) async -> String? {
        let toolLines = result.executedToolSteps.map { step in
            let argsPreview = step.args
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            return "- \(step.name)(\(argsPreview))"
        }.joined(separator: "\n")

        let outputLines = result.appendedOutputs.enumerated().map { index, item in
            let clipped = item.payload.replacingOccurrences(of: "\n", with: " ")
            let preview = clipped.count > 220 ? String(clipped.prefix(217)) + "..." : clipped
            return "- output[\(index + 1)] kind=\(item.kind.rawValue): \(preview)"
        }.joined(separator: "\n")

        let synthesisPrompt = """
        [TOOL_RESULT_FEEDBACK]
        User request: \(originalInput)
        Executed tools:
        \(toolLines.isEmpty ? "- (none)" : toolLines)
        Tool outputs:
        \(outputLines.isEmpty ? "- (none)" : outputLines)

        Write one concise final answer for the user using the tool results above.
        Return TALK JSON only. Do NOT call tools.
        """

        let plan: Plan?
        switch provider {
        case .openai:
            plan = try? await withTimeout(0.9) {
                try await self.openAIRouter.routePlan(synthesisPrompt, history: history)
            }
        case .ollama:
            plan = try? await withTimeout(0.8) {
                try await self.ollamaRouter.routePlan(synthesisPrompt, history: history)
            }
        case .none:
            plan = nil
        }

        guard let plan else { return nil }
        return talkOnlyLine(from: plan)
    }

    private func talkOnlyLine(from plan: Plan) -> String? {
        if plan.steps.count == 1, case .talk(let say) = plan.steps[0] {
            return say.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let talkLines = plan.steps.compactMap { step -> String? in
            guard case .talk(let say) = step else { return nil }
            return say.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        guard talkLines.count == 1 else { return nil }
        return talkLines[0]
    }

    private func applyResponsePolish(_ result: inout TurnResult, plan: Plan, hasMemoryHints: Bool, turnIndex: Int) {
        guard !result.appendedChat.isEmpty else { return }

        let shouldModulateConfidence = isTalkOnlyPlan(plan)
        let assistantIndices = result.appendedChat.indices.filter { result.appendedChat[$0].role == .assistant }

        for idx in assistantIndices {
            let original = result.appendedChat[idx]
            var updatedText = ResponsePolish.stripQuickDetailedPrompt(from: original.text)

            if shouldModulateConfidence {
                updatedText = ResponsePolish.applyConfidenceModulation(to: updatedText)
            }

            if ResponsePolish.containsMemoryAcknowledgement(updatedText) {
                let onCooldown = isMemoryAckOnCooldown(turnIndex)
                if !hasMemoryHints || onCooldown {
                    updatedText = ResponsePolish.stripLeadingMemoryAcknowledgement(from: updatedText)
                } else {
                    lastMemoryAckTurn = turnIndex
                }
            }

            if updatedText != original.text {
                result.appendedChat[idx] = ChatMessage(
                    id: original.id,
                    ts: original.ts,
                    role: original.role,
                    text: updatedText,
                    llmProvider: original.llmProvider,
                    isEphemeral: original.isEphemeral,
                    usedMemory: original.usedMemory,
                    usedLocalKnowledge: original.usedLocalKnowledge
                )
                if let spokenIdx = result.spokenLines.firstIndex(of: original.text) {
                    result.spokenLines[spokenIdx] = updatedText
                }
            }
        }
    }

    private func isMemoryAckOnCooldown(_ turnIndex: Int) -> Bool {
        guard let last = lastMemoryAckTurn else { return false }
        return (turnIndex - last) <= memoryAckCooldownTurns
    }

    private func isTalkOnlyPlan(_ plan: Plan) -> Bool {
        guard plan.steps.count == 1 else { return false }
        if case .talk = plan.steps[0] { return true }
        return false
    }

    private func applyFollowUpQuestionPolicy(_ result: inout TurnResult, turnIndex: Int) {
        guard !result.triggerFollowUpCapture else { return } // pending slots/asks are separate flows
        guard !isFollowUpQuestionOnCooldown(turnIndex) else { return }

        guard let idx = result.appendedChat.lastIndex(where: { $0.role == .assistant }) else { return }
        let original = result.appendedChat[idx]
        let trimmed = original.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return }
        guard !trimmed.contains("?") else { return } // don't stack questions
        guard let lastChar = trimmed.last, ".!".contains(lastChar) else { return }
        guard trimmed.count >= 30 else { return } // keep short replies snappy
        guard trimmed.count <= 240 else { return } // long answers should not add follow-up chatter

        let followUp = nextFollowUpQuestion()
        let combined = combineAnswer(trimmed, withFollowUp: followUp)
        guard isSingleTrailingQuestion(combined) else { return }

        result.appendedChat[idx] = ChatMessage(
            id: original.id,
            ts: original.ts,
            role: original.role,
            text: combined,
            llmProvider: original.llmProvider,
            isEphemeral: original.isEphemeral,
            usedMemory: original.usedMemory,
            usedLocalKnowledge: original.usedLocalKnowledge
        )

        if let spokenIdx = result.spokenLines.firstIndex(of: original.text) {
            result.spokenLines[spokenIdx] = combined
        } else {
            result.spokenLines.append(combined)
        }

        result.triggerQuestionAutoListen = true
        lastFollowUpTurn = turnIndex
    }

    private func combineAnswer(_ answer: String, withFollowUp followUp: String) -> String {
        let needsSpacer = !(answer.hasSuffix(" ") || answer.hasSuffix("\n"))
        return needsSpacer ? "\(answer) \(followUp)" : "\(answer)\(followUp)"
    }

    private func nextFollowUpQuestion() -> String {
        guard !followUpQuestions.isEmpty else { return "Want more detail?" }
        let value = followUpQuestions[followUpQuestionIndex % followUpQuestions.count]
        followUpQuestionIndex = (followUpQuestionIndex + 1) % followUpQuestions.count
        return value
    }

    private func isFollowUpQuestionOnCooldown(_ turnIndex: Int) -> Bool {
        guard let last = lastFollowUpTurn else { return false }
        return (turnIndex - last) < followUpCooldownTurns
    }

    private func isSingleTrailingQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?") else { return false }
        return trimmed.filter { $0 == "?" }.count == 1
    }

    private func applyKnowledgeAttribution(_ result: inout TurnResult,
                                           userInput: String,
                                           provider: LLMProvider,
                                           localKnowledgeContext: LocalKnowledgeContext) {
        guard let assistantText = result.appendedChat.last(where: { $0.role == .assistant })?.text else {
            return
        }

        let attribution = KnowledgeAttributionScorer.score(
            userInput: userInput,
            assistantText: assistantText,
            provider: provider,
            localSnippets: localKnowledgeContext.items
        )
        result.knowledgeAttribution = attribution

        guard attribution.usedLocalKnowledge else { return }
        for idx in result.appendedChat.indices where result.appendedChat[idx].role == .assistant {
            result.appendedChat[idx].usedLocalKnowledge = true
        }
    }

    private func buildLocalKnowledgeContext(for input: String) -> LocalKnowledgeContext {
        let memoryRows = fastMemoryHints(for: input, maxItems: 4, maxChars: 500)
        let memoryItems = memoryRows.map { row in
            KnowledgeSourceSnippet(
                kind: .memory,
                id: row.shortID,
                label: "Memory (\(row.type.rawValue))",
                text: row.content,
                url: nil
            )
        }
        return LocalKnowledgeContext(items: dedupeKnowledgeSnippets(memoryItems))
    }

    private func fastMemoryHints(for query: String, maxItems: Int, maxChars: Int) -> [MemoryRow] {
        MemoryStore.shared.memoryContext(
            query: query,
            maxItems: max(1, maxItems),
            maxChars: max(120, maxChars)
        )
    }

    private func relevantWebsiteKnowledgeSnippets(query: String, maxItems: Int) -> [KnowledgeSourceSnippet] {
        let records = WebsiteLearningStore.shared.allRecords()
        guard !records.isEmpty else { return [] }
        let ranked = LocalKnowledgeRetriever.rank(
            query: query,
            items: records,
            text: { record in
                "\(record.title) \(record.summary) \(record.highlights.joined(separator: " ")) \(record.host)"
            },
            recencyDate: { $0.updatedAt },
            extraBoost: { record in
                min(0.08, Double(record.highlights.count) * 0.02)
            },
            limit: max(1, maxItems * 4),
            minScore: 0.08
        )

        var selected: [KnowledgeSourceSnippet] = []
        for entry in ranked {
            let record = entry.item
            guard selected.count < max(1, maxItems) else { break }
            selected.append(
                KnowledgeSourceSnippet(
                    kind: .website,
                    id: String(record.id.uuidString.prefix(8)).lowercased(),
                    label: record.title,
                    text: record.summary,
                    url: record.url
                )
            )
        }

        return selected
    }

    private func relevantSelfLearningSnippets(query: String, maxItems: Int, maxChars: Int) -> [KnowledgeSourceSnippet] {
        let lessons = SelfLearningStore.shared.allLessons()
        guard !lessons.isEmpty else { return [] }
        let ranked = LocalKnowledgeRetriever.rank(
            query: query,
            items: lessons,
            text: { "[\($0.category.rawValue)] \($0.text)" },
            recencyDate: { $0.lastUpdatedAt },
            extraBoost: { lesson in
                let confidence = lesson.confidence * 0.20
                let observedBoost = min(0.14, log2(Double(max(1, lesson.observedCount)) + 1.0) * 0.05)
                let appliedBoost = min(0.10, log2(Double(max(1, lesson.appliedCount)) + 1.0) * 0.04)
                return confidence + observedBoost + appliedBoost
            },
            limit: max(1, maxItems * 4),
            minScore: 0.08
        )

        var items: [KnowledgeSourceSnippet] = []
        var usedChars = 0
        let cappedItems = max(1, maxItems)

        for entry in ranked {
            let lesson = entry.item
            guard items.count < cappedItems else { break }
            let line = String(lesson.text.prefix(220)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let nextChars = usedChars + line.count
            if !items.isEmpty && nextChars > maxChars { break }
            if items.isEmpty && line.count > maxChars { continue }
            items.append(
                KnowledgeSourceSnippet(
                    kind: .selfLearning,
                    id: String(lesson.id.uuidString.prefix(8)).lowercased(),
                    label: "Lesson (\(lesson.category.rawValue))",
                    text: line,
                    url: nil
                )
            )
            usedChars = nextChars
        }

        return items
    }

    private func dedupeKnowledgeSnippets(_ snippets: [KnowledgeSourceSnippet]) -> [KnowledgeSourceSnippet] {
        var seen: Set<String> = []
        var output: [KnowledgeSourceSnippet] = []
        for snippet in snippets {
            let trimmed = snippet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = "\(snippet.kind.rawValue)|\(snippet.id ?? "")|\(snippet.url ?? "")|\(trimmed.lowercased())"
            if seen.contains(key) { continue }
            seen.insert(key)
            output.append(
                KnowledgeSourceSnippet(
                    kind: snippet.kind,
                    id: snippet.id,
                    label: snippet.label,
                    text: trimmed,
                    url: snippet.url
                )
            )
        }
        return output
    }

    private func routerLog(provider: String, reason: String, ms: Int, ok: Bool) {
        #if DEBUG
        print("[ROUTER] provider=\(provider) reason=\(reason) ms=\(ms) ok=\(ok)")
        #endif
    }

    private func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private func normalizedSlotSet(from raw: String) -> Set<String> {
        let values = raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return Set(values)
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

extension TurnOrchestrator: TurnOrchestrating {}

struct TTSPacing {
    let preSpeakDelayMs: Int
    let ttsText: String

    var preSpeakDelayNs: UInt64 {
        UInt64(max(0, preSpeakDelayMs)) * 1_000_000
    }
}

enum ResponsePolish {

    private static let uncertaintyMarkers: [String] = [
        "i think", "maybe", "not sure", "likely", "might", "could be", "approximately",
        "can't confirm", "cannot confirm", "i don't have access", "unknown"
    ]

    private static let strongHedges: [String] = [
        "i'm not 100% sure", "i am not 100% sure", "not sure", "maybe", "i think"
    ]

    private static let memoryAckMarkers: [String] = [
        "i remember you mentioned", "i remember you said", "if i'm remembering right",
        "if i’m remembering right", "i recall you mentioned", "as you mentioned earlier",
        "you mentioned earlier"
    ]

    static func applyConfidenceModulation(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard isUncertain(trimmed) else { return text }
        guard !isStronglyHedged(trimmed) else { return text }
        guard !trimmed.lowercased().contains("double-check") else { return text }
        return "\(trimmed) (If you want, I can double-check.)"
    }

    static func ttsPacing(for text: String, mode: SpeechMode) -> TTSPacing {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, mode == .answer else {
            return TTSPacing(preSpeakDelayMs: 0, ttsText: trimmed)
        }

        let longResponse = trimmed.count > 120 || sentenceCount(in: trimmed) >= 3
        guard longResponse else {
            return TTSPacing(preSpeakDelayMs: 0, ttsText: trimmed)
        }

        return TTSPacing(preSpeakDelayMs: 250, ttsText: addSentencePauses(to: trimmed))
    }

    static func containsMemoryAcknowledgement(_ text: String) -> Bool {
        let firstSentence = leadingSentence(text).lowercased()
        return memoryAckMarkers.contains { firstSentence.contains($0) }
    }

    static func stripLeadingMemoryAcknowledgement(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsMemoryAcknowledgement(trimmed) else { return trimmed }

        if let punctuationRange = trimmed.range(of: #"[.!?]\s+"#, options: .regularExpression) {
            let remainder = String(trimmed[punctuationRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? trimmed : remainder
        }
        return trimmed
    }

    static func stripQuickDetailedPrompt(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let patterns = [
            #"\s*want\s+the\s+quick\s+version\s+or\s+more\s+detail\??\s*$"#,
            #"\s*want\s+me\s+to\s+keep\s+it\s+brief\s+or\s+expand\??\s*$"#,
            #"\s*quick\s+version\s+or\s+detailed?\s+version\??\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            let stripped = regex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped != trimmed {
                return stripped
            }
        }
        return trimmed
    }

    private static func isUncertain(_ text: String) -> Bool {
        let lower = text.lowercased()
        return uncertaintyMarkers.contains { lower.contains($0) }
    }

    private static func isStronglyHedged(_ text: String) -> Bool {
        let lower = text.lowercased()
        return strongHedges.contains { lower.contains($0) }
    }

    private static func leadingSentence(_ text: String) -> String {
        if let punctuationRange = text.range(of: #"[.!?]\s+"#, options: .regularExpression) {
            return String(text[..<punctuationRange.lowerBound])
        }
        return text
    }

    private static func sentenceCount(in text: String) -> Int {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.count
    }

    private static func addSentencePauses(to text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"([.!?])\s+"#, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1\n")
    }
}
