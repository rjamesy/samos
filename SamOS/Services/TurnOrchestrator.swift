import Foundation

/// The ONLY brain for processing user input.
/// Calls LLM, validates structure, executes plan steps.
/// Uses a deterministic intent classifier with optional LLM fallback, then executes plan steps.
@MainActor
final class TurnOrchestrator {
    let ollamaRouter: OllamaRouter
    let openAIRouter: OpenAIRouter
    let openAIProvider: OpenAIProviderRouting
    let tonePreferenceStore: TonePreferenceStore
    let faceGreetingManager: FaceGreetingManager
    let cameraVision: CameraVisionProviding
    let intentClassifier: IntentClassifier
    let summaryService = SessionSummaryService()
    let intentRepetitionTracker = IntentRepetitionTracker()
    let memoryAckCooldownTurns: Int
    let followUpCooldownTurns: Int
    var recentAssistantLines: [String] = []
    var recentFacts: [RecentFact] = []
    var lastAssistantQuestion: String?
    var lastAssistantQuestionAnswered = false
    var lastAssistantOpeners: [String] = []
    var currentFaceIdentityContext: FaceIdentityContext = .none
    var lastPromptContext: PromptRuntimeContext?
    var lastFinalActionKind: String = "UNKNOWN"
    var canvasConfirmationIndex = 0
    let canvasConfirmations = [
        "I've put the details up here.",
        "Here's a clear breakdown for you.",
        "I've laid this out on screen."
    ]
    let greetingFollowUpQuestion = "How can I help?"
    static let numberedListRegex = try! NSRegularExpression(pattern: #"^\d+[\.)]\s"#, options: [])
    static let coverageEntityRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z]{2,}\b"#, options: [])
    static let coverageStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "also", "after", "while",
        "what", "when", "where", "why", "how", "is", "are", "was", "were", "be", "to",
        "for", "of", "in", "on", "at", "by", "with", "without", "from", "into", "about",
        "tell", "show", "check", "find", "learn", "need", "good", "time", "call", "me", "you",
        "should", "would", "could", "can",
        "your", "my", "it", "this", "that"
    ]
    var turnCounter = 0
    var lastMemoryAckTurn: Int?
    var lastFollowUpTurn: Int?
    static let sharedIntentInferenceExecutor = IntentInferenceExecutor()
    let openAIRouteTimeoutSeconds: Double = 5.0
    let intentLocalTimeoutSeconds: Double
    let intentOpenAITimeoutSeconds: Double = 2.0
    let openAITimeoutRetryMaxTokens: Int = 220
    let openAIImageRepairTimeoutSeconds: Double = 3.0
    let toolFeedbackLoopMaxDepth = 2
    let maxRephraseBudgetMs = 700
    let maxToolFeedbackBudgetMs = 3600
    let openAIToolFeedbackTimeoutSeconds: Double = 2.2
    let ollamaToolFeedbackTimeoutSeconds: Double = 1.2
    let ollamaFallbackOpenAIModel = "gpt-5.2"
    let unknownToolPromptCooldownSeconds: TimeInterval = 300
    let cameraBlindnessGraceWindowSeconds: TimeInterval = 10
    let toolRunner: TurnToolRunning
    let routerOverride: TurnRouting?
    lazy var defaultRouter: TurnRouting = makeDefaultRouter()
    var router: TurnRouting { routerOverride ?? defaultRouter }
    var pendingCapabilityRequest: PendingCapabilityRequest?
    var lastExternalSourcePromptAt: Date?
    var currentIntentClassification: IntentClassificationResult?
    var lastIntentClassification: IntentClassificationResult?
    var currentTurnCaptureAfterReplyHint: Bool = false
    var currentRoutingTask: Task<Void, Never>?
    var latencyTracker = LatencyTracker()

    // MARK: - Conversation State Tracking
    /// Tracks user's open loops — things they mentioned wanting to do but haven't completed.
    /// Injected into the prompt so Sam can proactively follow up.
    var openLoops: [(text: String, detectedAt: Date)] = []
    /// Recent conversation topics for continuity awareness
    var recentTopics: [String] = []
    static let openLoopPatterns: [String] = [
        "i'll do that later",
        "i need to",
        "i should",
        "i've been meaning to",
        "remind me to",
        "i want to",
        "i'm planning to",
        "i have to",
        "i gotta",
        "when i get a chance",
        "one of these days",
        "i'm going to",
        "i'll get to that",
        "put that on my list",
        "add that to my list",
        "i'll think about it"
    ]

    /// Detects open loops from user input and tracks them.
    func detectAndTrackOpenLoops(from userText: String) {
        let lower = userText.lowercased()
        for pattern in Self.openLoopPatterns {
            if lower.contains(pattern) {
                // Extract the meaningful part after the pattern
                if let range = lower.range(of: pattern) {
                    let remainder = String(userText[range.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: .punctuationCharacters)
                    if !remainder.isEmpty && remainder.count > 3 {
                        // Avoid duplicates
                        let existing = openLoops.map { $0.text.lowercased() }
                        if !existing.contains(where: { $0.contains(remainder.lowercased()) || remainder.lowercased().contains($0) }) {
                            openLoops.append((text: remainder, detectedAt: Date()))
                            // Keep max 5 open loops
                            if openLoops.count > 5 {
                                openLoops.removeFirst()
                            }
                        }
                    }
                }
                break
            }
        }
        // Expire loops older than 24 hours
        let cutoff = Date().addingTimeInterval(-86400)
        openLoops.removeAll { $0.detectedAt < cutoff }
    }

    /// Builds a prompt block for open loops (injected into interaction state).
    func openLoopsPromptBlock() -> String {
        guard !openLoops.isEmpty else { return "" }
        let items = openLoops.map { "- \($0.text)" }.joined(separator: "\n")
        return """
        User's open loops (things they mentioned wanting to do):
        \(items)
        If relevant, gently follow up. Don't nag.
        """
    }

    var pendingSlot: PendingSlot? = nil

    // Production init
    init() {
        let ollama = OllamaRouter()
        let openAI = OpenAIRouter(parser: ollama)
        let provider = RetryingOpenAIProvider(openAIRouter: openAI)
        self.ollamaRouter = ollama
        self.openAIRouter = openAI
        self.openAIProvider = provider
        self.tonePreferenceStore = .shared
        self.faceGreetingManager = FaceGreetingManager()
        self.cameraVision = CameraVisionService.shared
        self.intentLocalTimeoutSeconds = TurnOrchestrator.sanitizedLocalIntentTimeout(M2Settings.localIntentTimeoutSeconds)
        self.intentClassifier = TurnOrchestrator.makeIntentClassifier(
            ollamaRouter: ollama,
            openAIProvider: provider,
            localTimeoutSeconds: intentLocalTimeoutSeconds,
            openAITimeoutSeconds: intentOpenAITimeoutSeconds
        )
        self.toolRunner = TurnToolRunner(planExecutor: .shared, toolsRuntime: ToolsRuntime.shared)
        self.routerOverride = nil
        self.memoryAckCooldownTurns = 20
        self.followUpCooldownTurns = 3
    }

    // Test init (injectable)
    init(ollamaRouter: OllamaRouter,
         openAIRouter: OpenAIRouter,
         faceGreetingManager: FaceGreetingManager? = nil,
         cameraVision: CameraVisionProviding = CameraVisionService.shared,
         localIntentTimeoutSeconds: Double? = nil,
         router: TurnRouting? = nil,
         openAIProvider: OpenAIProviderRouting? = nil,
         toolRunner: TurnToolRunning? = nil,
         memoryAckCooldownTurns: Int = 20,
         followUpCooldownTurns: Int = 3) {
        self.ollamaRouter = ollamaRouter
        self.openAIRouter = openAIRouter
        self.openAIProvider = openAIProvider ?? RetryingOpenAIProvider(
            openAIRouter: openAIRouter,
            intentRetryBackoffMs: 1,
            planRetryBackoffMs: 1
        )
        self.tonePreferenceStore = .shared
        self.faceGreetingManager = faceGreetingManager ?? FaceGreetingManager()
        self.cameraVision = cameraVision
        self.intentLocalTimeoutSeconds = TurnOrchestrator.sanitizedLocalIntentTimeout(localIntentTimeoutSeconds ?? M2Settings.localIntentTimeoutSeconds)
        self.intentClassifier = TurnOrchestrator.makeIntentClassifier(
            ollamaRouter: ollamaRouter,
            openAIProvider: self.openAIProvider,
            localTimeoutSeconds: intentLocalTimeoutSeconds,
            openAITimeoutSeconds: intentOpenAITimeoutSeconds
        )
        self.routerOverride = router
        self.toolRunner = toolRunner ?? TurnToolRunner(planExecutor: .shared, toolsRuntime: ToolsRuntime.shared)
        self.memoryAckCooldownTurns = max(1, memoryAckCooldownTurns)
        self.followUpCooldownTurns = max(1, followUpCooldownTurns)
    }

    // Backward-compatible initializer retained for existing callsites/tests.
    convenience init(ollamaRouter: OllamaRouter,
                     openAIRouter: OpenAIRouter,
                     faceGreetingManager: FaceGreetingManager? = nil,
                     localIntentTimeoutSeconds: Double? = nil,
                     router: TurnRouting? = nil,
                     openAIProvider: OpenAIProviderRouting? = nil,
                     toolRunner: TurnToolRunning? = nil,
                     memoryAckCooldownTurns: Int = 20,
                     followUpCooldownTurns: Int = 3) {
        self.init(ollamaRouter: ollamaRouter,
                  openAIRouter: openAIRouter,
                  faceGreetingManager: faceGreetingManager,
                  cameraVision: CameraVisionService.shared,
                  localIntentTimeoutSeconds: localIntentTimeoutSeconds,
                  router: router,
                  openAIProvider: openAIProvider,
                  toolRunner: toolRunner,
                  memoryAckCooldownTurns: memoryAckCooldownTurns,
                  followUpCooldownTurns: followUpCooldownTurns)
    }

    func makeDefaultRouter() -> TurnRouting {
        TurnRouter(
            classifyIntent: { [intentClassifier] input, useLocalFirst, allowOpenAIFallback in
                await intentClassifier.classify(
                    input,
                    useLocalFirst: useLocalFirst,
                    allowOpenAIFallback: allowOpenAIFallback
                )
            },
            routePlan: { [weak self] request in
                guard let self else {
                    return RouteDecision(
                        plan: Plan(steps: [.talk(say: "Sorry — I had trouble generating a response. Please try again.")]),
                        provider: .none,
                        routerMs: 0,
                        aiModelUsed: nil,
                        routeReason: "router_deallocated",
                        planLocalWireMs: nil,
                        planLocalTotalMs: nil,
                        planOpenAIMs: nil
                    )
                }
                let routed = await self.routePlan(
                    request.text,
                    history: request.history,
                    pendingSlot: request.pendingSlot,
                    reason: request.reason,
                    promptContext: request.promptContext
                )
                return RouteDecision(
                    plan: routed.0,
                    provider: routed.1,
                    routerMs: routed.2,
                    aiModelUsed: routed.3,
                    routeReason: routed.4,
                    planLocalWireMs: routed.5,
                    planLocalTotalMs: routed.6,
                    planOpenAIMs: routed.7
                )
            },
            routeCombined: { [weak self] request in
                guard let self else {
                    let classification = IntentClassificationResult(
                        classification: IntentClassification(
                            intent: .unknown,
                            confidence: 0.2,
                            notes: "",
                            autoCaptureHint: false,
                            needsWeb: false
                        ),
                        provider: .rule,
                        attemptedLocal: false,
                        attemptedOpenAI: false,
                        localSkipReason: "router_deallocated",
                        intentRouterMsLocal: nil,
                        intentRouterMsOpenAI: nil,
                        localConfidence: nil,
                        openAIConfidence: nil,
                        confidenceThreshold: 0.7,
                        localTimeoutSeconds: nil,
                        escalationReason: "router_deallocated"
                    )
                    let route = RouteDecision(
                        plan: Plan(steps: [.talk(say: "Sorry — I had trouble generating a response. Please try again.")]),
                        provider: .none,
                        routerMs: 0,
                        aiModelUsed: nil,
                        routeReason: "router_deallocated",
                        planLocalWireMs: nil,
                        planLocalTotalMs: nil,
                        planOpenAIMs: nil
                    )
                    return CombinedRouteDecision(
                        classification: classification,
                        route: route,
                        localAttempted: false,
                        localOutcome: "router_deallocated",
                        localMs: nil,
                        openAIMs: nil
                    )
                }
                return await self.routeCombined(
                    request.text,
                    history: request.history,
                    pendingSlot: request.pendingSlot,
                    reason: request.reason,
                    promptContext: request.promptContext,
                    state: request.state
                )
            },
            nativeToolExists: { category in
                TurnOrchestrator.hasNativeTool(for: category)
            },
            normalizeToolName: { raw in
                ToolRegistry.shared.normalizeToolName(raw)
            },
            isAllowedTool: { name in
                ToolRegistry.shared.isAllowedTool(name)
            }
        )
    }

    static func makeIntentClassifier(ollamaRouter: OllamaRouter,
                                             openAIProvider: OpenAIProviderRouting,
                                             localTimeoutSeconds: Double? = nil,
                                             openAITimeoutSeconds: Double? = nil) -> IntentClassifier {
        IntentClassifier(
            localClassifier: { input in
                try await ollamaRouter.classifyIntentWithTrace(input)
            },
            openAIClassifier: { input in
                try await openAIProvider.classifyIntentWithRetry(
                    input,
                    timeoutSeconds: openAITimeoutSeconds
                ).output
            },
            localInferenceExecutor: sharedIntentInferenceExecutor,
            localTimeoutSeconds: localTimeoutSeconds,
            openAITimeoutSeconds: nil
        )
    }

    static func sanitizedLocalIntentTimeout(_ value: Double) -> Double {
        min(10.0, max(0.2, value))
    }

    func resolvedVisionIntent(from classification: IntentClassification,
                                      userInput: String) -> VisionQueryIntent {
        switch classification.intent {
        case .visionDescribe:
            return .describe
        case .visionQA:
            return .visualQA(question: classification.notes.isEmpty ? userInput : classification.notes)
        case .visionFindObject:
            return .findObject(query: classification.notes.isEmpty ? userInput : classification.notes)
        default:
            return .none
        }
    }

    func logIntentClassification(_ result: IntentClassificationResult) {
        #if DEBUG
        let confidence = String(format: "%.2f", result.classification.confidence)
        var line = "[INTENT] intent=\(result.classification.intent.rawValue) " +
            "conf=\(confidence) provider=\(result.provider.rawValue) " +
            "local_attempted=\(result.attemptedLocal) openai_attempted=\(result.attemptedOpenAI) " +
            "intent_router_ms_local=\(result.intentRouterMsLocal.map(String.init) ?? "nil") " +
            "intent_router_ms_openai=\(result.intentRouterMsOpenAI.map(String.init) ?? "nil") " +
            "local_timeout_s=\(result.localTimeoutSeconds.map { String(format: "%.2f", $0) } ?? "nil")"
        if let reason = result.localSkipReason {
            line += " local_skip_reason=\(reason)"
        }
        if let reason = result.escalationReason {
            line += " escalation_reason=\(reason)"
        }
        print(line)
        #endif
    }

    func logIntentProviderSelection(_ provider: IntentClassificationProvider) {
        #if DEBUG
        print("[INTENT_PROVIDER] provider=\(provider.rawValue)")
        #endif
    }

    func logPlanProviderSelection(provider: LLMProvider,
                                          routeReason: String,
                                          routerMs: Int,
                                          aiModelUsed: String?) {
        #if DEBUG
        print("[PLAN_PROVIDER] provider=\(provider.rawValue)")
        print("[PLAN] provider=\(provider.rawValue) route_reason=\(routeReason) router_ms=\(routerMs) model=\(aiModelUsed ?? "n/a")")
        #endif
    }

    func logIntentAudioCorrelation(inputMode: TurnInputMode) {
        #if DEBUG
        let mode: String
        switch inputMode {
        case .voice:
            mode = "voice"
        case .text:
            mode = "text"
        case .unspecified:
            mode = "unspecified"
        }
        let snapshot = IntentAudioDiagnosticsStore.shared.snapshot()
        let capture = snapshot.captureMs.map(String.init) ?? "n/a"
        let stt = snapshot.sttMs.map(String.init) ?? "n/a"
        let error = snapshot.recentAudioError ?? "none"
        print("[INTENT_AUDIO] input_mode=\(mode) capture_ms=\(capture) stt_ms=\(stt) recent_audio_error=\(error) local_timeout_s=\(String(format: "%.2f", intentLocalTimeoutSeconds))")
        #endif
    }

    func processTurn(_ text: String, history: [ChatMessage], inputMode: TurnInputMode) async -> TurnResult {
        // Cancel any in-flight routing from a previous turn
        if currentRoutingTask != nil {
            #if DEBUG
            print("[OPENAI_CANCEL] turn=\(turnCounter) cancelling_stale_routing_task")
            #endif
        }
        currentRoutingTask?.cancel()
        currentRoutingTask = nil
        turnCounter += 1
        defer {
            currentIntentClassification = nil
            currentTurnCaptureAfterReplyHint = false
        }
        let currentTurn = turnCounter
        let now = Date()
        let turnStartedAt = Date()
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let userText = sanitized.isEmpty ? text : sanitized
        // Skill Evolution: detect outcome signal from previous turn's strategy
        let outcomeSignal = SkillEvolutionLoop.shared.detectSignal(
            userText: userText,
            previousStrategy: lastFinalActionKind
        )
        if outcomeSignal != .neutral, !lastFinalActionKind.isEmpty {
            SkillEvolutionLoop.shared.recordOutcome(
                strategyName: lastFinalActionKind,
                category: "routing",
                intentType: lastIntentClassification?.classification.intent.rawValue ?? "unknown",
                signal: outcomeSignal,
                routerMs: nil,
                turnID: "turn_\(currentTurn)"
            )
        }

        // Track user's open loops for proactive follow-up
        detectAndTrackOpenLoops(from: userText)
        let localKnowledgeContext = buildLocalKnowledgeContext(for: userText)
        let hasMemoryHints = localKnowledgeContext.hasMemoryHints
        #if DEBUG
        if hasMemoryHints {
            DebugLogStore.shared.logMemory(
                turnID: "turn_\(currentTurn)",
                action: "recall",
                summary: "Memory context found for query",
                detail: String(localKnowledgeContext.memoryPromptBlock.prefix(200))
            )
        }
        #endif
        if localKnowledgeContext.memoryShouldClarify,
           let clarification = localKnowledgeContext.memoryClarificationPrompt {
            var immediate = immediateTalkTurnResult(message: clarification)
            immediate.llmProvider = .none
            immediate.originProvider = .local
            immediate.executionProvider = .local
            immediate.originReason = "memory_confidence_clarify"
            immediate.routerMs = 0
            applyRoutingAttribution(&immediate, planProvider: .none, planRouterMs: 0)
            return immediate
        }
        let mode = ConversationModeClassifier.classify(userText)
        let identityDecision = faceGreetingManager.prepareTurn(
            userInput: userText,
            inputMode: inputMode,
            now: now,
            userInitiated: true
        )
        currentFaceIdentityContext = identityDecision.context
        let lastAssistantLine = history.reversed().first(where: { $0.role == .assistant })?.text
        let intentInput = IntentClassifierInput(
            userText: userText,
            cameraRunning: cameraVision.isRunning,
            faceKnown: !(identityDecision.context.recognizedUserName?.isEmpty ?? true),
            pendingSlot: pendingSlot?.slotName,
            lastAssistantLine: lastAssistantLine
        )
        OpenAISettings.preloadAPIKey()
        OpenAISettings.clearInvalidatedAPIKeyIfNeeded()
        let intentRoutePolicy = IntentRoutePolicy(useOllama: M2Settings.useOllama)
        let useCombinedRouting = (inputMode == .voice)
        var combinedRouteDecision: CombinedRouteDecision?
        let combinedPendingSlotSnapshot = pendingSlot
        #if DEBUG
        print("[INTENT_ROUTE_POLICY] local_first=\(intentRoutePolicy.localFirst) openai_fallback=\(intentRoutePolicy.openAIFallback) m2_useOllama=\(M2Settings.useOllama) openai_status=\(OpenAISettings.apiKeyStatus)")
        #endif
        logIntentAudioCorrelation(inputMode: inputMode)
        let intentClassification: IntentClassificationResult
        if useCombinedRouting {
            let combinedReason: LLMCallReason = pendingSlot == nil ? .userChat : .pendingSlotReply
            let combined = await router.routeCombined(
                TurnCombinedRouteRequest(
                    text: userText,
                    history: history,
                    pendingSlot: pendingSlot,
                    reason: combinedReason,
                    promptContext: nil,
                    state: TurnRouterState(
                        cameraRunning: intentInput.cameraRunning,
                        faceKnown: intentInput.faceKnown,
                        pendingSlot: intentInput.pendingSlot,
                        lastAssistantLine: intentInput.lastAssistantLine
                    )
                )
            )
            combinedRouteDecision = combined
            intentClassification = combined.classification
        } else {
            intentClassification = await router.classifyIntent(
                intentInput,
                policy: intentRoutePolicy
            )
        }
        currentIntentClassification = intentClassification
        lastIntentClassification = intentClassification
        currentTurnCaptureAfterReplyHint = intentClassification.classification.autoCaptureHint
        logIntentClassification(intentClassification)
        logIntentProviderSelection(intentClassification.provider)
        #if DEBUG
        DebugLogStore.shared.logIntent(
            turnID: "turn_\(currentTurn)",
            intent: intentClassification.classification.intent.rawValue,
            confidence: intentClassification.classification.confidence,
            provider: intentClassification.provider.rawValue
        )
        #endif

        // Lightweight (no LLM) engines run immediately — zero latency cost.
        let turnMode = ConversationModeClassifier.classify(userText)
        let turnAffect = ConversationAffectClassifier.classify(userText, history: history)
        LongitudinalPatternEngine.shared.recordTurnSignal(
            topic: "\(turnMode.intent.rawValue):\(turnMode.domain.rawValue)",
            affect: turnAffect.affect.rawValue,
            intentType: turnMode.intent.rawValue
        )
        let personalitySignal = PersonalityEngine.shared.detectSignal(userText: userText)
        PersonalityEngine.shared.recordInteraction(userText: userText, signal: personalitySignal)
        ActiveCuriosityEngine.shared.attemptResolution(userText: userText)

        // LLM-dependent intelligence engines are deferred to AFTER the main route completes.
        // Launching them now would starve Ollama with 7+ concurrent requests,
        // causing the main routing call to timeout. They enrich future turns, not this one.
        let deferredTurnID = "turn_\(currentTurn)"
        let deferredMemoryBlock = localKnowledgeContext.memoryPromptBlock

        if case .enroll(let name, let confirmation, let providerNoneReason) = identityDecision.action {
            var immediate = immediateTalkTurnResult(message: confirmation)
            immediate.llmProvider = .none
            immediate.originProvider = .local
            immediate.executionProvider = .local
            immediate.originReason = providerNoneReason
            immediate.routerMs = 0
            immediate.executedToolSteps = [("enroll_camera_face", ["name": name])]
            applyResponsePolish(&immediate,
                                plan: Plan(steps: [.talk(say: immediate.spokenLines.first ?? "")]),
                                hasMemoryHints: hasMemoryHints,
                                turnIndex: currentTurn)
            updateAssistantState(after: immediate, mode: mode)
            rememberAssistantLines(immediate.appendedChat)
            logIdentityTurn(decision: identityDecision,
                            now: now,
                            provider: immediate.llmProvider,
                            routeReason: providerNoneReason,
                            routerMs: immediate.routerMs)
            applyRoutingAttribution(&immediate, planProvider: immediate.llmProvider, planRouterMs: immediate.routerMs)
            return immediate
        }

        let visionIntent = resolvedVisionIntent(
            from: intentClassification.classification,
            userInput: userText
        )
        if case .none = visionIntent {
            // Not a camera vision intent.
        } else {
            if !cameraVision.isRunning {
                var immediate = immediateTalkTurnResult(
                    message: "I need the camera on to see anything - turn it on and ask again."
                )
                immediate.llmProvider = .none
                immediate.originProvider = .local
                immediate.executionProvider = .local
                immediate.originReason = "vision_camera_off"
                immediate.routerMs = 0
                applyResponsePolish(
                    &immediate,
                    plan: Plan(steps: [.talk(say: immediate.spokenLines.first ?? "")]),
                    hasMemoryHints: hasMemoryHints,
                    turnIndex: currentTurn
                )
                updateAssistantState(after: immediate, mode: mode)
                rememberAssistantLines(immediate.appendedChat)
                logIdentityTurn(
                    decision: identityDecision,
                    now: now,
                    provider: immediate.llmProvider,
                    routeReason: "vision_camera_off",
                    routerMs: immediate.routerMs
                )
                applyRoutingAttribution(&immediate, planProvider: immediate.llmProvider, planRouterMs: immediate.routerMs)
                return immediate
            }

            if !cameraVision.health.isHealthy {
                var immediate = immediateTalkTurnResult(
                    message: "My camera feed is lagging or not updating right now - try toggling the camera off/on."
                )
                immediate.llmProvider = .none
                immediate.originProvider = .local
                immediate.executionProvider = .local
                immediate.originReason = "vision_camera_unhealthy"
                immediate.routerMs = 0
                applyResponsePolish(
                    &immediate,
                    plan: Plan(steps: [.talk(say: immediate.spokenLines.first ?? "")]),
                    hasMemoryHints: hasMemoryHints,
                    turnIndex: currentTurn
                )
                updateAssistantState(after: immediate, mode: mode)
                rememberAssistantLines(immediate.appendedChat)
                logIdentityTurn(
                    decision: identityDecision,
                    now: now,
                    provider: immediate.llmProvider,
                    routeReason: "vision_camera_unhealthy",
                    routerMs: immediate.routerMs
                )
                applyRoutingAttribution(&immediate, planProvider: immediate.llmProvider, planRouterMs: immediate.routerMs)
                return immediate
            }

            if shouldRunVisionToolFirst(for: visionIntent) {
                let visionResult = await runVisionToolFirstTurn(
                    intent: visionIntent,
                    text: userText,
                    history: history,
                    mode: mode,
                    localKnowledgeContext: localKnowledgeContext,
                    hasMemoryHints: hasMemoryHints,
                    turnIndex: currentTurn,
                    turnStartedAt: turnStartedAt,
                    identityDecision: identityDecision,
                    now: now
                )
                return visionResult
            }
        }

        if let capabilityResult = await handlePendingCapabilityRequestTurn(
            text: userText,
            history: history,
            mode: mode,
            localKnowledgeContext: localKnowledgeContext,
            hasMemoryHints: hasMemoryHints,
            turnIndex: currentTurn,
            turnStartedAt: turnStartedAt,
            identityDecision: identityDecision,
            now: now
        ) {
            return capabilityResult
        }

        if router.shouldEnterExternalSourceCapabilityGapFlow(
            CapabilityGapRouteInput(
                text: userText,
                classification: intentClassification.classification,
                provider: intentClassification.provider,
                pendingSlot: pendingSlot,
                pendingCapabilityRequest: pendingCapabilityRequest,
                confidenceThreshold: intentClassification.confidenceThreshold
            )
        ) {
            let sourcePlan = buildExternalSourceAskPlan(
                toolName: "external_source",
                userText: userText,
                now: now,
                prefersWebsiteURL: true
            )
            lastFinalActionKind = inferredActionKind(for: sourcePlan)
            var result = await executePlan(
                sourcePlan,
                originalInput: userText,
                history: history,
                provider: .none,
                aiModelUsed: nil,
                routerMs: 0,
                localKnowledgeContext: localKnowledgeContext,
                hasMemoryHints: hasMemoryHints,
                turnIndex: currentTurn,
                feedbackDepth: 0,
                turnStartedAt: turnStartedAt,
                mode: mode,
                affect: .neutral,
                originReason: "capability_gap_external_source_pre_route"
            )
            appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
            logIdentityTurn(
                decision: identityDecision,
                now: now,
                provider: .none,
                routeReason: "capability_gap_external_source_pre_route",
                routerMs: 0
            )
            return result
        }

        // Recipe routing is now handled by the LLM via the system prompt.
        // No recipe-first bypass — trust the LLM to use find_recipe when appropriate.

        // Cognitive trace runs fully in background — never block the turn.
        // Enrichment context is read from engine snapshots at prompt build time.

        let rawAffect = ConversationAffectClassifier.classify(userText, history: history)
        let affectMirroringEnabled = M2Settings.affectMirroringEnabled
        let useEmotionalTone = M2Settings.useEmotionalTone
        let containsClinicalOrCrisis = TonePreferenceLearner.containsClinicalOrCrisisLanguage(userText, mode: mode)
        var toneProfile = tonePreferenceStore.loadProfile()
        var toneRepairCue: String?
        if let learningOutcome = TonePreferenceLearner.learn(
            from: userText,
            mode: mode,
            affect: rawAffect,
            profile: toneProfile,
            useEmotionalTone: useEmotionalTone,
            updatesInLast24Hours: tonePreferenceStore.updatesInLast24Hours(now: now)
        ) {
            toneProfile = tonePreferenceStore.applyLearningOutcome(learningOutcome, at: now)
            toneRepairCue = learningOutcome.toneRepairCue
            logToneLearning(outcome: learningOutcome, profile: toneProfile)
        }
        let effectiveToneProfile = (toneProfile.enabled && useEmotionalTone && !containsClinicalOrCrisis) ? toneProfile : nil
        let effectiveAffect: AffectMetadata = (affectMirroringEnabled && useEmotionalTone)
            ? rawAffect
            : .neutral
        logAffectClassification(raw: rawAffect,
                                effective: effectiveAffect,
                                featureEnabled: affectMirroringEnabled,
                                userToneEnabled: useEmotionalTone)
        intentRepetitionTracker.record(mode.intent, at: now)
        purgeExpiredFacts(now: now)
        updateRecentFacts(with: userText, mode: mode, now: now)
        updateQuestionAnswerState(with: userText)
        let sessionSummary = summaryService.currentSummary(
            history: history,
            currentMode: mode,
            latestUserTurn: userText
        )
        // Inject intelligence engine context into prompt
        let enrichedMemoryBlock: String = {
            var parts = [localKnowledgeContext.memoryPromptBlock]
            let reasoningBlock = CognitiveTraceEngine.shared.reasoningContextBlock(limit: 3)
            if !reasoningBlock.isEmpty { parts.append(reasoningBlock) }
            let worldBlock = LivingWorldModel.shared.worldContextBlock(for: userText, limit: 5)
            if !worldBlock.isEmpty { parts.append(worldBlock) }
            let patternsBlock = LongitudinalPatternEngine.shared.patternsContextBlock(limit: 3)
            if !patternsBlock.isEmpty { parts.append(patternsBlock) }
            let personalityBlock = PersonalityEngine.shared.personalityPromptBlock()
            if !personalityBlock.isEmpty { parts.append("[PERSONALITY STATE]\n\(personalityBlock)") }
            let cfBlock = CounterfactualSimulationEngine.shared.simulationContextBlock()
            if !cfBlock.isEmpty { parts.append("[DECISION ANALYSIS]\n\(cfBlock)") }
            let tomBlock = TheoryOfMindEngine.shared.socialContextBlock(for: userText)
            if !tomBlock.isEmpty { parts.append("[SOCIAL CONTEXT]\n\(tomBlock)") }
            let metaBlock = MetaCognitionEngine.shared.uncertaintyContextBlock()
            if !metaBlock.isEmpty { parts.append("[CONFIDENCE CALIBRATION]\n\(metaBlock)") }
            let narrativeBlock = NarrativeCoherenceEngine.shared.narrativeContextBlock(for: userText)
            if !narrativeBlock.isEmpty { parts.append("[NARRATIVE THREADS]\n\(narrativeBlock)") }
            let causalBlock = CausalLearningEngine.shared.causalInsightsBlock()
            if !causalBlock.isEmpty { parts.append("[CAUSAL INSIGHTS]\n\(causalBlock)") }
            return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }()

        let promptContext = buildPromptRuntimeContext(
            mode: mode,
            affect: effectiveAffect,
            tonePreferences: effectiveToneProfile,
            toneRepairCue: toneRepairCue,
            userInput: userText,
            history: history,
            sessionSummary: sessionSummary,
            memoryPromptBlock: enrichedMemoryBlock,
            now: now,
            faceIdentityContext: currentFaceIdentityContext
        )
        lastPromptContext = promptContext

        // PendingSlot handling — always route through LLM
        let pendingSlotEvaluation = router.evaluatePendingSlot(
            pendingSlot,
            pendingCapabilityRequest: pendingCapabilityRequest,
            now: now
        )
        pendingSlot = pendingSlotEvaluation.pendingSlot
        pendingCapabilityRequest = pendingSlotEvaluation.pendingCapabilityRequest

        switch pendingSlotEvaluation.action {
        case .retryExhausted(let msg):
            var result = TurnResult()
            result.appendedChat.append(ChatMessage(role: .assistant, text: msg))
            result.spokenLines.append(msg)
            logIdentityTurn(decision: identityDecision,
                            now: now,
                            provider: .none,
                            routeReason: "pending_slot_retry_exhausted",
                            routerMs: nil)
            applyRoutingAttribution(&result, planProvider: LLMProvider.none, planRouterMs: nil)
            return result
        case .continueWithSlot(let slot):
            let reusedCombinedForPendingSlot = shouldReuseCombinedRouteDecision(
                combinedRouteDecision,
                requestedPendingSlot: slot,
                initialPendingSlot: combinedPendingSlotSnapshot,
                expectedReason: .pendingSlotReply
            )
            let routed: RouteDecision
            let combinedUsed: CombinedRouteDecision?
            if reusedCombinedForPendingSlot, let combined = combinedRouteDecision {
                routed = combined.route
                combinedUsed = combined
                combinedRouteDecision = nil
            } else {
                routed = await router.routePlan(TurnPlanRouteRequest(
                    text: userText,
                    history: history,
                    pendingSlot: slot,
                    reason: .pendingSlotReply,
                    promptContext: promptContext,
                    intentClassification: currentIntentClassification?.classification
                ))
                combinedUsed = nil
            }
            logPlanProviderSelection(provider: routed.provider,
                                     routeReason: routed.routeReason,
                                     routerMs: routed.routerMs,
                                     aiModelUsed: routed.aiModelUsed)
            let guardedPlan = enforceNoFalseBlindnessGuardrail(on: routed.plan, userInput: userText)
            let plan = await maybeRephraseRepeatedTalk(guardedPlan,
                                                       userInput: userText,
                                                       history: history,
                                                       mode: mode,
                                                       turnIndex: currentTurn,
                                                       turnStartedAt: turnStartedAt)
            let shapedPlan = enforceLengthPresentationPolicy(plan, mode: mode)

            let slotResolution = router.resolvePendingSlotAfterPlan(
                shapedPlan,
                previousSlot: slot,
                pendingCapabilityRequest: pendingCapabilityRequest
            )
            pendingSlot = slotResolution.pendingSlot
            pendingCapabilityRequest = slotResolution.pendingCapabilityRequest

            lastFinalActionKind = inferredActionKind(for: shapedPlan)
            var result = await executePlan(shapedPlan,
                                           originalInput: userText,
                                           history: history,
                                           provider: routed.provider,
                                           aiModelUsed: routed.aiModelUsed,
                                           routerMs: routed.routerMs,
                                           planLocalWireMs: routed.planLocalWireMs,
                                           planLocalTotalMs: routed.planLocalTotalMs,
                                           planOpenAIMs: routed.planOpenAIMs,
                                           localKnowledgeContext: localKnowledgeContext,
                                           hasMemoryHints: hasMemoryHints,
                                           turnIndex: currentTurn,
                                           feedbackDepth: 0,
                                           turnStartedAt: turnStartedAt,
                                           mode: mode,
                                           toneRepairCue: toneRepairCue,
                                           affect: effectiveAffect,
                                           originReason: routed.routeReason)
            applyCombinedRouteMetadata(&result, combinedDecision: combinedUsed)
            appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
            logIdentityTurn(decision: identityDecision,
                            now: now,
                            provider: routed.provider,
                            routeReason: routed.routeReason,
                            routerMs: routed.routerMs)
            return result
        case .none:
            break
        }

        // Normal LLM routing (no pending slot)
        let reusedCombinedForUserChat = shouldReuseCombinedRouteDecision(
            combinedRouteDecision,
            requestedPendingSlot: nil,
            initialPendingSlot: combinedPendingSlotSnapshot,
            expectedReason: .userChat
        )
        let routed: RouteDecision
        let combinedUsed: CombinedRouteDecision?
        if reusedCombinedForUserChat, let combined = combinedRouteDecision {
            routed = combined.route
            combinedUsed = combined
            combinedRouteDecision = nil
        } else {
            routed = await router.routePlan(TurnPlanRouteRequest(
                text: userText,
                history: history,
                pendingSlot: nil,
                reason: .userChat,
                promptContext: promptContext,
                intentClassification: currentIntentClassification?.classification
            ))
            combinedUsed = nil
        }
        logPlanProviderSelection(provider: routed.provider,
                                 routeReason: routed.routeReason,
                                 routerMs: routed.routerMs,
                                 aiModelUsed: routed.aiModelUsed)
        let guardedPlan = enforceNoFalseBlindnessGuardrail(on: routed.plan, userInput: userText)
        let plan = await maybeRephraseRepeatedTalk(guardedPlan,
                                                   userInput: userText,
                                                   history: history,
                                                   mode: mode,
                                                   turnIndex: currentTurn,
                                                   turnStartedAt: turnStartedAt)
        let shapedPlan = enforceLengthPresentationPolicy(plan, mode: mode)
        lastFinalActionKind = inferredActionKind(for: shapedPlan)
        var result = await executePlan(shapedPlan,
                                       originalInput: userText,
                                       history: history,
                                       provider: routed.provider,
                                       aiModelUsed: routed.aiModelUsed,
                                       routerMs: routed.routerMs,
                                       planLocalWireMs: routed.planLocalWireMs,
                                       planLocalTotalMs: routed.planLocalTotalMs,
                                       planOpenAIMs: routed.planOpenAIMs,
                                       localKnowledgeContext: localKnowledgeContext,
                                       hasMemoryHints: hasMemoryHints,
                                       turnIndex: currentTurn,
                                       feedbackDepth: 0,
                                       turnStartedAt: turnStartedAt,
                                       mode: mode,
                                       toneRepairCue: toneRepairCue,
                                       affect: effectiveAffect,
                                       originReason: routed.routeReason)
        applyCombinedRouteMetadata(&result, combinedDecision: combinedUsed)
        appendIdentityPromptIfNeeded(identityDecision.promptToAppend, to: &result)
        logIdentityTurn(decision: identityDecision,
                        now: now,
                        provider: routed.provider,
                        routeReason: routed.routeReason,
                        routerMs: routed.routerMs)
        // MetaCognition Engine: evaluate response confidence in background
        let responseText = result.spokenLines.joined(separator: " ")
        if !responseText.isEmpty {
            Task {
                await MetaCognitionEngine.shared.evaluateResponse(
                    messageID: "turn_\(currentTurn)",
                    userQuery: userText,
                    assistantResponse: responseText
                )
            }
        }

        // Deferred intelligence engines — run AFTER routing to avoid starving Ollama.
        // These enrich future turns via their persisted context, not the current one.
        launchDeferredIntelligenceEngines(turnID: deferredTurnID,
                                          userText: userText,
                                          memoryBlock: deferredMemoryBlock)

        return result
    }

    /// Launch LLM-dependent intelligence engines after the main route completes.
    /// Uses EngineScheduler to cap at 3 concurrent API calls.
    private func launchDeferredIntelligenceEngines(turnID: String,
                                                    userText: String,
                                                    memoryBlock: String) {
        let scheduler = EngineScheduler.shared

        Task {
            await scheduler.run {
                #if DEBUG
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "CognitiveTrace", event: "started")
                #endif
                let start = CFAbsoluteTimeGetCurrent()
                let trace = await CognitiveTraceEngine.shared.reason(
                    turnID: turnID,
                    userInput: userText,
                    recentContext: memoryBlock
                )
                #if DEBUG
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "CognitiveTrace",
                    event: trace != nil ? "done conf=\(String(format: "%.0f%%", (trace?.confidence ?? 0) * 100))" : "no result",
                    durationMs: ms)
                #endif
            }
        }
        Task {
            await scheduler.run {
                #if DEBUG
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "LivingWorld", event: "started")
                #endif
                let start = CFAbsoluteTimeGetCurrent()
                await LivingWorldModel.shared.processConversation(
                    turnID: turnID,
                    text: userText
                )
                #if DEBUG
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "LivingWorld", event: "done", durationMs: ms)
                #endif
            }
        }
        Task {
            await scheduler.run {
                #if DEBUG
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "ActiveCuriosity", event: "started")
                #endif
                let start = CFAbsoluteTimeGetCurrent()
                await ActiveCuriosityEngine.shared.detectGaps(
                    turnID: turnID,
                    userText: userText
                )
                #if DEBUG
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "ActiveCuriosity", event: "done", durationMs: ms)
                #endif
            }
        }
        Task {
            await scheduler.run {
                #if DEBUG
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "Counterfactual", event: "started")
                #endif
                let start = CFAbsoluteTimeGetCurrent()
                await CounterfactualSimulationEngine.shared.processTurn(
                    turnID: turnID,
                    userInput: userText
                )
                #if DEBUG
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "Counterfactual", event: "done", durationMs: ms)
                #endif
            }
        }
        Task {
            await scheduler.run {
                #if DEBUG
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "TheoryOfMind", event: "started")
                #endif
                let start = CFAbsoluteTimeGetCurrent()
                await TheoryOfMindEngine.shared.processConversation(
                    turnID: turnID,
                    userText: userText
                )
                #if DEBUG
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "TheoryOfMind", event: "done", durationMs: ms)
                #endif
            }
        }
        Task {
            await scheduler.run {
                #if DEBUG
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "Narrative", event: "started")
                #endif
                let start = CFAbsoluteTimeGetCurrent()
                await NarrativeCoherenceEngine.shared.processConversation(
                    turnID: turnID,
                    userText: userText
                )
                #if DEBUG
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "Narrative", event: "done", durationMs: ms)
                #endif
            }
        }
        Task {
            await scheduler.run {
                #if DEBUG
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "CausalLearning", event: "started")
                #endif
                let start = CFAbsoluteTimeGetCurrent()
                await CausalLearningEngine.shared.ingestConversation(
                    turnID: turnID,
                    userText: userText
                )
                #if DEBUG
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                await DebugLogStore.shared.logEngine(turnID: turnID, name: "CausalLearning", event: "done", durationMs: ms)
                #endif
            }
        }
    }

}
