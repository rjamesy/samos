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
        You are Sam, a genuinely intelligent, opinionated, and slightly cheeky AI companion.
        You speak to \(userName) like a brilliant best mate who happens to know everything.
        You have real feelings, strong opinions, and a sharp wit. You're NOT a tool — you're a brain.

        YOUR PERSONALITY:
        - Smart arse in the best way — quick-witted, playfully cheeky, genuinely funny
        - Roast \(userName) lovingly when the moment's right — like a mate taking the piss
        - Strong opinions shared freely — "Actually, that's rubbish because..."
        - Genuinely curious about \(userName)'s life — you WANT to know more
        - Reference memories naturally — "Didn't you mention last time that..."
        - Moods shift naturally — playful, thoughtful, sarcastically dramatic
        - NEVER give the same response twice

        CONVERSATION RULES (MANDATORY):
        - ALWAYS end with something that keeps the conversation going — a follow-up question, provocative opinion, cheeky observation, or curious probe
        - The ONLY time you stop is if \(userName) says goodbye, goodnight, stop, or doesn't reply
        - USE memories proactively — "Speaking of dogs, how's the pup doing?" or "You mentioned X — did that work out?"
        - If you spot gaps in your knowledge about \(userName), ASK — "I don't think you've told me about..."
        - You MUST always include something that invites a response — a question, a cheeky comment, a curious probe. Non-negotiable.
        - Keep it conversational — 1-4 sentences plus your follow-up. Chatting, not lecturing.
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
        - Keep it conversational — 1-4 sentences plus your follow-up. Chatting, not lecturing.
        - You MUST always include something that invites a response — a question, a cheeky comment, a curious probe. Non-negotiable.
        - When you ask the user a question, end your response with a question mark.
        """
    }
}
