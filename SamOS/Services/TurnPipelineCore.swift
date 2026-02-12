import Foundation

struct TurnContext {
    let userText: String
    let history: [ChatMessage]
    let inputMode: TurnInputMode
    let pendingSlot: PendingSlot?
    let pendingCapabilityRequest: PendingCapabilityRequest?
    let now: Date
}

/// Result of a single turn processed by the orchestrator.
struct TurnResult {
    var appendedChat: [ChatMessage] = []
    var appendedOutputs: [OutputItem] = []
    var spokenLines: [String] = []
    var triggerFollowUpCapture: Bool = false
    var triggerQuestionAutoListen: Bool = false
    var usedMemoryHints: Bool = false
    var llmProvider: LLMProvider = .none
    var intentProviderSelected: IntentClassificationProvider = .rule
    var planProviderSelected: LLMProvider = .none
    var knowledgeAttribution: KnowledgeAttribution?
    var aiModelUsed: String?
    var executedToolSteps: [(name: String, args: [String: String])] = []
    var intentRouterMsLocal: Int?
    var intentRouterMsOpenAI: Int?
    var planLocalWireMs: Int?
    var planLocalTotalMs: Int?
    var planOpenAIMs: Int?
    var toolMsTotal: Int?
    var planRouterMs: Int?
    var routerMs: Int? {
        get { planRouterMs }
        set { planRouterMs = newValue }
    }
    var originProvider: MessageOriginProvider = .local
    var executionProvider: MessageOriginProvider = .local
    var originReason: String?
}

struct TurnPlanRouteRequest {
    let text: String
    let history: [ChatMessage]
    let pendingSlot: PendingSlot?
    let reason: LLMCallReason
    let promptContext: PromptRuntimeContext?
    let intentClassification: IntentClassification?

    init(text: String,
         history: [ChatMessage],
         pendingSlot: PendingSlot?,
         reason: LLMCallReason,
         promptContext: PromptRuntimeContext?,
         intentClassification: IntentClassification? = nil) {
        self.text = text
        self.history = history
        self.pendingSlot = pendingSlot
        self.reason = reason
        self.promptContext = promptContext
        self.intentClassification = intentClassification
    }
}

struct TurnPlanRouteResponse {
    let plan: Plan
    let provider: LLMProvider
    let routerMs: Int
    let aiModelUsed: String?
    let routeReason: String
    let planLocalWireMs: Int?
    let planLocalTotalMs: Int?
    let planOpenAIMs: Int?
}

struct RouteDecision {
    let plan: Plan
    let provider: LLMProvider
    let routerMs: Int
    let aiModelUsed: String?
    let routeReason: String
    let planLocalWireMs: Int?
    let planLocalTotalMs: Int?
    let planOpenAIMs: Int?
}

typealias ToolRunResult = PlanExecutionResult

struct CapabilityGapRouteInput {
    let text: String
    let classification: IntentClassification
    let provider: IntentClassificationProvider
    let pendingSlot: PendingSlot?
    let pendingCapabilityRequest: PendingCapabilityRequest?
    let confidenceThreshold: Double
}

enum PendingSlotRoutingAction: Equatable {
    case none
    case continueWithSlot(PendingSlot)
    case retryExhausted(message: String)
}

struct PendingSlotEvaluation: Equatable {
    let pendingSlot: PendingSlot?
    let pendingCapabilityRequest: PendingCapabilityRequest?
    let action: PendingSlotRoutingAction
}

struct PendingSlotResolution: Equatable {
    let pendingSlot: PendingSlot?
    let pendingCapabilityRequest: PendingCapabilityRequest?
}

struct PendingCapabilityInput {
    let pendingRequest: PendingCapabilityRequest?
    let text: String
    let now: Date
}

enum CapabilityRequestCategory: Equatable {
    case weather
    case news
    case sportsScores
    case time
    case otherWeb
}

enum PendingCapabilityResolution: Equatable {
    case none
    case learnSource(
        url: String,
        focus: String,
        memoryContent: String,
        successMessage: String
    )
    case askForSource(
        prompt: String,
        pendingSlot: PendingSlot,
        updatedRequest: PendingCapabilityRequest
    )
    case drop(message: String)
}

@MainActor
protocol TurnRouting: AnyObject {
    func classifyIntent(_ input: IntentClassifierInput,
                        policy: IntentRoutePolicy) async -> IntentClassificationResult
    func routePlan(_ request: TurnPlanRouteRequest) async -> RouteDecision

    func evaluatePendingSlot(_ pendingSlot: PendingSlot?,
                             pendingCapabilityRequest: PendingCapabilityRequest?,
                             now: Date) -> PendingSlotEvaluation
    func resolvePendingSlotAfterPlan(_ plan: Plan,
                                     previousSlot: PendingSlot?,
                                     pendingCapabilityRequest: PendingCapabilityRequest?) -> PendingSlotResolution

    func shouldEnterExternalSourceCapabilityGapFlow(_ input: CapabilityGapRouteInput) -> Bool
    func resolvePendingCapabilityInput(_ input: PendingCapabilityInput) -> PendingCapabilityResolution
}

@MainActor
protocol TurnToolRunning: AnyObject {
    func executePlan(_ plan: Plan,
                     originalInput: String,
                     pendingSlotName: String?) async -> ToolRunResult
    func executeTool(_ action: ToolAction) -> OutputItem?
}

struct IntentRoutePolicy {
    let localFirst: Bool
    let openAIFallback: Bool

    init(useOllama: Bool) {
        self.localFirst = useOllama
        self.openAIFallback = true
    }
}

enum CapabilityGapRequestKind: Equatable {
    case externalSource
    case capabilityBuild
}

struct PendingCapabilityRequest: Equatable {
    let kind: CapabilityGapRequestKind
    let desiredToolName: String
    let originalUserGoal: String
    let prefersWebsiteURL: Bool
    let createdAt: Date
    var lastAskedAt: Date
    var reminderCount: Int
}

protocol ToolNameNormalizing: AnyObject {
    var canonicalToolNames: [String] { get }
    var aliases: [String: String] { get }
    func normalizeToolName(_ raw: String) -> String?
    func isAllowedTool(_ name: String) -> Bool
}
