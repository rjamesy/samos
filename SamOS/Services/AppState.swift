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

    let alarmSession = AlarmSession()
    private let orchestrator = TurnOrchestrator()
    private let voicePipeline = VoicePipelineCoordinator()

    private var errorClearTask: Task<Void, Never>?
    private var ttsObserver: Task<Void, Never>?
    private var thinkingCueTask: Task<Void, Never>?
    private var followUpExpiryTask: Task<Void, Never>?

    /// When true, the next TTS-finish triggers follow-up capture (no wake word needed).
    private var awaitingUserReply = false

    /// Last time a "thinking" cue was spoken — rate-limited to once per 20 seconds.
    private var lastThinkingCueTime: Date = .distantPast

    /// Tracks whether listening was active before Settings was opened, to auto-resume on close.
    private(set) var wasListeningBeforeSettings = false

    /// Convenience for the Settings banner.
    var wasListeningPausedForSettings: Bool { wasListeningBeforeSettings }

    /// Persisted user preference: whether listening should auto-start.
    static var userWantsListeningEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "samos_userWantsListeningEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "samos_userWantsListeningEnabled") }
    }

    // MARK: - Init

    init() {
        setupVoicePipeline()
        setupAlarmSession()
        observeTTSState()
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

        // Auto-start listening if user previously enabled it and mic is authorized
        if Self.userWantsListeningEnabled
            && MicrophonePermission.currentStatus == .granted
            && M2Settings.isConfigured {
            startListening()
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
            case .transcribing:
                self.status = .thinking
            }
        }

        voicePipeline.onTranscript = { [weak self] text in
            self?.send(text)
        }

        voicePipeline.onError = { [weak self] error in
            self?.showError(error.localizedDescription)
        }
    }

    private func observeTTSState() {
        ttsObserver = Task { [weak self] in
            for await isSpeaking in TTSService.shared.$isSpeaking.values {
                guard let self else { return }
                if isSpeaking {
                    if self.status == .idle || self.status == .listening {
                        self.status = .speaking
                    }
                } else if self.status == .speaking {
                    self.status = self.isListeningEnabled ? .listening : .idle
                    if self.awaitingUserReply && self.isListeningEnabled {
                        self.triggerFollowUpCapture()
                    }
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
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms settle
            guard !Task.isCancelled else { return }

            self.voicePipeline.startFollowUpCapture()

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
        isListeningEnabled = false
        Self.userWantsListeningEnabled = false
        awaitingUserReply = false
        followUpExpiryTask?.cancel()
        followUpExpiryTask = nil
        status = .idle
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

        awaitingUserReply = false
        followUpExpiryTask?.cancel()
        followUpExpiryTask = nil

        chatMessages.append(ChatMessage(role: .user, text: trimmed))
        status = .thinking

        // Alarm intercept — hardware-tied, stays in AppState
        if alarmSession.isRinging {
            cancelThinkingCue()
            Task {
                await alarmSession.handleUserReply(trimmed)
                status = isListeningEnabled ? .listening : .idle
            }
            return
        }

        // Everything else → orchestrator
        startThinkingCueTimer()
        Task {
            let result = await orchestrator.processTurn(trimmed, history: chatMessages)
            cancelThinkingCue()
            applyResult(result)
            status = isListeningEnabled ? .listening : .idle
        }
    }

    // MARK: - Apply Orchestrator Result

    private func applyResult(_ result: TurnResult) {
        chatMessages.append(contentsOf: result.appendedChat)
        outputItems.append(contentsOf: result.appendedOutputs)
        pendingSlot = orchestrator.pendingSlot

        for line in result.spokenLines {
            TTSService.shared.speak(line)
        }

        if result.triggerFollowUpCapture && isListeningEnabled {
            awaitingUserReply = true
        }
    }

    // MARK: - Thinking Cue

    private func startThinkingCueTimer() {
        cancelThinkingCue()

        thinkingCueTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000) // 600ms
            guard !Task.isCancelled, let self else { return }

            let now = Date()
            guard now.timeIntervalSince(self.lastThinkingCueTime) >= 20 else { return }

            self.lastThinkingCueTime = now
            TTSService.shared.speak("One sec\u{2026}", mode: .confirm, interrupt: false)
        }
    }

    private func cancelThinkingCue() {
        thinkingCueTask?.cancel()
        thinkingCueTask = nil
    }

    // MARK: - Mute Toggle

    func toggleMute() {
        isMuted.toggle()
        ElevenLabsSettings.isMuted = isMuted
        if isMuted {
            TTSService.shared.stopSpeaking()
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

        guard let skill = SkillStore.shared.get(id: task.skillId) else { return }
        activeAlarm = task

        if let trigger = skill.onTrigger {
            if let soundName = trigger.sound {
                NSSound(named: NSSound.Name(soundName))?.play()
            }
            if trigger.showCard == true {
                let canSnooze = task.payload["snoozed_from"] == nil
                let payload = "{\"type\":\"alarm\",\"label\":\"\(task.label)\",\"task_id\":\"\(task.id.uuidString)\",\"can_snooze\":\(canSnooze)}"
                outputItems.append(OutputItem(kind: .card, payload: payload))
            }

            if task.payload["snoozed_from"] != nil {
                alarmSession.snoozeExpired(task: task)
            } else {
                alarmSession.startRinging(task: task)
            }
        }
    }

    func dismissAlarm() {
        alarmSession.dismiss()
        followUpExpiryTask?.cancel()
        followUpExpiryTask = nil
        TTSService.shared.stopSpeaking()
    }

    // MARK: - SkillForge Queue Observation

    private func setupForgeQueueObservation() {
        SkillForgeQueueService.shared.onJobCompleted = { [weak self] job, skill in
            guard let self else { return }
            let done = "I learned how to \(skill.name.lowercased())! Try asking me again."
            self.chatMessages.append(ChatMessage(role: .assistant, text: done))
            TTSService.shared.speak(done)
            self.skillForgeState = .idle
        }

        SkillForgeQueueService.shared.onJobFailed = { [weak self] job, reason in
            guard let self else { return }
            let fail = "I couldn't figure that one out: \(reason)"
            self.chatMessages.append(ChatMessage(role: .assistant, text: fail))
            TTSService.shared.speak(fail)
            self.skillForgeState = .idle
        }
    }

    // MARK: - Follow-Up Capture

    private func triggerFollowUpCapture() {
        awaitingUserReply = false
        guard isListeningEnabled else { return }

        followUpExpiryTask?.cancel()
        followUpExpiryTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard !Task.isCancelled else { return }

            self.voicePipeline.startFollowUpCapture()

            try? await Task.sleep(nanoseconds: 8_000_000_000) // 8s
            guard !Task.isCancelled else { return }
            self.voicePipeline.cancelFollowUpCapture()
        }
    }
}
