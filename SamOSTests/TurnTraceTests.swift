import XCTest
@testable import SamOS

@MainActor
final class TurnTraceTests: XCTestCase {
    private var savedMuted: Bool = false
    private var savedListeningPref: Bool = false
    private var savedCameraPref: Bool = false

    override func setUp() {
        super.setUp()
        savedMuted = ElevenLabsSettings.isMuted
        savedListeningPref = AppState.userWantsListeningEnabled
        savedCameraPref = AppState.userWantsCameraEnabled

        ElevenLabsSettings.isMuted = true
        AppState.userWantsListeningEnabled = false
        AppState.userWantsCameraEnabled = false
    }

    override func tearDown() {
        ElevenLabsSettings.isMuted = savedMuted
        AppState.userWantsListeningEnabled = savedListeningPref
        AppState.userWantsCameraEnabled = savedCameraPref
        super.tearDown()
    }

    private func waitForTrace(appState: AppState, timeoutSeconds: TimeInterval = 1.5) async -> TurnTrace? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let trace = appState.debugLastTurnTrace() {
                return trace
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    private func makeTraceResult(routeLocalOutcome: String,
                                 planLocalTotalMs: Int,
                                 planOpenAIMs: Int? = nil) -> TurnResult {
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Trace-ready response")]
        result.spokenLines = []
        result.llmProvider = planOpenAIMs == nil ? .ollama : .openai
        result.intentProviderSelected = planOpenAIMs == nil ? .ollama : .openai
        result.planProviderSelected = planOpenAIMs == nil ? .ollama : .openai
        result.routeLocalOutcome = routeLocalOutcome
        result.planLocalTotalMs = planLocalTotalMs
        result.planOpenAIMs = planOpenAIMs
        result.intentRouterMsLocal = planLocalTotalMs
        result.intentRouterMsOpenAI = planOpenAIMs
        result.planExecutionMs = 32
        result.speechSelectionMs = 8
        result.toolMsTotal = 14
        return result
    }

    func testVoiceTurnTraceIsMonotonicAndContainsRequiredPhases() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        fakeOrchestrator.queuedResults = [makeTraceResult(routeLocalOutcome: "ok", planLocalTotalMs: 120)]

        let fakeVoicePipeline = FakeVoicePipeline()
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            enableRuntimeServices: true
        )

        fakeVoicePipeline.onStatusChange?(.capturingAudio)
        try? await Task.sleep(nanoseconds: 5_000_000)
        fakeVoicePipeline.onStatusChange?(.transcribing)
        try? await Task.sleep(nanoseconds: 5_000_000)
        fakeVoicePipeline.onTranscript?("hello from voice")

        guard let trace = await waitForTrace(appState: appState) else {
            return XCTFail("Expected deterministic turn trace")
        }

        let names = trace.events.map(\.name)
        let required = [
            "TURN_START",
            "CAPTURE_START",
            "CAPTURE_END",
            "STT_START",
            "STT_END",
            "ROUTE_LOCAL_START",
            "ROUTE_LOCAL_END",
            "PLAN_EXEC_START",
            "PLAN_EXEC_END",
            "SPEECH_SELECT_START",
            "SPEECH_SELECT_END",
            "TURN_END"
        ]

        for phase in required {
            XCTAssertTrue(names.contains(phase), "Missing phase in trace: \(phase)")
        }

        for pair in zip(trace.events, trace.events.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.tMsFromStart, pair.1.tMsFromStart)
        }

        XCTAssertEqual(trace.events.first?.name, "TURN_START")
        XCTAssertEqual(trace.events.last?.name, "TURN_END")
        XCTAssertEqual(trace.events.last?.tMsFromStart, trace.totalMs)
    }

    func testTurnTraceIncludesOpenAIFallbackEventsWhenPlanOpenAIMsPresent() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        fakeOrchestrator.queuedResults = [
            makeTraceResult(
                routeLocalOutcome: "timeout",
                planLocalTotalMs: RouterTimeouts.localCombinedDeadlineMs,
                planOpenAIMs: 420
            )
        ]

        let appState = AppState(
            orchestrator: fakeOrchestrator,
            thinkingFillerDelay: 0.05,
            enableRuntimeServices: false
        )

        appState.send("text turn")

        guard let trace = await waitForTrace(appState: appState) else {
            return XCTFail("Expected deterministic turn trace")
        }

        let openAIStart = trace.events.first(where: { $0.name == "ROUTE_OPENAI_START" })
        let openAIEnd = trace.events.first(where: { $0.name == "ROUTE_OPENAI_END" })

        XCTAssertNotNil(openAIStart)
        XCTAssertNotNil(openAIEnd)
        if let start = openAIStart?.tMsFromStart,
           let end = openAIEnd?.tMsFromStart {
            XCTAssertLessThanOrEqual(start, end)
        }
    }
}
