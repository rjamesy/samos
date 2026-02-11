import Foundation

protocol FaceGreetingSettingsProviding {
    var faceRecognitionEnabled: Bool { get }
    var personalizedGreetingsEnabled: Bool { get }
}

struct M2FaceGreetingSettings: FaceGreetingSettingsProviding {
    var faceRecognitionEnabled: Bool { M2Settings.faceRecognitionEnabled }
    var personalizedGreetingsEnabled: Bool { M2Settings.personalizedGreetingsEnabled }
}

struct FaceIdentityContext: Equatable {
    let recognizedUserName: String?
    let faceConfidence: Float?
    let unrecognizedUserPresent: Bool
    let awaitingIdentityConfirmation: Bool

    static let none = FaceIdentityContext(
        recognizedUserName: nil,
        faceConfidence: nil,
        unrecognizedUserPresent: false,
        awaitingIdentityConfirmation: false
    )

    var identityPromptContextLine: String? {
        if let recognizedUserName,
           !recognizedUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Recognized user: \(recognizedUserName) (confidence high)"
        }
        if awaitingIdentityConfirmation {
            return "Unrecognized user present. If useful, ask for their name once and avoid repeating."
        }
        if unrecognizedUserPresent {
            return "Unrecognized user present. Answer first, then optionally ask for name once."
        }
        return nil
    }
}

enum FaceIdentityConfirmationResolution: Equatable {
    case enrolled(name: String, message: String)
    case declined(message: String)
    case requestName(message: String)
}

enum IdentityState: Equatable {
    case none
    case unknownDetected(lastPromptAt: Date?)
    case awaitingName(lastPromptAt: Date)
    case enrolledPendingRecognition(name: String, enrolledAt: Date)
    case known(name: String, lastSeenAt: Date)
}

extension IdentityState {
    func debugSummary(reference now: Date = Date()) -> String {
        switch self {
        case .none:
            return "none"
        case .unknownDetected(let lastPromptAt):
            if let lastPromptAt {
                let age = Int(now.timeIntervalSince(lastPromptAt))
                return "unknownDetected(lastPromptAgo=\(age)s)"
            }
            return "unknownDetected(lastPromptAgo=nil)"
        case .awaitingName(let lastPromptAt):
            let age = Int(now.timeIntervalSince(lastPromptAt))
            return "awaitingName(lastPromptAgo=\(age)s)"
        case .enrolledPendingRecognition(let name, let enrolledAt):
            let age = Int(now.timeIntervalSince(enrolledAt))
            return "enrolledPendingRecognition(name=\(name), enrolledAgo=\(age)s)"
        case .known(let name, let lastSeenAt):
            let age = Int(now.timeIntervalSince(lastSeenAt))
            return "known(name=\(name), lastSeenAgo=\(age)s)"
        }
    }
}

enum IdentityTurnAction: Equatable {
    case routeNormally
    case enroll(name: String, confirmation: String, reason: String)
}

struct IdentityTurnDecision: Equatable {
    let stateBefore: IdentityState
    let stateAfter: IdentityState
    let recognitionSummary: String
    let shouldPromptIdentity: Bool
    let promptReason: String
    let promptToAppend: String?
    let context: FaceIdentityContext
    let action: IdentityTurnAction
}

@MainActor
final class FaceGreetingManager {
    private enum PrimaryRecognition {
        case none
        case recognized(name: String, confidence: Float)
        case unknown
    }

    private let camera: CameraVisionProviding
    private let settings: FaceGreetingSettingsProviding
    private let recognitionThreshold: Float
    private let namedGreetingCooldownTurns: Int
    private let identityPromptCooldownSeconds: TimeInterval
    private let awaitingNameTimeoutSeconds: TimeInterval
    private let postEnrollGracePeriodSeconds: TimeInterval
    private let recognitionCacheSeconds: TimeInterval

    private(set) var currentIdentityContext: FaceIdentityContext = .none
    private(set) var identityState: IdentityState = .none

    var awaitingIdentityConfirmation: Bool {
        if case .awaitingName = identityState { return true }
        return false
    }

    private var lastNamedGreetingTurn: Int?
    private var cachedRecognition: (at: Date, result: CameraFaceRecognitionResult)?
    private var postEnrollRepairPromptIssued = false
    private var lastRecognitionSummary = "faces=0, primary=none"

    init(camera: CameraVisionProviding = CameraVisionService.shared,
         settings: FaceGreetingSettingsProviding = M2FaceGreetingSettings(),
         recognitionThreshold: Float = 0.72,
         namedGreetingCooldownTurns: Int = 2,
         onboardingPromptCooldownTurns: Int = 2,
         identityPromptCooldownSeconds: TimeInterval = 120,
         awaitingNameTimeoutSeconds: TimeInterval = 30,
         postEnrollGracePeriodSeconds: TimeInterval = 300,
         recognitionCacheSeconds: TimeInterval = 1.5) {
        _ = onboardingPromptCooldownTurns
        self.camera = camera
        self.settings = settings
        self.recognitionThreshold = max(0.0, min(1.0, recognitionThreshold))
        self.namedGreetingCooldownTurns = max(0, namedGreetingCooldownTurns)
        self.identityPromptCooldownSeconds = max(0, identityPromptCooldownSeconds)
        self.awaitingNameTimeoutSeconds = max(1, awaitingNameTimeoutSeconds)
        self.postEnrollGracePeriodSeconds = max(1, postEnrollGracePeriodSeconds)
        self.recognitionCacheSeconds = max(0, recognitionCacheSeconds)
    }

    @discardableResult
    func evaluateFrame(now: Date = Date()) -> FaceIdentityContext {
        _ = refreshIdentityFromCamera(now: now)
        return currentIdentityContext
    }

    func prepareTurn(userInput: String,
                     inputMode: TurnInputMode,
                     now: Date = Date(),
                     userInitiated: Bool = true) -> IdentityTurnDecision {
        _ = inputMode
        let stateBefore = identityState
        let frame = refreshIdentityFromCamera(now: now)
        var promptToAppend: String?
        var shouldPromptIdentity = false
        var promptReason = "not_needed"

        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let identityCheckRequested = isIdentityCheckQuery(trimmed)
        if case .awaitingName(let lastPromptAt) = identityState {
            if let extractedName = parseNameReply(from: trimmed) {
                let enrollResult = camera.enrollFace(name: extractedName)
                let enrolledName = enrollResult.enrolledName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (enrollResult.enrolledName ?? extractedName)
                    : extractedName
                let confirmation = enrollmentConfirmation(for: enrollResult.status, name: enrolledName)

                switch enrollResult.status {
                case .success:
                    // Prevent stale "unknown" cache from persisting right after enrollment.
                    cachedRecognition = nil
                    identityState = .enrolledPendingRecognition(name: enrolledName, enrolledAt: now)
                    postEnrollRepairPromptIssued = false
                default:
                    identityState = .unknownDetected(lastPromptAt: now)
                }

                currentIdentityContext = buildContext(primary: frame.primary, state: identityState)
                return IdentityTurnDecision(
                    stateBefore: stateBefore,
                    stateAfter: identityState,
                    recognitionSummary: lastRecognitionSummary,
                    shouldPromptIdentity: false,
                    promptReason: "enroll_attempted",
                    promptToAppend: nil,
                    context: currentIdentityContext,
                    action: .enroll(name: enrolledName, confirmation: confirmation, reason: "awaitingName->enroll_tool")
                )
            }

            if isDecline(trimmed) {
                identityState = .unknownDetected(lastPromptAt: now)
                currentIdentityContext = buildContext(primary: frame.primary, state: identityState)
            } else if now.timeIntervalSince(lastPromptAt) > awaitingNameTimeoutSeconds {
                identityState = .unknownDetected(lastPromptAt: lastPromptAt)
                currentIdentityContext = buildContext(primary: frame.primary, state: identityState)
            } else {
                identityState = .unknownDetected(lastPromptAt: lastPromptAt)
                currentIdentityContext = buildContext(primary: frame.primary, state: identityState)
            }
        }

        switch identityState {
        case .none:
            promptReason = "identity_state_none"
        case .known:
            promptReason = "known_face"
        case .awaitingName:
            promptReason = "awaiting_name"
        case .enrolledPendingRecognition(_, let enrolledAt):
            if case .unknown = frame.primary {
                if now.timeIntervalSince(enrolledAt) <= postEnrollGracePeriodSeconds {
                    if userInitiated && identityCheckRequested && !postEnrollRepairPromptIssued {
                        promptToAppend = "I might need one more look to recognize you next time - want to try again?"
                        shouldPromptIdentity = true
                        promptReason = "post_enroll_repair_once"
                        postEnrollRepairPromptIssued = true
                    } else {
                        promptReason = "post_enroll_grace_active"
                    }
                } else {
                    identityState = .unknownDetected(lastPromptAt: lastPromptDate(in: identityState))
                    currentIdentityContext = buildContext(primary: frame.primary, state: identityState)
                    promptReason = "post_enroll_grace_expired"
                }
            } else {
                promptReason = "post_enroll_waiting"
            }
        case .unknownDetected(let lastPromptAt):
            let canPromptByCooldown: Bool
            if let lastPromptAt {
                canPromptByCooldown = now.timeIntervalSince(lastPromptAt) > identityPromptCooldownSeconds
            } else {
                canPromptByCooldown = true
            }
            if userInitiated && canPromptByCooldown {
                shouldPromptIdentity = true
                promptToAppend = "By the way, what's your name? I can remember you."
                identityState = .awaitingName(lastPromptAt: now)
                currentIdentityContext = buildContext(primary: frame.primary, state: identityState)
                promptReason = lastPromptAt == nil
                    ? "unknown_detected_first_prompt"
                    : "unknown_detected_cooldown_elapsed"
            } else {
                promptReason = userInitiated ? "identity_prompt_cooldown_active" : "not_user_initiated"
            }
        }

        return IdentityTurnDecision(
            stateBefore: stateBefore,
            stateAfter: identityState,
            recognitionSummary: lastRecognitionSummary,
            shouldPromptIdentity: shouldPromptIdentity,
            promptReason: promptReason,
            promptToAppend: promptToAppend,
            context: currentIdentityContext,
            action: .routeNormally
        )
    }

    func proactiveOnboardingPrompt(turnIndex: Int) -> String? {
        _ = turnIndex
        return nil
    }

    func greetingOverride(for mode: ConversationMode,
                          repetitionCount: Int,
                          turnIndex: Int) -> String? {
        guard mode.intent == .greeting else { return nil }
        guard case .known(let name, _) = identityState else { return nil }
        guard shouldEmitNamedGreeting(turnIndex: turnIndex) else { return nil }
        lastNamedGreetingTurn = turnIndex
        return namedGreeting(for: name, repetitionCount: repetitionCount)
    }

    func resolveIdentityConfirmationResponse(_ userInput: String,
                                             now: Date = Date()) -> FaceIdentityConfirmationResolution? {
        guard case .awaitingName = identityState else { return nil }
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isDecline(trimmed) {
            identityState = .unknownDetected(lastPromptAt: now)
            currentIdentityContext = buildContext(primary: .unknown, state: identityState)
            return .declined(message: "No worries at all.")
        }

        if let extractedName = parseNameReply(from: trimmed) {
            let enrollResult = camera.enrollFace(name: extractedName)
            let enrolledName = enrollResult.enrolledName ?? extractedName
            switch enrollResult.status {
            case .success:
                // Prevent stale "unknown" cache from persisting right after enrollment.
                cachedRecognition = nil
                identityState = .enrolledPendingRecognition(name: enrolledName, enrolledAt: now)
                currentIdentityContext = buildContext(primary: .unknown, state: identityState)
            default:
                identityState = .unknownDetected(lastPromptAt: now)
                currentIdentityContext = buildContext(primary: .unknown, state: identityState)
            }
            return .enrolled(name: enrolledName, message: enrollmentConfirmation(for: enrollResult.status, name: enrolledName))
        }

        if isAffirmative(trimmed) {
            return .requestName(message: "Awesome - what name should I use?")
        }

        return nil
    }

    @discardableResult
    func clearSavedFaces() -> Bool {
        let cleared = camera.clearKnownFaces()
        cachedRecognition = nil
        postEnrollRepairPromptIssued = false
        identityState = .none
        currentIdentityContext = .none
        return cleared
    }

    private var isIdentityLogicEnabled: Bool {
        guard camera.isRunning else { return false }
        return settings.faceRecognitionEnabled && settings.personalizedGreetingsEnabled
    }

    private func shouldEmitNamedGreeting(turnIndex: Int) -> Bool {
        guard let lastNamedGreetingTurn else { return true }
        return (turnIndex - lastNamedGreetingTurn) > namedGreetingCooldownTurns
    }

    private func namedGreeting(for name: String, repetitionCount: Int) -> String {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let templates = [
            "Hey {name}, what's up?",
            "Hi {name}, how can I help?",
            "Morning {name}, how's it going?"
        ]
        let idx = max(0, repetitionCount - 1) % templates.count
        return templates[idx].replacingOccurrences(of: "{name}", with: cleanedName)
    }

    private func refreshIdentityFromCamera(now: Date) -> (primary: PrimaryRecognition, detectedFaces: Int) {
        guard isIdentityLogicEnabled else {
            cachedRecognition = nil
            identityState = .none
            currentIdentityContext = .none
            lastRecognitionSummary = "faces=0, primary=none (identity disabled)"
            return (.none, 0)
        }

        let detectedFaces = camera.currentAnalysis()?.faces.count ?? 0
        guard detectedFaces > 0 else {
            cachedRecognition = nil
            switch identityState {
            case .known:
                break
            case .awaitingName(let lastPromptAt):
                if now.timeIntervalSince(lastPromptAt) > awaitingNameTimeoutSeconds {
                    identityState = .none
                }
            default:
                identityState = .none
            }
            currentIdentityContext = buildContext(primary: .none, state: identityState)
            lastRecognitionSummary = "faces=0, primary=none"
            return (.none, 0)
        }

        guard let recognition = recognitionResult(now: now) else {
            if !preserveKnownOrAwaitingStateForUnknown(now: now) {
                identityState = .unknownDetected(lastPromptAt: lastPromptDate(in: identityState))
            }
            currentIdentityContext = buildContext(primary: .unknown, state: identityState)
            lastRecognitionSummary = "faces=\(detectedFaces), primary=unknown(recognizer_unavailable)"
            return (.unknown, detectedFaces)
        }

        if let primary = recognition.matches.max(by: { $0.confidence < $1.confidence }),
           shouldTreatPrimaryAsKnown(primary, in: recognition) {
            let confidence = max(primary.confidence, recognitionThreshold)
            identityState = .known(name: primary.name, lastSeenAt: now)
            postEnrollRepairPromptIssued = false
            currentIdentityContext = buildContext(primary: .recognized(name: primary.name, confidence: confidence), state: identityState)
            lastRecognitionSummary = "faces=\(recognition.detectedFaces), primary=known(\(primary.name), confidence=\(String(format: "%.2f", confidence)))"
            logFaceRecognition(recognition: recognition, primary: primary, recognized: true, reason: "primary_match")
            return (.recognized(name: primary.name, confidence: confidence), recognition.detectedFaces)
        }

        if !preserveKnownOrAwaitingStateForUnknown(now: now) {
            identityState = .unknownDetected(lastPromptAt: lastPromptDate(in: identityState))
        }
        currentIdentityContext = buildContext(primary: .unknown, state: identityState)
        let primaryDescriptor = recognition.matches.isEmpty ? "unknown" : "unknown(low_confidence)"
        lastRecognitionSummary = "faces=\(recognition.detectedFaces), primary=\(primaryDescriptor), matches=\(recognition.matches.count), unknown_faces=\(recognition.unknownFaces)"
        let primary = recognition.matches.max(by: { $0.confidence < $1.confidence })
        logFaceRecognition(recognition: recognition, primary: primary, recognized: false, reason: "low_confidence_or_no_match")
        return (.unknown, recognition.detectedFaces)
    }

    private func preserveKnownOrAwaitingStateForUnknown(now: Date) -> Bool {
        switch identityState {
        case .known:
            // Keep known state for potential "different face" scenarios.
            return true
        case .awaitingName(let lastPromptAt):
            if now.timeIntervalSince(lastPromptAt) > awaitingNameTimeoutSeconds {
                identityState = .unknownDetected(lastPromptAt: lastPromptAt)
            }
            return true
        case .enrolledPendingRecognition(_, let enrolledAt):
            if now.timeIntervalSince(enrolledAt) <= postEnrollGracePeriodSeconds {
                return true
            }
            identityState = .unknownDetected(lastPromptAt: lastPromptDate(in: identityState))
            return false
        case .unknownDetected, .none:
            return false
        }
    }

    private func recognitionResult(now: Date) -> CameraFaceRecognitionResult? {
        if let cachedRecognition,
           now.timeIntervalSince(cachedRecognition.at) <= recognitionCacheSeconds {
            return cachedRecognition.result
        }
        guard let live = camera.recognizeKnownFaces() else {
            cachedRecognition = nil
            return nil
        }
        cachedRecognition = (at: now, result: live)
        return live
    }

    private func buildContext(primary: PrimaryRecognition, state: IdentityState) -> FaceIdentityContext {
        let recognizedName: String?
        let confidence: Float?
        switch primary {
        case .recognized(let name, let value):
            recognizedName = name
            confidence = value
        case .none, .unknown:
            switch state {
            case .known(let name, _):
                recognizedName = name
            default:
                recognizedName = nil
            }
            confidence = nil
        }

        let unrecognized: Bool
        switch primary {
        case .unknown:
            unrecognized = true
        case .none, .recognized:
            unrecognized = false
        }

        let awaiting = {
            if case .awaitingName = state { return true }
            return false
        }()

        return FaceIdentityContext(
            recognizedUserName: recognizedName,
            faceConfidence: confidence,
            unrecognizedUserPresent: unrecognized,
            awaitingIdentityConfirmation: awaiting
        )
    }

    private func lastPromptDate(in state: IdentityState) -> Date? {
        switch state {
        case .unknownDetected(let lastPromptAt):
            return lastPromptAt
        case .awaitingName(let lastPromptAt):
            return lastPromptAt
        case .none, .enrolledPendingRecognition, .known:
            return nil
        }
    }

    private func enrollmentConfirmation(for status: CameraFaceEnrollmentResult.Status, name: String) -> String {
        switch status {
        case .success:
            return "Nice to meet you, \(name)."
        case .cameraOff:
            return "I can't enroll right now because the camera is off."
        case .noFrame:
            return "I can't enroll yet because I don't have a fresh camera frame."
        case .noFaceDetected:
            return "I couldn't find a clear face in the frame. Want to try again?"
        case .invalidName:
            return "I need a valid name to enroll this face."
        case .unsupported:
            return "Face enrollment isn't available in the current camera provider."
        }
    }

    private func isDecline(_ text: String) -> Bool {
        let normalized = normalize(text)
        let declines: Set<String> = [
            "no", "nope", "nah", "no thanks", "not now", "never mind", "nevermind", "skip", "cancel"
        ]
        return declines.contains(normalized)
    }

    private func isAffirmative(_ text: String) -> Bool {
        let normalized = normalize(text)
        let affirmatives: Set<String> = [
            "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "please", "go ahead"
        ]
        return affirmatives.contains(normalized)
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseNameReply(from text: String) -> String? {
        guard looksLikeNameReply(text) else { return nil }
        let normalized = normalize(text)
        var candidate = normalized
            .replacingOccurrences(of: #"[.!?,]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixes = [
            "i am ", "i'm ", "im ",
            "my name is ", "name is ", "this is "
        ]
        if let prefix = prefixes.first(where: { candidate.hasPrefix($0) }) {
            candidate.removeFirst(prefix.count)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let words = candidate.split(separator: " ").map(String.init)
        guard (1...3).contains(words.count) else { return nil }
        guard words.allSatisfy({
            $0.range(of: #"^[a-z][a-z'\-]{0,31}$"#, options: .regularExpression) != nil
        }) else { return nil }

        let disallowed: Set<String> = [
            "hello", "hi", "hey",
            "thanks", "thank", "please", "sure",
            "okay", "ok", "yes", "no", "nope", "nah",
            "later", "maybe", "skip", "cancel",
            "help", "weather", "time",
            "what", "when", "where", "why", "who", "how", "are", "you", "today"
        ]
        if words.contains(where: { disallowed.contains($0) }) {
            return nil
        }

        return sanitizedDisplayName(words.joined(separator: " "))
    }

    private func shouldTreatPrimaryAsKnown(_ primary: CameraRecognizedFaceMatch,
                                           in recognition: CameraFaceRecognitionResult) -> Bool {
        if primary.confidence >= recognitionThreshold {
            return true
        }
        guard case .enrolledPendingRecognition = identityState else {
            return false
        }
        // If there is exactly one visible face and exactly one recognizer match,
        // treat it as the primary face match to avoid post-enroll mismatch loops.
        let singleFaceSingleMatch = recognition.detectedFaces == 1
            && recognition.matches.count == 1
            && recognition.unknownFaces == 0
        return singleFaceSingleMatch
    }

    private func isIdentityCheckQuery(_ text: String) -> Bool {
        let normalized = normalize(text)
        let phrases = [
            "do you recognize me",
            "did you recognize me",
            "do you know me",
            "did you save my face",
            "did you save me",
            "did you enroll my face",
            "did you learn my face",
            "did you remember my face",
            "who am i",
            "am i recognized",
            "are you recognizing me"
        ]
        return phrases.contains(where: { normalized.contains($0) })
    }

    private func logFaceRecognition(recognition: CameraFaceRecognitionResult,
                                    primary: CameraRecognizedFaceMatch?,
                                    recognized: Bool,
                                    reason: String) {
        #if DEBUG
        let primaryName = primary?.name ?? "none"
        let confidence = primary.map { String(format: "%.2f", $0.confidence) } ?? "n/a"
        let state = recognized ? "known" : "unknown"
        print(
            "[FACE] faces=\(recognition.detectedFaces) primaryFaceId=inferred_0 " +
            "matchedFaceId=\(primaryName) confidence=\(confidence) state=\(state) reason=\(reason)"
        )
        #endif
    }

    private func looksLikeNameReply(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("?") { return false }

        let lowered = normalize(trimmed)
        let compact = lowered
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let stripped = compact.replacingOccurrences(of: #"[^a-z'\-\s]"#, with: "", options: .regularExpression)
        let tokens = stripped.split(separator: " ")
        guard (1...4).contains(tokens.count) else { return false }

        let noSpaces = compact.replacingOccurrences(of: " ", with: "")
        guard !noSpaces.isEmpty else { return false }
        let letters = noSpaces.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let ratio = Double(letters.count) / Double(noSpaces.unicodeScalars.count)
        guard ratio >= 0.75 else { return false }

        if compact.contains(",") && tokens.count > 3 {
            return false
        }
        return true
    }

    private func sanitizedDisplayName(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let tokens = cleaned.split(separator: " ").map { token -> String in
            let lower = token.lowercased()
            guard let first = lower.first else { return "" }
            let rest = lower.dropFirst()
            return String(first).uppercased() + rest
        }

        return tokens.joined(separator: " ")
    }
}
