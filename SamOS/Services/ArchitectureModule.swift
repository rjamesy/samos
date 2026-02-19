import Foundation

// MARK: - Domain: Conversation / LLM

struct LLMMessage: Equatable {
    let role: String
    let content: String
}

struct LLMRequest {
    let system: String?
    let messages: [LLMMessage]
    let model: String?
}

struct LLMResult {
    let text: String
    let model: String
    let latencyMs: Int
}

protocol LLMClient {
    func complete(prompt: LLMRequest) async throws -> LLMResult
}

// MARK: - Domain: Routing

struct RoutingTurnContext {
    let text: String
    let history: [ChatMessage]
}

struct ToolCall: Equatable {
    let name: String
    let args: [String: String]
}

struct TimingInfo: Equatable {
    let startedAt: Date
    let finishedAt: Date
    let routeDurationMs: Int
}

struct RouteResult {
    let sayText: String
    let uiBlocks: [OutputItem]
    let debug: TimingInfo
    let toolCalls: [ToolCall]
}

protocol RoutingService {
    func route(turn: RoutingTurnContext) async throws -> RouteResult
}

enum RouteProvider: Equatable {
    case ollama
    case openai
}

// MARK: - Domain: Memory

protocol MemoryStoreContract {
    @discardableResult
    func addMemory(type: MemoryType,
                   content: String,
                   source: String?,
                   confidence: MemoryConfidence,
                   ttlDays: Int?,
                   sourceSnippet: String?,
                   tags: [String],
                   isResolved: Bool,
                   createdAt: Date,
                   lastSeenAt: Date?) -> MemoryRow?

    func listMemories(filterType: MemoryType?) -> [MemoryRow]
    func memoryContext(query: String, maxItems: Int, maxChars: Int) -> [MemoryRow]
    func clearMemories()
}

protocol MemoryCompressor {
    func compress(rows: [MemoryRow], now: Date) -> [MemoryRow]
}

protocol MemoryRetriever {
    func retrieve(query: String, limit: Int) -> [MemoryRow]
}

struct NoopMemoryCompressor: MemoryCompressor {
    func compress(rows: [MemoryRow], now: Date) -> [MemoryRow] {
        rows
    }
}

struct DefaultMemoryRetriever: MemoryRetriever {
    private let store: MemoryStoreContract

    init(store: MemoryStoreContract) {
        self.store = store
    }

    func retrieve(query: String, limit: Int) -> [MemoryRow] {
        store.memoryContext(query: query, maxItems: limit, maxChars: 1400)
    }
}

extension MemoryStore: MemoryStoreContract {}

// MARK: - Domain: Skills

protocol SkillStoreContract {
    func loadInstalled() -> [SkillSpec]
    @discardableResult
    func install(_ skill: SkillSpec) -> Bool
    @discardableResult
    func remove(id: String) -> Bool
}

protocol SkillRuntime {
    func execute(skill: SkillSpec, slots: [String: String]) -> [Action]
}

protocol SkillForgePipeline {
    @MainActor
    func forge(goal: String, missing: String, onProgress: @escaping (SkillForgeJob) -> Void) async throws -> SkillSpec
}

extension SkillStore: SkillStoreContract {}
extension SkillEngine: SkillRuntime {}
extension SkillForge: SkillForgePipeline {}

// MARK: - Domain: Tools

protocol ToolRegistryContract {
    var allTools: [Tool] { get }
    func get(_ name: String) -> Tool?
    func register(_ tool: Tool)
    func normalizeToolName(_ raw: String) -> String?
    func isAllowedTool(_ name: String) -> Bool
}

extension ToolRegistry: ToolRegistryContract {}

protocol ToolRegistryContributor {
    func register(into registry: ToolRegistry)
}

struct CoreToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(ShowTextTool())
        registry.register(FindRecipeTool())
        registry.register(FindImageTool())
        registry.register(FindVideoTool())
        registry.register(FindFilesTool())
        registry.register(ShowImageTool())
    }
}

struct CameraToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(DescribeCameraViewTool())
        registry.register(CameraObjectFinderTool())
        registry.register(CameraFacePresenceTool())
        registry.register(EnrollCameraFaceTool())
        registry.register(RecognizeCameraFacesTool())
        registry.register(CameraVisualQATool())
        registry.register(CameraInventorySnapshotTool())
        registry.register(SaveCameraMemoryNoteTool())
    }
}

struct MemoryToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(SaveMemoryTool())
        registry.register(ListMemoriesTool())
        registry.register(DeleteMemoryTool())
        registry.register(ClearMemoriesTool())
    }
}

struct SchedulingToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(ScheduleTaskTool())
        registry.register(CancelTaskTool())
        registry.register(ListTasksTool())
        registry.register(GetWeatherTool())
        registry.register(GetTimeTool())
    }
}

struct LearningToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(LearnWebsiteTool())
        registry.register(AutonomousLearnTool())
        registry.register(StopAutonomousLearnTool())
    }
}

struct SkillsToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(StartSkillForgeTool())
        registry.register(ForgeQueueStatusTool())
        registry.register(ForgeQueueClearTool())
    }
}

struct CapabilityToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(CapabilityGapToClaudePromptTool())
    }
}

// MARK: - Domain: Settings

protocol SettingsStore {
    var useOllama: Bool { get set }
    var ollamaEndpoint: String { get set }
    var ollamaModel: String { get set }
    var disableAutoClosePrompts: Bool { get set }
    var useEmotionalTone: Bool { get set }
    var captureBeepEnabled: Bool { get set }
    var userName: String { get set }
}

final class UserDefaultsSettingsStore: SettingsStore {
    var useOllama: Bool {
        get { M2Settings.useOllama }
        set { M2Settings.useOllama = newValue }
    }

    var ollamaEndpoint: String {
        get { M2Settings.ollamaEndpoint }
        set { M2Settings.ollamaEndpoint = newValue }
    }

    var ollamaModel: String {
        get { M2Settings.ollamaModel }
        set { M2Settings.ollamaModel = newValue }
    }

    var disableAutoClosePrompts: Bool {
        get { M2Settings.disableAutoClosePrompts }
        set { M2Settings.disableAutoClosePrompts = newValue }
    }

    var useEmotionalTone: Bool {
        get { M2Settings.useEmotionalTone }
        set { M2Settings.useEmotionalTone = newValue }
    }

    var captureBeepEnabled: Bool {
        get { M2Settings.captureBeepEnabled }
        set { M2Settings.captureBeepEnabled = newValue }
    }

    var userName: String {
        get { M2Settings.userName }
        set { M2Settings.userName = newValue }
    }
}

final class InMemorySettingsStore: SettingsStore {
    var useOllama: Bool = true
    var ollamaEndpoint: String = "http://127.0.0.1:11434"
    var ollamaModel: String = "qwen2.5:3b-instruct"
    var disableAutoClosePrompts: Bool = true
    var useEmotionalTone: Bool = true
    var captureBeepEnabled: Bool = true
    var userName: String = "there"
}

// MARK: - Core: Logging / Timing

protocol AppLogger {
    func info(_ event: String, metadata: [String: String])
    func error(_ event: String, metadata: [String: String])
}

final class JSONLineLogger: AppLogger {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "SamOS.JSONLineLogger")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("SamOS/logs", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            self.fileURL = dir.appendingPathComponent("runtime_events.jsonl")
            if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
            }
        }
    }

    func info(_ event: String, metadata: [String: String]) {
        write(level: "info", event: event, metadata: metadata)
    }

    func error(_ event: String, metadata: [String: String]) {
        write(level: "error", event: event, metadata: metadata)
    }

    private func write(level: String, event: String, metadata: [String: String]) {
        let payload: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "level": level,
            "event": event,
            "metadata": metadata,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"

        queue.async { [fileURL] in
            guard let handle = try? FileHandle(forWritingTo: fileURL),
                  let bytes = line.data(using: .utf8)
            else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: bytes)
            } catch {
                // Logging should never crash runtime behavior.
            }
        }
    }
}

protocol Clock {
    var now: Date { get }
}

struct SystemClock: Clock {
    var now: Date { Date() }
}

struct TimingSpan: Equatable {
    let name: String
    let startedAt: Date
    let endedAt: Date

    var durationMs: Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt) * 1000))
    }
}

final class TimingTracer {
    private var starts: [String: Date] = [:]
    private(set) var spans: [TimingSpan] = []
    private let clock: Clock

    init(clock: Clock) {
        self.clock = clock
    }

    func begin(_ name: String) {
        starts[name] = clock.now
    }

    func end(_ name: String) {
        guard let startedAt = starts.removeValue(forKey: name) else { return }
        spans.append(TimingSpan(name: name, startedAt: startedAt, endedAt: clock.now))
    }

    func clear() {
        starts.removeAll()
        spans.removeAll()
    }
}

// MARK: - Infrastructure: LLM clients

final class OpenAILLMClient: LLMClient {
    private let router: OpenAIRouter

    init(router: OpenAIRouter = OpenAIRouter(parser: OllamaRouter())) {
        self.router = router
    }

    func complete(prompt: LLMRequest) async throws -> LLMResult {
        let input = prompt.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let startedAt = Date()
        let plan = try await router.routePlan(input, history: [], pendingSlot: nil, reason: .other)
        let text = extractedText(from: plan)
        let ms = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))

        return LLMResult(
            text: text,
            model: prompt.model ?? OpenAISettings.generalModel,
            latencyMs: ms
        )
    }

    private func extractedText(from plan: Plan) -> String {
        if let say = plan.say?.trimmingCharacters(in: .whitespacesAndNewlines), !say.isEmpty {
            return say
        }
        for step in plan.steps {
            if case .talk(let say) = step {
                let trimmed = say.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return ""
    }
}

final class OllamaLLMClient: LLMClient {
    private let router: OllamaRouter

    init(router: OllamaRouter = OllamaRouter()) {
        self.router = router
    }

    func complete(prompt: LLMRequest) async throws -> LLMResult {
        let input = prompt.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let startedAt = Date()
        let plan = try await router.routePlan(input, history: [], pendingSlot: nil, promptContext: nil)
        let ms = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))

        return LLMResult(
            text: extractedText(from: plan),
            model: M2Settings.ollamaModel,
            latencyMs: ms
        )
    }

    private func extractedText(from plan: Plan) -> String {
        if let say = plan.say?.trimmingCharacters(in: .whitespacesAndNewlines), !say.isEmpty {
            return say
        }
        for step in plan.steps {
            if case .talk(let say) = step {
                let trimmed = say.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return ""
    }
}

// MARK: - Routing pipeline components

struct FallbackPolicy {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func routeOrder(openAIConfigured: Bool) -> [RouteProvider] {
        if settingsStore.useOllama {
            return openAIConfigured ? [.ollama, .openai] : [.ollama]
        }
        return openAIConfigured ? [.openai] : []
    }
}

struct RoutePlanner {
    private let fallbackPolicy: FallbackPolicy

    init(fallbackPolicy: FallbackPolicy) {
        self.fallbackPolicy = fallbackPolicy
    }

    func plannedProviders() -> [RouteProvider] {
        fallbackPolicy.routeOrder(openAIConfigured: OpenAISettings.apiKeyStatus == .ready)
    }
}

struct ResponsePresenter {
    func present(turnResult: TurnResult, startedAt: Date, finishedAt: Date) -> RouteResult {
        let sayText = preferredSpokenText(from: turnResult)
        let toolCalls = turnResult.executedToolSteps.map { ToolCall(name: $0.name, args: $0.args) }
        return RouteResult(
            sayText: sayText,
            uiBlocks: turnResult.appendedOutputs,
            debug: TimingInfo(
                startedAt: startedAt,
                finishedAt: finishedAt,
                routeDurationMs: max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000))
            ),
            toolCalls: toolCalls
        )
    }

    private func preferredSpokenText(from turnResult: TurnResult) -> String {
        if let lastAssistant = turnResult.appendedChat.last(where: { $0.role == .assistant })?.text,
           !lastAssistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lastAssistant
        }
        if let firstSpoken = turnResult.spokenLines.first,
           !firstSpoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return firstSpoken
        }
        return ""
    }
}

@MainActor
final class TurnPipeline {
    private let orchestrator: TurnOrchestrating
    private let routePlanner: RoutePlanner
    private let presenter: ResponsePresenter
    private let clock: Clock

    init(orchestrator: TurnOrchestrating,
         routePlanner: RoutePlanner,
         presenter: ResponsePresenter,
         clock: Clock) {
        self.orchestrator = orchestrator
        self.routePlanner = routePlanner
        self.presenter = presenter
        self.clock = clock
    }

    func execute(turn: RoutingTurnContext) async -> RouteResult {
        _ = routePlanner.plannedProviders()

        let startedAt = clock.now
        let result = await orchestrator.processTurn(turn.text, history: turn.history, inputMode: .text)
        let finishedAt = clock.now
        return presenter.present(turnResult: result, startedAt: startedAt, finishedAt: finishedAt)
    }
}

@MainActor
final class TurnRoutingServiceAdapter: RoutingService {
    private let pipeline: TurnPipeline

    init(pipeline: TurnPipeline) {
        self.pipeline = pipeline
    }

    func route(turn: RoutingTurnContext) async throws -> RouteResult {
        await pipeline.execute(turn: turn)
    }
}

// MARK: - Core: DI

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
         toolRegistry: ToolRegistryContract = ToolRegistry.shared,
         orchestrator: TurnOrchestrating? = nil) {
        self.logger = logger
        self.clock = clock
        self.settingsStore = settingsStore
        self.memoryStore = memoryStore
        self.memoryCompressor = memoryCompressor
        self.memoryRetriever = DefaultMemoryRetriever(store: memoryStore)
        self.skillStore = skillStore
        self.skillRuntime = skillRuntime
        self.skillForge = skillForge ?? SkillForge.shared
        self.toolRegistry = toolRegistry
        self.orchestrator = orchestrator ?? TurnOrchestrator()

        self.ollamaClient = OllamaLLMClient()
        self.openAIClient = OpenAILLMClient()

        let fallbackPolicy = FallbackPolicy(settingsStore: settingsStore)
        let routePlanner = RoutePlanner(fallbackPolicy: fallbackPolicy)
        let presenter = ResponsePresenter()
        let pipeline = TurnPipeline(
            orchestrator: self.orchestrator,
            routePlanner: routePlanner,
            presenter: presenter,
            clock: clock
        )
        self.routingService = TurnRoutingServiceAdapter(pipeline: pipeline)
    }
}
