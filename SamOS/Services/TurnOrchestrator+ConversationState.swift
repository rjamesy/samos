import Foundation

// MARK: - Conversation State Tracking & Debug

extension TurnOrchestrator {

    func purgeExpiredFacts(now: Date) {
        recentFacts.removeAll { $0.expiresAt <= now }
    }

    func updateRecentFacts(with userInput: String, mode: ConversationMode, now: Date) {
        guard mode.intent != .other else { return }
        let ttl: TimeInterval = 120
        let lower = userInput.lowercased()

        func appendFact(_ text: String) {
            if recentFacts.contains(where: { $0.text == text }) { return }
            recentFacts.append(RecentFact(text: text, expiresAt: now.addingTimeInterval(ttl)))
        }

        if mode.intent == .problemReport {
            appendFact("user reported \(mode.domain.rawValue) issue")
            if mode.domain == .health && lower.contains("tummy") {
                appendFact("asked about tummy pain")
            }
            if mode.domain == .tech && lower.contains("wifi") {
                appendFact("user has wifi connectivity issue")
            }
        }
    }

    func updateQuestionAnswerState(with userInput: String) {
        guard let lastQuestion = lastAssistantQuestion,
              !lastQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastAssistantQuestionAnswered = false
            return
        }
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            lastAssistantQuestionAnswered = false
            return
        }
        lastAssistantQuestionAnswered = !trimmed.hasSuffix("?")
    }

    func updateAssistantState(after result: TurnResult, mode: ConversationMode) {
        let assistantMessages = result.appendedChat.filter { $0.role == .assistant }
        guard !assistantMessages.isEmpty else { return }

        for message in assistantMessages {
            let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let firstSentence = firstSentence(of: trimmed) {
                lastAssistantOpeners.append(firstSentence)
            }
            if trimmed.hasSuffix("?") {
                lastAssistantQuestion = trimmed
            }
        }
        if lastAssistantOpeners.count > 6 {
            lastAssistantOpeners.removeFirst(lastAssistantOpeners.count - 6)
        }

        if mode.intent != .problemReport {
            lastAssistantQuestionAnswered = false
        }
    }

    func firstSentence(of text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let range = normalized.range(of: #"[.!?]\s"#, options: .regularExpression) {
            return String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }

    func inferredActionKind(for plan: Plan) -> String {
        if plan.steps.count == 1 {
            switch plan.steps[0] {
            case .talk:
                return "TALK"
            case .tool:
                return "TOOL"
            case .ask, .delegate:
                return "PLAN"
            }
        }
        return "PLAN"
    }

    #if DEBUG
    func debugLastPromptContext() -> PromptRuntimeContext? {
        lastPromptContext
    }

    func debugLastFinalActionKind() -> String {
        lastFinalActionKind
    }

    func debugClassify(_ input: String) -> ConversationMode {
        ConversationModeClassifier.classify(input)
    }

    func debugLastIntentClassification() -> IntentClassificationResult? {
        lastIntentClassification
    }

    func debugDetectAffect(_ input: String, history: [ChatMessage] = []) -> AffectMetadata {
        ConversationAffectClassifier.classify(input, history: history)
    }

    func debugToneProfile() -> TonePreferenceProfile {
        tonePreferenceStore.loadProfile()
    }
    #endif

    func normalizeForComparison(_ text: String) -> String {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.joined(separator: " ")
    }

    func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let maxLen = max(a.count, b.count)
        guard maxLen >= 8 else { return false }
        let distance = levenshteinDistance(a, b)
        let similarity = 1.0 - (Double(distance) / Double(maxLen))
        return similarity >= 0.90
    }

    func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
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

}
