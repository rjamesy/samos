import Foundation

/// The result of processing a turn through the pipeline.
struct TurnResult: Sendable {
    let sayText: String
    let outputItems: [OutputItem]
    let latencyMs: Int
    let usedMemory: Bool
    let toolCalls: [String]
    let engineSummary: String
}

/// Contract for the turn orchestrator.
protocol TurnOrchestrating: Sendable {
    func processTurn(text: String, history: [ChatMessage], sessionId: String, attachments: [ChatAttachment]) async throws -> TurnResult
}

extension TurnOrchestrating {
    func processTurn(text: String, history: [ChatMessage], sessionId: String) async throws -> TurnResult {
        try await processTurn(text: text, history: history, sessionId: sessionId, attachments: [])
    }
}

/// DI container — wires all services. All dependencies are protocol-typed for testability.
@MainActor
final class AppContainer {
    // MARK: - Core
    let settings: any SettingsStoreProtocol
    let database: DatabaseManager

    // MARK: - LLM
    let llmClient: any LLMClient

    // MARK: - Memory
    let memoryStore: any MemoryStoreProtocol
    let memorySearch: MemorySearch
    let memoryInjector: MemoryInjector
    let memoryAutoSave: MemoryAutoSave
    let crossSessionHistory: CrossSessionHistory
    let semanticMemoryEngine: SemanticMemoryEngine

    // MARK: - Tools
    let toolRegistry: ToolRegistry

    // MARK: - Skills
    let skillStore: any SkillStoreProtocol
    let skillEngine: SkillEngine
    let skillForge: SkillForge

    // MARK: - Pipeline
    let promptBuilder: PromptBuilder
    let responseParser: ResponseParser
    let planExecutor: PlanExecutor
    let orchestrator: TurnOrchestrator

    // MARK: - Intelligence
    let engineScheduler: EngineScheduler

    // MARK: - Speech
    let elevenlabsClient: ElevenLabsClient
    let openAITTSClient: OpenAITTSClient
    let ttsService: TTSService
    let sttService: STTService
    let voicePipeline: VoicePipeline
    let speechRecognition: SpeechRecognitionService
    let wakeWordService: WakeWordService

    // MARK: - Scheduling
    let taskScheduler: TaskScheduler

    // MARK: - Ambient / Proactive
    let proactiveAwareness: ProactiveAwareness
    let ambientListening: AmbientListeningService

    // MARK: - Web / Learning
    let webLearningService: WebLearningService
    let autonomousResearch: AutonomousResearchService

    // MARK: - Vision / Camera
    let cameraService: CameraService
    let visionProcessor: VisionProcessor
    let gptVisionClient: GPTVisionClient
    let emotionDetector: EmotionDetector
    let faceEnrollment: FaceEnrollment

    // MARK: - Email
    let googleAuthService: GoogleAuthService
    let gmailClient: GmailClient

    // MARK: - Embeddings
    let embeddingClient: OpenAIEmbeddingClient

    // MARK: - API Server
    let apiHandler: APIHandler
    let alexaHandler: AlexaHandler
    let apiServer: SamAPIServer?

    init(
        settings: any SettingsStoreProtocol,
        database: DatabaseManager,
        llmClient: any LLMClient,
        memoryStore: any MemoryStoreProtocol,
        memorySearch: MemorySearch,
        memoryInjector: MemoryInjector,
        memoryAutoSave: MemoryAutoSave,
        crossSessionHistory: CrossSessionHistory,
        semanticMemoryEngine: SemanticMemoryEngine,
        toolRegistry: ToolRegistry,
        skillStore: any SkillStoreProtocol,
        skillEngine: SkillEngine,
        skillForge: SkillForge,
        promptBuilder: PromptBuilder,
        responseParser: ResponseParser,
        planExecutor: PlanExecutor,
        orchestrator: TurnOrchestrator,
        engineScheduler: EngineScheduler,
        elevenlabsClient: ElevenLabsClient,
        openAITTSClient: OpenAITTSClient,
        ttsService: TTSService,
        sttService: STTService,
        voicePipeline: VoicePipeline,
        speechRecognition: SpeechRecognitionService,
        wakeWordService: WakeWordService,
        taskScheduler: TaskScheduler,
        proactiveAwareness: ProactiveAwareness,
        ambientListening: AmbientListeningService,
        webLearningService: WebLearningService,
        autonomousResearch: AutonomousResearchService,
        cameraService: CameraService,
        visionProcessor: VisionProcessor,
        gptVisionClient: GPTVisionClient,
        emotionDetector: EmotionDetector,
        faceEnrollment: FaceEnrollment,
        googleAuthService: GoogleAuthService,
        gmailClient: GmailClient,
        embeddingClient: OpenAIEmbeddingClient,
        apiHandler: APIHandler,
        alexaHandler: AlexaHandler,
        apiServer: SamAPIServer?
    ) {
        self.settings = settings
        self.database = database
        self.llmClient = llmClient
        self.memoryStore = memoryStore
        self.memorySearch = memorySearch
        self.memoryInjector = memoryInjector
        self.memoryAutoSave = memoryAutoSave
        self.crossSessionHistory = crossSessionHistory
        self.semanticMemoryEngine = semanticMemoryEngine
        self.toolRegistry = toolRegistry
        self.skillStore = skillStore
        self.skillEngine = skillEngine
        self.skillForge = skillForge
        self.promptBuilder = promptBuilder
        self.responseParser = responseParser
        self.planExecutor = planExecutor
        self.orchestrator = orchestrator
        self.engineScheduler = engineScheduler
        self.elevenlabsClient = elevenlabsClient
        self.openAITTSClient = openAITTSClient
        self.ttsService = ttsService
        self.sttService = sttService
        self.voicePipeline = voicePipeline
        self.speechRecognition = speechRecognition
        self.wakeWordService = wakeWordService
        self.taskScheduler = taskScheduler
        self.proactiveAwareness = proactiveAwareness
        self.ambientListening = ambientListening
        self.webLearningService = webLearningService
        self.autonomousResearch = autonomousResearch
        self.cameraService = cameraService
        self.visionProcessor = visionProcessor
        self.gptVisionClient = gptVisionClient
        self.emotionDetector = emotionDetector
        self.faceEnrollment = faceEnrollment
        self.googleAuthService = googleAuthService
        self.gmailClient = gmailClient
        self.embeddingClient = embeddingClient
        self.apiHandler = apiHandler
        self.alexaHandler = alexaHandler
        self.apiServer = apiServer
    }

    /// Factory that creates a fully-wired production container.
    static func createDefault() async -> AppContainer {
        let settings = UserDefaultsSettingsStore()
        let database = DatabaseManager()
        await database.initialize()

        // LLM
        let llmClient = OpenAIClient(settings: settings)

        // Embeddings
        let embeddingClient = OpenAIEmbeddingClient(settings: settings)

        // Memory
        let memoryStore = MemoryStore(database: database)
        let memorySearch = MemorySearch(database: database, embeddingClient: embeddingClient)
        let memoryInjector = MemoryInjector(memoryStore: memoryStore, embeddingClient: embeddingClient, memorySearch: memorySearch)
        let memoryAutoSave = MemoryAutoSave(memoryStore: memoryStore, memorySearch: memorySearch, embeddingClient: embeddingClient)
        let crossSessionHistory = CrossSessionHistory(database: database)
        let semanticMemoryEngine = SemanticMemoryEngine(database: database, llmClient: llmClient)

        // Scheduling
        let taskScheduler = TaskScheduler()

        // Web / Learning
        let webLearningService = WebLearningService(llmClient: llmClient, db: database)
        let autonomousResearch = AutonomousResearchService(llmClient: llmClient, webLearner: webLearningService)

        // Ambient / Proactive
        let proactiveAwareness = ProactiveAwareness()
        await proactiveAwareness.setScheduler(taskScheduler)
        let ambientListening = AmbientListeningService(settings: settings)

        // Vision / Camera
        let cameraService = CameraService()
        let visionProcessor = VisionProcessor()
        let gptVisionClient = GPTVisionClient(settings: settings)
        let emotionDetector = EmotionDetector()
        let faceEnrollment = FaceEnrollment()

        // Email
        let googleAuthService = GoogleAuthService(settings: settings)
        let gmailClient = GmailClient(authService: googleAuthService)

        // Skills
        let skillStore = SkillStore(database: database)
        let skillForge = SkillForge(
            llmClient: llmClient,
            skillStore: skillStore,
            toolRegistry: ToolRegistry(), // Temp registry for forge validation
            db: database
        )

        // Tools — wire all services
        let toolRegistry = ToolRegistry()
        toolRegistry.registerDefaults(
            memoryStore: memoryStore,
            taskScheduler: taskScheduler,
            skillForge: skillForge,
            skillStore: skillStore,
            webLearner: webLearningService,
            autonomousResearch: autonomousResearch,
            cameraService: cameraService,
            visionProcessor: visionProcessor,
            gptVisionClient: gptVisionClient,
            emotionDetector: emotionDetector,
            faceEnrollment: faceEnrollment,
            gmailClient: gmailClient
        )

        let skillEngine = SkillEngine(skillStore: skillStore, toolRegistry: toolRegistry)

        // Pipeline
        let promptBuilder = PromptBuilder(settings: settings)
        let responseParser = ResponseParser()
        let planExecutor = PlanExecutor(toolRegistry: toolRegistry, memoryStore: memoryStore)

        // Intelligence engines
        let engineScheduler = EngineScheduler(settings: settings)
        await registerAllEngines(scheduler: engineScheduler)

        let orchestrator = TurnOrchestrator(
            llmClient: llmClient,
            promptBuilder: promptBuilder,
            responseParser: responseParser,
            planExecutor: planExecutor,
            memoryInjector: memoryInjector,
            memoryStore: memoryStore,
            settings: settings,
            toolRegistry: toolRegistry,
            engineScheduler: engineScheduler,
            memoryAutoSave: memoryAutoSave,
            skillEngine: skillEngine,
            proactiveAwareness: proactiveAwareness,
            ambientListening: ambientListening,
            semanticMemoryEngine: semanticMemoryEngine,
            database: database,
            crossSessionHistory: crossSessionHistory
        )

        // Speech
        let elevenlabsClient = ElevenLabsClient(settings: settings)
        let openAITTSClient = OpenAITTSClient(settings: settings)
        let ttsService = TTSService(client: elevenlabsClient, openAIClient: openAITTSClient, settings: settings)
        let sttService = STTService(settings: settings)
        let voicePipeline = VoicePipeline(settings: settings)
        let speechRecognition = SpeechRecognitionService(settings: settings)
        let wakeWordService = WakeWordService(settings: settings)

        // API Server
        let apiHandler = APIHandler(orchestrator: orchestrator, settings: settings)
        let alexaHandler = AlexaHandler(apiHandler: apiHandler)
        apiHandler.setAlexaHandler(alexaHandler)

        let apiPort = UInt16(settings.double(forKey: SettingsKey.apiPort))
        let effectivePort: UInt16 = apiPort > 0 ? apiPort : 8443
        let apiServer = SamAPIServer(port: effectivePort, handler: apiHandler.route)
        if settings.bool(forKey: SettingsKey.apiEnabled) {
            try? apiServer.start()
        }

        // Prune expired memories on launch
        await memoryStore.pruneExpired()

        return AppContainer(
            settings: settings,
            database: database,
            llmClient: llmClient,
            memoryStore: memoryStore,
            memorySearch: memorySearch,
            memoryInjector: memoryInjector,
            memoryAutoSave: memoryAutoSave,
            crossSessionHistory: crossSessionHistory,
            semanticMemoryEngine: semanticMemoryEngine,
            toolRegistry: toolRegistry,
            skillStore: skillStore,
            skillEngine: skillEngine,
            skillForge: skillForge,
            promptBuilder: promptBuilder,
            responseParser: responseParser,
            planExecutor: planExecutor,
            orchestrator: orchestrator,
            engineScheduler: engineScheduler,
            elevenlabsClient: elevenlabsClient,
            openAITTSClient: openAITTSClient,
            ttsService: ttsService,
            sttService: sttService,
            voicePipeline: voicePipeline,
            speechRecognition: speechRecognition,
            wakeWordService: wakeWordService,
            taskScheduler: taskScheduler,
            proactiveAwareness: proactiveAwareness,
            ambientListening: ambientListening,
            webLearningService: webLearningService,
            autonomousResearch: autonomousResearch,
            cameraService: cameraService,
            visionProcessor: visionProcessor,
            gptVisionClient: gptVisionClient,
            emotionDetector: emotionDetector,
            faceEnrollment: faceEnrollment,
            googleAuthService: googleAuthService,
            gmailClient: gmailClient,
            embeddingClient: embeddingClient,
            apiHandler: apiHandler,
            alexaHandler: alexaHandler,
            apiServer: apiServer
        )
    }

    /// Register all 12 intelligence engines with the scheduler.
    private static func registerAllEngines(scheduler: EngineScheduler) async {
        let engines: [any IntelligenceEngine] = [
            CognitiveTraceEngine(),
            LivingWorldModel(),
            ActiveCuriosityEngine(),
            LongitudinalPatternEngine(),
            BehaviorPatternEngine(),
            CounterfactualEngine(),
            TheoryOfMindEngine(),
            NarrativeCoherenceEngine(),
            CausalLearningEngine(),
            MetaCognitionEngine(),
            PersonalityEngine(),
            SkillEvolutionEngine(),
        ]
        await scheduler.registerEngines(engines)
    }
}
