import Foundation
import AppKit

/// The brain of SamOS. Assembles context, routes to OpenAI, executes plans.
/// Target: ~500 lines max. No singletons.
final class TurnOrchestrator: TurnOrchestrating, @unchecked Sendable {
    private let llmClient: any LLMClient
    private let promptBuilder: PromptBuilder
    private let responseParser: ResponseParser
    private let planExecutor: PlanExecutor
    private let memoryInjector: MemoryInjector
    private let memoryStore: any MemoryStoreProtocol
    private let settings: any SettingsStoreProtocol

    // Phase 10 additions
    private let toolRegistry: (any ToolRegistryProtocol)?
    private let engineScheduler: EngineScheduler?
    private let memoryAutoSave: MemoryAutoSave?
    private let skillEngine: SkillEngine?

    // Phase 1 additions: proactive awareness, ambient, semantic memory
    private let proactiveAwareness: ProactiveAwareness?
    private let ambientListening: AmbientListeningService?
    private let semanticMemoryEngine: SemanticMemoryEngine?

    init(
        llmClient: any LLMClient,
        promptBuilder: PromptBuilder,
        responseParser: ResponseParser,
        planExecutor: PlanExecutor,
        memoryInjector: MemoryInjector,
        memoryStore: any MemoryStoreProtocol,
        settings: any SettingsStoreProtocol,
        toolRegistry: (any ToolRegistryProtocol)? = nil,
        engineScheduler: EngineScheduler? = nil,
        memoryAutoSave: MemoryAutoSave? = nil,
        skillEngine: SkillEngine? = nil,
        proactiveAwareness: ProactiveAwareness? = nil,
        ambientListening: AmbientListeningService? = nil,
        semanticMemoryEngine: SemanticMemoryEngine? = nil
    ) {
        self.llmClient = llmClient
        self.promptBuilder = promptBuilder
        self.responseParser = responseParser
        self.planExecutor = planExecutor
        self.memoryInjector = memoryInjector
        self.memoryStore = memoryStore
        self.settings = settings
        self.toolRegistry = toolRegistry
        self.engineScheduler = engineScheduler
        self.memoryAutoSave = memoryAutoSave
        self.skillEngine = skillEngine
        self.proactiveAwareness = proactiveAwareness
        self.ambientListening = ambientListening
        self.semanticMemoryEngine = semanticMemoryEngine
    }

    func processTurn(text: String, history: [ChatMessage], sessionId: String, attachments: [ChatAttachment] = []) async throws -> TurnResult {
        let start = Date()

        // 0. Check for skill match first
        if let skillEngine, let plan = await skillEngine.tryExecute(input: text) {
            let executionResult = await planExecutor.execute(plan: plan)
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            await triggerPostTurnHooks(userText: text, assistantText: executionResult.spokenText, history: history, sessionId: sessionId)
            return TurnResult(
                sayText: executionResult.spokenText,
                outputItems: executionResult.outputItems,
                latencyMs: latencyMs,
                usedMemory: false,
                toolCalls: executionResult.toolCalls,
                engineSummary: "(skill match — engines skipped)"
            )
        }

        // 1. Build memory context
        let memoryBlock = await memoryInjector.buildMemoryBlock(query: text)
        let usedMemory = !memoryBlock.isEmpty

        // 2. Build tool manifest
        let toolManifest: String
        if let registry = toolRegistry as? ToolRegistry {
            toolManifest = registry.buildToolManifest()
        } else {
            toolManifest = ""
        }

        // 3. Run intelligence engines
        let engineSchedulerResult: EngineSchedulerResult?
        let engineContext: String
        if let scheduler = engineScheduler {
            let turnContext = EngineTurnContext(
                userText: text,
                assistantText: "",
                turnId: UUID().uuidString,
                sessionId: sessionId,
                timestamp: Date()
            )
            let result = await scheduler.runEngines(context: turnContext)
            engineSchedulerResult = result
            engineContext = result.contextBlock
        } else {
            engineSchedulerResult = nil
            engineContext = ""
        }

        // 4. Build current state (including proactive & ambient context)
        let currentState = await buildCurrentState()

        // 5. Build temporal context
        let temporalContext = await memoryStore.temporalContext(query: text, maxChars: AppConfig.maxTemporalChars)

        // 6. Extract recent Sam responses for anti-repetition
        let recentResponses = history
            .filter { $0.role == .assistant }
            .suffix(5)
            .map(\.text)

        // 7. Build system prompt
        let systemPrompt = promptBuilder.buildSystemPrompt(
            memoryBlock: memoryBlock,
            engineContext: engineContext,
            toolManifest: toolManifest,
            conversationHistory: buildHistoryString(history),
            currentState: currentState,
            temporalContext: temporalContext,
            recentResponses: recentResponses
        )

        // 8. Route to OpenAI
        var messages: [LLMMessage] = []
        let recentHistory = history.suffix(20)
        for msg in recentHistory {
            messages.append(LLMMessage(role: msg.role.rawValue, content: msg.text))
        }

        if attachments.isEmpty {
            messages.append(LLMMessage(role: "user", content: text))
        } else {
            var parts: [LLMContentPart] = [.text(text)]
            for attachment in attachments.prefix(5) {
                if attachment.isImage {
                    let compressed = Self.resizeAndCompress(data: attachment.data, maxDimension: 1024, jpegQuality: 0.7)
                    let b64 = compressed.base64EncodedString()
                    parts.append(.imageURL("data:image/jpeg;base64,\(b64)"))
                } else {
                    if let textContent = String(data: attachment.data, encoding: .utf8) {
                        let truncated = String(textContent.prefix(10_000))
                        parts.append(.text("[File: \(attachment.filename)]\n\(truncated)"))
                    }
                }
            }
            messages.append(LLMMessage(role: "user", content: .multipart(parts)))
        }

        // Build tool definitions for native function calling (Phase 5)
        let toolDefs: [ToolDefinition]?
        if let registry = toolRegistry as? ToolRegistry {
            let defs = registry.buildToolDefinitions()
            toolDefs = defs.isEmpty ? nil : defs
        } else {
            toolDefs = nil
        }

        let request = LLMRequest(
            system: systemPrompt,
            messages: messages,
            responseFormat: .jsonObject,
            tools: toolDefs
        )

        let response: LLMResponse
        do {
            response = try await llmClient.complete(request)
        } catch {
            throw error
        }

        // 9. Parse response — handle native tool_calls or text response
        let plan: Plan
        if let toolCalls = response.toolCalls, !toolCalls.isEmpty {
            // Native function calling: convert tool_calls directly to plan steps
            plan = Plan.fromToolCalls(toolCalls, spokenText: response.text)
        } else {
            plan = responseParser.parse(response.text)
        }

        // 10. Execute plan
        let executionResult = await planExecutor.execute(plan: plan)

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

        // 11. Post-turn hooks (fire and forget)
        await triggerPostTurnHooks(userText: text, assistantText: executionResult.spokenText, history: history, sessionId: sessionId)

        return TurnResult(
            sayText: executionResult.spokenText,
            outputItems: executionResult.outputItems,
            latencyMs: latencyMs,
            usedMemory: usedMemory,
            toolCalls: executionResult.toolCalls,
            engineSummary: engineSchedulerResult?.summary ?? ""
        )
    }

    // MARK: - Streaming (Phase 4)

    /// Process a turn with streaming tokens for real-time TTS.
    func processTurnStreaming(
        text: String,
        history: [ChatMessage],
        sessionId: String,
        attachments: [ChatAttachment] = [],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> TurnResult {
        let start = Date()

        // Build context same as non-streaming
        let memoryBlock = await memoryInjector.buildMemoryBlock(query: text)
        let usedMemory = !memoryBlock.isEmpty

        let toolManifest: String
        if let registry = toolRegistry as? ToolRegistry {
            toolManifest = registry.buildToolManifest()
        } else {
            toolManifest = ""
        }

        let currentState = await buildCurrentState()
        let temporalContext = await memoryStore.temporalContext(query: text, maxChars: AppConfig.maxTemporalChars)
        let recentResponses = history.filter { $0.role == .assistant }.suffix(5).map(\.text)

        let systemPrompt = promptBuilder.buildSystemPrompt(
            memoryBlock: memoryBlock,
            engineContext: "",
            toolManifest: toolManifest,
            conversationHistory: buildHistoryString(history),
            currentState: currentState,
            temporalContext: temporalContext,
            recentResponses: recentResponses
        )

        var messages: [LLMMessage] = []
        for msg in history.suffix(20) {
            messages.append(LLMMessage(role: msg.role.rawValue, content: msg.text))
        }
        messages.append(LLMMessage(role: "user", content: text))

        let request = LLMRequest(
            system: systemPrompt,
            messages: messages,
            responseFormat: .jsonObject
        )

        // Stream tokens and accumulate full response
        var fullText = ""
        let stream = llmClient.stream(request)
        for try await token in stream {
            fullText += token
            onToken(token)
        }

        // Parse the complete response
        let plan = responseParser.parse(fullText)
        let executionResult = await planExecutor.execute(plan: plan)
        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

        await triggerPostTurnHooks(userText: text, assistantText: executionResult.spokenText, history: history, sessionId: sessionId)

        return TurnResult(
            sayText: executionResult.spokenText,
            outputItems: executionResult.outputItems,
            latencyMs: latencyMs,
            usedMemory: usedMemory,
            toolCalls: executionResult.toolCalls,
            engineSummary: ""
        )
    }

    // MARK: - Post-Turn Hooks

    private func triggerPostTurnHooks(userText: String, assistantText: String, history: [ChatMessage], sessionId: String) async {
        // Auto-save memories from user message
        if let autoSave = memoryAutoSave {
            await autoSave.processMessage(userText, role: .user)
        }

        // Semantic memory: compress episodes and extract profile facts
        if let semantic = semanticMemoryEngine {
            Task {
                await semantic.compressEpisode(messages: history, sessionId: sessionId)
                await semantic.extractProfileFacts(messages: history)
            }
        }
    }

    // MARK: - Helpers

    private func buildCurrentState() async -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        var state = "Current time: \(formatter.string(from: Date()))"

        // Append proactive awareness context
        if let proactive = proactiveAwareness {
            let block = await proactive.buildContextBlock()
            if !block.isEmpty { state += "\n\n\(block)" }
        }

        // Append ambient listening context
        if let ambient = ambientListening {
            let block = await ambient.buildContextBlock()
            if !block.isEmpty { state += "\n\n\(block)" }
        }

        return state
    }

    private func buildHistoryString(_ history: [ChatMessage]) -> String {
        let recent = history.suffix(10)
        return recent.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Image Compression

    private static func resizeAndCompress(data: Data, maxDimension: CGFloat = 1024, jpegQuality: CGFloat = 0.7) -> Data {
        guard let image = NSImage(data: data) else { return data }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return data }
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        let newSize = NSSize(width: round(size.width * scale), height: round(size.height * scale))
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: newSize), from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return data }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) ?? data
    }
}
