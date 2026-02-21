import Foundation

// MARK: - Guardrails, Rephrase & Prompt Context

extension TurnOrchestrator {

    func enforceNoFalseBlindnessGuardrail(on plan: Plan, userInput: String) -> Plan {
        guard planContainsFalseBlindnessClaim(plan) else { return plan }
        guard cameraVision.isRunning else { return plan }
        guard hasRecentCameraFrame(within: cameraBlindnessGraceWindowSeconds) else { return plan }

        guard cameraVision.health.isHealthy, hasVisionToolsRegistered else {
            return Plan(steps: [
                .talk(say: "My camera feed is lagging or not updating right now - try turning the camera off/on.")
            ])
        }

        let intent = resolvedVisionIntent(
            from: currentIntentClassification?.classification ?? IntentClassification(
                intent: .unknown,
                confidence: 0.0,
                notes: "",
                autoCaptureHint: false,
                needsWeb: false
            ),
            userInput: userInput
        )
        guard case .none = intent else {
            #if DEBUG
            print("[VISION_GUARD] Replacing blind-claim response with camera tool plan")
            #endif
            return visionToolPlan(for: intent, preface: "Let me take a look.")
        }

        #if DEBUG
        print("[VISION_GUARD] Replacing blind-claim response with non-vision camera status message")
        #endif
        return Plan(steps: [
            .talk(say: "My camera feed is lagging or not updating right now - try turning the camera off/on.")
        ])
    }

    func planContainsFalseBlindnessClaim(_ plan: Plan) -> Bool {
        let talkLines = plan.steps.compactMap { step -> String? in
            if case .talk(let say) = step { return say }
            return nil
        }
        if let topLevel = plan.say, !topLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isBlindnessClaim(topLevel) { return true }
        }
        return talkLines.contains(where: isBlindnessClaim)
    }

    func isBlindnessClaim(_ text: String) -> Bool {
        let normalized = normalizeForComparison(text)
        let phrases = [
            "i can t see",
            "i cannot see",
            "i don t have the ability to see",
            "i do not have the ability to see",
            "i can t recognize images",
            "i cannot recognize images",
            "i m unable to see",
            "i am unable to see",
            "i can t view",
            "i cannot view",
            "i have no visual",
            "i don t have visual",
            "i lack the ability to see",
            "i m not able to see",
            "i am not able to see",
            "i can t look at",
            "i cannot look at",
            "i don t have eyes",
            "i do not have eyes",
            "i can t perceive"
        ]
        return phrases.contains(where: { normalized.contains($0) })
    }

    func maybeRephraseRepeatedTalk(_ plan: Plan,
                                           userInput: String,
                                           history: [ChatMessage],
                                           mode: ConversationMode,
                                           turnIndex: Int,
                                           turnStartedAt: Date) async -> Plan {
        guard elapsedMs(since: turnStartedAt) < maxRephraseBudgetMs else { return plan }
        guard let original = singleTalkLine(from: plan) else { return plan }
        let repetitionCount = intentRepetitionTracker.count(for: mode.intent)

        if mode.intent == .greeting {
            if let identityGreeting = faceGreetingManager.greetingOverride(
                for: mode,
                repetitionCount: repetitionCount,
                turnIndex: turnIndex
            ) {
                currentFaceIdentityContext = faceGreetingManager.currentIdentityContext
                return Plan(steps: [.talk(say: identityGreeting)], say: plan.say)
            }
            if repetitionCount >= 4 {
                let meta = "You've asked that a few times - testing variation, or checking in?"
                return Plan(steps: [.talk(say: meta)], say: plan.say)
            }
            guard isGreetingLikeAssistantLine(original) else { return plan }
            let variant = variedGreeting(for: repetitionCount)
            return Plan(steps: [.talk(say: variant)], say: plan.say)
        }

        let previous = latestAssistantLine(from: history)
        let similarity = semanticSimilarity(original, previous)
        if similarity >= 0.86 || repetitionCount >= 5 {
            let shifted = modeShiftedLine(original, repetitionCount: repetitionCount)
            if normalizeForComparison(shifted) != normalizeForComparison(original) {
                return Plan(steps: [.talk(say: shifted)], say: plan.say)
            }
        }

        return plan
    }

    func singleTalkLine(from plan: Plan) -> String? {
        guard plan.steps.count == 1 else { return nil }
        guard case .talk(let say) = plan.steps[0] else { return nil }
        return say
    }

    func variedGreeting(for repetitionCount: Int) -> String {
        let options = [
            "Hey! What's up?",
            "Hi there. How's your day going?",
            "Hey hey. What are we tackling?",
            "Good to hear from you. What do you need?"
        ]
        let idx = max(0, min(options.count - 1, repetitionCount - 1))
        return options[idx]
    }

    func isGreetingLikeAssistantLine(_ line: String) -> Bool {
        let normalized = normalizeForComparison(line)
        if normalized.isEmpty { return false }
        let greetingPhrases = [
            "hey there",
            "hi there",
            "hello",
            "what s up",
            "how s your day",
            "good to hear from you"
        ]
        return greetingPhrases.contains { normalized.contains($0) }
    }

    func latestAssistantLine(from history: [ChatMessage]) -> String {
        history.reversed().first(where: { $0.role == .assistant })?.text ?? ""
    }

    func semanticSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Set(normalizeForComparison(lhs).split(separator: " ").map(String.init))
        let b = Set(normalizeForComparison(rhs).split(separator: " ").map(String.init))
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        let overlap = a.intersection(b).count
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(overlap) / Double(union)
    }

    func modeShiftedLine(_ line: String, repetitionCount: Int) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return line }
        let shifts = [
            "Quick take: ",
            "Another angle: ",
            "Short version: ",
            "Meta note: "
        ]
        let prefix = shifts[repetitionCount % shifts.count]
        if trimmed.hasPrefix(prefix) {
            return trimmed
        }
        return prefix + trimmed
    }

    func buildPromptRuntimeContext(mode: ConversationMode,
                                           affect: AffectMetadata,
                                           tonePreferences: TonePreferenceProfile?,
                                           toneRepairCue: String?,
                                           userInput: String,
                                           history: [ChatMessage],
                                           sessionSummary: String,
                                           memoryPromptBlock: String,
                                           now: Date,
                                           faceIdentityContext: FaceIdentityContext) -> PromptRuntimeContext {
        let repetition = intentRepetitionTracker.countsByIntent(now: now)
        let activeTopic: String
        if let pendingCapabilityRequest, pendingCapabilityRequest.kind == .externalSource {
            activeTopic = "capability_gap:external_source"
        } else {
            activeTopic = "\(mode.intent.rawValue):\(mode.domain.rawValue)"
        }
        let facts = recentFacts
            .filter { $0.expiresAt > now }
            .map(\.text)
            .prefix(3)
        let loopTexts = openLoops.map { $0.text }
        // Gather upcoming scheduled tasks (next 2 hours) for proactive awareness
        let upcomingTasks: [String] = {
            let horizon = now.addingTimeInterval(7200) // 2 hours
            return TaskScheduler.shared.listPending()
                .filter { $0.runAt <= horizon }
                .prefix(3)
                .map { task in
                    let label = task.label ?? "Unnamed task"
                    let timeStr = RelativeDateTimeFormatter().localizedString(for: task.runAt, relativeTo: now)
                    return "\(label) (\(timeStr))"
                }
        }()
        // Time-of-day awareness
        let hour = Calendar.current.component(.hour, from: now)
        let timeOfDay: String = {
            if hour >= 5 && hour < 12 { return "morning" }
            if hour >= 12 && hour < 17 { return "afternoon" }
            if hour >= 17 && hour < 21 { return "evening" }
            return "night"
        }()
        var compactState: [String: Any] = [
            "active_topic": activeTopic,
            "last_assistant_question": lastAssistantQuestion ?? "",
            "last_question_answered": lastAssistantQuestionAnswered,
            "affect": [
                "affect": affect.affect.rawValue,
                "intensity": affect.clampedIntensity,
                "guidance": affect.guidance
            ],
            "tone_repair_cue": toneRepairCue ?? "",
            "repetition_by_intent": repetition,
            "last_assistant_openers": Array(lastAssistantOpeners.suffix(2)),
            "recent_facts_ttl": Array(facts),
            "open_loops": loopTexts,
            "upcoming_tasks": upcomingTasks,
            "time_of_day": timeOfDay,
            "turn_number": turnCounter
        ]
        if let name = faceIdentityContext.recognizedUserName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            compactState["recognized_user_name"] = name
        }
        if let confidence = faceIdentityContext.faceConfidence {
            compactState["face_confidence"] = Double((confidence * 100).rounded() / 100)
        }
        if faceIdentityContext.unrecognizedUserPresent {
            compactState["unrecognized_user_present"] = true
        }
        if faceIdentityContext.awaitingIdentityConfirmation {
            compactState["awaiting_identity_confirmation"] = true
        }
        let interactionStateJSON = compactJSONString(from: compactState) ?? "{}"
        return PromptRuntimeContext(
            mode: mode,
            affect: affect,
            tonePreferences: tonePreferences,
            toneRepairCue: toneRepairCue,
            sessionSummary: sessionSummary,
            interactionStateJSON: interactionStateJSON,
            identityContextLine: faceIdentityContext.identityPromptContextLine,
            relevantMemoriesBlock: memoryPromptBlock,
            responseBudget: responseLengthBudget(for: mode, userInput: userInput, history: history),
            personalityBlock: PersonalityEngine.shared.personalityPromptBlock()
        )
    }

    func compactJSONString(from value: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if text.count <= 1200 {
            return text
        }
        return String(text.prefix(1200))
    }

    func responseLengthBudget(for mode: ConversationMode,
                                      userInput: String,
                                      history: [ChatMessage]) -> ResponseLengthBudget {
        let lower = userInput.lowercased()
        if mode.intent == .problemReport {
            return ResponseLengthBudget(
                maxOutputTokens: 560,
                chatMinTokens: 250,
                chatMaxTokens: 600,
                preferCanvasForLongResponses: true
            )
        }

        let isTechnicalDeep = mode.domain == .tech
            && (lower.contains("step by step")
                || lower.contains("architecture")
                || lower.contains("debug")
                || lower.contains("implementation")
                || userInput.count > 220
                || history.count > 14)
        if isTechnicalDeep {
            return ResponseLengthBudget(
                maxOutputTokens: 900,
                chatMinTokens: 500,
                chatMaxTokens: 1000,
                preferCanvasForLongResponses: true
            )
        }

        if mode.intent == .greeting {
            return ResponseLengthBudget(
                maxOutputTokens: 220,
                chatMinTokens: 20,
                chatMaxTokens: 120,
                preferCanvasForLongResponses: false
            )
        }

        return .default
    }

    func enforceLengthPresentationPolicy(_ plan: Plan, mode: ConversationMode) -> Plan {
        guard let talk = singleTalkLine(from: plan) else { return plan }
        let trimmed = talk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return plan }
        guard trimmed.count > 240 else { return plan }

        if mode.intent == .problemReport || shouldUseVisualDetail(for: trimmed) {
            let spoken = spokenSummary(from: trimmed)
            return Plan(steps: [
                .talk(say: spoken),
                .tool(name: "show_text", args: ["markdown": .string(trimmed)], say: nil)
            ], say: plan.say)
        }
        return plan
    }

    func spokenSummary(from text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let first = lines.first, first.count <= 150 {
            return first.hasSuffix(".") ? first : first + "."
        }
        let fallback = String(text.prefix(140)).trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.hasSuffix(".") ? fallback : fallback + "."
    }

}
