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
        if unrecognizedUserPresent || awaitingIdentityConfirmation {
            return "Unrecognized user present. Offer optional enrollment."
        }
        return nil
    }
}

enum FaceIdentityConfirmationResolution: Equatable {
    case enrolled(name: String, message: String)
    case declined(message: String)
    case requestName(message: String)
}

@MainActor
final class FaceGreetingManager {
    private let camera: CameraVisionProviding
    private let settings: FaceGreetingSettingsProviding
    private let recognitionThreshold: Float
    private let namedGreetingCooldownTurns: Int
    private let onboardingPromptCooldownTurns: Int

    private(set) var currentIdentityContext: FaceIdentityContext = .none
    private(set) var awaitingIdentityConfirmation = false

    private var lastNamedGreetingTurn: Int?
    private var lastOnboardingPromptTurn: Int?

    init(camera: CameraVisionProviding = CameraVisionService.shared,
         settings: FaceGreetingSettingsProviding = M2FaceGreetingSettings(),
         recognitionThreshold: Float = 0.72,
         namedGreetingCooldownTurns: Int = 2,
         onboardingPromptCooldownTurns: Int = 2) {
        self.camera = camera
        self.settings = settings
        self.recognitionThreshold = max(0.0, min(1.0, recognitionThreshold))
        self.namedGreetingCooldownTurns = max(0, namedGreetingCooldownTurns)
        self.onboardingPromptCooldownTurns = max(0, onboardingPromptCooldownTurns)
    }

    @discardableResult
    func evaluateFrame() -> FaceIdentityContext {
        guard isIdentityLogicEnabled else {
            awaitingIdentityConfirmation = false
            currentIdentityContext = .none
            return currentIdentityContext
        }

        // Equivalent of get_camera_face_presence in-process.
        let detectedFaces = camera.currentAnalysis()?.faces.count ?? 0
        guard detectedFaces > 0 else {
            currentIdentityContext = FaceIdentityContext(
                recognizedUserName: nil,
                faceConfidence: nil,
                unrecognizedUserPresent: false,
                awaitingIdentityConfirmation: awaitingIdentityConfirmation
            )
            return currentIdentityContext
        }

        // Equivalent of recognize_camera_faces in-process.
        guard let recognition = camera.recognizeKnownFaces() else {
            // Silent fallback on recognizer failure.
            currentIdentityContext = FaceIdentityContext(
                recognizedUserName: nil,
                faceConfidence: nil,
                unrecognizedUserPresent: false,
                awaitingIdentityConfirmation: awaitingIdentityConfirmation
            )
            return currentIdentityContext
        }

        guard recognition.detectedFaces > 0 else {
            currentIdentityContext = FaceIdentityContext(
                recognizedUserName: nil,
                faceConfidence: nil,
                unrecognizedUserPresent: false,
                awaitingIdentityConfirmation: awaitingIdentityConfirmation
            )
            return currentIdentityContext
        }

        // Primary user = highest confidence recognized face.
        if let primary = recognition.matches.max(by: { $0.confidence < $1.confidence }),
           primary.confidence >= recognitionThreshold {
            currentIdentityContext = FaceIdentityContext(
                recognizedUserName: primary.name,
                faceConfidence: primary.confidence,
                unrecognizedUserPresent: false,
                awaitingIdentityConfirmation: awaitingIdentityConfirmation
            )
            return currentIdentityContext
        }

        // Face(s) present but no sufficiently confident match.
        currentIdentityContext = FaceIdentityContext(
            recognizedUserName: nil,
            faceConfidence: nil,
            unrecognizedUserPresent: true,
            awaitingIdentityConfirmation: awaitingIdentityConfirmation
        )
        return currentIdentityContext
    }

    func greetingOverride(for mode: ConversationMode,
                          repetitionCount: Int,
                          turnIndex: Int) -> String? {
        guard mode.intent == .greeting else { return nil }

        if currentIdentityContext.unrecognizedUserPresent {
            guard shouldEmitOnboardingPrompt(turnIndex: turnIndex) else { return nil }
            awaitingIdentityConfirmation = true
            currentIdentityContext = FaceIdentityContext(
                recognizedUserName: nil,
                faceConfidence: nil,
                unrecognizedUserPresent: true,
                awaitingIdentityConfirmation: true
            )
            lastOnboardingPromptTurn = turnIndex
            return onboardingGreeting(for: repetitionCount)
        }

        guard let name = currentIdentityContext.recognizedUserName,
              shouldEmitNamedGreeting(turnIndex: turnIndex) else {
            return nil
        }

        lastNamedGreetingTurn = turnIndex
        return namedGreeting(for: name, repetitionCount: repetitionCount)
    }

    func resolveIdentityConfirmationResponse(_ userInput: String) -> FaceIdentityConfirmationResolution? {
        guard awaitingIdentityConfirmation else { return nil }

        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isDecline(trimmed) {
            awaitingIdentityConfirmation = false
            currentIdentityContext = FaceIdentityContext(
                recognizedUserName: nil,
                faceConfidence: nil,
                unrecognizedUserPresent: false,
                awaitingIdentityConfirmation: false
            )
            return .declined(message: "No worries at all.")
        }

        if let extractedName = extractName(from: trimmed) {
            awaitingIdentityConfirmation = false
            _ = camera.enrollFace(name: extractedName)
            currentIdentityContext = FaceIdentityContext(
                recognizedUserName: extractedName,
                faceConfidence: nil,
                unrecognizedUserPresent: false,
                awaitingIdentityConfirmation: false
            )
            return .enrolled(name: extractedName, message: "Nice to meet you, \(extractedName).")
        }

        if isAffirmative(trimmed) {
            return .requestName(message: "Awesome - what name should I use?")
        }

        return nil
    }

    @discardableResult
    func clearSavedFaces() -> Bool {
        camera.clearKnownFaces()
    }

    private var isIdentityLogicEnabled: Bool {
        guard camera.isRunning else { return false }
        return settings.faceRecognitionEnabled && settings.personalizedGreetingsEnabled
    }

    private func shouldEmitNamedGreeting(turnIndex: Int) -> Bool {
        guard let lastNamedGreetingTurn else { return true }
        return (turnIndex - lastNamedGreetingTurn) > namedGreetingCooldownTurns
    }

    private func shouldEmitOnboardingPrompt(turnIndex: Int) -> Bool {
        guard let lastOnboardingPromptTurn else { return true }
        return (turnIndex - lastOnboardingPromptTurn) > onboardingPromptCooldownTurns
    }

    private func namedGreeting(for name: String, repetitionCount: Int) -> String {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let templates = [
            "Hey %@, what's up?",
            "Hi %@, how can I help?",
            "Morning %@, how's it going?"
        ]
        let idx = max(0, repetitionCount - 1) % templates.count
        return String(format: templates[idx], cleanedName)
    }

    private func onboardingGreeting(for repetitionCount: Int) -> String {
        let templates = [
            "Hi there! I don't think we've met - what's your name? I can remember you if you'd like.",
            "Hey! I don't recognize you yet. Want me to remember you so things feel more personal?"
        ]
        let idx = max(0, repetitionCount - 1) % templates.count
        return templates[idx]
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

    private func extractName(from text: String) -> String? {
        let normalized = normalize(text)

        let explicitPatterns = [
            #"^(?:i am|i'm|im|my name is|name is|this is|it is|it's|its)\s+([a-z][a-z'\-]{1,31}(?:\s+[a-z][a-z'\-]{1,31})?)\.?$"#
        ]

        for pattern in explicitPatterns {
            if let name = firstCapture(in: normalized, pattern: pattern) {
                return sanitizedDisplayName(name)
            }
        }

        // Allow concise direct replies like "sarah" or "james lee".
        if let direct = directNameCandidate(from: normalized) {
            return sanitizedDisplayName(direct)
        }

        return nil
    }

    private func directNameCandidate(from normalized: String) -> String? {
        if normalized.contains("?") { return nil }
        let compact = normalized
            .replacingOccurrences(of: #"[^a-z'\-\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !compact.isEmpty else { return nil }
        let parts = compact.split(separator: " ").map(String.init)
        // Privacy-first: direct replies only accept a single-token name.
        // Multi-token names still work via explicit patterns (e.g., "I'm James Lee").
        guard parts.count == 1 else { return nil }
        guard parts.allSatisfy({
            $0.count >= 2 &&
            $0.range(of: #"^[a-z][a-z'\-]{1,31}$"#, options: .regularExpression) != nil
        }) else {
            return nil
        }

        let disallowed: Set<String> = [
            "hello", "hi", "hey",
            "thanks", "thank", "please", "sure",
            "okay", "ok", "yes", "no", "nope", "nah",
            "later", "maybe", "skip", "cancel",
            "help", "weather", "time",
            "what", "when", "where", "why", "who", "how"
        ]
        if parts.contains(where: { disallowed.contains($0) }) {
            return nil
        }

        return parts.joined(separator: " ")
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let raw = String(text[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
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
