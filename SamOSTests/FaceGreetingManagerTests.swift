import XCTest
import AppKit
@testable import SamOS

private struct StubFaceGreetingSettings: FaceGreetingSettingsProviding {
    var faceRecognitionEnabled: Bool = true
    var personalizedGreetingsEnabled: Bool = true
}

private final class FakeFaceCamera: CameraVisionProviding {
    var isRunning: Bool = true
    var latestFrameAt: Date? = Date()
    var analysis: CameraFrameAnalysis?
    var recognitionResult: CameraFaceRecognitionResult?
    var enrollCalls: [String] = []
    var clearCalls = 0
    var onEnroll: ((String) -> Void)?

    func start() throws {}
    func stop() {}
    func latestPreviewImage() -> NSImage? { nil }
    func describeCurrentScene() -> CameraSceneDescription? { nil }
    func currentAnalysis() -> CameraFrameAnalysis? { analysis }
    func recognizeKnownFaces() -> CameraFaceRecognitionResult? { recognitionResult }

    func enrollFace(name: String) -> CameraFaceEnrollmentResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        enrollCalls.append(trimmed)
        onEnroll?(trimmed)
        return CameraFaceEnrollmentResult(
            status: .success,
            enrolledName: trimmed,
            samplesForName: 1,
            totalKnownNames: Set(enrollCalls).count,
            capturedAt: Date()
        )
    }

    func knownFaceNames() -> [String] {
        Array(Set(enrollCalls)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func clearKnownFaces() -> Bool {
        clearCalls += 1
        enrollCalls.removeAll()
        return true
    }

    var health: CameraHealth { CameraHealth(lastGoodFrameAt: nil, lastFrameErrorAt: nil, consecutiveErrors: 0, isHealthy: true) }
    func detectFacialEmotions() -> CameraEmotionSnapshot? { nil }
    func captureFrameAsJPEG(quality: CGFloat) -> Data? { nil }
}

@MainActor
final class FaceGreetingManagerTests: XCTestCase {
    private var savedAPIKey: String = ""
    private var savedUseOllama: Bool = false

    override func setUp() {
        super.setUp()
        savedAPIKey = OpenAISettings.apiKey
        savedUseOllama = M2Settings.useOllama
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false
    }

    override func tearDown() {
        OpenAISettings.apiKey = savedAPIKey
        M2Settings.useOllama = savedUseOllama
        OpenAISettings._resetCacheForTesting()
        super.tearDown()
    }

    func testKnownFaceUsesNameInGreeting() {
        let camera = FakeFaceCamera()
        camera.analysis = makeAnalysis(faceCount: 1)
        camera.recognitionResult = makeRecognition(
            detectedFaces: 1,
            matches: [CameraRecognizedFaceMatch(name: "Richard", confidence: 0.84, distance: 0.12)],
            unknownFaces: 0
        )
        let manager = FaceGreetingManager(camera: camera, settings: StubFaceGreetingSettings())

        _ = manager.evaluateFrame()
        let line = manager.greetingOverride(for: greetingMode, repetitionCount: 1, turnIndex: 1)

        XCTAssertEqual(manager.currentIdentityContext.recognizedUserName, "Richard")
        XCTAssertEqual(manager.currentIdentityContext.faceConfidence ?? 0, 0.84, accuracy: 0.001)
        XCTAssertEqual(line?.contains("Richard"), true)
        XCTAssertEqual(nameCount(in: line ?? "", name: "Richard"), 1, "Name should appear once per greeting")
    }

    func testUnknownFaceTriggersOnboarding() {
        let camera = FakeFaceCamera()
        camera.analysis = makeAnalysis(faceCount: 1)
        camera.recognitionResult = makeRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)
        let manager = FaceGreetingManager(camera: camera, settings: StubFaceGreetingSettings())

        _ = manager.evaluateFrame()
        let decision = manager.prepareTurn(
            userInput: "Hi",
            inputMode: .voice,
            now: Date(),
            userInitiated: true
        )

        XCTAssertTrue(manager.currentIdentityContext.unrecognizedUserPresent)
        XCTAssertTrue(manager.awaitingIdentityConfirmation)
        XCTAssertTrue(decision.shouldPromptIdentity)
        XCTAssertTrue((decision.promptToAppend ?? "").localizedCaseInsensitiveContains("what's your name"))
    }

    func testDeclineEnrollmentResetsState() {
        let camera = FakeFaceCamera()
        camera.analysis = makeAnalysis(faceCount: 1)
        camera.recognitionResult = makeRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)
        let manager = FaceGreetingManager(camera: camera, settings: StubFaceGreetingSettings())

        _ = manager.evaluateFrame()
        _ = manager.prepareTurn(
            userInput: "Hi",
            inputMode: .voice,
            now: Date(),
            userInitiated: true
        )
        XCTAssertTrue(manager.awaitingIdentityConfirmation)
        let resolution = manager.resolveIdentityConfirmationResponse("No thanks")

        XCTAssertEqual(resolution, .declined(message: "No worries at all."))
        XCTAssertFalse(manager.awaitingIdentityConfirmation)
        XCTAssertTrue(camera.enrollCalls.isEmpty)
    }

    func testMultipleFacesSelectsPrimary() {
        let camera = FakeFaceCamera()
        camera.analysis = makeAnalysis(faceCount: 2)
        camera.recognitionResult = makeRecognition(
            detectedFaces: 2,
            matches: [
                CameraRecognizedFaceMatch(name: "Alex", confidence: 0.78, distance: 0.14),
                CameraRecognizedFaceMatch(name: "Richard", confidence: 0.91, distance: 0.08)
            ],
            unknownFaces: 0
        )
        let manager = FaceGreetingManager(camera: camera, settings: StubFaceGreetingSettings())

        _ = manager.evaluateFrame()

        XCTAssertEqual(manager.currentIdentityContext.recognizedUserName, "Richard")
        XCTAssertEqual(manager.currentIdentityContext.faceConfidence ?? 0, 0.91, accuracy: 0.001)
    }

    func testLowConfidenceTreatedAsUnknown() {
        let camera = FakeFaceCamera()
        camera.analysis = makeAnalysis(faceCount: 1)
        camera.recognitionResult = makeRecognition(
            detectedFaces: 1,
            matches: [CameraRecognizedFaceMatch(name: "Richard", confidence: 0.61, distance: 0.22)],
            unknownFaces: 0
        )
        let manager = FaceGreetingManager(camera: camera, settings: StubFaceGreetingSettings(), recognitionThreshold: 0.72)

        _ = manager.evaluateFrame()

        XCTAssertNil(manager.currentIdentityContext.recognizedUserName)
        XCTAssertTrue(manager.currentIdentityContext.unrecognizedUserPresent)
    }

    func testPersonalizedGreetingFlow() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(#"{"action":"TALK","say":"Hey! What's up?"}"#)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = FakeFaceCamera()
        camera.analysis = makeAnalysis(faceCount: 1)
        camera.recognitionResult = makeRecognition(
            detectedFaces: 1,
            matches: [CameraRecognizedFaceMatch(name: "Richard", confidence: 0.88, distance: 0.09)],
            unknownFaces: 0
        )
        let manager = FaceGreetingManager(camera: camera, settings: StubFaceGreetingSettings())

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, faceGreetingManager: manager)
        let result = await orchestrator.processTurn("Hey Sam", history: [])

        let line = result.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(line.contains("Richard"), "Greeting should use recognized name")

        let context = orchestrator.debugLastPromptContext()
        XCTAssertEqual(context?.identityContextLine, "Recognized user: Richard (confidence high)")
        XCTAssertTrue(context?.interactionStateJSON.contains("recognized_user_name") == true)
    }

    func testUnknownFaceOnboardingFlow() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Hey! What's up?"}"#),
            .success(#"{"action":"TALK","say":"Hey! What's up?"}"#)
        ]

        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = FakeFaceCamera()
        camera.analysis = makeAnalysis(faceCount: 1)
        camera.recognitionResult = makeRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)
        camera.onEnroll = { name in
            let match = CameraRecognizedFaceMatch(name: name, confidence: 0.9, distance: 0.08)
            camera.recognitionResult = CameraFaceRecognitionResult(
                capturedAt: Date(),
                detectedFaces: 1,
                matches: [match],
                unknownFaces: 0,
                enrolledNames: [name]
            )
        }

        let manager = FaceGreetingManager(camera: camera, settings: StubFaceGreetingSettings())
        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, faceGreetingManager: manager)

        let first = await orchestrator.processTurn("Hi", history: [])
        let firstLine = first.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(firstLine.localizedCaseInsensitiveContains("what's your name"))

        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Hi"),
            ChatMessage(role: .assistant, text: firstLine)
        ]
        let second = await orchestrator.processTurn("I'm James", history: history)
        let secondLine = second.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""

        XCTAssertEqual(secondLine, "Nice to meet you, James.")
        XCTAssertEqual(camera.enrollCalls, ["James"])
    }

    func testUnknownFacePromptsOnFirstVoiceTurnAfterDetection() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success(#"{"intent":"general_qna","confidence":0.93,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#)
        ]
        fakeOpenAI.queuedResponses = [.success(#"{"action":"TALK","say":"I can help with that."}"#)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = FakeFaceCamera()
        camera.analysis = makeAnalysis(faceCount: 1)
        camera.recognitionResult = makeRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        let manager = FaceGreetingManager(camera: camera, settings: StubFaceGreetingSettings())
        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, faceGreetingManager: manager)

        let result = await orchestrator.processTurn(
            "What's the weather in Tokyo?",
            history: [],
            inputMode: .voice
        )
        let line = result.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""

        XCTAssertTrue(line.localizedCaseInsensitiveContains("what's your name"), "Expected identity prompt, got: \(line)")
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Unknown-face onboarding must still route normal chat once")
    }

    func testUnknownFaceTextInputUsesNormalRouting() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(#"{"action":"TALK","say":"I can help with that."}"#)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = FakeFaceCamera()
        camera.analysis = makeAnalysis(faceCount: 1)
        camera.recognitionResult = makeRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        let manager = FaceGreetingManager(camera: camera, settings: StubFaceGreetingSettings())
        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, faceGreetingManager: manager)

        let result = await orchestrator.processTurn(
            "What's the weather in Tokyo?",
            history: [],
            inputMode: .text
        )
        let line = result.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""

        XCTAssertTrue(line.localizedCaseInsensitiveContains("what's your name"), "Expected identity prompt appended once, got: \(line)")
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)
    }

    func testPrivacyNoAutoEnroll() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Hey! What's up?"}"#),
            .success(#"{"action":"TALK","say":"Sure, I can help with that."}"#)
        ]

        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = FakeFaceCamera()
        camera.analysis = makeAnalysis(faceCount: 1)
        camera.recognitionResult = makeRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        let manager = FaceGreetingManager(camera: camera, settings: StubFaceGreetingSettings())
        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, faceGreetingManager: manager)

        let first = await orchestrator.processTurn("Hi", history: [])
        let prompt = first.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""

        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Hi"),
            ChatMessage(role: .assistant, text: prompt)
        ]
        _ = await orchestrator.processTurn("What's the weather?", history: history)

        XCTAssertTrue(camera.enrollCalls.isEmpty, "Face should never auto-enroll without explicit consent")
    }

    func testCameraOffNoIdentityLogic() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(#"{"action":"TALK","say":"Hey! What's up?"}"#)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = FakeFaceCamera()
        camera.isRunning = false
        camera.analysis = makeAnalysis(faceCount: 1)
        camera.recognitionResult = makeRecognition(
            detectedFaces: 1,
            matches: [CameraRecognizedFaceMatch(name: "Richard", confidence: 0.9, distance: 0.08)],
            unknownFaces: 0
        )

        let manager = FaceGreetingManager(camera: camera, settings: StubFaceGreetingSettings())
        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, faceGreetingManager: manager)

        let result = await orchestrator.processTurn("Hi", history: [])
        let line = result.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""

        XCTAssertFalse(line.contains("Richard"), "Camera off should fall back to normal greeting")
        XCTAssertFalse(line.localizedCaseInsensitiveContains("met"), "Camera off should not trigger onboarding")
    }

    private func makeOrchestrator(fakeOpenAI: FakeOpenAITransport,
                                  fakeOllama: FakeOllamaTransportForPipeline,
                                  faceGreetingManager: FaceGreetingManager) -> TurnOrchestrator {
        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        return TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            faceGreetingManager: faceGreetingManager
        )
    }

    private func makeAnalysis(faceCount: Int) -> CameraFrameAnalysis {
        CameraFrameAnalysis(
            labels: [],
            recognizedText: [],
            faces: CameraFacePresence(count: faceCount),
            capturedAt: Date()
        )
    }

    private func makeRecognition(detectedFaces: Int,
                                 matches: [CameraRecognizedFaceMatch],
                                 unknownFaces: Int) -> CameraFaceRecognitionResult {
        CameraFaceRecognitionResult(
            capturedAt: Date(),
            detectedFaces: detectedFaces,
            matches: matches,
            unknownFaces: unknownFaces,
            enrolledNames: Array(Set(matches.map(\.name))).sorted()
        )
    }

    private var greetingMode: ConversationMode {
        ConversationMode(
            intent: .greeting,
            domain: .unknown,
            urgency: .low,
            needsClarification: false,
            userGoalHint: .unknown
        )
    }

    private func nameCount(in text: String, name: String) -> Int {
        text.components(separatedBy: name).count - 1
    }
}
