import Foundation

// MARK: - Image Auto-Repair, Identity Helpers & Vision Tool

extension TurnOrchestrator {

    // MARK: - Image Auto-Repair

    /// Retries the LLM once with repair context when image URLs fail the probe.
    /// Uses same provider logic as routePlan: OpenAI only when configured, Ollama only as standalone.
    func autoRepairImage(originalInput: String,
                                 history: [ChatMessage],
                                 failureReason: String,
                                 aiModelUsed: String?,
                                 localKnowledgeContext: LocalKnowledgeContext,
                                 hasMemoryHints: Bool,
                                 turnIndex: Int,
                                 feedbackDepth: Int,
                                 turnStartedAt: Date,
                                 originReason: String?) async -> TurnResult? {
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
                    try await self.openAIRouter.routePlan(
                        originalInput,
                        history: [],
                        repairReasons: repairReasons,
                        modelOverride: aiModelUsed,
                        reason: .rewrite
                    )
                }
                return await executeImageRepair(plan,
                                                originalInput: originalInput,
                                                history: history,
                                                provider: .openai,
                                                aiModelUsed: aiModelUsed,
                                                localKnowledgeContext: localKnowledgeContext,
                                                hasMemoryHints: hasMemoryHints,
                                                turnIndex: turnIndex,
                                                feedbackDepth: feedbackDepth,
                                                turnStartedAt: turnStartedAt,
                                                originReason: originReason ?? "openai_image_repair")
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
                                                aiModelUsed: nil,
                                                localKnowledgeContext: localKnowledgeContext,
                                                hasMemoryHints: hasMemoryHints,
                                                turnIndex: turnIndex,
                                                feedbackDepth: feedbackDepth,
                                                turnStartedAt: turnStartedAt,
                                                originReason: originReason ?? "ollama_image_repair")
            } catch {
                #if DEBUG
                print("[ROUTER] imageRepair ollama failed: \(error.localizedDescription)")
                #endif
            }
        }

        return nil
    }

    func executeImageRepair(_ plan: Plan,
                                    originalInput: String,
                                    history: [ChatMessage],
                                    provider: LLMProvider,
                                    aiModelUsed: String?,
                                    localKnowledgeContext: LocalKnowledgeContext,
                                    hasMemoryHints: Bool,
                                    turnIndex: Int,
                                    feedbackDepth: Int,
                                    turnStartedAt: Date,
                                    originReason: String?) async -> TurnResult? {
        let exec = await toolRunner.executePlan(plan, originalInput: originalInput, pendingSlotName: nil)

        // If the retry ALSO produced an image_url failure, give up
        if let req = exec.pendingSlotRequest, req.slot == "image_url" {
            #if DEBUG
            print("[TurnOrchestrator] Image auto-repair also failed — giving up")
            #endif
            var result = TurnResult()
            result.llmProvider = provider
            result.aiModelUsed = aiModelUsed
            result.originProvider = originProvider(for: provider)
            result.executionProvider = executionProvider(for: provider, hasToolExecution: false)
            result.originReason = originReason
            let msg = "I couldn't find a working image for that - sorry about that."
            result.appendedChat = [ChatMessage(
                role: .assistant,
                text: msg,
                llmProvider: provider,
                originProvider: result.originProvider,
                executionProvider: result.executionProvider,
                originReason: result.originReason
            )]
            result.spokenLines = [msg]
            return result
        }

        var result = TurnResult()
        result.llmProvider = provider
        result.aiModelUsed = aiModelUsed
        result.originProvider = originProvider(for: provider)
        result.executionProvider = executionProvider(for: provider, hasToolExecution: !exec.executedToolSteps.isEmpty)
        result.originReason = originReason
        result.appendedChat = exec.chatMessages.map { msg in
            if msg.role == .assistant {
                var stamped = msg
                stamped.llmProvider = provider
                stamped.originProvider = result.originProvider
                stamped.executionProvider = result.executionProvider
                stamped.originReason = result.originReason
                return stamped
            }
            return msg
        }
        result.spokenLines = exec.spokenLines
        result.appendedOutputs = exec.outputItems
        result.triggerFollowUpCapture = exec.triggerFollowUpCapture
        result.usedMemoryHints = hasMemoryHints && provider != .none

        if let req = exec.pendingSlotRequest {
            pendingSlot = PendingSlot(slotName: req.slot, prompt: req.prompt, originalUserText: originalInput)
            result.triggerFollowUpCapture = true
        }

        let shouldNarrateProgress = shouldNarrateToolProgress(for: originalInput, plan: plan)
        let forceToolFeedback = shouldForceToolFeedback(for: originalInput, plan: plan)
        if shouldNarrateProgress {
            prependAssistantProgressLines(toolProgressLines(from: plan), into: &result, provider: provider)
        }

        await applyToolResultFeedbackLoop(
            &result,
            originalInput: originalInput,
            history: history,
            provider: provider,
            aiModelUsed: aiModelUsed,
            force: forceToolFeedback,
            allowFeedback: shouldAllowToolFeedback(for: plan),
            depth: feedbackDepth,
            turnStartedAt: turnStartedAt
        )
        result.executionProvider = executionProvider(for: provider, hasToolExecution: !result.executedToolSteps.isEmpty)
        applyCanvasPresentationPolicy(&result)
        applyResponsePolish(&result, plan: plan, hasMemoryHints: hasMemoryHints, turnIndex: turnIndex)
        applyFollowUpQuestionPolicy(&result, turnIndex: turnIndex)
        if currentTurnCaptureAfterReplyHint, !result.triggerFollowUpCapture {
            result.triggerQuestionAutoListen = true
        }
        applyKnowledgeAttribution(&result,
                                  userInput: originalInput,
                                  provider: provider,
                                  aiModelUsed: aiModelUsed,
                                  localKnowledgeContext: localKnowledgeContext)
        applyRoutingAttribution(&result, planProvider: provider, planRouterMs: nil)
        applyOriginMetadata(&result)
        updateAssistantState(after: result, mode: ConversationModeClassifier.classify(originalInput))
        rememberAssistantLines(result.appendedChat)
        return result
    }

    func immediateIdentityTurnResult(for resolution: FaceIdentityConfirmationResolution) -> TurnResult {
        let message: String
        switch resolution {
        case .enrolled(_, let enrolledMessage):
            message = enrolledMessage
        case .declined(let declinedMessage):
            message = declinedMessage
        case .requestName(let requestMessage):
            message = requestMessage
        }

        return immediateTalkTurnResult(message: message)
    }

    func immediateTalkTurnResult(message: String) -> TurnResult {
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: message)]
        result.spokenLines = [message]
        applyRoutingAttribution(&result, planProvider: result.llmProvider, planRouterMs: result.routerMs)
        return result
    }

    func appendIdentityPromptIfNeeded(_ prompt: String?, to result: inout TurnResult) {
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return }
        guard !result.triggerFollowUpCapture else { return }

        let alreadyContainsIdentityPrompt = result.appendedChat.contains { message in
            guard message.role == .assistant else { return false }
            return isIdentityPromptLike(message.text)
        }
        if alreadyContainsIdentityPrompt {
            return
        }

        result.appendedChat.append(
            ChatMessage(
                role: .assistant,
                text: prompt,
                llmProvider: result.llmProvider,
                originProvider: result.originProvider,
                executionProvider: result.executionProvider,
                originReason: result.originReason
            )
        )
        result.spokenLines.append(prompt)
    }

    func isIdentityPromptLike(_ text: String) -> Bool {
        let normalized = normalizeForComparison(text)
        if normalized.contains("what s your name") || normalized.contains("what is your name") {
            return true
        }
        if normalized.contains("remember you") && normalized.contains("name") {
            return true
        }
        if normalized.contains("recognize you next time") {
            return true
        }
        return false
    }

    func logIdentityTurn(decision: IdentityTurnDecision,
                                 now: Date,
                                 provider: LLMProvider,
                                 routeReason: String,
                                 routerMs: Int?) {
        #if DEBUG
        let shouldPrompt = decision.shouldPromptIdentity ? "yes" : "no"
        let msLabel = routerMs.map(String.init) ?? "n/a"
        print(
            "[IDENTITY] before=\(decision.stateBefore.debugSummary(reference: now)) " +
            "after=\(decision.stateAfter.debugSummary(reference: now)) " +
            "recognition=\(decision.recognitionSummary) " +
            "shouldPromptIdentity=\(shouldPrompt) " +
            "promptReason=\(decision.promptReason) " +
            "provider=\(provider.rawValue) route_reason=\(routeReason) router_ms=\(msLabel)"
        )
        #endif
    }

    // MARK: - Helpers

    func shouldRunVisionToolFirst(for intent: VisionQueryIntent) -> Bool {
        guard isVisionToolingEnabled else { return false }
        if case .none = intent { return false }
        return true
    }

    var isVisionToolingEnabled: Bool {
        guard cameraVision.isRunning else { return false }
        guard cameraVision.health.isHealthy else { return false }
        return hasVisionToolsRegistered
    }

    var hasVisionToolsRegistered: Bool {
        let registry = ToolRegistry.shared
        return registry.get("describe_camera_view") != nil
            && registry.get("camera_visual_qa") != nil
            && registry.get("find_camera_objects") != nil
    }

    func hasRecentCameraFrame(within seconds: TimeInterval) -> Bool {
        guard let latestFrameAt = cameraVision.latestFrameAt else { return false }
        return Date().timeIntervalSince(latestFrameAt) <= seconds
    }

    func runVisionToolFirstTurn(intent: VisionQueryIntent,
                                        text: String,
                                        history: [ChatMessage],
                                        mode: ConversationMode,
                                        localKnowledgeContext: LocalKnowledgeContext,
                                        hasMemoryHints: Bool,
                                        turnIndex: Int,
                                        turnStartedAt: Date,
                                        identityDecision: IdentityTurnDecision,
                                        now: Date) async -> TurnResult {
        let plan = visionToolPlan(for: intent, preface: nil)
        lastFinalActionKind = inferredActionKind(for: plan)
        var result = await executePlan(
            plan,
            originalInput: text,
            history: history,
            provider: .none,
            aiModelUsed: nil,
            routerMs: 0,
            localKnowledgeContext: localKnowledgeContext,
            hasMemoryHints: hasMemoryHints,
            turnIndex: turnIndex,
            feedbackDepth: 0,
            turnStartedAt: turnStartedAt,
            mode: mode,
            affect: .neutral,
            originReason: "vision_tool_first"
        )
        ensureVisionAssistantSummary(intent: intent, result: &result)
        appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
        logIdentityTurn(
            decision: identityDecision,
            now: now,
            provider: .none,
            routeReason: "vision_tool_first",
            routerMs: 0
        )
        return result
    }

    func ensureVisionAssistantSummary(intent: VisionQueryIntent, result: inout TurnResult) {
        let assistantLines = result.appendedChat
            .filter { $0.role == .assistant }
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if assistantLines.contains(where: containsVisionSummaryPhrase) {
            return
        }

        let fallback = extractVisionSpokenSummary(from: result.appendedOutputs)
            ?? defaultVisionSpokenSummary(for: intent)
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !assistantLines.contains(trimmed) else { return }

        result.appendedChat.append(
            ChatMessage(
                role: .assistant,
                text: trimmed,
                llmProvider: result.llmProvider,
                originProvider: result.originProvider,
                executionProvider: result.executionProvider,
                originReason: result.originReason
            )
        )
        result.spokenLines.append(trimmed)
    }

    func containsVisionSummaryPhrase(_ text: String) -> Bool {
        let normalized = normalizeForComparison(text)
        if normalized.contains("what i can see") || normalized.contains("i can see") {
            return true
        }
        if normalized.contains("checked the camera") || normalized.contains("looked at the camera") {
            return true
        }
        return false
    }

    func extractVisionSpokenSummary(from outputs: [OutputItem]) -> String? {
        for output in outputs where output.kind == .markdown {
            guard let data = output.payload.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let spoken = dict["spoken"] as? String else {
                continue
            }
            let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    func defaultVisionSpokenSummary(for intent: VisionQueryIntent) -> String {
        switch intent {
        case .describe, .none:
            return "Here's what I can see right now."
        case .visualQA:
            return "I checked the camera and answered that."
        case .findObject:
            return "I checked the camera and found what I could."
        }
    }

    func visionToolPlan(for intent: VisionQueryIntent, preface: String?) -> Plan {
        let spokenPrefix = preface?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch intent {
        case .describe, .none:
            return Plan(
                steps: [.tool(name: "describe_camera_view", args: [:], say: nil)],
                say: spokenPrefix?.isEmpty == false ? spokenPrefix : nil
            )
        case .visualQA(let question):
            // Route complex visual questions to GPT vision instead of local-only Q&A
            let toolName = needsGPTVision(question) ? "camera_gpt_vision" : "camera_visual_qa"
            return Plan(
                steps: [.tool(name: toolName, args: ["question": .string(question)], say: nil)],
                say: spokenPrefix?.isEmpty == false ? spokenPrefix : nil
            )
        case .findObject(let query):
            return Plan(
                steps: [.tool(name: "find_camera_objects", args: ["query": .string(query)], say: nil)],
                say: spokenPrefix?.isEmpty == false ? spokenPrefix : nil
            )
        }
    }

    /// Returns true if the question requires GPT-5.2 vision (clothing, appearance, scene narrative, etc.)
    /// These questions can't be answered by local VNClassifyImageRequest labels alone.
    private func needsGPTVision(_ question: String) -> Bool {
        let lower = question.lowercased()
        let gptKeywords = [
            "wear", "wearing", "clothes", "clothing", "outfit", "shirt", "pants", "dress",
            "jacket", "hoodie", "shoes", "hat", "glasses", "accessories",
            "look like", "looks like", "appearance", "describe",
            "doing", "activity", "happening", "scene",
            "holding", "carrying",
            "color of", "colour of",
            "hair", "beard", "tattoo",
            "brand", "logo",
            "how old", "age",
            "expression", "emotion", "feeling", "mood",
            "posture", "gesture", "sitting", "standing"
        ]
        return gptKeywords.contains { lower.contains($0) }
    }

}
