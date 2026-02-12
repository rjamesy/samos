import Foundation
import SwiftUI
import AppKit

// MARK: - System Status

enum SystemStatus: String {
    case idle = "Idle"
    case listening = "Listening"
    case capturing = "Capturing"
    case thinking = "Thinking"
    case speaking = "Speaking"
}

// MARK: - SkillForge State

enum SkillForgeState {
    case idle
    case building(SkillForgeJob)
}

// MARK: - Input Classification

enum InputClassifier {
    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go ahead",
        "do it", "go for it", "absolutely", "yes please", "please", "ya",
        "y", "yea", "give it a go", "try it", "let's go"
    ]

    private static let negatives: Set<String> = [
        "no", "nah", "nope", "no thanks", "not now", "never mind",
        "nevermind", "skip", "cancel", "don't", "n"
    ]

    static func isAffirmative(_ text: String) -> Bool {
        affirmatives.contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isNegative(_ text: String) -> Bool {
        negatives.contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isQuestion(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
    }
}

// MARK: - App State

/// Central observable state for the app.
@MainActor
final class AppState: ObservableObject {
    private enum TurnSpeechPhase: String {
        case idle
        case routing
        case speechReady
        case speaking
    }

    typealias ThinkingFillerSpeaker = (String) -> Void
    private struct TurnLatencyTrace {
        let id: Int
        let turnID: String
        let inputMode: String
        let userChars: Int
        var routerMs: Int?
        var intentLocalMs: Int?
        var intentOpenAIMs: Int?
        var planLocalWireMs: Int?
        var planLocalTotalMs: Int?
        var planOpenAIMs: Int?
        var toolMsTotal: Int?
        var captureStartedAt: Date?
        var transcribeStartedAt: Date?
        var transcriptReadyAt: Date?
        var routeStartedAt: Date
        var routeFinishedAt: Date?
        var applyFinishedAt: Date?
        var speechEnqueuedAt: Date?
        var ttsStartedAt: Date?
        var ttsFinishedAt: Date?
        var expectsTTS: Bool
        var provider: LLMProvider
        var toolSteps: Int
        var assistantChars: Int
    }

    @Published var chatMessages: [ChatMessage] = []
    @Published var outputItems: [OutputItem] = []
    @Published var status: SystemStatus = .idle
    @Published var isMuted: Bool = ElevenLabsSettings.isMuted
    @Published var showSettings: Bool = false
    @Published var isListeningEnabled: Bool = false
    @Published var lastError: String?
    @Published var skillForgeState: SkillForgeState = .idle
    @Published var activeAlarm: ScheduledTask? = nil
    @Published var pendingSlot: PendingSlot? = nil
    @Published var isThinkingIndicatorVisible: Bool = false
    @Published var learnedWebsiteCount: Int = 0
    @Published var autonomousLearningReportCount: Int = 0
    @Published var activeAutonomousLearningSession: AutonomousLearningService.ActiveSession?
    @Published var isCameraEnabled: Bool = false
    @Published var cameraPermissionStatus: CameraPermission.Status = CameraPermission.currentStatus
    @Published var cameraErrorMessage: String?
    @Published var cameraLastFrameAt: Date?
    @Published var cameraPreviewImage: NSImage?

    let alarmSession = AlarmSession()
    private let orchestrator: TurnOrchestrating
    private let voicePipeline: VoicePipelineCoordinating
    private let memoryAutoSaveService: MemoryAutoSaveService
    private let selfLearningService: SelfLearningService
    private let thinkingFillerDelay: TimeInterval
    private let thinkingFillerSpeaker: ThinkingFillerSpeaker
    private let speechCoordinator: TurnSpeechCoordinating
    private let outputCanvasLogStore: OutputCanvasLogStore
    private let cameraVisionService: CameraVisionService

    private var errorClearTask: Task<Void, Never>?
    private var ttsObserver: Task<Void, Never>?
    private var thinkingFillerTask: Task<Void, Never>?
    private var followUpExpiryTask: Task<Void, Never>?

    /// When true, the next TTS-finish triggers follow-up capture (no wake word needed).
    private var awaitingUserReply = false
    /// Follow-up question mode uses a short no-speech timeout; pending slot mode does not.
    private var awaitingQuestionAutoListen = false
    private let questionAutoListenNoSpeechTimeoutMs: Int
    private static let questionAutoListenFeatureFlagKey = "samos_feature_question_auto_listen"
    private static let alarmFollowUpSettleDelayNs: UInt64 = 120_000_000
    private static let followUpSettleDelayNs: UInt64 = 80_000_000

    private var forgeLogItemByJobID: [UUID: UUID] = [:]
    private var forgeLogMarkdownByJobID: [UUID: String] = [:]
    private var activeTurnLatencyStartAt: Date?
    private var pendingCaptureStartedAt: Date?
    private var pendingTranscribeStartedAt: Date?
    private var pendingTranscriptReadyAt: Date?
    private var turnLatencyTrace: TurnLatencyTrace?
    private var turnLatencyTraceSequence: Int = 0
    private var turnLatencyFinalizeTask: Task<Void, Never>?
    private var speechStartMonitorTask: Task<Void, Never>?
    private var activeSpeechCorrelationID: String?
    private var activeSpeechRetryAttempt: Int = 0
    private var activeSpeechStartedAt: Date?
    private var lastSpeechDropReason: String?
    private var activeTurnID: String?
    private var turnSpeechPhase: TurnSpeechPhase = .idle
    private var turnSequence: Int = 0
    private let ttsStartDeadlineSeconds: Double
    private let ttsTotalDeadlineSeconds: Double
    private let enforceStrictTurnSpeechPhases: Bool

    /// Tracks whether listening was active before Settings was opened, to auto-resume on close.
    private(set) var wasListeningBeforeSettings = false

    /// Convenience for the Settings banner.
    var wasListeningPausedForSettings: Bool { wasListeningBeforeSettings }

    /// Persisted user preference: whether listening should auto-start.
    static var userWantsListeningEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "samos_userWantsListeningEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "samos_userWantsListeningEnabled") }
    }

    /// Persisted user preference: whether camera vision should auto-start.
    static var userWantsCameraEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "samos_userWantsCameraEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "samos_userWantsCameraEnabled") }
    }

    private static let liveVisionScriptFlag = "--run-live-vision-script"
    private static let liveLockdownCheckFlag = "--run-live-lockdown-check"

    // MARK: - Init

    init() {
        self.orchestrator = TurnOrchestrator()
        self.voicePipeline = VoicePipelineCoordinator()
        self.memoryAutoSaveService = .shared
        self.selfLearningService = .shared
        self.thinkingFillerDelay = 2.0
        self.questionAutoListenNoSpeechTimeoutMs = 3500
        self.speechCoordinator = SpeechCoordinator()
        self.outputCanvasLogStore = .shared
        self.cameraVisionService = .shared
        self.ttsStartDeadlineSeconds = 1.6
        self.ttsTotalDeadlineSeconds = 45.0
        self.enforceStrictTurnSpeechPhases = true
        self.thinkingFillerSpeaker = { phrase in
            TTSService.shared.speak(phrase, mode: .confirm, interrupt: false)
        }
        configureRuntimeServicesIfNeeded(true)
        refreshWebsiteLearningDebug()
        refreshAutonomousLearningDebug()
        refreshCameraDebug()
        maybeRunLiveVisionScriptIfRequested()
    }

    init(orchestrator: TurnOrchestrating,
         voicePipeline: VoicePipelineCoordinating,
         memoryAutoSaveService: MemoryAutoSaveService? = nil,
         thinkingFillerDelay: TimeInterval = 2.0,
         questionAutoListenNoSpeechTimeoutMs: Int = 3500,
         ttsStartDeadlineSeconds: Double = 1.6,
         ttsTotalDeadlineSeconds: Double = 45.0,
         enforceStrictTurnSpeechPhases: Bool? = nil,
         speechCoordinator: TurnSpeechCoordinating? = nil,
         thinkingFillerSpeaker: @escaping ThinkingFillerSpeaker = { phrase in
             Task { @MainActor in
                 TTSService.shared.speak(phrase, mode: .confirm, interrupt: false)
             }
        },
         enableRuntimeServices: Bool = true) {
        self.orchestrator = orchestrator
        self.voicePipeline = voicePipeline
        self.memoryAutoSaveService = memoryAutoSaveService ?? .shared
        self.selfLearningService = .shared
        self.thinkingFillerDelay = thinkingFillerDelay
        self.questionAutoListenNoSpeechTimeoutMs = max(100, questionAutoListenNoSpeechTimeoutMs)
        self.speechCoordinator = speechCoordinator ?? SpeechCoordinator()
        self.outputCanvasLogStore = .shared
        self.cameraVisionService = .shared
        self.ttsStartDeadlineSeconds = max(0.1, ttsStartDeadlineSeconds)
        self.ttsTotalDeadlineSeconds = max(self.ttsStartDeadlineSeconds, ttsTotalDeadlineSeconds)
        self.enforceStrictTurnSpeechPhases = enforceStrictTurnSpeechPhases ?? enableRuntimeServices
        self.thinkingFillerSpeaker = thinkingFillerSpeaker
        configureRuntimeServicesIfNeeded(enableRuntimeServices)
        refreshWebsiteLearningDebug()
        refreshAutonomousLearningDebug()
        refreshCameraDebug()
        maybeRunLiveVisionScriptIfRequested()
    }

    init(orchestrator: TurnOrchestrating,
         memoryAutoSaveService: MemoryAutoSaveService? = nil,
         thinkingFillerDelay: TimeInterval = 2.0,
         questionAutoListenNoSpeechTimeoutMs: Int = 3500,
         ttsStartDeadlineSeconds: Double = 1.6,
         ttsTotalDeadlineSeconds: Double = 45.0,
         enforceStrictTurnSpeechPhases: Bool? = nil,
         speechCoordinator: TurnSpeechCoordinating? = nil,
         thinkingFillerSpeaker: @escaping ThinkingFillerSpeaker = { phrase in
             Task { @MainActor in
                 TTSService.shared.speak(phrase, mode: .confirm, interrupt: false)
             }
         },
         enableRuntimeServices: Bool = true) {
        self.orchestrator = orchestrator
        self.voicePipeline = VoicePipelineCoordinator()
        self.memoryAutoSaveService = memoryAutoSaveService ?? .shared
        self.selfLearningService = .shared
        self.thinkingFillerDelay = thinkingFillerDelay
        self.questionAutoListenNoSpeechTimeoutMs = max(100, questionAutoListenNoSpeechTimeoutMs)
        self.speechCoordinator = speechCoordinator ?? SpeechCoordinator()
        self.outputCanvasLogStore = .shared
        self.cameraVisionService = .shared
        self.ttsStartDeadlineSeconds = max(0.1, ttsStartDeadlineSeconds)
        self.ttsTotalDeadlineSeconds = max(self.ttsStartDeadlineSeconds, ttsTotalDeadlineSeconds)
        self.enforceStrictTurnSpeechPhases = enforceStrictTurnSpeechPhases ?? enableRuntimeServices
        self.thinkingFillerSpeaker = thinkingFillerSpeaker
        configureRuntimeServicesIfNeeded(enableRuntimeServices)
        refreshWebsiteLearningDebug()
        refreshAutonomousLearningDebug()
        refreshCameraDebug()
        maybeRunLiveVisionScriptIfRequested()
    }

    convenience init(orchestrator: TurnOrchestrating,
                     voicePipeline: VoicePipelineCoordinating,
                     memoryAutoSaveService: MemoryAutoSaveService? = nil,
                     thinkingFillerDelay: TimeInterval = 2.0,
                     questionAutoListenNoSpeechTimeoutMs: Int = 3500,
                     thinkingFillerSpeaker: @escaping ThinkingFillerSpeaker = { phrase in
                         Task { @MainActor in
                             TTSService.shared.speak(phrase, mode: .confirm, interrupt: false)
                         }
                     },
                     enableRuntimeServices: Bool = true) {
        self.init(
            orchestrator: orchestrator,
            voicePipeline: voicePipeline,
            memoryAutoSaveService: memoryAutoSaveService,
            thinkingFillerDelay: thinkingFillerDelay,
            questionAutoListenNoSpeechTimeoutMs: questionAutoListenNoSpeechTimeoutMs,
            ttsStartDeadlineSeconds: 1.6,
            ttsTotalDeadlineSeconds: 45.0,
            enforceStrictTurnSpeechPhases: nil,
            thinkingFillerSpeaker: thinkingFillerSpeaker,
            enableRuntimeServices: enableRuntimeServices
        )
    }

    convenience init(orchestrator: TurnOrchestrating,
                     memoryAutoSaveService: MemoryAutoSaveService? = nil,
                     thinkingFillerDelay: TimeInterval = 2.0,
                     questionAutoListenNoSpeechTimeoutMs: Int = 3500,
                     thinkingFillerSpeaker: @escaping ThinkingFillerSpeaker = { phrase in
                         Task { @MainActor in
                             TTSService.shared.speak(phrase, mode: .confirm, interrupt: false)
                         }
                     },
                     enableRuntimeServices: Bool = true) {
        self.init(
            orchestrator: orchestrator,
            memoryAutoSaveService: memoryAutoSaveService,
            thinkingFillerDelay: thinkingFillerDelay,
            questionAutoListenNoSpeechTimeoutMs: questionAutoListenNoSpeechTimeoutMs,
            ttsStartDeadlineSeconds: 1.6,
            ttsTotalDeadlineSeconds: 45.0,
            enforceStrictTurnSpeechPhases: nil,
            thinkingFillerSpeaker: thinkingFillerSpeaker,
            enableRuntimeServices: enableRuntimeServices
        )
    }

    private func configureRuntimeServicesIfNeeded(_ enabled: Bool) {
        guard enabled else { return }

        setupVoicePipeline()
        setupAlarmSession()
        observeTTSState()
        MemoryStore.shared.pruneExpiredMemoriesDaily(referenceDate: Date())
        SkillStore.shared.installBundledSkillsIfNeeded()
        #if DEBUG
        TaskScheduler.shared.expireAllPending()
        #else
        TaskScheduler.shared.expireStaleTasks()
        #endif
        TaskScheduler.shared.onTaskFired = { [weak self] task in
            Task { @MainActor in self?.handleScheduledTask(task) }
        }
        TaskScheduler.shared.startPolling()
        setupForgeQueueObservation()
        setupAutonomousLearningObservation()
        setupCameraVision()
        scheduleOllamaWarmupIfNeeded()

        // Auto-start listening if user previously enabled it and mic is authorized
        if Self.userWantsListeningEnabled
            && MicrophonePermission.currentStatus == .granted
            && M2Settings.isConfigured {
            startListening()
        }

        if Self.userWantsCameraEnabled && CameraPermission.currentStatus == .granted {
            startCamera(requestPermission: false)
        }
    }

    private func scheduleOllamaWarmupIfNeeded() {
        guard M2Settings.useOllama else { return }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        Task.detached(priority: .utility) {
            await OllamaRouter().warmupIfNeeded()
        }
    }

    private func setupVoicePipeline() {
        voicePipeline.onStatusChange = { [weak self] pipelineStatus in
            guard let self else { return }
            switch pipelineStatus {
            case .off:
                self.status = .idle
            case .listeningForWakeWord:
                self.status = .listening
            case .capturingAudio:
                self.status = .capturing
                self.pendingCaptureStartedAt = Date()
            case .transcribing:
                self.status = .thinking
                self.activeTurnLatencyStartAt = Date()
                self.isThinkingIndicatorVisible = true
                self.pendingTranscribeStartedAt = Date()
            }
        }

        voicePipeline.onTranscript = { [weak self] text in
            guard let self else { return }
            guard let sanitized = self.sanitizedVoiceTranscript(text) else {
                #if DEBUG
                print("[AppState] Dropped non-speech transcript artifact: \(text)")
                #endif
                self.activeTurnLatencyStartAt = nil
                self.pendingTranscriptReadyAt = nil
                return
            }
            self.pendingTranscriptReadyAt = Date()
            self.send(sanitized)
        }

        voicePipeline.onError = { [weak self] error in
            IntentAudioDiagnosticsStore.shared.recordAudioError(error.localizedDescription)
            guard let self else { return }
            if let downgraded = self.debugOnlyAudioNoiseMessage(for: error.localizedDescription) {
                #if DEBUG
                print("[AUDIO_DEBUG] \(downgraded)")
                #endif
                return
            }
            self.showError(error.localizedDescription)
        }
    }

    private func debugOnlyAudioNoiseMessage(for message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("-10877") {
            return "Suppressed benign AVAudio session hiccup (-10877); this is typically transient."
        }
        if lower.contains("halc_proxyiocontext") && lower.contains("overload") {
            return "Suppressed HALC IO overload warning; short overload during capture/playback handoff."
        }
        return nil
    }

    private func setupCameraVision() {
        cameraPermissionStatus = CameraPermission.currentStatus
        cameraVisionService.onFrameUpdated = { [weak self] image, capturedAt in
            Task { @MainActor in
                guard let self else { return }
                self.cameraPreviewImage = image
                self.cameraLastFrameAt = capturedAt
                self.cameraPermissionStatus = CameraPermission.currentStatus
            }
        }
    }

    private func observeTTSState() {
        ttsObserver = Task { [weak self] in
            for await isSpeaking in TTSService.shared.$isSpeaking.values {
                guard let self else { return }
                if isSpeaking {
                    self.voicePipeline.suspendForTTS()
                    self.activeSpeechStartedAt = Date()
                    if self.enforceStrictTurnSpeechPhases,
                       let turnID = self.activeTurnID,
                       self.activeSpeechCorrelationID == turnID,
                       self.turnSpeechPhase == .routing {
                        #if DEBUG
                        print("[TURN_PHASE_VIOLATION] turn_id=\(turnID) detail=no_tts_before_route_plan_resolved")
                        #endif
                    }
                    if self.activeSpeechCorrelationID == self.activeTurnID {
                        self.turnSpeechPhase = .speaking
                    }
                    #if DEBUG
                    let correlationID = self.activeSpeechCorrelationID ?? "unknown"
                    print("[TTS_START] correlation_id=\(correlationID) retry_attempt=\(self.activeSpeechRetryAttempt)")
                    #endif
                    self.markTurnTTSStartedIfNeeded()
                } else {
                    self.voicePipeline.resumeAfterTTSIfNeeded()
                    #if DEBUG
                    let correlationID = self.activeSpeechCorrelationID ?? "unknown"
                    if let startedAt = self.activeSpeechStartedAt {
                        let ms = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                        print("[TTS_END] correlation_id=\(correlationID) tts_ms=\(ms)")
                    } else {
                        print("[TTS_END] correlation_id=\(correlationID) tts_ms=unknown")
                    }
                    #endif
                    self.activeSpeechStartedAt = nil
                    if self.activeSpeechCorrelationID == self.activeTurnID {
                        self.turnSpeechPhase = .idle
                    }
                    self.markTurnTTSFinishedIfNeeded()
                }
                if isSpeaking {
                    if self.status == .idle || self.status == .listening {
                        self.status = .speaking
                    }
                } else if self.status == .speaking {
                    self.status = self.isListeningEnabled ? .listening : .idle
                    self.handleSpeechPlaybackFinished()
                }
            }
        }
    }

    // MARK: - Alarm Session Setup

    private func setupAlarmSession() {
        alarmSession.onSpeak = { [weak self] text in
            self?.speakForAlarm(text)
        }
        alarmSession.onAddChatMessage = { [weak self] text in
            self?.chatMessages.append(ChatMessage(role: .assistant, text: text))
        }
        alarmSession.onDismiss = { [weak self] taskId in
            TaskScheduler.shared.dismiss(id: taskId.uuidString)
            self?.activeAlarm = nil
        }
        alarmSession.onRequestFollowUp = { [weak self] in
            self?.triggerAlarmFollowUpCapture()
        }
    }

    private func speakForAlarm(_ text: String) {
        TTSService.shared.speak(text)
        // Auto-trigger follow-up capture so user never needs "hey sam" during alarm
        if alarmSession.isRinging {
            triggerAlarmFollowUpCapture()
        }
    }

    private func triggerAlarmFollowUpCapture() {
        guard isListeningEnabled else { return }

        followUpExpiryTask?.cancel()
        followUpExpiryTask = Task {
            try? await Task.sleep(nanoseconds: Self.alarmFollowUpSettleDelayNs)
            guard !Task.isCancelled else { return }

            self.voicePipeline.startFollowUpCapture(noSpeechTimeoutMs: nil)

            // 30s timeout — matches alarm loop interval
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            guard !Task.isCancelled else { return }
            self.voicePipeline.cancelFollowUpCapture()
        }
    }

    // MARK: - Voice Pipeline

    func startListening() {
        Task {
            let granted = await MicrophonePermission.request()
            guard granted else {
                showError("Microphone access denied. Enable in System Settings → Privacy → Microphone.")
                return
            }

            guard M2Settings.isConfigured else {
                showError("Voice pipeline not configured. Open Settings to set AccessKey, keyword file, and Whisper model.")
                return
            }

            do {
                try voicePipeline.startListening()
                isListeningEnabled = true
                Self.userWantsListeningEnabled = true
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func stopListening() {
        voicePipeline.stopListening()
        speechStartMonitorTask?.cancel()
        speechStartMonitorTask = nil
        activeSpeechCorrelationID = nil
        activeSpeechRetryAttempt = 0
        activeSpeechStartedAt = nil
        activeTurnID = nil
        turnSpeechPhase = .idle
        speechCoordinator.clearSlowStartTracking()
        Task {
            await AudioCoordinator.shared.clearTTSPending(owner: nil)
        }
        isListeningEnabled = false
        Self.userWantsListeningEnabled = false
        awaitingUserReply = false
        awaitingQuestionAutoListen = false
        cancelThinkingFiller()
        clearThinkingFeedback()
        followUpExpiryTask?.cancel()
        followUpExpiryTask = nil
        status = .idle
    }

    func reconfigureVoicePipelineForCurrentMode() {
        guard isListeningEnabled else { return }
        stopListening()
        startListening()
    }

    func toggleCamera() {
        isCameraEnabled ? stopCamera() : startCamera()
    }

    func setCameraEnabled(_ enabled: Bool) {
        enabled ? startCamera() : stopCamera()
    }

    func startCamera(requestPermission: Bool = true) {
        Task {
            if requestPermission {
                let granted = await CameraPermission.request()
                cameraPermissionStatus = CameraPermission.currentStatus
                guard granted else {
                    isCameraEnabled = false
                    Self.userWantsCameraEnabled = false
                    cameraErrorMessage = "Camera access denied. Enable in System Settings > Privacy > Camera."
                    return
                }
            }

            do {
                try cameraVisionService.start()
                isCameraEnabled = true
                Self.userWantsCameraEnabled = true
                cameraPermissionStatus = CameraPermission.currentStatus
                cameraErrorMessage = nil
                if let preview = cameraVisionService.latestPreviewImage() {
                    cameraPreviewImage = preview
                }
                cameraLastFrameAt = cameraVisionService.latestFrameAt
            } catch {
                isCameraEnabled = false
                Self.userWantsCameraEnabled = false
                cameraPermissionStatus = CameraPermission.currentStatus
                cameraErrorMessage = error.localizedDescription
            }
        }
    }

    func stopCamera() {
        cameraVisionService.stop()
        isCameraEnabled = false
        Self.userWantsCameraEnabled = false
        cameraPermissionStatus = CameraPermission.currentStatus
    }

    func refreshCameraPermissionStatus() {
        cameraPermissionStatus = CameraPermission.currentStatus
    }

    func describeCurrentCameraView() {
        guard isCameraEnabled else {
            let text = "Camera is off right now. Turn it on and ask again."
            chatMessages.append(ChatMessage(role: .assistant, text: text))
            TTSService.shared.enqueue([text])
            return
        }

        guard let scene = cameraVisionService.describeCurrentScene() else {
            let text = "Camera is on, but I don't have a frame yet. Try again in a second."
            chatMessages.append(ChatMessage(role: .assistant, text: text))
            TTSService.shared.enqueue([text])
            return
        }

        let spoken = "Here's what I can see right now: \(scene.summary)"
        chatMessages.append(ChatMessage(role: .assistant, text: spoken))
        TTSService.shared.enqueue([spoken])
        appendOutputItem(OutputItem(kind: .markdown, payload: scene.markdown()), source: "camera_describe")
    }

    @discardableResult
    func clearSavedFaces() -> Bool {
        let didClear = cameraVisionService.clearKnownFaces()
        refreshCameraDebug()
        return didClear
    }

    /// Call when Settings opens — pauses listening to avoid ViewBridge / audio contention.
    func pauseListeningForSettings() {
        wasListeningBeforeSettings = isListeningEnabled
        if isListeningEnabled {
            stopListening()
        }
    }

    /// Call when Settings closes — resumes listening if it was active before.
    func resumeListeningAfterSettings() {
        if wasListeningBeforeSettings {
            wasListeningBeforeSettings = false
            startListening()
        }
    }

    private func showError(_ message: String) {
        lastError = message
        errorClearTask?.cancel()
        errorClearTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self.lastError = nil
        }
    }

    // MARK: - Send Message

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let turnID = nextTurnID()
        activeTurnID = turnID
        turnSpeechPhase = .routing
        #if DEBUG
        print("[TURN_PHASE] turn_id=\(turnID) phase=routing")
        #endif
        let existingTurnStart = activeTurnLatencyStartAt
        let turnStart = existingTurnStart ?? Date()
        activeTurnLatencyStartAt = turnStart
        let userLatencyMs = Self.elapsedMs(since: turnStart)
        let preserveThinkingIndicator = existingTurnStart != nil && isThinkingIndicatorVisible
        beginTurnLatencyTrace(
            turnID: turnID,
            userText: trimmed,
            inputMode: existingTurnStart != nil ? "voice" : "text"
        )
        let previousAssistantMessage = chatMessages.last(where: { $0.role == .assistant })?.text
        selfLearningService.observeIncomingUserReply(
            userMessage: trimmed,
            previousAssistantMessage: previousAssistantMessage
        )

        awaitingUserReply = false
        awaitingQuestionAutoListen = false
        speechStartMonitorTask?.cancel()
        speechCoordinator.beginTurn()
        cancelThinkingFiller()
        if !preserveThinkingIndicator {
            clearThinkingFeedback()
        }
        followUpExpiryTask?.cancel()
        followUpExpiryTask = nil

        chatMessages.append(ChatMessage(role: .user, text: trimmed, latencyMs: userLatencyMs))
        status = .thinking
        let baseChatCount = chatMessages.count
        let baseOutputCount = outputItems.count

        // Alarm intercept — hardware-tied, stays in AppState
        if alarmSession.isRinging {
            Task {
                await alarmSession.handleUserReply(trimmed)
                self.activeTurnLatencyStartAt = nil
                status = isListeningEnabled ? .listening : .idle
            }
            return
        }

        // Everything else → orchestrator
        startThinkingFillerTimer(baseChatCount: baseChatCount, baseOutputCount: baseOutputCount)
        let turnInputMode: TurnInputMode = existingTurnStart != nil ? .voice : .text
        let intentAudioTimings = currentIntentAudioTimings()
        IntentAudioDiagnosticsStore.shared.recordTiming(
            captureMs: intentAudioTimings.captureMs,
            sttMs: intentAudioTimings.sttMs
        )
        Task(priority: .userInitiated) {
            let result = await TurnExecutionContext.$turnID.withValue(turnID) {
                await orchestrator.processTurn(trimmed, history: chatMessages, inputMode: turnInputMode)
            }
            self.markTurnSpeechReady(turnID: turnID)
            markTurnRouteFinished(
                provider: result.llmProvider,
                toolSteps: result.executedToolSteps.count,
                routerMs: result.routerMs
            )
            cancelThinkingFiller()
            clearThinkingFeedback()
            applyResult(result, turnID: turnID)
            let assistantMessage = result.appendedChat.last(where: { $0.role == .assistant })?.text
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.memoryAutoSaveService.processTurn(
                    userMessage: trimmed,
                    assistantMessage: assistantMessage
                )
                self.selfLearningService.processTurn(
                    userMessage: trimmed,
                    assistantMessage: assistantMessage,
                    hadCanvasOutput: !result.appendedOutputs.isEmpty,
                    previousAssistantMessage: previousAssistantMessage
                )
                self.refreshWebsiteLearningDebug()
                self.refreshAutonomousLearningDebug()
            }
            status = isListeningEnabled ? .listening : .idle
        }
    }

    // MARK: - Apply Orchestrator Result

    private func applyResult(_ result: TurnResult, turnID: String) {
        var appendedChat = result.appendedChat
        let assistantLatencyMs = activeTurnLatencyStartAt.map { Self.elapsedMs(since: $0) }
        #if DEBUG
        if let assistantLatencyMs {
            let provider = result.llmProvider.rawValue
            let toolCount = result.executedToolSteps.count
            print("[Latency] assistant_total_ms=\(assistantLatencyMs) provider=\(provider) tool_steps=\(toolCount)")
        }
        #endif
        if let assistantLatencyMs {
            for idx in appendedChat.indices where appendedChat[idx].role == .assistant {
                appendedChat[idx].latencyMs = assistantLatencyMs
            }
        }
        if result.usedMemoryHints {
            for idx in appendedChat.indices where appendedChat[idx].role == .assistant {
                appendedChat[idx].usedMemory = true
            }
        }
        if result.knowledgeAttribution?.usedLocalKnowledge == true {
            for idx in appendedChat.indices where appendedChat[idx].role == .assistant {
                appendedChat[idx].usedLocalKnowledge = true
            }
        }
        for idx in appendedChat.indices where appendedChat[idx].role == .assistant && appendedChat[idx].originProvider == .openai {
            appendedChat[idx].assistantResponseMode = currentAssistantResponseMode()
        }

        chatMessages.append(contentsOf: appendedChat)
        appendOutputItems(result.appendedOutputs, source: "turn_result")
        if let attribution = result.knowledgeAttribution {
            appendOutputItem(
                OutputItem(kind: .markdown, payload: formatKnowledgeAttribution(attribution)),
                source: "knowledge_attribution"
            )
        }
        pendingSlot = orchestrator.pendingSlot
        if var trace = turnLatencyTrace {
            trace.intentLocalMs = result.intentRouterMsLocal
            trace.intentOpenAIMs = result.intentRouterMsOpenAI
            trace.planLocalWireMs = result.planLocalWireMs
            trace.planLocalTotalMs = result.planLocalTotalMs
            trace.planOpenAIMs = result.planOpenAIMs
            trace.toolMsTotal = result.toolMsTotal
            turnLatencyTrace = trace
        }

        #if DEBUG
        print("[INTENT_PROVIDER] provider=\(result.intentProviderSelected.rawValue)")
        print("[PLAN_PROVIDER] provider=\(result.planProviderSelected.rawValue)")
        #endif
        enqueueSpeech(result.spokenLines, correlationID: turnID)
        #if DEBUG
        let openAICalls = OpenAICallTracker.shared.summary(for: turnID)
        let reasons = openAICalls.reasons.joined(separator: ",")
        print("[OPENAI_CALLS] turn_id=\(turnID) count=\(openAICalls.count) reasons=[\(reasons)]")
        if result.planProviderSelected == .ollama, openAICalls.count > 0 {
            let callers = openAICalls.callers.joined(separator: ",")
            print("[OPENAI_CALLS_ERROR] turn_id=\(turnID) plan_provider=ollama count=\(openAICalls.count) callers=[\(callers)]")
        }
        OpenAICallTracker.shared.clear(turnID: turnID)
        #endif

        let finalAssistantText = appendedChat.last(where: { $0.role == .assistant })?.text
        finalizeTurnLatencyTraceIfReady(
            spokenLines: result.spokenLines,
            finalAssistantText: finalAssistantText
        )
        let shouldAutoListenForQuestion = result.triggerQuestionAutoListen
            || (finalAssistantText.map(endsWithSingleQuestionMark(_:)) ?? false)

        if isQuestionAutoListenFeatureEnabled && shouldAutoListenForQuestion && isListeningEnabled {
            awaitingUserReply = true
            awaitingQuestionAutoListen = true
        } else if result.triggerFollowUpCapture && isListeningEnabled {
            awaitingUserReply = true
            awaitingQuestionAutoListen = false
        }

        activeTurnLatencyStartAt = nil
    }

    private func enqueueSpeech(_ lines: [String], correlationID: String) {
        let speakable = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !speakable.isEmpty else {
            if correlationID == activeTurnID {
                turnSpeechPhase = .idle
            }
            return
        }

        if enforceStrictTurnSpeechPhases,
           correlationID == activeTurnID,
           turnSpeechPhase == .routing {
            #if DEBUG
            print("[TURN_PHASE_VIOLATION] turn_id=\(correlationID) detail=speech_enqueued_before_route_plan_resolved")
            #endif
            return
        }

        speechStartMonitorTask?.cancel()
        activeSpeechCorrelationID = correlationID
        activeSpeechRetryAttempt = 0
        if var trace = turnLatencyTrace, trace.turnID == correlationID {
            trace.speechEnqueuedAt = Date()
            turnLatencyTrace = trace
        }
        TTSService.shared.clearLastDropReason()
        lastSpeechDropReason = nil
        speechCoordinator.clearSlowStartTracking()
        logSpeechEnqueue(lines: speakable, correlationID: correlationID, retryAttempt: 0)
        Task {
            await AudioCoordinator.shared.setTTSPending(owner: correlationID)
        }
        TTSService.shared.enqueue(speakable, correlationID: correlationID)

        speechStartMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await self.waitForSpeechStart(
                correlationID: correlationID,
                timeoutSeconds: self.ttsStartDeadlineSeconds
            )
            guard !started else { return }
            self.speechCoordinator.recordSlowStart(correlationID: correlationID)
            #if DEBUG
            let deadlineMs = Int(self.ttsStartDeadlineSeconds * 1000)
            print("[TTS_SLOW_START] correlation_id=\(correlationID) tts_start_deadline_ms=\(deadlineMs)")
            #endif
        }
    }

    private func waitForSpeechStart(correlationID: String, timeoutSeconds: Double) async -> Bool {
        func didCurrentSpeechStart() -> Bool {
            if activeSpeechCorrelationID == correlationID,
               activeSpeechStartedAt != nil,
               TTSService.shared.currentCorrelationID == correlationID {
                return true
            }
            return TTSService.shared.isSpeaking && TTSService.shared.currentCorrelationID == correlationID
        }

        if didCurrentSpeechStart() {
            return true
        }
        let deadline = Date().addingTimeInterval(max(0.2, timeoutSeconds))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 60_000_000)
            if Task.isCancelled { return false }
            if didCurrentSpeechStart() {
                return true
            }
        }
        return false
    }

    private func logSpeechEnqueue(lines: [String], correlationID: String, retryAttempt: Int) {
        #if DEBUG
        for line in lines {
            let preview = String(line.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            print("[SPEECH_ENQUEUE] correlation_id=\(correlationID) retry_attempt=\(retryAttempt) chars=\(line.count) preview=\"\(preview)\"")
        }
        #endif
    }

    private func beginTurnLatencyTrace(turnID: String, userText: String, inputMode: String) {
        if turnLatencyTrace != nil {
            finalizeTurnLatencyTrace(reason: "replaced_by_new_turn")
        }
        turnLatencyFinalizeTask?.cancel()
        turnLatencyTraceSequence += 1
        turnLatencyTrace = TurnLatencyTrace(
            id: turnLatencyTraceSequence,
            turnID: turnID,
            inputMode: inputMode,
            userChars: userText.count,
            routerMs: nil,
            intentLocalMs: nil,
            intentOpenAIMs: nil,
            planLocalWireMs: nil,
            planLocalTotalMs: nil,
            planOpenAIMs: nil,
            toolMsTotal: nil,
            captureStartedAt: pendingCaptureStartedAt,
            transcribeStartedAt: pendingTranscribeStartedAt,
            transcriptReadyAt: pendingTranscriptReadyAt,
            routeStartedAt: Date(),
            routeFinishedAt: nil,
            applyFinishedAt: nil,
            speechEnqueuedAt: nil,
            ttsStartedAt: nil,
            ttsFinishedAt: nil,
            expectsTTS: false,
            provider: .none,
            toolSteps: 0,
            assistantChars: 0
        )
        pendingCaptureStartedAt = nil
        pendingTranscribeStartedAt = nil
        pendingTranscriptReadyAt = nil
    }

    private func maybeRunLiveVisionScriptIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains(Self.liveLockdownCheckFlag) {
            Task { [weak self] in
                let succeeded = await self?.runLiveLockdownCheckHarness() ?? false
                exit(succeeded ? 0 : 1)
            }
            return
        }
        if args.contains(Self.liveVisionScriptFlag) {
            Task { [weak self] in
                let succeeded = await self?.runLiveVisionScriptHarness() ?? false
                exit(succeeded ? 0 : 1)
            }
        }
    }

    @discardableResult
    private func runLiveVisionScriptHarness() async -> Bool {
        let reportHeader = "[LIVE_VISION_SCRIPT]"
        print("\(reportHeader) start")

        var failures: [String] = []
        let keyStatus = OpenAISettings.apiKeyStatus
        if keyStatus != .ready {
            failures.append("OpenAI key not ready (\(keyStatus))")
        }

        if !cameraVisionService.isRunning {
            if CameraPermission.currentStatus == .granted {
                do {
                    try cameraVisionService.start()
                    isCameraEnabled = true
                } catch {
                    failures.append("Camera failed to start: \(error.localizedDescription)")
                }
            } else {
                failures.append("Camera permission not granted")
            }
        }

        if cameraVisionService.currentAnalysis() == nil {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if cameraVisionService.currentAnalysis() != nil { break }
            }
        }
        if cameraVisionService.currentAnalysis() == nil {
            failures.append("No live camera frame available")
        }

        var history: [ChatMessage] = []
        var scriptRows: [(turn: String, tools: [String], origin: String, assistant: String, pass: Bool)] = []

        func hasBlindClaim(_ text: String) -> Bool {
            let normalized = text.lowercased()
            return normalized.contains("i can't see")
                || normalized.contains("i dont have the ability to see")
                || normalized.contains("i don't have the ability to see")
                || normalized.contains("i can't recognize images")
        }

        func appendHistory(turn: String, result: TurnResult) {
            history.append(ChatMessage(role: .user, text: turn))
            history.append(contentsOf: result.appendedChat)
        }

        let firstTurn = "What do you see?"
        let firstResult = await orchestrator.processTurn(firstTurn, history: history, inputMode: .text)
        appendHistory(turn: firstTurn, result: firstResult)
        let firstTools = firstResult.executedToolSteps.map(\.name)
        let firstAssistant = firstResult.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""
        let firstOrigin = firstResult.appendedChat.last(where: { $0.role == .assistant })?.originProvider.rawValue
            ?? firstResult.originProvider.rawValue
        let firstPass = firstTools.contains("describe_camera_view") && !hasBlindClaim(firstAssistant)
        if !firstPass {
            failures.append("Turn 1 failed: expected describe_camera_view and no blindness claim")
        }
        scriptRows.append((turn: firstTurn, tools: firstTools, origin: firstOrigin, assistant: firstAssistant, pass: firstPass))

        let secondTurn = "Do you see a person?"
        let secondResult = await orchestrator.processTurn(secondTurn, history: history, inputMode: .text)
        appendHistory(turn: secondTurn, result: secondResult)
        let secondTools = secondResult.executedToolSteps.map(\.name)
        let secondAssistant = secondResult.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""
        let secondOrigin = secondResult.appendedChat.last(where: { $0.role == .assistant })?.originProvider.rawValue
            ?? secondResult.originProvider.rawValue
        let secondPass = secondTools.contains("camera_visual_qa")
        if !secondPass {
            failures.append("Turn 2 failed: expected camera_visual_qa")
        }
        scriptRows.append((turn: secondTurn, tools: secondTools, origin: secondOrigin, assistant: secondAssistant, pass: secondPass))

        print("\(reportHeader) report_begin")
        for row in scriptRows {
            print("\(reportHeader) turn=\"\(row.turn)\" pass=\(row.pass) origin=\(row.origin) tools=\(row.tools.joined(separator: ","))")
            print("\(reportHeader) assistant=\"\(row.assistant)\"")
        }
        if failures.isEmpty {
            print("\(reportHeader) result=PASS")
        } else {
            print("\(reportHeader) result=FAIL failures=\(failures.joined(separator: " | "))")
        }
        print("\(reportHeader) report_end")
        return failures.isEmpty
    }

    @discardableResult
    private func runLiveLockdownCheckHarness() async -> Bool {
        let reportHeader = "[LIVE_LOCKDOWN_CHECK]"
        let enterThreshold: Float = 0.70
        print("\(reportHeader) start")

        var failures: [String] = []

        func hasBlindClaim(_ text: String) -> Bool {
            let normalized = text.lowercased()
            return normalized.contains("i can't see")
                || normalized.contains("i dont have the ability to see")
                || normalized.contains("i don't have the ability to see")
                || normalized.contains("i can't recognize images")
        }

        func looksLikeIdentityPrompt(_ text: String) -> Bool {
            let normalized = text.lowercased()
            return normalized.contains("what's your name") || normalized.contains("what is your name")
        }

        let keyStatus = OpenAISettings.apiKeyStatus
        if keyStatus != .ready {
            failures.append("OpenAI key not ready (\(keyStatus))")
        }

        if !cameraVisionService.isRunning {
            if CameraPermission.currentStatus == .granted {
                do {
                    try cameraVisionService.start()
                    isCameraEnabled = true
                } catch {
                    failures.append("Camera failed to start: \(error.localizedDescription)")
                }
            } else {
                failures.append("Camera permission not granted")
            }
        }

        var becameHealthy = false
        for _ in 0..<30 {
            if cameraVisionService.health.isHealthy {
                becameHealthy = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !becameHealthy {
            failures.append("Camera health did not become healthy within 3s")
        }
        let initialHealth = cameraVisionService.health

        let enrollResult = cameraVisionService.enrollFace(name: "Richard")
        if enrollResult.status != .success {
            failures.append("Enroll failed with status \(enrollResult.status)")
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        var confidenceSamples: [Float] = []
        let recognitionLoopStart = Date()
        while Date().timeIntervalSince(recognitionLoopStart) < 5.0 {
            if let recognition = cameraVisionService.recognizeKnownFaces(),
               let primary = recognition.matches.max(by: { $0.confidence < $1.confidence }) {
                confidenceSamples.append(primary.confidence)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let maxConfidence = confidenceSamples.max() ?? 0
        let minConfidence = confidenceSamples.min() ?? 0

        var trustKnown = false
        var history: [ChatMessage] = []
        let trustProbe = await orchestrator.processTurn("Hi", history: history, inputMode: .text)
        history.append(ChatMessage(role: .user, text: "Hi"))
        history.append(contentsOf: trustProbe.appendedChat)
        let trustAssistant = trustProbe.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""
        #if DEBUG
        let identityContext = (orchestrator as? TurnOrchestrator)?.debugLastPromptContext()?.identityContextLine ?? ""
        #else
        let identityContext = ""
        #endif
        trustKnown = trustAssistant.localizedCaseInsensitiveContains("richard")
            || identityContext.localizedCaseInsensitiveContains("recognized user: richard")
        if looksLikeIdentityPrompt(trustAssistant) {
            failures.append("Trust probe re-prompted identity after enrollment")
        }

        if !(maxConfidence >= enterThreshold || trustKnown) {
            failures.append("Recognition confidence never reached enter threshold and trust-window did not force known")
        }

        let visionTurn = "What do you see?"
        let visionResult = await orchestrator.processTurn(visionTurn, history: history, inputMode: .text)
        history.append(ChatMessage(role: .user, text: visionTurn))
        history.append(contentsOf: visionResult.appendedChat)
        let visionAssistant = visionResult.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""
        let visionTools = visionResult.executedToolSteps.map(\.name)
        let visionPass = visionTools.contains("describe_camera_view") && !hasBlindClaim(visionAssistant)
        if !visionPass {
            failures.append("Vision turn failed: expected describe_camera_view and no blindness claim")
        }

        let chatTurn = "How are you today?"
        let chatResult = await orchestrator.processTurn(chatTurn, history: history, inputMode: .text)
        history.append(ChatMessage(role: .user, text: chatTurn))
        history.append(contentsOf: chatResult.appendedChat)
        let chatAssistant = chatResult.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""
        let chatLower = chatAssistant.lowercased()
        let answeredQuestion = chatLower.contains("i'm")
            || chatLower.contains("i am")
            || chatLower.contains("doing")
            || chatLower.contains("well")
        if !answeredQuestion {
            failures.append("Chat turn did not answer 'How are you today?'")
        }
        if looksLikeIdentityPrompt(chatAssistant) {
            failures.append("Chat turn re-prompted identity after enrollment")
        }

        print("\(reportHeader) report_begin")
        print("\(reportHeader) health_initial isHealthy=\(initialHealth.isHealthy) lastGoodFrameAt=\(String(describing: initialHealth.lastGoodFrameAt)) consecutiveErrors=\(initialHealth.consecutiveErrors)")
        print("\(reportHeader) enroll status=\(enrollResult.status) samplesForName=\(enrollResult.samplesForName) totalKnownNames=\(enrollResult.totalKnownNames)")
        print("\(reportHeader) recognition samples=\(confidenceSamples.count) minConfidence=\(String(format: "%.3f", minConfidence)) maxConfidence=\(String(format: "%.3f", maxConfidence)) trustKnown=\(trustKnown)")
        print("\(reportHeader) turn=\"\(visionTurn)\" tools=\(visionTools.joined(separator: ",")) assistant=\"\(visionAssistant)\"")
        print("\(reportHeader) turn=\"\(chatTurn)\" provider=\(chatResult.llmProvider.rawValue) assistant=\"\(chatAssistant)\"")
        if failures.isEmpty {
            print("\(reportHeader) result=PASS")
        } else {
            print("\(reportHeader) result=FAIL failures=\(failures.joined(separator: " | "))")
        }
        print("\(reportHeader) report_end")
        return failures.isEmpty
    }

    private func markTurnRouteFinished(provider: LLMProvider, toolSteps: Int, routerMs: Int?) {
        guard var trace = turnLatencyTrace else { return }
        trace.routeFinishedAt = Date()
        trace.provider = provider
        trace.toolSteps = toolSteps
        trace.routerMs = routerMs
        turnLatencyTrace = trace
    }

    private func finalizeTurnLatencyTraceIfReady(spokenLines: [String], finalAssistantText: String?) {
        guard var trace = turnLatencyTrace else { return }
        trace.applyFinishedAt = Date()
        trace.assistantChars = finalAssistantText?.count ?? 0
        let expectsTTS = !spokenLines.isEmpty && !ElevenLabsSettings.isMuted && ElevenLabsSettings.isConfigured
        trace.expectsTTS = expectsTTS
        turnLatencyTrace = trace

        if expectsTTS {
            turnLatencyFinalizeTask?.cancel()
            turnLatencyFinalizeTask = Task { @MainActor [weak self] in
                let seconds = self?.ttsTotalDeadlineSeconds ?? 45.0
                let timeoutNs = UInt64(max(1.0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard let self else { return }
                guard let pending = self.turnLatencyTrace, pending.id == trace.id, pending.expectsTTS else { return }
                #if DEBUG
                let correlationID = self.activeSpeechCorrelationID ?? "unknown"
                print("[TTS_SLOW_FINISH] correlation_id=\(correlationID) tts_total_deadline_ms=\(Int(self.ttsTotalDeadlineSeconds * 1000))")
                #endif
                self.finalizeTurnLatencyTrace(reason: "tts_total_deadline_exceeded")
            }
            return
        }

        finalizeTurnLatencyTrace(reason: "no_tts")
    }

    private func markTurnTTSStartedIfNeeded() {
        guard var trace = turnLatencyTrace, trace.expectsTTS else { return }
        guard trace.ttsStartedAt == nil else { return }
        trace.ttsStartedAt = Date()
        turnLatencyTrace = trace
    }

    private func markTurnTTSFinishedIfNeeded() {
        guard var trace = turnLatencyTrace, trace.expectsTTS else { return }
        guard trace.ttsStartedAt != nil, trace.ttsFinishedAt == nil else { return }
        trace.ttsFinishedAt = Date()
        turnLatencyTrace = trace
        finalizeTurnLatencyTrace(reason: "tts_finished")
    }

    private func finalizeTurnLatencyTrace(reason: String) {
        guard let trace = turnLatencyTrace else { return }
        turnLatencyTrace = nil
        turnLatencyFinalizeTask?.cancel()
        turnLatencyFinalizeTask = nil

        #if DEBUG
        func ms(_ start: Date?, _ end: Date?) -> Int? {
            guard let start, let end else { return nil }
            return max(0, Int(end.timeIntervalSince(start) * 1000))
        }
        func str(_ value: Int?) -> String {
            guard let value else { return "n/a" }
            return "\(value)"
        }

        let captureMs = ms(trace.captureStartedAt, trace.transcribeStartedAt)
        let sttMs = ms(trace.transcribeStartedAt, trace.transcriptReadyAt)
        let orchestratorMs = ms(trace.routeStartedAt, trace.routeFinishedAt)
        let applyMs = ms(trace.routeFinishedAt, trace.applyFinishedAt)
        let snapshot = TTSService.shared.timingSnapshot(for: trace.turnID)
        let ttsQueueWaitMs = snapshot?.queueWaitMs ?? ms(trace.speechEnqueuedAt, trace.ttsStartedAt)
        let ttsSynthesisMs = snapshot?.synthesisMs
        let ttsPlaybackStartMs = snapshot?.playbackStartMs ?? ms(trace.speechEnqueuedAt, trace.ttsStartedAt)
        let ttsMs = ms(trace.ttsStartedAt, trace.ttsFinishedAt)
        let end = trace.ttsFinishedAt ?? trace.applyFinishedAt ?? trace.routeFinishedAt
        let start = trace.transcriptReadyAt ?? trace.routeStartedAt
        let totalMs = ms(start, end)
        let playbackStartedAt: Date? = {
            if let enqueueAt = trace.speechEnqueuedAt,
               let playbackStartMs = ttsPlaybackStartMs {
                return enqueueAt.addingTimeInterval(Double(playbackStartMs) / 1000.0)
            }
            return trace.ttsStartedAt
        }()
        let firstAudioMs = ms(start, playbackStartedAt)

        let routerMs = trace.routerMs.map(String.init) ?? "n/a"
        print("[LatencyBreakdown] turn=\(trace.id) mode=\(trace.inputMode) capture_ms=\(str(captureMs)) stt_ms=\(str(sttMs)) router_ms=\(routerMs) orchestrator_ms=\(str(orchestratorMs)) apply_ms=\(str(applyMs)) tts_wait_ms=\(str(ttsQueueWaitMs)) tts_ms=\(str(ttsMs)) total_ms=\(str(totalMs)) provider=\(trace.provider.rawValue) tool_steps=\(trace.toolSteps) user_chars=\(trace.userChars) assistant_chars=\(trace.assistantChars) reason=\(reason)")
        print("[PERF_TURN] turn_id=\(trace.turnID) mode=\(trace.inputMode) capture_ms=\(str(captureMs)) stt_ms=\(str(sttMs)) intent_local_ms=\(str(trace.intentLocalMs)) intent_openai_ms=\(str(trace.intentOpenAIMs)) plan_local_wire_ms=\(str(trace.planLocalWireMs)) plan_local_total_ms=\(str(trace.planLocalTotalMs)) plan_openai_ms=\(str(trace.planOpenAIMs)) tool_ms_total=\(str(trace.toolMsTotal)) tts_queue_wait_ms=\(str(ttsQueueWaitMs)) tts_synthesis_ms=\(str(ttsSynthesisMs)) tts_playback_start_ms=\(str(ttsPlaybackStartMs)) first_audio_ms=\(str(firstAudioMs)) total_ms=\(str(totalMs))")
        #endif
    }

    private func currentAssistantResponseMode() -> AssistantResponseMode {
        let useRealtimeSTT = OpenAISettings.realtimeModeEnabled && !OpenAISettings.realtimeUseClassicSTT
        return useRealtimeSTT ? .realtimeAI : .openAIClassic
    }

    private func formatKnowledgeAttribution(_ attribution: KnowledgeAttribution) -> String {
        var lines = [
            "### Knowledge Usage",
            "- Local knowledge used: \(attribution.localKnowledgePercent)%",
            "- OpenAI fill gap: \(attribution.openAIFillPercent)%",
            "- Local matches: \(attribution.matchedLocalItems)/\(attribution.consideredLocalItems)"
        ]

        if let model = attribution.aiModelUsed?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            lines.append("- AI Model Used: \(model)")
        }

        if attribution.provider != .openai {
            lines.append("- Response provider: \(attribution.provider.rawValue)")
        }

        if !attribution.evidence.isEmpty {
            lines.append("")
            lines.append("#### Evidence Used")
            for entry in attribution.evidence {
                lines.append("- \(entry.markdownLine())")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func nextTurnID() -> String {
        turnSequence += 1
        return "turn_\(turnSequence)"
    }

    private func markTurnSpeechReady(turnID: String) {
        guard activeTurnID == turnID else { return }
        turnSpeechPhase = .speechReady
        #if DEBUG
        print("[TURN_PHASE] turn_id=\(turnID) phase=speech_ready route_plan_execute_done=true speech_policy_selected=true")
        #endif
    }

    // MARK: - Thinking Filler

    private func startThinkingFillerTimer(baseChatCount: Int, baseOutputCount: Int) {
        cancelThinkingFiller()

        thinkingFillerTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.thinkingFillerDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            let hasOutput = self.chatMessages.count > baseChatCount || self.outputItems.count > baseOutputCount
            guard !hasOutput else { return }

            self.isThinkingIndicatorVisible = true
            self.speakThinkingFillerIfAllowed()
        }
    }

    private func cancelThinkingFiller() {
        thinkingFillerTask?.cancel()
        thinkingFillerTask = nil
    }

    private func clearThinkingFeedback() {
        isThinkingIndicatorVisible = false
    }

    private func speakThinkingFillerIfAllowed() {
        if enforceStrictTurnSpeechPhases && turnSpeechPhase == .routing {
            #if DEBUG
            if let turnID = activeTurnID {
                print("[TURN_PHASE] turn_id=\(turnID) filler_suppressed_until_route_plan_resolved=true")
            }
            #endif
            return
        }

        let ttsIsSpeaking = enforceStrictTurnSpeechPhases ? TTSService.shared.isSpeaking : false
        if let filler = speechCoordinator.consumeThinkingFillerIfAllowed(
            isTTSSpeaking: ttsIsSpeaking,
            isCapturing: status == .capturing,
            enforceStrictPhases: enforceStrictTurnSpeechPhases,
            isRoutingPhase: turnSpeechPhase == .routing
        ) {
            thinkingFillerSpeaker(filler)
        }
    }

    // MARK: - Mute Toggle

    func toggleMute() {
        isMuted.toggle()
        ElevenLabsSettings.isMuted = isMuted
        if isMuted {
            TTSService.shared.stopSpeaking(reason: .explicitCancel)
        }
    }

    // MARK: - Scheduled Task Handling

    private func handleScheduledTask(_ task: ScheduledTask) {
        #if DEBUG
        let age = Date().timeIntervalSince(task.runAt)
        print("[AppState] handleScheduledTask: id=\(task.id.uuidString.prefix(8)) label=\"\(task.label)\" skillId=\(task.skillId) runAt=\(task.runAt) age=\(Int(age))s")
        #else
        let age = Date().timeIntervalSince(task.runAt)
        #endif

        // Hard gate: reject tasks whose runAt is more than 30s in the past (stale)
        if age > 30 {
            #if DEBUG
            print("[AppState] Rejected stale task \(task.id.uuidString.prefix(8)) (age=\(Int(age))s)")
            #endif
            TaskScheduler.shared.dismiss(id: task.id.uuidString)
            return
        }

        if task.payload["type"] == "memory_checkin" {
            handleMemoryCheckInTask(task)
            return
        }

        guard let skill = SkillStore.shared.get(id: task.skillId) else { return }
        activeAlarm = task

        if let trigger = skill.onTrigger {
            if let soundName = trigger.sound {
                NSSound(named: NSSound.Name(soundName))?.play()
            }
            if trigger.showCard == true {
                let canSnooze = task.payload["snoozed_from"] == nil
                let payload = "{\"type\":\"alarm\",\"label\":\"\(task.label)\",\"task_id\":\"\(task.id.uuidString)\",\"can_snooze\":\(canSnooze)}"
                appendOutputItem(OutputItem(kind: .card, payload: payload), source: "scheduled_task_alarm_card")
            }

            if task.payload["snoozed_from"] != nil {
                alarmSession.snoozeExpired(task: task)
            } else {
                alarmSession.startRinging(task: task)
            }
        }
    }

    private func handleMemoryCheckInTask(_ task: ScheduledTask) {
        let message = task.payload["message"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (message?.isEmpty == false) ? message! : "Hey — feeling any better today?"

        chatMessages.append(ChatMessage(role: .assistant, text: text))
        TTSService.shared.enqueue([text])

        if isListeningEnabled, text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            awaitingUserReply = true
            awaitingQuestionAutoListen = true
        }
    }

    func dismissAlarm() {
        alarmSession.dismiss()
        followUpExpiryTask?.cancel()
        followUpExpiryTask = nil
        TTSService.shared.stopSpeaking(reason: .explicitCancel)
    }

    // MARK: - SkillForge Queue Observation

    private func setupForgeQueueObservation() {
        SkillForgeQueueService.shared.onJobLog = { [weak self] job, message in
            guard let self else { return }
            self.appendForgeLogToCanvas(job: job, message: message)
        }

        SkillForgeQueueService.shared.onJobCompleted = { [weak self] job, skill in
            guard let self else { return }
            self.appendForgeLogToCanvas(job: job, message: "Installed capability: \(skill.name)")
            let done = "Capability installed: \(skill.name). You can ask me to use it now."
            self.chatMessages.append(ChatMessage(role: .assistant, text: done))
            TTSService.shared.speak(done)
            self.skillForgeState = .idle
        }

        SkillForgeQueueService.shared.onJobFailed = { [weak self] job, reason in
            guard let self else { return }
            self.appendForgeLogToCanvas(job: job, message: "Build failed: \(reason)")
            let fail = "I couldn't figure that one out: \(reason)"
            self.chatMessages.append(ChatMessage(role: .assistant, text: fail))
            TTSService.shared.speak(fail)
            self.skillForgeState = .idle
        }
    }

    private func setupAutonomousLearningObservation() {
        AutonomousLearningService.shared.onSessionCompleted = { [weak self] report in
            Task { @MainActor in
                self?.handleAutonomousLearningCompletion(report)
            }
        }
        refreshAutonomousLearningDebug()
    }

    private func handleAutonomousLearningCompletion(_ report: AutonomousLearningReport) {
        refreshWebsiteLearningDebug()
        refreshAutonomousLearningDebug()

        let topicPhrase = report.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = report.openQuestions.first ?? "Do you want me to keep learning on this?"
        let completionLabel = autonomousCompletionLabel(report.completionReason)
        let spoken = "I \(completionLabel) autonomous learning on \(topicPhrase). I reviewed \(report.sources.count) sources and learned \(report.lessons.count) key points. \(question)"

        chatMessages.append(ChatMessage(role: .assistant, text: spoken))
        TTSService.shared.enqueue([spoken])

        let markdown = formatAutonomousLearningReport(report)
        appendOutputItem(OutputItem(kind: .markdown, payload: markdown), source: "autonomous_learning_report")

        if isListeningEnabled && spoken.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            awaitingUserReply = true
            awaitingQuestionAutoListen = true
        }
    }

    private func formatAutonomousLearningReport(_ report: AutonomousLearningReport) -> String {
        var lines: [String] = [
            "# Autonomous Learning Complete",
            "",
            "- Topic: \(report.topic)",
            "- Duration: \(report.requestedMinutes) minute\(report.requestedMinutes == 1 ? "" : "s")",
            "- Sources reviewed: \(report.sources.count)",
            "- Learned points: \(report.lessons.count)"
        ]
        if let reason = report.completionReason {
            lines.append("- Completion: \(autonomousCompletionDescription(reason))")
        }

        if !report.lessons.isEmpty {
            lines.append("")
            lines.append("## What I Learned")
            for lesson in report.lessons {
                lines.append("- \(lesson)")
            }
        }

        if !report.sources.isEmpty {
            lines.append("")
            lines.append("## Sources")
            for source in report.sources {
                lines.append("- \(source)")
            }
        }

        if !report.openQuestions.isEmpty {
            lines.append("")
            lines.append("## Questions For You")
            for question in report.openQuestions.prefix(3) {
                lines.append("- \(question)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func autonomousCompletionLabel(_ reason: String?) -> String {
        switch reason {
        case "user_stopped":
            return "stopped"
        case "learned_enough":
            return "wrapped up"
        case "storage_budget_reached", "source_budget_reached", "lesson_budget_reached":
            return "ended"
        default:
            return "finished"
        }
    }

    private func autonomousCompletionDescription(_ reason: String) -> String {
        switch reason {
        case "time_elapsed":
            return "Time limit reached"
        case "learned_enough":
            return "Learned enough (coverage + low new information)"
        case "user_stopped":
            return "Stopped by user"
        case "source_budget_reached":
            return "Session source budget reached"
        case "lesson_budget_reached":
            return "Session lesson budget reached"
        case "storage_budget_reached":
            return "Session storage budget reached"
        default:
            return reason
        }
    }

    private func appendForgeLogToCanvas(job: ForgeQueueJob, message: String) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let eventMarkdown: String
        if normalized.hasPrefix("[OpenAI Request]\n") {
            let body = normalized.replacingOccurrences(of: "[OpenAI Request]\n", with: "")
            eventMarkdown = "### \(timestamp) · OpenAI Request\n```text\n\(body)\n```"
        } else if normalized.hasPrefix("[OpenAI Response]\n") {
            let body = normalized.replacingOccurrences(of: "[OpenAI Response]\n", with: "")
            eventMarkdown = "### \(timestamp) · OpenAI Response\n```text\n\(body)\n```"
        } else if normalized.hasPrefix("[OpenAI Error]\n") {
            let body = normalized.replacingOccurrences(of: "[OpenAI Error]\n", with: "")
            eventMarkdown = "### \(timestamp) · OpenAI Error\n```text\n\(body)\n```"
        } else {
            eventMarkdown = "- \(timestamp): \(normalized)"
        }

        let transcriptHeader = """
        # Capability Build

        - Goal: \(job.goal)
        - Job ID: \(job.id.uuidString)

        ## Activity
        """
        let updatedTranscript: String
        if let existing = forgeLogMarkdownByJobID[job.id], !existing.isEmpty {
            updatedTranscript = existing + "\n\n" + eventMarkdown
        } else {
            updatedTranscript = transcriptHeader + "\n\n" + eventMarkdown
        }
        forgeLogMarkdownByJobID[job.id] = updatedTranscript

        if let itemID = forgeLogItemByJobID[job.id],
           let idx = outputItems.firstIndex(where: { $0.id == itemID }) {
            let existing = outputItems[idx]
            replaceOutputItem(
                at: idx,
                with: OutputItem(id: existing.id, ts: existing.ts, kind: .markdown, payload: updatedTranscript),
                source: "forge_log_update"
            )
        } else {
            let item = OutputItem(kind: .markdown, payload: updatedTranscript)
            appendOutputItem(item, source: "forge_log_new")
            forgeLogItemByJobID[job.id] = item.id
        }
    }

    func clearOutputCanvas() {
        let previousCount = outputItems.count
        outputItems.removeAll()
        outputCanvasLogStore.logClear(previousCount: previousCount, source: "user_clear")
    }

    private func appendOutputItems(_ items: [OutputItem], source: String) {
        guard !items.isEmpty else { return }
        outputItems.append(contentsOf: items)
        for item in items {
            outputCanvasLogStore.logAppend(item: item, source: source)
        }
    }

    private func appendOutputItem(_ item: OutputItem, source: String) {
        outputItems.append(item)
        outputCanvasLogStore.logAppend(item: item, source: source)
    }

    private func replaceOutputItem(at index: Int, with item: OutputItem, source: String) {
        guard outputItems.indices.contains(index) else { return }
        outputItems[index] = item
        outputCanvasLogStore.logUpdate(item: item, source: source)
    }

    // MARK: - Follow-Up Capture

    private func triggerFollowUpCapture() {
        awaitingUserReply = false
        awaitingQuestionAutoListen = false
        guard isListeningEnabled else { return }

        followUpExpiryTask?.cancel()
        followUpExpiryTask = Task {
            try? await Task.sleep(nanoseconds: Self.followUpSettleDelayNs)
            guard !Task.isCancelled else { return }

            self.voicePipeline.startFollowUpCapture(noSpeechTimeoutMs: nil)

            try? await Task.sleep(nanoseconds: 8_000_000_000) // 8s
            guard !Task.isCancelled else { return }
            self.voicePipeline.cancelFollowUpCapture()
        }
    }

    private func triggerQuestionAutoListenWindow() {
        awaitingUserReply = false
        awaitingQuestionAutoListen = false
        guard isListeningEnabled else { return }

        followUpExpiryTask?.cancel()
        followUpExpiryTask = Task {
            try? await Task.sleep(nanoseconds: Self.followUpSettleDelayNs)
            guard !Task.isCancelled else { return }
            // Let AudioCaptureService endpoint speech naturally to avoid dropping short replies.
            self.voicePipeline.startFollowUpCapture(
                noSpeechTimeoutMs: self.questionAutoListenNoSpeechTimeoutMs
            )
        }
    }

    private func handleSpeechPlaybackFinished() {
        guard awaitingUserReply, isListeningEnabled else { return }
        if awaitingQuestionAutoListen {
            triggerQuestionAutoListenWindow()
        } else {
            triggerFollowUpCapture()
        }
    }

    #if DEBUG
    func debugHandleSpeechPlaybackFinished() {
        handleSpeechPlaybackFinished()
    }

    func debugSanitizedVoiceTranscript(_ text: String) -> String? {
        sanitizedVoiceTranscript(text)
    }

    func debugLastSpeechDropReason() -> String? {
        lastSpeechDropReason ?? TTSService.shared.lastDropReasonRawValue
    }

    func debugLastSpeechSlowStartCorrelationID() -> String? {
        speechCoordinator.lastSlowStartCorrelationID
    }

    func debugActiveTurnID() -> String? {
        activeTurnID
    }

    func debugTurnSpeechPhase() -> String {
        turnSpeechPhase.rawValue
    }
    #endif

    private func endsWithSingleQuestionMark(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?") else { return false }
        return trimmed.filter { $0 == "?" }.count == 1
    }

    private func sanitizedVoiceTranscript(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !Self.isLikelyNonSpeechArtifact(trimmed) else { return nil }
        return trimmed
    }

    private static func isLikelyNonSpeechArtifact(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = normalized
            .replacingOccurrences(of: #"[\[\]\(\)_]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let exactNoiseLabels: Set<String> = [
            "music",
            "background music",
            "dramatic music",
            "ambient music",
            "instrumental music",
            "blank audio",
            "silence",
            "noise",
            "applause",
            "laughter"
        ]
        return exactNoiseLabels.contains(compact)
    }

    private static func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private static func durationMs(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(end.timeIntervalSince(start) * 1000))
    }

    private func currentIntentAudioTimings() -> (captureMs: Int?, sttMs: Int?) {
        guard let trace = turnLatencyTrace else {
            return (nil, nil)
        }
        return (
            captureMs: Self.durationMs(from: trace.captureStartedAt, to: trace.transcribeStartedAt),
            sttMs: Self.durationMs(from: trace.transcribeStartedAt, to: trace.transcriptReadyAt)
        )
    }

    private var isQuestionAutoListenFeatureEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: Self.questionAutoListenFeatureFlagKey) as? Bool {
            return stored
        }
        return true
    }

    func refreshWebsiteLearningDebug(limit: Int = 20) {
        _ = limit
        learnedWebsiteCount = WebsiteLearningStore.shared.count()
    }

    func refreshAutonomousLearningDebug(limit: Int = 20) {
        _ = limit
        autonomousLearningReportCount = AutonomousLearningReportStore.shared.count()
        activeAutonomousLearningSession = AutonomousLearningService.shared.activeSessionSnapshot()
    }

    func refreshCameraDebug() {
        cameraPermissionStatus = CameraPermission.currentStatus
        isCameraEnabled = cameraVisionService.isRunning
        cameraLastFrameAt = cameraVisionService.latestFrameAt
        if let preview = cameraVisionService.latestPreviewImage() {
            cameraPreviewImage = preview
        }
    }
}

private final class OutputCanvasLogStore {
    static let shared = OutputCanvasLogStore()

    private let queue = DispatchQueue(label: "com.samos.outputcanvas.log")
    private let encoder: JSONEncoder
    private let sessionID = UUID().uuidString
    private let logFileURL: URL?

    private init() {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        self.encoder = jsonEncoder

        do {
            let fileManager = FileManager.default
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let logsDir = appSupport
                .appendingPathComponent("SamOS", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
            try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
            self.logFileURL = logsDir.appendingPathComponent("output_canvas_events.jsonl", isDirectory: false)
        } catch {
            #if DEBUG
            print("[OutputCanvasLogStore] init failed: \(error.localizedDescription)")
            #endif
            self.logFileURL = nil
        }
    }

    func logAppend(item: OutputItem, source: String) {
        log(
            type: "append",
            source: source,
            itemID: item.id.uuidString,
            itemTimestamp: item.ts,
            kind: item.kind.rawValue,
            payload: item.payload,
            previousCount: nil
        )
    }

    func logUpdate(item: OutputItem, source: String) {
        log(
            type: "update",
            source: source,
            itemID: item.id.uuidString,
            itemTimestamp: item.ts,
            kind: item.kind.rawValue,
            payload: item.payload,
            previousCount: nil
        )
    }

    func logClear(previousCount: Int, source: String) {
        log(
            type: "clear",
            source: source,
            itemID: nil,
            itemTimestamp: nil,
            kind: nil,
            payload: nil,
            previousCount: previousCount
        )
    }

    private func log(type: String,
                     source: String,
                     itemID: String?,
                     itemTimestamp: Date?,
                     kind: String?,
                     payload: String?,
                     previousCount: Int?) {
        guard let logFileURL else { return }
        let event = CanvasLogEvent(
            sessionID: sessionID,
            loggedAt: Date(),
            type: type,
            source: source,
            itemID: itemID,
            itemTimestamp: itemTimestamp,
            kind: kind,
            payload: payload,
            previousCount: previousCount
        )

        queue.async { [encoder] in
            guard let encoded = try? encoder.encode(event) else { return }
            var line = encoded
            line.append(0x0A)
            self.appendLine(line, to: logFileURL)
        }
    }

    private func appendLine(_ line: Data, to url: URL) {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: url.path) {
            do {
                try line.write(to: url, options: .atomic)
            } catch {
                #if DEBUG
                print("[OutputCanvasLogStore] write failed: \(error.localizedDescription)")
                #endif
            }
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer {
                handle.closeFile()
            }
            handle.seekToEndOfFile()
            handle.write(line)
        } catch {
            #if DEBUG
            print("[OutputCanvasLogStore] append failed: \(error.localizedDescription)")
            #endif
        }
    }
}

private struct CanvasLogEvent: Codable {
    let sessionID: String
    let loggedAt: Date
    let type: String
    let source: String
    let itemID: String?
    let itemTimestamp: Date?
    let kind: String?
    let payload: String?
    let previousCount: Int?
}
