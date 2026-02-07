import Foundation

// MARK: - Alarm Session State

enum AlarmSessionState: Equatable {
    case idle
    case ringing(taskId: UUID, fireTime: Date, snoozedOnce: Bool, attempt: Int)
    case snoozed(taskId: UUID, nextFireTime: Date, snoozedOnce: Bool, attempt: Int)
}

enum AlarmReplyIntent: Equatable {
    case ackAwake
    case snooze(minutes: Int)
    case other
}

// MARK: - Alarm Context

struct AlarmContext: Sendable {
    let userName: String
    let timeOfDay: String       // "morning" | "afternoon" | "evening"
    let localTime: String       // "7:32 AM"
    let repeatCount: Int
    let snoozedOnce: Bool
    let canSnooze: Bool
    let lastSpokenVariants: [String]
}

// MARK: - Alarm Plan Router Protocol

@MainActor
protocol AlarmPlanRouter {
    func routeAlarmPlan(_ input: String, history: [ChatMessage], alarmContext: AlarmContext) async throws -> Plan
}

@MainActor
final class DefaultAlarmPlanRouter: AlarmPlanRouter {
    private let router = OllamaRouter()

    func routeAlarmPlan(_ input: String, history: [ChatMessage], alarmContext: AlarmContext) async throws -> Plan {
        try await router.routePlan(input, history: history, alarmContext: alarmContext)
    }
}

// MARK: - Alarm Session

@MainActor
final class AlarmSession: ObservableObject {

    @Published private(set) var state: AlarmSessionState = .idle

    private var lastSpokenVariants: [String] = []
    private var alarmHistory: [ChatMessage] = []
    private var loopTask: Task<Void, Never>?
    private let planRouter: any AlarmPlanRouter

    // Callbacks — wired by AppState
    var onSpeak: ((String) -> Void)?
    var onAddChatMessage: ((String) -> Void)?
    var onDismiss: ((UUID) -> Void)?
    var onRequestFollowUp: (() -> Void)?

    // MARK: - Init

    init(planRouter: (any AlarmPlanRouter)? = nil) {
        self.planRouter = planRouter ?? DefaultAlarmPlanRouter()
    }

    // MARK: - Computed

    var isRinging: Bool {
        if case .ringing = state { return true }
        return false
    }

    var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    var activeTaskId: UUID? {
        switch state {
        case .idle: return nil
        case .ringing(let taskId, _, _, _): return taskId
        case .snoozed(let taskId, _, _, _): return taskId
        }
    }

    var canSnooze: Bool {
        if case .ringing(_, _, let snoozedOnce, _) = state {
            return !snoozedOnce
        }
        return false
    }

    // MARK: - Time-of-Day Greeting

    nonisolated static func timeOfDayGreeting(userName: String? = nil) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = (userName?.isEmpty ?? true) ? "there" : userName!
        let period: String
        if hour >= 5 && hour < 12 {
            period = "morning"
        } else if hour >= 12 && hour < 17 {
            period = "afternoon"
        } else {
            period = "evening"
        }
        return "Good \(period) \(name) — time to get up."
    }

    // MARK: - Build Context

    private func buildContext() -> AlarmContext {
        let hour = Calendar.current.component(.hour, from: Date())
        let timeOfDay: String
        if hour >= 5 && hour < 12 {
            timeOfDay = "morning"
        } else if hour >= 12 && hour < 17 {
            timeOfDay = "afternoon"
        } else {
            timeOfDay = "evening"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let localTime = formatter.string(from: Date())

        let repeatCount: Int
        let snoozedOnce: Bool
        switch state {
        case .ringing(_, _, let snoozed, let attempt):
            repeatCount = attempt
            snoozedOnce = snoozed
        case .snoozed(_, _, let snoozed, let attempt):
            repeatCount = attempt
            snoozedOnce = snoozed
        case .idle:
            repeatCount = 0
            snoozedOnce = false
        }

        return AlarmContext(
            userName: M2Settings.userName,
            timeOfDay: timeOfDay,
            localTime: localTime,
            repeatCount: repeatCount,
            snoozedOnce: snoozedOnce,
            canSnooze: canSnooze,
            lastSpokenVariants: lastSpokenVariants
        )
    }

    // MARK: - Start / Stop

    func startRinging(task: ScheduledTask) {
        loopTask?.cancel()
        state = .ringing(taskId: task.id, fireTime: task.runAt, snoozedOnce: false, attempt: 1)
        lastSpokenVariants = []
        alarmHistory = []

        Task {
            let context = buildContext()
            let greeting = await generateLine(
                input: "[alarm triggered]",
                context: context,
                fallback: Self.timeOfDayGreeting(userName: M2Settings.userName)
            )
            lastSpokenVariants = [greeting]
            appendToHistory(role: .assistant, text: greeting)
            onAddChatMessage?(greeting)
            onSpeak?(greeting)
            startLoop()
        }
    }

    func snoozeExpired(task: ScheduledTask) {
        loopTask?.cancel()
        state = .ringing(taskId: task.id, fireTime: task.runAt, snoozedOnce: true, attempt: 1)
        lastSpokenVariants = []
        alarmHistory = []

        Task {
            let context = buildContext()
            let msg = await generateLine(
                input: "[snooze expired]",
                context: context,
                fallback: "Snooze is over — time to get up."
            )
            lastSpokenVariants = [msg]
            appendToHistory(role: .assistant, text: msg)
            onAddChatMessage?(msg)
            onSpeak?(msg)
            startLoop()
        }
    }

    func dismiss() {
        guard case .ringing(let taskId, _, _, _) = state else {
            // idle or snoozed — noop
            if case .snoozed(let taskId, _, _, _) = state {
                loopTask?.cancel()
                loopTask = nil
                onDismiss?(taskId)
                state = .idle
            }
            return
        }
        loopTask?.cancel()
        loopTask = nil
        onDismiss?(taskId)
        state = .idle
    }

    // MARK: - Generate Line (LLM with fallback)

    private func generateLine(input: String, context: AlarmContext, fallback: String) async -> String {
        #if DEBUG
        let reason: LLMCallReason = input.contains("repeat") ? .alarmRepeat
            : input.contains("snooze") ? .snoozeExpired : .alarmTriggered
        print("[LLM_CALL] reason=\(reason.rawValue) input=\"\(input.prefix(60))\"")
        #endif
        do {
            let plan = try await planRouter.routeAlarmPlan(input, history: alarmHistory, alarmContext: context)
            if let text = Self.extractTalkText(from: plan), !text.isEmpty {
                return text
            }
            return fallback
        } catch {
            return fallback
        }
    }

    // MARK: - Loop

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRinging else { return }

                // Request follow-up capture so user can respond without wake word
                self.onRequestFollowUp?()

                // Wait 30 seconds
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                guard self.isRinging else { return }

                // Generate a new wake line via LLM
                let context = self.buildContext()
                let line = await self.generateLine(
                    input: "[alarm repeat]",
                    context: context,
                    fallback: self.nextFallbackLine()
                )
                self.lastSpokenVariants.append(line)
                if self.lastSpokenVariants.count > 3 {
                    self.lastSpokenVariants.removeFirst()
                }
                self.appendToHistory(role: .assistant, text: line)

                // Bump attempt
                if case .ringing(let taskId, let fire, let snoozed, let attempt) = self.state {
                    self.state = .ringing(taskId: taskId, fireTime: fire, snoozedOnce: snoozed, attempt: attempt + 1)
                }

                self.onAddChatMessage?(line)
                self.onSpeak?(line)
            }
        }
    }

    // MARK: - Handle User Reply

    func handleUserReply(_ text: String) async {
        TTSService.shared.stopSpeaking()

        // Track user reply in alarm history
        appendToHistory(role: .user, text: text)

        let context = buildContext()

        #if DEBUG
        print("[LLM_CALL] reason=alarmReply input=\"\(text.prefix(60))\"")
        #endif
        let plan: Plan
        do {
            plan = try await planRouter.routeAlarmPlan(text, history: alarmHistory, alarmContext: context)
        } catch {
            let msg = "Hmm, try again."
            appendToHistory(role: .assistant, text: msg)
            onAddChatMessage?(msg)
            onSpeak?(msg)
            return
        }

        guard let taskId = activeTaskId else { return }

        // 1. Sanitize: enforce invariants by rewriting plan steps
        let sanitized = Self.sanitizePlan(plan, taskId: taskId, canSnooze: canSnooze)

        // 2. Interpret plan WITHOUT executing tools — alarm never runs tools
        let interpretation = Self.interpretPlan(sanitized)

        // 3. Speak talk lines + track in alarm history
        for line in interpretation.talkLines {
            appendToHistory(role: .assistant, text: line)
            onAddChatMessage?(line)
            onSpeak?(line)
        }

        // 4. Determine outcome from plan STRUCTURE (not executed tools)
        if interpretation.hasCancelTask {
            dismiss()
        } else if interpretation.hasScheduleTask {
            // Snooze via internal state — TaskScheduler.shared.schedule() creates the snooze task
            loopTask?.cancel()
            loopTask = nil
            guard case .ringing(let tid, _, _, let attempt) = state else { return }
            let snoozeSeconds = max(60, min(interpretation.snoozeSeconds, 900))
            let nextFire = Date().addingTimeInterval(Double(snoozeSeconds))

            TaskScheduler.shared.schedule(
                runAt: nextFire,
                label: "alarm_snooze",
                skillId: "alarm_v1",
                payload: ["snoozed_from": taskId.uuidString]
            )

            state = .snoozed(taskId: tid, nextFireTime: nextFire, snoozedOnce: true, attempt: attempt)
        }
        // else: other — already spoke, continue ringing
    }

    // MARK: - Plan Sanitization

    nonisolated static func sanitizePlan(_ plan: Plan, taskId: UUID, canSnooze: Bool) -> Plan {
        var sanitizedSteps: [PlanStep] = []
        var droppedSnooze = false

        for step in plan.steps {
            switch step {
            case .tool(let name, var args, let say) where name == "cancel_task":
                // Force the alarm's task ID
                args["id"] = .string(taskId.uuidString)
                sanitizedSteps.append(.tool(name: name, args: args, say: say))

            case .tool(let name, var args, let say) where name == "schedule_task":
                if !canSnooze {
                    // Drop schedule_task entirely — snooze already used
                    droppedSnooze = true
                    continue
                }
                // Clamp in_seconds to 60–900 (1–15 min)
                let rawSeconds = Int(args["in_seconds"]?.stringValue ?? "300") ?? 300
                let clampedSeconds = max(60, min(rawSeconds, 900))
                args["in_seconds"] = .string(String(clampedSeconds))
                args["label"] = .string("alarm_snooze")
                args["skill_id"] = .string("alarm_v1")
                sanitizedSteps.append(.tool(name: name, args: args, say: say))

            default:
                sanitizedSteps.append(step)
            }
        }

        if droppedSnooze {
            sanitizedSteps.append(.talk(say: "No more snoozes — you've got this."))
        }

        return Plan(steps: sanitizedSteps)
    }

    // MARK: - Plan Interpretation (no tool execution)

    struct AlarmPlanInterpretation {
        var talkLines: [String] = []
        var hasCancelTask = false
        var hasScheduleTask = false
        var snoozeSeconds: Int = 300
    }

    /// Reads plan structure to determine intent without executing any tools.
    nonisolated static func interpretPlan(_ plan: Plan) -> AlarmPlanInterpretation {
        var result = AlarmPlanInterpretation()
        for step in plan.steps {
            switch step {
            case .talk(let say):
                result.talkLines.append(say)
            case .tool(let name, let args, let say):
                if name == "cancel_task" {
                    result.hasCancelTask = true
                } else if name == "schedule_task" {
                    result.hasScheduleTask = true
                    if let secsStr = args["in_seconds"]?.stringValue, let secs = Int(secsStr) {
                        result.snoozeSeconds = secs
                    }
                }
                if let say = say {
                    result.talkLines.append(say)
                }
            case .ask(_, let prompt):
                result.talkLines.append(prompt)
            case .delegate(_, _, let say):
                if let say = say {
                    result.talkLines.append(say)
                }
            }
        }
        return result
    }

    // MARK: - Extract Talk Text

    nonisolated static func extractTalkText(from plan: Plan) -> String? {
        let talkTexts = plan.steps.compactMap { step -> String? in
            if case .talk(let say) = step { return say }
            return nil
        }
        guard !talkTexts.isEmpty else { return nil }
        return talkTexts.joined(separator: " ")
    }

    // MARK: - Parsing Helpers (static for testability / backward compat)

    nonisolated static func parseClassifierResponse(_ text: String) -> AlarmReplyIntent {
        guard let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intent = dict["intent"] as? String
        else {
            return .other
        }

        switch intent.uppercased() {
        case "ACK_AWAKE":
            return .ackAwake
        case "SNOOZE":
            let minutes = dict["minutes"] as? Int ?? 5
            return .snooze(minutes: parseSnoozeMinutes(requested: minutes))
        default:
            return .other
        }
    }

    nonisolated static func parseSnoozeMinutes(requested: Int) -> Int {
        max(1, min(requested, 15))
    }

    // MARK: - Alarm History

    private func appendToHistory(role: MessageRole, text: String) {
        alarmHistory.append(ChatMessage(role: role, text: text))
        // Keep only the last 12 messages to bound context size
        if alarmHistory.count > 12 {
            alarmHistory.removeFirst(alarmHistory.count - 12)
        }
    }

    // MARK: - Fallback Lines

    private static let fallbackLines = [
        "Rise and shine! The day is waiting for you.",
        "Wakey wakey! Time to seize the day.",
        "Come on, you can do it — time to get up!",
        "The world needs you awake. Let's go!",
        "Still here! Your alarm isn't giving up on you."
    ]

    private var fallbackIndex = 0

    private func nextFallbackLine() -> String {
        let line = Self.fallbackLines[fallbackIndex % Self.fallbackLines.count]
        fallbackIndex += 1
        return line
    }
}
