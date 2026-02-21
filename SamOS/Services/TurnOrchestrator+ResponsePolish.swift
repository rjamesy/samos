import Foundation

// MARK: - Response Polish, Tone & Follow-Up

extension TurnOrchestrator {

    func applyResponsePolish(_ result: inout TurnResult, plan: Plan, hasMemoryHints: Bool, turnIndex: Int) {
        guard !result.appendedChat.isEmpty else { return }

        let shouldModulateConfidence = isTalkOnlyPlan(plan)
        let assistantIndices = result.appendedChat.indices.filter { result.appendedChat[$0].role == .assistant }

        for idx in assistantIndices {
            let original = result.appendedChat[idx]
            var updatedText = ResponsePolish.stripQuickDetailedPrompt(from: original.text)

            if shouldModulateConfidence {
                updatedText = ResponsePolish.applyConfidenceModulation(to: updatedText)
            }

            if M2Settings.disableAutoClosePrompts,
               currentIntentClassification?.classification.intent != .greeting {
                updatedText = ResponsePolish.stripAutoClosePrompt(from: updatedText)
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

    func applyToneRepairResponsePolicy(_ result: inout TurnResult, cue: String?) {
        guard let cue = cue?.trimmingCharacters(in: .whitespacesAndNewlines), !cue.isEmpty else { return }
        guard let idx = result.appendedChat.firstIndex(where: { $0.role == .assistant }) else { return }

        let original = result.appendedChat[idx]
        let originalTrimmed = original.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalTrimmed.isEmpty else { return }

        let lower = originalTrimmed.lowercased()
        let acknowledgementMarkers = [
            "understood",
            "got it",
            "thanks for the feedback",
            "i'll keep it",
            "i will keep it"
        ]
        if acknowledgementMarkers.contains(where: { lower.contains($0) }) {
            return
        }

        let replacement: String
        let transientFailureMarkers = [
            "had trouble generating a response",
            "had trouble processing that",
            "took too long",
            "please try again"
        ]
        if transientFailureMarkers.contains(where: { lower.contains($0) }) {
            replacement = cue
        } else {
            replacement = "\(cue) \(originalTrimmed)"
        }

        result.appendedChat[idx] = ChatMessage(
            id: original.id,
            ts: original.ts,
            role: original.role,
            text: replacement,
            llmProvider: original.llmProvider,
            isEphemeral: original.isEphemeral,
            usedMemory: original.usedMemory,
            usedLocalKnowledge: original.usedLocalKnowledge
        )

        if let spokenIdx = result.spokenLines.firstIndex(of: original.text) {
            result.spokenLines[spokenIdx] = replacement
        } else if result.spokenLines.isEmpty {
            result.spokenLines.append(replacement)
        }
    }

    func applyAffectMirroringResponsePolicy(_ result: inout TurnResult, affect: AffectMetadata) {
        guard affect.affect != .neutral else { return }
        guard let idx = result.appendedChat.firstIndex(where: { $0.role == .assistant }) else { return }

        let original = result.appendedChat[idx]
        let originalTrimmed = original.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalTrimmed.isEmpty else { return }

        let opening = firstSentence(of: originalTrimmed)?.lowercased() ?? originalTrimmed.lowercased()
        if hasAffectAcknowledgement(opening: opening, affect: affect.affect) {
            return
        }

        let acknowledgement = affectAcknowledgement(for: affect.affect)
        let replacement = "\(acknowledgement) \(originalTrimmed)"

        result.appendedChat[idx] = ChatMessage(
            id: original.id,
            ts: original.ts,
            role: original.role,
            text: replacement,
            llmProvider: original.llmProvider,
            isEphemeral: original.isEphemeral,
            usedMemory: original.usedMemory,
            usedLocalKnowledge: original.usedLocalKnowledge
        )

        if let spokenIdx = result.spokenLines.firstIndex(of: original.text) {
            result.spokenLines[spokenIdx] = replacement
        } else if result.spokenLines.isEmpty {
            result.spokenLines.append(replacement)
        }
    }

    func affectAcknowledgement(for affect: ConversationAffect) -> String {
        switch affect {
        case .neutral:
            return ""
        case .frustrated:
            return "That sounds frustrating."
        case .anxious:
            return "I get why that feels worrying."
        case .sad:
            return "I'm sorry, that sounds heavy."
        case .angry:
            return "I can tell this is really intense."
        case .excited:
            return "That's awesome!"
        }
    }

    func hasAffectAcknowledgement(opening: String, affect: ConversationAffect) -> Bool {
        let markers: [String]
        switch affect {
        case .neutral:
            return true
        case .frustrated:
            markers = ["frustrat", "annoy", "i get why", "i can see why", "sorry you're", "sorry you’re"]
        case .anxious:
            markers = ["worr", "nervous", "unsettling", "normal to feel", "understandable"]
        case .sad:
            markers = ["sorry", "tough", "heavy", "i hear you"]
        case .angry:
            markers = ["intense", "let's slow", "lets slow", "frustrat", "sorry you're", "sorry you’re"]
        case .excited:
            markers = ["awesome", "great", "nice", "excited", "love that energy"]
        }
        return markers.contains { opening.contains($0) }
    }

    func isMemoryAckOnCooldown(_ turnIndex: Int) -> Bool {
        guard let last = lastMemoryAckTurn else { return false }
        return (turnIndex - last) <= memoryAckCooldownTurns
    }

    func isTalkOnlyPlan(_ plan: Plan) -> Bool {
        guard plan.steps.count == 1 else { return false }
        if case .talk = plan.steps[0] { return true }
        return false
    }

    func applyFollowUpQuestionPolicy(_ result: inout TurnResult, turnIndex: Int) {
        guard !M2Settings.disableAutoClosePrompts else { return }
        guard !result.triggerFollowUpCapture else { return } // pending slots/asks are separate flows
        guard !isFollowUpQuestionOnCooldown(turnIndex) else { return }
        guard currentIntentClassification?.classification.intent == .greeting else { return }

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

    func combineAnswer(_ answer: String, withFollowUp followUp: String) -> String {
        let needsSpacer = !(answer.hasSuffix(" ") || answer.hasSuffix("\n"))
        return needsSpacer ? "\(answer) \(followUp)" : "\(answer)\(followUp)"
    }

    func nextFollowUpQuestion() -> String {
        greetingFollowUpQuestion
    }

    func isFollowUpQuestionOnCooldown(_ turnIndex: Int) -> Bool {
        guard let last = lastFollowUpTurn else { return false }
        return (turnIndex - last) < followUpCooldownTurns
    }

    func isSingleTrailingQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?") else { return false }
        return trimmed.filter { $0 == "?" }.count == 1
    }

    /// Inject a curiosity question if the timing is right and there's an unresolved knowledge gap.
    func applyCuriosityQuestionPolicy(_ result: inout TurnResult, turnIndex: Int) {
        // Don't stack on existing questions
        guard let idx = result.appendedChat.lastIndex(where: { $0.role == .assistant }) else { return }
        let text = result.appendedChat[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !text.contains("?") else { return } // already has a question
        guard !result.triggerFollowUpCapture else { return }
        guard isFollowUpQuestionOnCooldown(turnIndex) == false else { return }

        guard let question = ActiveCuriosityEngine.shared.maybeCuriosityQuestion() else { return }

        let original = result.appendedChat[idx]
        let combined = "\(text) \(question)"
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
        }
        lastFollowUpTurn = turnIndex
    }

    func applyKnowledgeAttribution(_ result: inout TurnResult,
                                           userInput: String,
                                           provider: LLMProvider,
                                           aiModelUsed: String?,
                                           localKnowledgeContext: LocalKnowledgeContext) {
        guard provider != .none else {
            result.knowledgeAttribution = KnowledgeAttribution(
                localKnowledgePercent: 0,
                openAIFillPercent: 0,
                matchedLocalItems: 0,
                consideredLocalItems: 0,
                provider: provider,
                aiModelUsed: aiModelUsed,
                evidence: []
            )
            return
        }

        guard let assistantText = result.appendedChat.last(where: { $0.role == .assistant })?.text else {
            return
        }

        let attribution = KnowledgeAttributionScorer.score(
            userInput: userInput,
            assistantText: assistantText,
            provider: provider,
            aiModelUsed: aiModelUsed,
            localSnippets: localKnowledgeContext.items
        )
        result.knowledgeAttribution = attribution

        guard attribution.usedLocalKnowledge else { return }
        for idx in result.appendedChat.indices where result.appendedChat[idx].role == .assistant {
            result.appendedChat[idx].usedLocalKnowledge = true
        }
    }

}
