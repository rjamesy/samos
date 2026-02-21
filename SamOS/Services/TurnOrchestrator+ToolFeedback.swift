import Foundation

// MARK: - Tool Result Feedback Loop & Coverage

extension TurnOrchestrator {

    func applyToolResultFeedbackLoop(_ result: inout TurnResult,
                                             originalInput: String,
                                             history: [ChatMessage],
                                             provider: LLMProvider,
                                             aiModelUsed: String?,
                                             force: Bool,
                                             allowFeedback: Bool,
                                             depth: Int,
                                             turnStartedAt: Date) async {
        guard depth < toolFeedbackLoopMaxDepth else { return }

        var loopDepth = depth
        var seenPlanFingerprints: Set<String> = []
        var pendingCoverageTokens = force ? requiredCoverageTokens(for: originalInput) : []
        var deferredTalkLine: String?
        var committedTalk = false

        while loopDepth < toolFeedbackLoopMaxDepth {
            guard elapsedMs(since: turnStartedAt) < maxToolFeedbackBudgetMs else { break }
            guard shouldRunToolFeedbackLoop(result, force: force, allowFeedback: allowFeedback) else { break }
            guard let feedbackPlan = await synthesizeToolAwarePlan(
                from: result,
                originalInput: originalInput,
                history: history,
                provider: provider,
                aiModelUsed: aiModelUsed,
                requiredCoverageTokens: pendingCoverageTokens
            ) else { break }

            let fingerprint = feedbackPlanFingerprint(feedbackPlan)
            guard seenPlanFingerprints.insert(fingerprint).inserted else { break }

            if let talk = talkOnlyLine(from: feedbackPlan) {
                if force, !pendingCoverageTokens.isEmpty {
                    let missing = missingCoverageTokens(in: talk, required: pendingCoverageTokens)
                    if !missing.isEmpty {
                        deferredTalkLine = deferredTalkLine ?? talk
                        pendingCoverageTokens = missing
                        loopDepth += 1
                        continue
                    }
                }
                upsertToolFeedbackTalkLine(talk, result: &result, provider: provider)
                committedTalk = true
                break
            }

            let hasToolStep = feedbackPlan.steps.contains { step in
                if case .tool = step { return true }
                return false
            }
            guard hasToolStep else { break }

            let exec = await toolRunner.executePlan(
                feedbackPlan,
                originalInput: originalInput,
                pendingSlotName: pendingSlot?.slotName
            )

            mergeToolFeedbackExecution(exec, into: &result, provider: provider, originalInput: originalInput)
            if result.triggerFollowUpCapture {
                break
            }
            loopDepth += 1
        }

        if force,
           !committedTalk,
           pendingCoverageTokens.isEmpty,
           let deferredTalkLine {
            upsertToolFeedbackTalkLine(deferredTalkLine, result: &result, provider: provider)
        }
    }

    func shouldRunToolFeedbackLoop(_ result: TurnResult, force: Bool, allowFeedback: Bool) -> Bool {
        guard allowFeedback || force else { return false }
        guard !result.executedToolSteps.isEmpty else { return false }
        guard !result.triggerFollowUpCapture else { return false }
        guard !result.appendedOutputs.isEmpty else { return false }
        guard !containsToolErrorOutput(result) else { return false }

        let assistantLines = result.appendedChat
            .filter { $0.role == .assistant }
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if force { return true }
        if assistantLines.isEmpty { return true }
        return assistantLines.allSatisfy(isLikelyCanvasConfirmation)
    }

    func shouldForceToolFeedback(for userInput: String, plan: Plan) -> Bool {
        let hasOnlyToolSteps = !plan.steps.isEmpty && plan.steps.allSatisfy { step in
            if case .tool = step { return true }
            return false
        }
        guard hasOnlyToolSteps else { return false }
        if plan.steps.count > 1 { return true }
        return isMultiClauseRequest(userInput)
    }

    func shouldAllowToolFeedback(for plan: Plan) -> Bool {
        let allowlist: Set<String> = ["get_weather", "get_time", "find_files", "learn_website"]
        for step in plan.steps {
            guard case .tool(let name, let args, _) = step else { continue }
            if allowlist.contains(name) { return true }
            if let marker = args["needs_reasoning"]?.stringValue.lowercased(),
               marker == "true" || marker == "1" || marker == "yes" {
                return true
            }
        }
        return false
    }

    func containsToolErrorOutput(_ result: TurnResult) -> Bool {
        result.appendedOutputs.contains { output in
            let lower = output.payload.lowercased()
            if lower.contains("\"kind\":\"error\"") { return true }
            if lower.hasPrefix("error:") { return true }
            if lower.contains("i couldn't") { return true }
            return false
        }
    }

    func shouldNarrateToolProgress(for userInput: String, plan: Plan) -> Bool {
        let toolSteps = plan.steps.filter { step in
            if case .tool = step { return true }
            return false
        }
        guard !toolSteps.isEmpty else { return false }
        guard !plan.steps.contains(where: {
            if case .ask = $0 { return true }
            return false
        }) else {
            return false
        }
        if toolSteps.count > 1 { return true }
        return shouldForceToolFeedback(for: userInput, plan: plan)
    }

    func isMultiClauseRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [" then ", " and ", " also ", " after ", " while ", " if ", ", then ", ";"]
        if markers.contains(where: { lower.contains($0) }) { return true }
        let questionCount = lower.filter { $0 == "?" }.count
        if questionCount > 1 { return true }
        return lower.count > 80
    }

    func toolProgressLines(from plan: Plan) -> [String] {
        var lines: [String] = []
        var seen: Set<String> = []
        for step in plan.steps {
            if case .tool(_, _, let say) = step,
               let line = say?.trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                let normalized = normalizeForComparison(line)
                guard !normalized.isEmpty else { continue }
                if seen.insert(normalized).inserted {
                    lines.append(line)
                }
            }
        }
        return lines
    }

    func prependAssistantProgressLines(_ lines: [String],
                                               into result: inout TurnResult,
                                               provider: LLMProvider) {
        guard !lines.isEmpty else { return }

        for line in lines.reversed() {
            let normalized = normalizeForComparison(line)
            guard !normalized.isEmpty else { continue }
            if result.appendedChat.contains(where: { $0.role == .assistant && normalizeForComparison($0.text) == normalized }) {
                continue
            }
            let progress = ChatMessage(role: .assistant, text: line, llmProvider: provider)
            result.appendedChat.insert(progress, at: 0)
            result.spokenLines.insert(line, at: 0)
        }
    }

    func isLikelyCanvasConfirmation(_ text: String) -> Bool {
        let normalized = normalizeForComparison(text)
        guard !normalized.isEmpty else { return false }

        let canned = canvasConfirmations.map(normalizeForComparison)
        if canned.contains(normalized) { return true }

        let genericStarts = [
            "here you go",
            "done",
            "i ve put the details up here",
            "i ve laid this out on screen",
            "i ll find",
            "i ll check",
            "i ll look"
        ]
        if genericStarts.contains(where: { normalized.hasPrefix($0) }) && normalized.count <= 80 {
            return true
        }
        return false
    }

    func synthesizeToolAwarePlan(from result: TurnResult,
                                         originalInput: String,
                                         history: [ChatMessage],
                                         provider: LLMProvider,
                                         aiModelUsed: String?,
                                         requiredCoverageTokens: [String]) async -> Plan? {
        let toolLines = result.executedToolSteps.map { step in
            let argsPreview = step.args
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            return "- \(step.name)(\(argsPreview))"
        }.joined(separator: "\n")

        let outputLines = result.appendedOutputs.enumerated().map { index, item in
            let clipped = item.payload.replacingOccurrences(of: "\n", with: " ")
            let preview = clipped.count > 460 ? String(clipped.prefix(457)) + "..." : clipped
            return "- output[\(index + 1)] kind=\(item.kind.rawValue): \(preview)"
        }.joined(separator: "\n")

        let assistantLines = result.appendedChat
            .filter { $0.role == .assistant }
            .map { "- \($0.text.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")

        let coverageGuidance: String
        if requiredCoverageTokens.isEmpty {
            coverageGuidance = "- (none)"
        } else {
            let joined = requiredCoverageTokens.joined(separator: ", ")
            coverageGuidance = """
            - This is a multi-part user request.
            - Final TALK must explicitly address these entities/topics: \(joined)
            - If current tool outputs are insufficient to address all required topics, run another concrete tool step first.
            """
        }

        let synthesisPrompt = """
        [TOOL_RESULT_FEEDBACK]
        User request: \(originalInput)
        Executed tools:
        \(toolLines.isEmpty ? "- (none)" : toolLines)
        Tool outputs:
        \(outputLines.isEmpty ? "- (none)" : outputLines)
        Current assistant lines:
        \(assistantLines.isEmpty ? "- (none)" : assistantLines)

        Decide the best next action using the tool results above.
        Coverage requirements:
        \(coverageGuidance)
        - If there is enough information, return TALK with one concise final answer.
        - If one more tool call is required, return a PLAN with concrete tool step(s).
        - For comparative or decision-style user requests, provide an explicit recommendation or judgment.
        - Do NOT repeat an identical tool call that already ran with the same args.
        - Never return CAPABILITY_GAP in this feedback pass.
        Output valid JSON only.
        """

        let plan: Plan?
        switch provider {
        case .openai:
            let openAIPlan = try? await withTimeout(toolFeedbackTimeoutSeconds(requiredCoverageTokens: requiredCoverageTokens)) {
                try await self.openAIRouter.routePlan(
                    synthesisPrompt,
                    history: history,
                    modelOverride: aiModelUsed,
                    reason: .polish
                )
            }
            if let openAIPlan {
                plan = openAIPlan
                break
            }
            if M2Settings.useOllama {
                plan = try? await withTimeout(ollamaToolFeedbackTimeoutSeconds) {
                    try await self.ollamaRouter.routePlan(synthesisPrompt, history: history)
                }
            } else {
                plan = nil
            }
        case .ollama:
            plan = try? await withTimeout(ollamaToolFeedbackTimeoutSeconds) {
                try await self.ollamaRouter.routePlan(synthesisPrompt, history: history)
            }
        case .none:
            if M2Settings.useOllama {
                plan = try? await withTimeout(ollamaToolFeedbackTimeoutSeconds) {
                    try await self.ollamaRouter.routePlan(synthesisPrompt, history: history)
                }
            } else {
                plan = nil
            }
        }

        return plan
    }

    func toolFeedbackTimeoutSeconds(requiredCoverageTokens: [String]) -> Double {
        if !requiredCoverageTokens.isEmpty {
            return openAIToolFeedbackTimeoutSeconds
        }
        return 1.2
    }

    func feedbackPlanFingerprint(_ plan: Plan) -> String {
        plan.steps.map { step in
            switch step {
            case .talk(let say):
                return "talk:\(normalizeForComparison(say))"
            case .ask(let slot, let prompt):
                return "ask:\(slot.lowercased()):\(normalizeForComparison(prompt))"
            case .delegate(let task, let context, let say):
                return "delegate:\(normalizeForComparison(task)):\(normalizeForComparison(context ?? "")):\(normalizeForComparison(say ?? ""))"
            case .tool(let name, let args, let say):
                let orderedArgs = args
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value.stringValue)" }
                    .joined(separator: ",")
                return "tool:\(name.lowercased()){\(orderedArgs)}:\(normalizeForComparison(say ?? ""))"
            }
        }.joined(separator: "|")
    }

    func mergeToolFeedbackExecution(_ exec: PlanExecutionResult,
                                            into result: inout TurnResult,
                                            provider: LLMProvider,
                                            originalInput: String) {
        let stampedChat = exec.chatMessages.map { msg -> ChatMessage in
            guard msg.role == .assistant else { return msg }
            var stamped = msg
            stamped.llmProvider = provider
            stamped.originProvider = result.originProvider
            stamped.executionProvider = result.executionProvider
            stamped.originReason = result.originReason
            return stamped
        }
        result.appendedChat.append(contentsOf: stampedChat)
        result.spokenLines.append(contentsOf: exec.spokenLines)
        result.appendedOutputs.append(contentsOf: exec.outputItems)
        result.executedToolSteps.append(contentsOf: exec.executedToolSteps)
        result.toolMsTotal = (result.toolMsTotal ?? 0) + exec.toolMsTotal
        result.triggerFollowUpCapture = result.triggerFollowUpCapture || exec.triggerFollowUpCapture

        if let req = exec.pendingSlotRequest {
            pendingSlot = PendingSlot(slotName: req.slot, prompt: req.prompt, originalUserText: originalInput)
            result.triggerFollowUpCapture = true
        }
    }

    func upsertToolFeedbackTalkLine(_ line: String,
                                            result: inout TurnResult,
                                            provider: LLMProvider) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalized = normalizeForComparison(trimmed)
        let assistantIndices = result.appendedChat.indices.filter { result.appendedChat[$0].role == .assistant }
        if assistantIndices.contains(where: { normalizeForComparison(result.appendedChat[$0].text) == normalized }) {
            return
        }

        if let lastIndex = assistantIndices.last,
           isLikelyCanvasConfirmation(result.appendedChat[lastIndex].text) {
            let prior = result.appendedChat[lastIndex].text
            result.appendedChat[lastIndex] = ChatMessage(
                id: result.appendedChat[lastIndex].id,
                ts: result.appendedChat[lastIndex].ts,
                role: .assistant,
                text: trimmed,
                llmProvider: provider,
                isEphemeral: result.appendedChat[lastIndex].isEphemeral,
                usedMemory: result.appendedChat[lastIndex].usedMemory,
                usedLocalKnowledge: result.appendedChat[lastIndex].usedLocalKnowledge
            )
            if let spokenIndex = result.spokenLines.lastIndex(of: prior) {
                result.spokenLines[spokenIndex] = trimmed
            } else {
                result.spokenLines.append(trimmed)
            }
            return
        }

        result.appendedChat.append(ChatMessage(role: .assistant, text: trimmed, llmProvider: provider))
        result.spokenLines.append(trimmed)
    }

    func talkOnlyLine(from plan: Plan) -> String? {
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

    func requiredCoverageTokens(for userInput: String) -> [String] {
        let entities = capitalizedEntityTokens(in: userInput)
        if entities.count >= 2 {
            return Array(entities.prefix(4))
        }

        let lower = userInput.lowercased()
        let markers = [" then ", " and ", " also ", " after ", " while ", " if ", ", then ", ";"]
        let tail: String
        if let range = markers
            .compactMap({ marker in lower.range(of: marker) })
            .min(by: { $0.lowerBound < $1.lowerBound }) {
            tail = String(lower[range.upperBound...])
        } else {
            tail = lower
        }

        let tailTokens = coverageTokens(from: tail)
            .filter { !Self.coverageStopwords.contains($0) }
            .filter { $0.count >= 4 }

        let merged = entities + tailTokens.filter { !entities.contains($0) }
        if !merged.isEmpty {
            return Array(merged.prefix(4))
        }
        return Array(tailTokens.prefix(2))
    }

    func missingCoverageTokens(in talk: String, required: [String]) -> [String] {
        let present = Set(coverageTokens(from: talk))
        return required.filter { !present.contains($0) }
    }

    func coverageTokens(from text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    func capitalizedEntityTokens(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = Self.coverageEntityRegex.matches(in: text, range: range)
        var output: [String] = []
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let token = text[matchRange].lowercased()
            guard !Self.coverageStopwords.contains(token) else { continue }
            if !output.contains(token) {
                output.append(token)
            }
        }
        return output
    }

}
