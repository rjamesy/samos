import Foundation

@MainActor
final class AppContainer {
    let logger: AppLogger
    let clock: Clock

    let settingsStore: SettingsStore
    let routingService: RoutingService

    let ollamaClient: LLMClient
    let openAIClient: LLMClient

    let memoryStore: MemoryStoreContract
    let memoryCompressor: MemoryCompressor
    let memoryRetriever: MemoryRetriever

    let skillStore: SkillStoreContract
    let skillRuntime: SkillRuntime
    let skillForge: SkillForgePipeline

    let toolRegistry: ToolRegistryContract
    let orchestrator: TurnOrchestrating

    init(logger: AppLogger = JSONLineLogger(),
         clock: Clock = SystemClock(),
         settingsStore: SettingsStore = UserDefaultsSettingsStore(),
         memoryStore: MemoryStoreContract = MemoryStore.shared,
         memoryCompressor: MemoryCompressor = NoopMemoryCompressor(),
         skillStore: SkillStoreContract = SkillStore.shared,
         skillRuntime: SkillRuntime = SkillEngine.shared,
         skillForge: SkillForgePipeline? = nil,
         toolRegistry: ToolRegistryContract? = nil,
         orchestrator: TurnOrchestrating? = nil) {
        let resolvedSkillForge = skillForge ?? SkillForge.shared
        let resolvedToolRegistry = toolRegistry ?? ToolRegistry.shared
        let resolvedOrchestrator = orchestrator ?? TurnOrchestrator()

        self.logger = logger
        self.clock = clock
        self.settingsStore = settingsStore
        self.memoryStore = memoryStore
        self.memoryCompressor = memoryCompressor
        self.memoryRetriever = DefaultMemoryRetriever(store: memoryStore)
        self.skillStore = skillStore
        self.skillRuntime = skillRuntime
        self.skillForge = resolvedSkillForge
        self.toolRegistry = resolvedToolRegistry
        self.orchestrator = resolvedOrchestrator

        self.ollamaClient = OllamaLLMClient()
        self.openAIClient = OpenAILLMClient()

        let fallbackPolicy = FallbackPolicy(settingsStore: settingsStore)
        let routePlanner = RoutePlanner(fallbackPolicy: fallbackPolicy)
        let presenter = ResponsePresenter()
        let pipeline = TurnPipeline(
            orchestrator: resolvedOrchestrator,
            routePlanner: routePlanner,
            presenter: presenter,
            clock: clock,
            settingsStore: settingsStore
        )
        self.routingService = TurnRoutingServiceAdapter(pipeline: pipeline)
    }
}
