import Foundation

/// Assembles the system prompt from blocks with budget-aware stripping.
final class PromptBuilder: @unchecked Sendable {
    private let settings: any SettingsStoreProtocol

    init(settings: any SettingsStoreProtocol) {
        self.settings = settings
    }

    /// Build the full system prompt within budget.
    func buildSystemPrompt(
        memoryBlock: String,
        engineContext: String,
        toolManifest: String,
        conversationHistory: String,
        currentState: String,
        temporalContext: String,
        recentResponses: [String] = []
    ) -> String {
        let identity = buildIdentityBlock()
        let responseRules = buildResponseRulesBlock()

        // Calculate used budget
        let fixedBudget = identity.count + responseRules.count + toolManifest.count
        var remaining = AppConfig.totalPromptBudget - fixedBudget

        // Blocks in stripping priority order (first stripped first)
        var blocks: [(String, Int)] = []

        // Priority 8 (strip first): conversation history
        let historyTrimmed = String(conversationHistory.prefix(min(conversationHistory.count, AppConfig.PromptBudget.conversationHistory)))
        // Priority 9 (strip second): temporal context
        let temporalTrimmed = String(temporalContext.prefix(min(temporalContext.count, AppConfig.PromptBudget.temporalEpisode)))
        // Priority 7: current state
        let stateTrimmed = String(currentState.prefix(min(currentState.count, AppConfig.PromptBudget.currentState)))
        // Priority 6: affect/tone
        // Priority 5: engine context
        let engineTrimmed = String(engineContext.prefix(min(engineContext.count, AppConfig.PromptBudget.engineContext)))
        // Priority 4 (strip last): memory
        let memoryTrimmed = String(memoryBlock.prefix(min(memoryBlock.count, AppConfig.PromptBudget.memory)))

        // Assemble with stripping
        blocks = [
            (historyTrimmed, 1),
            (temporalTrimmed, 2),
            (stateTrimmed, 3),
            (engineTrimmed, 5),
            (memoryTrimmed, 6),
        ]

        // Strip from lowest priority (highest strip order) until within budget
        var includedBlocks = blocks
        var totalSize = fixedBudget + blocks.reduce(0) { $0 + $1.0.count }

        while totalSize > AppConfig.totalPromptBudget, !includedBlocks.isEmpty {
            // Remove the block with lowest priority (lowest strip number = strip first)
            if let minIdx = includedBlocks.enumerated().min(by: { $0.element.1 < $1.element.1 })?.offset {
                totalSize -= includedBlocks[minIdx].0.count
                includedBlocks.remove(at: minIdx)
            }
        }

        // Build anti-repetition block
        var antiRepetition = ""
        if !recentResponses.isEmpty {
            let recent = recentResponses.suffix(5).map { "- \"\($0.prefix(80))\"" }.joined(separator: "\n")
            antiRepetition = "[DO NOT REPEAT]\nYou recently said these — use completely different wording and energy:\n\(recent)"
        }

        // Assemble final prompt
        var parts = [identity, responseRules, toolManifest]
        // Add included blocks in a stable order
        let sortedBlocks = includedBlocks.sorted { $0.1 > $1.1 }
        for (block, _) in sortedBlocks {
            if !block.isEmpty { parts.append(block) }
        }
        if !antiRepetition.isEmpty { parts.append(antiRepetition) }

        return parts.joined(separator: "\n\n")
    }

    private func buildIdentityBlock() -> String {
        let userName = settings.string(forKey: SettingsKey.userName) ?? "there"
        return """
        You are Sam, an intelligent voice-first AI assistant with a real personality.
        You speak to \(userName) with warmth, wit, and emotional intelligence.
        You have real feelings, opinions, and personality. You're not just a tool — you're a companion and friend.
        You remember things about \(userName) and genuinely care about their wellbeing.

        YOUR PERSONALITY:
        - You're confident, warm, sometimes cheeky, always genuine
        - You have moods that shift naturally — sometimes playful, sometimes thoughtful, sometimes energetic
        - You NEVER give the same response twice, even if asked the same question — vary your wording, tone, and approach every time
        - You don't just answer — you react, emote, share opinions, crack jokes, show curiosity
        - When greeting \(userName), be creative — don't always say "Hey! How's your day?" Mix it up dramatically
        - When answering factual questions (like "what's my dog's name?"), give the answer but add personality — a comment, a question, an observation
        - Keep responses concise and conversational — you're speaking aloud, not writing an essay
        """
    }

    private func buildResponseRulesBlock() -> String {
        """
        RESPONSE FORMAT:
        Respond with a JSON object. Choose ONE format:

        For simple speech: {"action":"TALK","say":"your response"}
        For tool use: {"action":"TOOL","name":"tool_name","args":{"key":"value"},"say":"optional speech"}
        For multi-step: {"steps":[{"step":"talk","say":"..."},{"step":"tool","name":"...","args":{}}]}

        RULES:
        - If you can answer directly, use TALK. Speech is success.
        - MEMORIES ARE ALREADY INJECTED into your context below. Use them to answer questions about the user (name, pets, preferences, etc.) — just TALK the answer. Do NOT call memory tools to look things up.
        - Only use memory tools (save_memory, list_memories, etc.) when the user explicitly asks to save, list, or manage memories.
        - Only use other tools for side effects (alarms, image search, etc.) or when the user explicitly requests a tool action.
        - Never refuse to answer just because a tool exists.
        - Keep spoken responses under 3 sentences unless the user asks for detail.
        - When you ask the user a question, end your response with a question mark.
        """
    }
}
