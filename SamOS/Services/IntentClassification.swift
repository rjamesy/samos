import Foundation

@MainActor
protocol TurnOrchestrating: AnyObject {
    var pendingSlot: PendingSlot? { get set }
    func processTurn(_ text: String, history: [ChatMessage], inputMode: TurnInputMode) async -> TurnResult
}

enum TurnInputMode {
    case voice
    case text
    case unspecified
}

enum VisionQueryIntent: Equatable {
    case none
    case describe
    case visualQA(question: String)
    case findObject(query: String)
}

enum RoutedIntent: String, CaseIterable, Codable {
    case greeting
    case recipe
    case webRequest = "web_request"
    case visionDescribe = "vision_describe"
    case visionQA = "vision_qa"
    case visionFindObject = "vision_find_object"
    case automationRequest = "automation_request"
    case generalQnA = "general_qna"
    case identityResponse = "identity_response"
    case settingsCommand = "settings_command"
    case unknown
}

struct IntentClassifierInput: Equatable, Sendable {
    let userText: String
    let cameraRunning: Bool
    let faceKnown: Bool
    let pendingSlot: String?
    let lastAssistantLine: String?
}

struct IntentClassification: Codable, Equatable, Sendable {
    let intent: RoutedIntent
    let confidence: Double
    let notes: String
    let autoCaptureHint: Bool
    let needsWeb: Bool

    enum CodingKeys: String, CodingKey { case intent, confidence, notes, autoCaptureHint, needsWeb }
}

enum IntentClassificationProvider: String {
    case rule
    case ollama
    case openai
}

struct IntentClassificationResult: Equatable, Sendable {
    let classification: IntentClassification
    let provider: IntentClassificationProvider
    let attemptedLocal: Bool
    let attemptedOpenAI: Bool
    let localSkipReason: String?
    let intentRouterMsLocal: Int?
    let intentRouterMsOpenAI: Int?
    let localConfidence: Double?
    let openAIConfidence: Double?
    let confidenceThreshold: Double
    let localTimeoutSeconds: Double?
    let escalationReason: String?
}

struct IntentLLMCallOutput: Sendable {
    let rawText: String
    let model: String?
    let endpoint: String?
    let prompt: String
}

actor IntentInferenceExecutor {
    func run<T: Sendable>(priority: TaskPriority = .userInitiated,
                          _ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        try await Task.detached(priority: priority) {
            try await operation()
        }.value
    }
}

struct IntentClassifier {
    private let localClassifier: (@Sendable (IntentClassifierInput) async throws -> IntentLLMCallOutput)?
    private let openAIClassifier: (@Sendable (IntentClassifierInput) async throws -> IntentLLMCallOutput)?
    private let localInferenceExecutor: IntentInferenceExecutor?
    private let confidenceThreshold: Double
    private let localTimeoutSeconds: Double?
    private let openAITimeoutSeconds: Double?

    init(localClassifier: (@Sendable (IntentClassifierInput) async throws -> IntentLLMCallOutput)?,
         openAIClassifier: (@Sendable (IntentClassifierInput) async throws -> IntentLLMCallOutput)?,
         localInferenceExecutor: IntentInferenceExecutor? = nil,
         confidenceThreshold: Double = 0.70,
         localTimeoutSeconds: Double? = nil,
         openAITimeoutSeconds: Double? = nil) {
        self.localClassifier = localClassifier
        self.openAIClassifier = openAIClassifier
        self.localInferenceExecutor = localInferenceExecutor
        self.confidenceThreshold = confidenceThreshold
        self.localTimeoutSeconds = localTimeoutSeconds
        self.openAITimeoutSeconds = openAITimeoutSeconds
    }

    func classify(_ input: IntentClassifierInput,
                  useLocalFirst: Bool,
                  allowOpenAIFallback: Bool) async -> IntentClassificationResult {
        enum AttemptFailureKind: String {
            case timeout
            case transport
            case parseFail = "parse_fail"
        }

        struct AttemptOutcome {
            let call: IntentLLMCallOutput?
            let classification: IntentClassification?
            let parseError: String?
            let elapsedMs: Int?
            let failureKind: AttemptFailureKind?
            let failureDetail: String?
        }

        func outcomeReason(_ outcome: AttemptOutcome?) -> String? {
            guard let outcome else { return nil }
            if let kind = outcome.failureKind {
                return kind.rawValue
            }
            if let confidence = outcome.classification?.confidence, confidence < confidenceThreshold {
                return "low_conf"
            }
            return nil
        }

        func confidenceString(_ value: Double?) -> String {
            guard let value else { return "nil" }
            return String(format: "%.2f", value)
        }

        func msString(_ value: Int?) -> String {
            guard let value else { return "nil" }
            return "\(value)"
        }

        func timeoutString(_ value: Double?) -> String {
            guard let value else { return "nil" }
            return String(format: "%.2f", value)
        }

        func parsedJSONString(_ classification: IntentClassification) -> String {
            """
            {"intent":"\(classification.intent.rawValue)","confidence":\(String(format: "%.2f", classification.confidence)),"autoCaptureHint":\(classification.autoCaptureHint),"needsWeb":\(classification.needsWeb),"notes":"\(classification.notes)"}
            """
        }

        func debugDumpAttempt(_ label: String, outcome: AttemptOutcome?) {
            #if DEBUG
            guard let outcome else { return }
            if let call = outcome.call {
                print("[INTENT_\(label)_REQUEST] model=\(call.model ?? "unknown") endpoint=\(call.endpoint ?? "unknown")")
                print("[INTENT_\(label)_PROMPT_BEGIN]\n\(call.prompt)\n[INTENT_\(label)_PROMPT_END]")
                print("[INTENT_\(label)_RAW] \(call.rawText)")
            }
            if let classification = outcome.classification {
                print("[INTENT_\(label)_PARSED] \(parsedJSONString(classification))")
            } else {
                print("[INTENT_\(label)_PARSE_FAIL] detail=\(outcome.parseError ?? outcome.failureDetail ?? "unknown")")
            }
            #endif
        }

        func runAttempt(_ label: String,
                        classifier: @escaping @Sendable (IntentClassifierInput) async throws -> IntentLLMCallOutput,
                        timeout: Double?,
                        runOnLocalExecutor: Bool = false) async -> AttemptOutcome {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let attemptOperation: @Sendable () async throws -> AttemptOutcome = {
                let call: IntentLLMCallOutput
                if let timeout {
                    call = try await withTimeout(timeout) { try await classifier(input) }
                } else {
                    call = try await classifier(input)
                }
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                switch Self.decodeStrictJSON(call.rawText) {
                case .success(let payload):
                    return AttemptOutcome(
                        call: call,
                        classification: payload,
                        parseError: nil,
                        elapsedMs: elapsedMs,
                        failureKind: nil,
                        failureDetail: nil
                    )
                case .failure(let parseError):
                    return AttemptOutcome(
                        call: call,
                        classification: nil,
                        parseError: parseError,
                        elapsedMs: elapsedMs,
                        failureKind: .parseFail,
                        failureDetail: parseError
                    )
                }
            }

            func executeAttemptOperation() async throws -> AttemptOutcome {
                if runOnLocalExecutor, let localInferenceExecutor {
                    return try await localInferenceExecutor.run(priority: .userInitiated, attemptOperation)
                } else {
                    return try await attemptOperation()
                }
            }

            let result = await Task(priority: .userInitiated) {
                do {
                    return Result<AttemptOutcome, Error>.success(try await executeAttemptOperation())
                } catch {
                    return Result<AttemptOutcome, Error>.failure(error)
                }
            }.value

            switch result {
            case .success(let outcome):
                return outcome
            case .failure(let error):
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                if error is RouterTimeout {
                    return AttemptOutcome(
                        call: nil,
                        classification: nil,
                        parseError: nil,
                        elapsedMs: elapsedMs,
                        failureKind: .timeout,
                        failureDetail: "local timeout exceeded"
                    )
                }
                return AttemptOutcome(
                    call: nil,
                    classification: nil,
                    parseError: nil,
                    elapsedMs: elapsedMs,
                    failureKind: .transport,
                    failureDetail: error.localizedDescription
                )
            }
        }

        func buildResult(_ classification: IntentClassification,
                         provider: IntentClassificationProvider,
                         attemptedLocal: Bool,
                         attemptedOpenAI: Bool,
                         localSkipReason: String?,
                         localOutcome: AttemptOutcome?,
                         openAIOutcome: AttemptOutcome?,
                         escalationReason: String?) -> IntentClassificationResult {
            let result = IntentClassificationResult(
                classification: classification,
                provider: provider,
                attemptedLocal: attemptedLocal,
                attemptedOpenAI: attemptedOpenAI,
                localSkipReason: localSkipReason,
                intentRouterMsLocal: localOutcome?.elapsedMs,
                intentRouterMsOpenAI: openAIOutcome?.elapsedMs,
                localConfidence: localOutcome?.classification?.confidence,
                openAIConfidence: openAIOutcome?.classification?.confidence,
                confidenceThreshold: confidenceThreshold,
                localTimeoutSeconds: localTimeoutSeconds,
                escalationReason: escalationReason
            )

            #if DEBUG
            print("[INTENT_DECISION] intent_provider_selected=\(result.provider.rawValue) local_attempted=\(result.attemptedLocal) openai_attempted=\(result.attemptedOpenAI) local_confidence=\(confidenceString(result.localConfidence)) openai_confidence=\(confidenceString(result.openAIConfidence)) threshold=\(String(format: "%.2f", result.confidenceThreshold)) local_timeout_s=\(timeoutString(result.localTimeoutSeconds)) reason_for_escalation=\(result.escalationReason ?? "none") local_skip_reason=\(result.localSkipReason ?? "none") intent_router_ms_local=\(msString(result.intentRouterMsLocal)) intent_router_ms_openai=\(msString(result.intentRouterMsOpenAI))")
            #endif

            return result
        }

        var attemptedLocal = false
        var attemptedOpenAI = false
        var localSkipReason: String?
        var localOutcome: AttemptOutcome?
        var openAIOutcome: AttemptOutcome?
        var escalationReason: String?

        if useLocalFirst {
            if let localClassifier {
                attemptedLocal = true
                localOutcome = await runAttempt(
                    "LOCAL",
                    classifier: localClassifier,
                    timeout: localTimeoutSeconds,
                    runOnLocalExecutor: true
                )
                debugDumpAttempt("LOCAL", outcome: localOutcome)
                if let local = localOutcome?.classification,
                   local.confidence >= confidenceThreshold {
                    return buildResult(
                        local,
                        provider: .ollama,
                        attemptedLocal: attemptedLocal,
                        attemptedOpenAI: false,
                        localSkipReason: nil,
                        localOutcome: localOutcome,
                        openAIOutcome: nil,
                        escalationReason: nil
                    )
                }
                escalationReason = outcomeReason(localOutcome)
            } else {
                localSkipReason = "classifier_nil"
                escalationReason = "classifier_nil"
            }
        } else {
            localSkipReason = "policy_disabled"
            escalationReason = "policy_disabled"
        }

        if allowOpenAIFallback, let openAIClassifier {
            attemptedOpenAI = true
            openAIOutcome = await runAttempt("OPENAI", classifier: openAIClassifier, timeout: openAITimeoutSeconds)
            debugDumpAttempt("OPENAI", outcome: openAIOutcome)
            if let openAI = openAIOutcome?.classification,
               openAI.confidence >= confidenceThreshold {
                return buildResult(
                    openAI,
                    provider: .openai,
                    attemptedLocal: attemptedLocal,
                    attemptedOpenAI: attemptedOpenAI,
                    localSkipReason: localSkipReason,
                    localOutcome: localOutcome,
                    openAIOutcome: openAIOutcome,
                    escalationReason: escalationReason
                )
            }
            escalationReason = outcomeReason(openAIOutcome) ?? escalationReason
        }

        let ruleFallback = deterministicClassification(for: input)
        if ruleFallback.intent != .unknown {
            return buildResult(
                ruleFallback,
                provider: .rule,
                attemptedLocal: attemptedLocal,
                attemptedOpenAI: attemptedOpenAI,
                localSkipReason: localSkipReason,
                localOutcome: localOutcome,
                openAIOutcome: openAIOutcome,
                escalationReason: escalationReason
            )
        }

        return buildResult(
            IntentClassification(
                intent: .unknown,
                confidence: 0.20,
                notes: "",
                autoCaptureHint: false,
                needsWeb: false,
            ),
            provider: .rule,
            attemptedLocal: attemptedLocal,
            attemptedOpenAI: attemptedOpenAI,
            localSkipReason: localSkipReason,
            localOutcome: localOutcome,
            openAIOutcome: openAIOutcome,
            escalationReason: escalationReason
        )
    }

    private enum IntentDecodeOutcome {
        case success(IntentClassification)
        case failure(String)
    }

    private func deterministicClassification(for input: IntentClassifierInput) -> IntentClassification {
        let trimmed = input.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.isEmpty {
            return IntentClassification(
                intent: .unknown,
                confidence: 0.20,
                notes: "",
                autoCaptureHint: false,
                needsWeb: false
            )
        }

        // Rules are emergency brakes only: conservative and low confidence.
        if lower.hasPrefix("turn on ")
            || lower.hasPrefix("turn off ")
            || lower.hasPrefix("enable ")
            || lower.hasPrefix("disable ")
            || lower == "settings" {
            return IntentClassification(
                intent: .settingsCommand,
                confidence: 0.68,
                notes: "",
                autoCaptureHint: false,
                needsWeb: false
            )
        }

        if lower.range(of: #"^[\p{P}\p{S}\s]{1,12}$"#, options: .regularExpression) != nil {
            return IntentClassification(
                intent: .unknown,
                confidence: 0.25,
                notes: "",
                autoCaptureHint: false,
                needsWeb: false
            )
        }

        return IntentClassification(
            intent: .unknown,
            confidence: 0.30,
            notes: "",
            autoCaptureHint: false,
            needsWeb: false
        )
    }

    private static func decodeStrictJSON(_ text: String) -> IntentDecodeOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("empty_response") }
        guard trimmed.first == "{", trimmed.last == "}",
              let data = trimmed.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = jsonObject as? [String: Any] else {
            return .failure("not_single_json_object")
        }
        let allowedKeys: Set<String> = ["intent", "confidence", "autoCaptureHint", "needsWeb", "notes"]
        let actualKeys = Set(dictionary.keys)
        let extra = actualKeys.subtracting(allowedKeys).sorted().joined(separator: ",")
        guard extra.isEmpty else {
            return .failure("key_mismatch missing=[] extra=[\(extra)]")
        }

        guard let intentRaw = dictionary["intent"] as? String,
              let intent = RoutedIntent(rawValue: intentRaw) else {
            return .failure("decode_failed_missing_or_invalid_intent")
        }
        guard let confidenceValue = dictionary["confidence"] as? NSNumber else {
            return .failure("decode_failed_missing_or_invalid_confidence")
        }

        let notes = (dictionary["notes"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let autoCaptureHint = dictionary["autoCaptureHint"] as? Bool ?? false
        let clamped = min(1.0, max(0.0, confidenceValue.doubleValue))

        let payload = IntentClassification(
            intent: intent,
            confidence: clamped,
            notes: notes,
            autoCaptureHint: autoCaptureHint,
            needsWeb: intent == .webRequest
        )
        return .success(payload)
    }

}

struct PlanRoutePolicy {
    let useOllama: Bool
    let preferOpenAIPlans: Bool
    let openAIStatus: OpenAISettings.APIKeyStatus

    var localFirst: Bool { routeOrder.first == .ollama }
    var openAIFallback: Bool { routeOrder.contains(.openai) }

    var routeOrder: [LLMProvider] {
        switch openAIStatus {
        case .ready:
            guard useOllama else { return [.openai] }
            if preferOpenAIPlans {
                return [.openai]
            }
            return [.ollama, .openai]
        case .invalid:
            return useOllama ? [.ollama] : [.none]
        case .missing:
            return useOllama ? [.ollama] : [.none]
        }
    }
}

extension TurnOrchestrating {
    func processTurn(_ text: String, history: [ChatMessage]) async -> TurnResult {
        await processTurn(text, history: history, inputMode: .unspecified)
    }
}

// MARK: - Timeout Helper

enum RouterTimeout: Error { case exceeded }

func withTimeout<T: Sendable>(_ seconds: Double, _ op: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RouterTimeout.exceeded
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// The ONLY brain for processing user input.
/// Calls LLM, validates structure, executes plan steps.
/// Uses a deterministic intent classifier with optional LLM fallback, then executes plan steps.
