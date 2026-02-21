import Foundation

// MARK: - Recipe Tool, Capability Requests & Enrollment

extension TurnOrchestrator {

    func runRecipeToolFirstTurnIfNeeded(text: String,
                                                intent: RoutedIntent,
                                                history: [ChatMessage],
                                                mode: ConversationMode,
                                                localKnowledgeContext: LocalKnowledgeContext,
                                                hasMemoryHints: Bool,
                                                turnIndex: Int,
                                                turnStartedAt: Date,
                                                identityDecision: IdentityTurnDecision,
                                                now: Date) async -> TurnResult? {
        guard intent == .recipe else { return nil }
        guard let query = recipeToolFirstQuery(from: text) else { return nil }

        let recipePlan = Plan(steps: [
            .tool(name: "find_recipe", args: ["query": .string(query)], say: nil)
        ])

        lastFinalActionKind = inferredActionKind(for: recipePlan)
        var result = await executePlan(
            recipePlan,
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
            originReason: "recipe_tool_first"
        )

        if recipeToolOutputLooksFailed(result), OpenAISettings.apiKeyStatus == .ready {
            let (rawPlan, provider, routerMs, aiModelUsed, routeProviderReason, planLocalWireMs, planLocalTotalMs, planOpenAIMs) = await routePlan(
                text,
                history: history,
                reason: .userChat,
                promptContext: nil
            )
            let guardedPlan = enforceNoFalseBlindnessGuardrail(on: rawPlan, userInput: text)
            let fallbackPlan = await maybeRephraseRepeatedTalk(
                guardedPlan,
                userInput: text,
                history: history,
                mode: mode,
                turnIndex: turnIndex,
                turnStartedAt: turnStartedAt
            )
            let shapedPlan = enforceLengthPresentationPolicy(fallbackPlan, mode: mode)
            lastFinalActionKind = inferredActionKind(for: shapedPlan)
            result = await executePlan(
                shapedPlan,
                originalInput: text,
                history: history,
                provider: provider,
                aiModelUsed: aiModelUsed,
                routerMs: routerMs,
                planLocalWireMs: planLocalWireMs,
                planLocalTotalMs: planLocalTotalMs,
                planOpenAIMs: planOpenAIMs,
                localKnowledgeContext: localKnowledgeContext,
                hasMemoryHints: hasMemoryHints,
                turnIndex: turnIndex,
                feedbackDepth: 0,
                turnStartedAt: turnStartedAt,
                mode: mode,
                affect: .neutral,
                originReason: routeProviderReason
            )
            appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
            logIdentityTurn(
                decision: identityDecision,
                now: now,
                provider: provider,
                routeReason: routeProviderReason,
                routerMs: routerMs
            )
            return result
        }

        appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
        logIdentityTurn(
            decision: identityDecision,
            now: now,
            provider: .none,
            routeReason: "recipe_tool_first",
            routerMs: 0
        )
        return result
    }

    func recipeToolFirstQuery(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        let recipeMarkers = [
            "recipe",
            "how to make",
            "how do i make",
            "ingredients",
            "cook",
            "cooking",
            "bake",
            "baking"
        ]
        guard recipeMarkers.contains(where: { lower.contains($0) }) else { return nil }

        var query = trimmed
        let patterns = [
            #"(?i)\b(find|show|get)\s+(me\s+)?(a\s+)?recipe\s+for\s+"#,
            #"(?i)\brecipe\s+for\s+"#,
            #"(?i)\bhow\s+to\s+make\s+"#,
            #"(?i)\bhow\s+do\s+i\s+make\s+"#
        ]
        for pattern in patterns {
            query = query.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        query = query.replacingOccurrences(
            of: #"(?i)\s+(and|&)\s+(show|find|get).*$"#,
            with: "",
            options: .regularExpression
        )
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? trimmed : query
    }

    func recipeToolOutputLooksFailed(_ result: TurnResult) -> Bool {
        let merged = result.appendedOutputs
            .filter { $0.kind == .markdown }
            .map(\.payload)
            .joined(separator: "\n")
            .lowercased()

        if merged.isEmpty { return true }
        return merged.contains("couldn't fetch a reliable recipe page")
            || merged.contains("recipe search")
                && merged.contains("couldn't")
    }

    func handlePendingCapabilityRequestTurn(text: String,
                                                    history: [ChatMessage],
                                                    mode: ConversationMode,
                                                    localKnowledgeContext: LocalKnowledgeContext,
                                                    hasMemoryHints: Bool,
                                                    turnIndex: Int,
                                                    turnStartedAt: Date,
                                                    identityDecision: IdentityTurnDecision,
                                                    now: Date) async -> TurnResult? {
        _ = history
        _ = localKnowledgeContext
        _ = turnStartedAt
        let resolution = router.resolvePendingCapabilityInput(
            PendingCapabilityInput(
                pendingRequest: pendingCapabilityRequest,
                text: text,
                now: now
            )
        )
        switch resolution {
        case .none:
            return nil
        case .learnSource(let url, let focus, let memoryContent, let successMessage):
            pendingSlot = nil
            pendingCapabilityRequest = nil

            let learnArgs = ["url": url, "focus": focus]
            let learnAction = ToolAction(name: "learn_website", args: learnArgs, say: nil)
            let learnOutput = toolRunner.executeTool(learnAction)

            let memoryArgs = [
                "type": "preference",
                "content": memoryContent,
                "source": "capability_gap_external_source"
            ]
            let memoryAction = ToolAction(name: "save_memory", args: memoryArgs, say: nil)
            _ = toolRunner.executeTool(memoryAction)

            var result = immediateTalkTurnResult(message: successMessage)
            result.llmProvider = .none
            result.originProvider = .local
            result.executionProvider = .local
            result.originReason = "capability_gap_source_learned"
            result.routerMs = 0
            result.executedToolSteps = [
                (learnAction.name, learnAction.args),
                (memoryAction.name, memoryAction.args)
            ]
            if let learnOutput {
                result.appendedOutputs.append(learnOutput)
            }

            applyResponsePolish(
                &result,
                plan: Plan(steps: [.talk(say: result.spokenLines.first ?? "")]),
                hasMemoryHints: hasMemoryHints,
                turnIndex: turnIndex
            )
            updateAssistantState(after: result, mode: mode)
            rememberAssistantLines(result.appendedChat)
            logIdentityTurn(
                decision: identityDecision,
                now: now,
                provider: .none,
                routeReason: "capability_gap_source_learned",
                routerMs: 0
            )
            return result
        case .askForSource(let prompt, let pendingSlotValue, let updatedRequest):
            pendingCapabilityRequest = updatedRequest
            lastExternalSourcePromptAt = now
            pendingSlot = pendingSlotValue

            var result = immediateTalkTurnResult(message: prompt)
            result.llmProvider = .none
            result.originProvider = .local
            result.executionProvider = .local
            result.originReason = "capability_gap_need_exact_url"
            result.routerMs = 0
            result.triggerFollowUpCapture = true

            applyResponsePolish(
                &result,
                plan: Plan(steps: [.ask(slot: "source_url_or_site", prompt: prompt)]),
                hasMemoryHints: hasMemoryHints,
                turnIndex: turnIndex
            )
            updateAssistantState(after: result, mode: mode)
            rememberAssistantLines(result.appendedChat)
            logIdentityTurn(
                decision: identityDecision,
                now: now,
                provider: .none,
                routeReason: "capability_gap_need_exact_url",
                routerMs: 0
            )
            return result
        case .drop(let message):
            pendingSlot = nil
            pendingCapabilityRequest = nil

            var result = immediateTalkTurnResult(message: message)
            result.llmProvider = .none
            result.originProvider = .local
            result.executionProvider = .local
            result.originReason = "capability_gap_source_url_missing_drop"
            result.routerMs = 0
            applyResponsePolish(
                &result,
                plan: Plan(steps: [.talk(say: result.spokenLines.first ?? "")]),
                hasMemoryHints: hasMemoryHints,
                turnIndex: turnIndex
            )
            updateAssistantState(after: result, mode: mode)
            rememberAssistantLines(result.appendedChat)
            logIdentityTurn(
                decision: identityDecision,
                now: now,
                provider: .none,
                routeReason: "capability_gap_source_url_missing_drop",
                routerMs: 0
            )
            return result
        }
    }

    func planForRouterValidationFailure(_ failure: RouterValidationFailure,
                                                userText: String,
                                                now: Date) -> (Plan, String) {
        switch failure.kind {
        case .unknownTool:
            if let canonicalEnrollmentPlan = canonicalEnrollmentPlanIfNeeded(
                toolName: failure.toolName,
                rawPlanPrefix: failure.rawPlanPrefix,
                userText: userText
            ) {
                return (canonicalEnrollmentPlan, "unknown_tool_enrollment_normalized")
            }
            let classification = classifyUnknownToolFailure(
                toolName: failure.toolName,
                userText: userText
            )
            switch classification {
            case .externalSource:
                let plan = buildExternalSourceAskPlan(
                    toolName: failure.toolName,
                    userText: userText,
                    now: now,
                    prefersWebsiteURL: prefersWebsiteURLForUnknownTool()
                )
                let routeReason: String
                if plan.steps.contains(where: { step in
                    if case .ask = step { return true }
                    return false
                }) {
                    routeReason = "unknown_tool_external_source_ask"
                } else if plan.steps.contains(where: { step in
                    if case .delegate(let task, _, _) = step {
                        return task.lowercased().hasPrefix("capability_gap:")
                    }
                    return false
                }) {
                    routeReason = "unknown_tool_capability_gap_delegate"
                } else {
                    routeReason = "unknown_tool_external_source_reminder"
                }
                return (plan, routeReason)
            case .capabilityBuild:
                let plan = buildExternalSourceAskPlan(
                    toolName: failure.toolName,
                    userText: userText,
                    now: now,
                    prefersWebsiteURL: false
                )
                return (plan, "unknown_tool_capability_gap_delegate")
            }
        }
    }

    func buildExternalSourceAskPlan(toolName: String,
                                            userText: String,
                                            now: Date,
                                            prefersWebsiteURL: Bool) -> Plan {
        _ = now
        _ = prefersWebsiteURL
        pendingCapabilityRequest = nil
        pendingSlot = nil
        lastExternalSourcePromptAt = nil

        let goal = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveGoal = goal.isEmpty ? "build missing capability for \(toolName)" : goal
        let context = "missing: auto_source_discovery_via_gpt=true; requested_tool=\(toolName)"
        let prompt = "I can learn this with GPT, discover trusted sources, and then ask you to save, change, or cancel."
        return Plan(steps: [
            .delegate(
                task: "capability_gap: \(effectiveGoal)",
                context: context,
                say: prompt
            )
        ])
    }

    func classifyUnknownToolFailure(toolName: String, userText: String) -> CapabilityGapRequestKind {
        if prefersWebsiteURLForUnknownTool() {
            return .externalSource
        }
        if let intent = currentIntentClassification?.classification.intent,
           intent == .automationRequest {
            return .capabilityBuild
        }
        return .externalSource
    }

    func prefersWebsiteURLForUnknownTool() -> Bool {
        guard let classification = currentIntentClassification?.classification else { return true }
        if classification.needsWeb {
            return true
        }
        return classification.intent == .webRequest
    }

    func canonicalEnrollmentPlanIfNeeded(toolName: String,
                                                 rawPlanPrefix: String,
                                                 userText: String) -> Plan? {
        guard isEnrollmentToolAlias(toolName) else { return nil }
        guard let name = extractEnrollmentName(from: rawPlanPrefix) ?? extractEnrollmentName(from: userText) else {
            return nil
        }
        return Plan(steps: [
            .tool(name: "enroll_camera_face", args: ["name": .string(name)], say: nil)
        ])
    }

    func isEnrollmentToolAlias(_ toolName: String) -> Bool {
        let normalized = toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
        let aliases: Set<String> = [
            "enrollfacetool",
            "enrollface",
            "enrollcameraface",
            "enrolluserface",
            "enrollfacerecognition"
        ]
        return aliases.contains(normalized)
    }

    func extractEnrollmentName(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let regex = try? NSRegularExpression(pattern: #""name"\s*:\s*"([^"]{1,48})""#, options: .caseInsensitive) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               match.numberOfRanges >= 2,
               let nameRange = Range(match.range(at: 1), in: trimmed),
               let name = sanitizedEnrollmentName(String(trimmed[nameRange])) {
                return name
            }
        }

        return sanitizedEnrollmentName(trimmed)
    }

    func sanitizedEnrollmentName(_ text: String) -> String? {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[.!?,]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.contains("?") else { return nil }

        var candidate = normalized
        let prefixes = ["i am ", "i'm ", "im ", "my name is ", "name is ", "this is "]
        if let prefix = prefixes.first(where: { candidate.hasPrefix($0) }) {
            candidate.removeFirst(prefix.count)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let words = candidate.split(separator: " ").map(String.init)
        guard (1...3).contains(words.count) else { return nil }
        guard words.allSatisfy({ $0.range(of: #"^[a-z][a-z'\-]{0,31}$"#, options: .regularExpression) != nil }) else {
            return nil
        }

        let disallowed: Set<String> = [
            "yes", "yeah", "yep", "yup", "no", "nope", "nah",
            "help", "weather", "time", "what", "where", "when", "why", "how",
            "remember", "recognize", "enroll"
        ]
        guard !words.contains(where: { disallowed.contains($0) }) else { return nil }

        return words.map { token in
            guard let first = token.first else { return "" }
            return String(first).uppercased() + token.dropFirst()
        }.joined(separator: " ")
    }

    func routerValidationFailure(from error: Error) -> RouterValidationFailure? {
        if let openAIError = error as? OpenAIRouter.OpenAIError,
           case .validationFailure(let failure) = openAIError {
            return failure
        }
        if let ollamaError = error as? OllamaRouter.OllamaError,
           case .validationFailure(let failure) = ollamaError {
            return failure
        }
        return nil
    }

}
