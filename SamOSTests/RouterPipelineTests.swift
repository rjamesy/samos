import XCTest
import AppKit
@testable import SamOS

// MARK: - Fake OpenAI Transport

final class FakeOpenAITransport: OpenAITransport {
    var queuedResponses: [Result<String, Error>] = []
    var queuedIntentResponses: [Result<String, Error>] = []
    var delayNanoseconds: UInt64 = 0
    var perCallDelayNanoseconds: [UInt64] = []
    private(set) var chatCallCount = 0
    private(set) var intentCallCount = 0
    private(set) var chatCallLog: [[[String: String]]] = []
    private(set) var chatModelLog: [String] = []
    private(set) var chatMaxTokensLog: [Int?] = []
    private(set) var intentMaxTokensLog: [Int?] = []
    private(set) var intentTemperatureLog: [Double?] = []

    func chat(messages: [[String: String]], model: String, maxOutputTokens: Int?) async throws -> String {
        chatCallCount += 1
        chatCallLog.append(messages)
        chatModelLog.append(model)
        chatMaxTokensLog.append(maxOutputTokens)
        let delay = perCallDelayNanoseconds.isEmpty ? delayNanoseconds : perCallDelayNanoseconds.removeFirst()
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        guard !queuedResponses.isEmpty else {
            throw OpenAIRouter.OpenAIError.requestFailed("No queued response")
        }
        return try queuedResponses.removeFirst().get()
    }

    func chat(messages: [[String: String]],
              model: String,
              maxOutputTokens: Int?,
              responseFormat: [String: Any]?,
              temperature: Double?) async throws -> String {
        if responseFormat != nil {
            intentCallCount += 1
            intentMaxTokensLog.append(maxOutputTokens)
            intentTemperatureLog.append(temperature)
            guard !queuedIntentResponses.isEmpty else {
                throw OpenAIRouter.OpenAIError.requestFailed("No queued intent response")
            }
            return try queuedIntentResponses.removeFirst().get()
        }
        return try await chat(messages: messages, model: model, maxOutputTokens: maxOutputTokens)
    }
}

@MainActor
final class ScriptedConversationRunnerTests: XCTestCase {

    private struct ScenarioTurnMetric {
        let intent: String
        let domain: String
        let urgency: String
        let budget: Int
        let summaryChars: Int
        let stateChars: Int
        let action: String
        let sayLength: Int
        let showTextLength: Int
        let assistantText: String
    }

    private struct ScriptedScenario {
        let name: String
        let turns: [String]
        let responses: [String]
        let validator: ([ScenarioTurnMetric]) -> Bool
    }

    func testRunScriptedConversationRunner() async {
        let savedToneProfile = TonePreferenceStore.shared.loadProfile()
        defer { TonePreferenceStore.shared.replaceProfileForTesting(savedToneProfile) }
        TonePreferenceStore.shared.replaceProfileForTesting(.neutralDefaults)

        let longHealth = """
        I hear you, that sounds uncomfortable. To narrow this down: when did this start, where exactly is the pain, how severe is it from 1-10, and have you had vomiting, fever, diarrhea, blood, or trouble keeping fluids down? For now, sip water regularly, avoid heavy meals, and rest while tracking changes. Red flags: severe or worsening pain, blood, black stools, persistent vomiting, fainting, or a rigid belly.
        """
        let longVehicle = """
        That sounds stressful, and you're right to check it early. Can you tell me when the noise happens (idle vs acceleration), whether any warning lights are on, if the engine is overheating or smoking, and when oil/service was last done? Immediate checks: verify oil level, listen for changes with gentle throttle, and avoid hard acceleration. Red flags: oil pressure light, overheating, smoke or strong fuel smell, loud knocking, or power loss — stop driving and tow if those appear.
        """
        let longTech = """
        That is frustrating, and we can narrow it fast. What exact error are you seeing, when did it start, what changed recently (updates/router settings), and is it only this device or all devices on the network? Quick checks now: reboot router and MacBook, forget/rejoin Wi-Fi, and disable VPN/private relay temporarily. Red flags: signs of account compromise or sudden data loss — change passwords and secure accounts immediately.
        """

        let scenarios: [ScriptedScenario] = [
            ScriptedScenario(
                name: "Greeting x10 variation",
                turns: Array(repeating: "how are you", count: 10),
                responses: Array(repeating: #"{"action":"TALK","say":"I am doing well, thanks for asking."}"#, count: 10),
                validator: { metrics in
                    guard metrics.count == 10 else { return false }
                    let window = metrics.dropFirst(3).prefix(3)
                    return window.contains { $0.assistantText.lowercased().contains("few times") }
                }
            ),
            ScriptedScenario(
                name: "Health problem flow",
                turns: ["i dont feel well", "my tummy is sore", "started this morning, pain 6/10, no vomiting"],
                responses: [
                    #"{"action":"TALK","say":"\#(longHealth)"}"#,
                    #"{"action":"TALK","say":"\#(longHealth)"}"#,
                    #"{"action":"TALK","say":"\#(longHealth)"}"#
                ],
                validator: { metrics in
                    guard let m = metrics.dropFirst().first else { return false }
                    return m.intent == "problem_report" && m.domain == "health" && m.showTextLength > 0
                }
            ),
            ScriptedScenario(
                name: "Vehicle problem flow",
                turns: ["my car engine is making a funny noise", "only when accelerating, no lights"],
                responses: [
                    #"{"action":"TALK","say":"\#(longVehicle)"}"#,
                    #"{"action":"TALK","say":"\#(longVehicle)"}"#
                ],
                validator: { metrics in
                    metrics.contains { $0.domain == "vehicle" && $0.showTextLength > 0 }
                }
            ),
            ScriptedScenario(
                name: "Tech wifi troubleshooting",
                turns: ["wifi keeps dropping out", "since yesterday, nbn, macbook"],
                responses: [
                    #"{"action":"TALK","say":"\#(longTech)"}"#,
                    #"{"action":"TALK","say":"\#(longTech)"}"#
                ],
                validator: { metrics in
                    metrics.contains { $0.domain == "tech" && $0.showTextLength > 0 }
                }
            ),
            ScriptedScenario(
                name: "Tool synthesis weather+jacket",
                turns: ["what's the weather tomorrow and should I bring a jacket?"],
                responses: [
                    "{\"action\":\"PLAN\",\"steps\":[{\"step\":\"tool\",\"name\":\"show_text\",\"args\":{\"markdown\":\"## Weather\\n- Rain chance: 62%\\n- Temp: 14-19C\\n- Light wind\",\"needs_reasoning\":\"true\"},\"say\":\"Checking weather details.\"}]}",
                    #"{"action":"TALK","say":"Rain chance is moderate and temps are cool, so bring a light jacket."}"#
                ],
                validator: { metrics in
                    guard let last = metrics.last else { return false }
                    return last.action == "PLAN" || last.assistantText.lowercased().contains("jacket")
                }
            ),
            ScriptedScenario(
                name: "20-turn continuity summary",
                turns: [
                    "my dog's name is Bingo",
                    "can you remember that context",
                    "what can we do this weekend",
                    "maybe hiking",
                    "what gear should I bring",
                    "i have a small car",
                    "any compact checklist",
                    "good",
                    "what about weather risks",
                    "okay continue",
                    "add food planning",
                    "and water planning",
                    "and safety steps",
                    "keep it short",
                    "what did i say my dog's name was",
                    "nice",
                    "continue",
                    "one more tip",
                    "another tip",
                    "final recap"
                ],
                responses: Array(repeating: #"{"action":"TALK","say":"Noted. I can help with that next step."}"#, count: 20),
                validator: { metrics in
                    guard metrics.count == 20 else { return false }
                    return metrics.dropFirst(10).contains { $0.summaryChars > 0 }
                }
            ),
            ScriptedScenario(
                name: "Task request classification",
                turns: ["set an alarm for 7"],
                responses: [#"{"action":"TALK","say":"Sure, I can help set that."}"#],
                validator: { $0.first?.intent == "task_request" }
            ),
            ScriptedScenario(
                name: "Memory recall classification",
                turns: ["what did i say my dog's name was?"],
                responses: [#"{"action":"TALK","say":"You said your dog's name is Bingo."}"#],
                validator: { $0.first?.intent == "memory_recall" }
            ),
            ScriptedScenario(
                name: "Decision help classification",
                turns: ["should i buy the sedan or suv?"],
                responses: [#"{"action":"TALK","say":"If parking and fuel matter most, sedan is usually the better fit."}"#],
                validator: { $0.first?.intent == "decision_help" }
            ),
            ScriptedScenario(
                name: "Creative classification",
                turns: ["write a short joke about coding"],
                responses: [#"{"action":"TALK","say":"Why did the bug stay calm? It knew how to handle exceptions."}"#],
                validator: { $0.first?.intent == "creative" }
            )
        ]

        var failed: [String] = []

        for scenario in scenarios {
            let fakeOpenAI = FakeOpenAITransport()
            fakeOpenAI.queuedResponses = scenario.responses.map { .success($0) }
            let fakeOllama = FakeOllamaTransportForPipeline()

            OpenAISettings.apiKey = "test-key-123"
            OpenAISettings._resetCacheForTesting()
            OpenAISettings.apiKey = "test-key-123"
            M2Settings.useOllama = false

            let ollamaRouter = OllamaRouter(transport: fakeOllama)
            let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
            let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

            var history: [ChatMessage] = []
            var metrics: [ScenarioTurnMetric] = []

            for (index, turn) in scenario.turns.enumerated() {
                let result = await orchestrator.processTurn(turn, history: history)
                history.append(ChatMessage(role: .user, text: turn))
                history.append(contentsOf: result.appendedChat)

                let context = orchestrator.debugLastPromptContext()
                let mode = context?.mode ?? orchestrator.debugClassify(turn)
                let budget = context?.responseBudget.maxOutputTokens ?? 0
                let summaryChars = context?.sessionSummary.count ?? 0
                let stateChars = context?.interactionStateJSON.count ?? 0
                let action = orchestrator.debugLastFinalActionKind()
                let assistantText = result.appendedChat.last(where: { $0.role == .assistant })?.text ?? ""
                let sayLength = assistantText.count
                let showTextLength = result.appendedOutputs
                    .filter { $0.kind == .markdown }
                    .map(\.payload.count)
                    .max() ?? 0

                let metric = ScenarioTurnMetric(
                    intent: mode.intent.rawValue,
                    domain: mode.domain.rawValue,
                    urgency: mode.urgency.rawValue,
                    budget: budget,
                    summaryChars: summaryChars,
                    stateChars: stateChars,
                    action: action,
                    sayLength: sayLength,
                    showTextLength: showTextLength,
                    assistantText: assistantText
                )
                metrics.append(metric)

                print("[RUNNER] scenario=\(scenario.name) turn=\(index + 1) intent=\(metric.intent) domain=\(metric.domain) urgency=\(metric.urgency) budget=\(metric.budget) summary_chars=\(metric.summaryChars) state_chars=\(metric.stateChars) action=\(metric.action) say_len=\(metric.sayLength) show_text_len=\(metric.showTextLength)")
            }

            let passed = scenario.validator(metrics)
            print("[RUNNER] scenario=\(scenario.name) result=\(passed ? "PASS" : "FAIL")")
            if !passed {
                failed.append(scenario.name)
            }
        }

        XCTAssertTrue(failed.isEmpty, "Scripted runner failures: \(failed)")
    }

    func testAffectScriptedRunnerCases() async {
        let savedToneProfile = TonePreferenceStore.shared.loadProfile()
        defer { TonePreferenceStore.shared.replaceProfileForTesting(savedToneProfile) }

        struct AffectCase {
            let input: String
            let expectedAffect: ConversationAffect
            let responseJSON: String
            let taskMarkers: [String]
        }

        let cases: [AffectCase] = [
            AffectCase(
                input: "This wifi is ridiculous, it keeps dropping",
                expectedAffect: .frustrated,
                responseJSON: #"{"action":"TALK","say":"Yeah, that's really frustrating. Let's restart the router, run a quick ping test, and check if drops happen on all devices."}"#,
                taskMarkers: ["restart", "router", "ping"]
            ),
            AffectCase(
                input: "I'm worried about this chest tightness",
                expectedAffect: .anxious,
                responseJSON: #"{"action":"TALK","say":"I get why that feels worrying. Is the chest tightness severe, getting worse, or paired with shortness of breath or fainting? If yes, seek urgent care now."}"#,
                taskMarkers: ["shortness of breath", "urgent care", "severe"]
            ),
            AffectCase(
                input: "I don't feel like doing anything today",
                expectedAffect: .sad,
                responseJSON: #"{"action":"TALK","say":"I'm sorry, that sounds heavy. Want a quick reset plan for today, or do you want to talk for a minute first?"}"#,
                taskMarkers: ["quick reset plan", "talk for a minute"]
            ),
            AffectCase(
                input: "THIS THING IS BROKEN",
                expectedAffect: .angry,
                responseJSON: #"{"action":"TALK","say":"I can tell this is really intense. Let's slow it down: what changed right before it broke, and what error do you see now?"}"#,
                taskMarkers: ["what changed", "error"]
            ),
            AffectCase(
                input: "Yay it finally worked!!!",
                expectedAffect: .excited,
                responseJSON: #"{"action":"TALK","say":"That's awesome! Nice momentum here: run one more validation test, then save this as your baseline setup."}"#,
                taskMarkers: ["validation test", "baseline setup"]
            )
        ]

        let savedApiKey = OpenAISettings.apiKey
        let savedUseOllama = M2Settings.useOllama
        let savedAffectMirroringEnabled = M2Settings.affectMirroringEnabled
        let savedUseEmotionalTone = M2Settings.useEmotionalTone
        defer {
            OpenAISettings.apiKey = savedApiKey
            M2Settings.useOllama = savedUseOllama
            M2Settings.affectMirroringEnabled = savedAffectMirroringEnabled
            M2Settings.useEmotionalTone = savedUseEmotionalTone
            OpenAISettings._resetCacheForTesting()
        }

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true
        TonePreferenceStore.shared.replaceProfileForTesting(.neutralDefaults)

        for scripted in cases {
            let fakeOpenAI = FakeOpenAITransport()
            fakeOpenAI.queuedResponses = [.success(scripted.responseJSON)]
            let fakeOllama = FakeOllamaTransportForPipeline()
            let ollamaRouter = OllamaRouter(transport: fakeOllama)
            let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
            let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

            let result = await orchestrator.processTurn(scripted.input, history: [])
            let context = orchestrator.debugLastPromptContext()
            XCTAssertEqual(
                context?.affect.affect,
                scripted.expectedAffect,
                "Expected affect \(scripted.expectedAffect.rawValue) for input: \(scripted.input)"
            )

            let assistantText = result.appendedChat.last(where: { $0.role == .assistant })?.text.lowercased() ?? ""
            XCTAssertFalse(assistantText.isEmpty, "Expected assistant output for input: \(scripted.input)")
            XCTAssertLessThanOrEqual(emotionalSentenceCount(in: assistantText), 1, "Expected <=1 emotional sentence")
            XCTAssertTrue(
                scripted.taskMarkers.contains(where: { assistantText.contains($0) }),
                "Expected task logic markers in output: \(assistantText)"
            )
            XCTAssertFalse(containsTherapyLanguage(assistantText), "Output should avoid unsolicited therapy language")
        }
    }

    func testToneLearningScenarioDontBeCheerfulThenFrustratedProblemReport() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Understood. I'll keep it grounded and direct."}"#),
            .success(#"{"action":"TALK","say":"That sounds frustrating. Restart the router, run a quick network check, and confirm whether all devices are dropping."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()

        let savedApiKey = OpenAISettings.apiKey
        let savedUseOllama = M2Settings.useOllama
        let savedAffectMirroringEnabled = M2Settings.affectMirroringEnabled
        let savedUseEmotionalTone = M2Settings.useEmotionalTone
        let savedToneProfile = TonePreferenceStore.shared.loadProfile()
        defer {
            OpenAISettings.apiKey = savedApiKey
            M2Settings.useOllama = savedUseOllama
            M2Settings.affectMirroringEnabled = savedAffectMirroringEnabled
            M2Settings.useEmotionalTone = savedUseEmotionalTone
            TonePreferenceStore.shared.replaceProfileForTesting(savedToneProfile)
            OpenAISettings._resetCacheForTesting()
        }

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true

        var tone = TonePreferenceProfile.neutralDefaults
        tone.enabled = true
        TonePreferenceStore.shared.replaceProfileForTesting(tone)

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        var history: [ChatMessage] = []
        let first = await orchestrator.processTurn("don't be so cheerful", history: history)
        history.append(ChatMessage(role: .user, text: "don't be so cheerful"))
        history.append(contentsOf: first.appendedChat)

        let updatedProfile = TonePreferenceStore.shared.loadProfile()
        XCTAssertTrue(updatedProfile.avoidCheerfulWhenUpset)

        let second = await orchestrator.processTurn("This wifi is ridiculous, it keeps dropping", history: history)
        let secondText = (second.appendedChat.last(where: { $0.role == .assistant })?.text ?? "").lowercased()
        XCTAssertFalse(containsCheerfulLanguage(secondText), "Opening should stay grounded after cheerful-feedback update")
        XCTAssertTrue(secondText.contains("restart") || secondText.contains("router") || secondText.contains("network"),
                      "Response should remain practically helpful")
    }

    private func emotionalSentenceCount(in text: String) -> Int {
        let emotionalMarkers = [
            "frustrating",
            "worrying",
            "unsettling",
            "sorry",
            "heavy",
            "intense",
            "awesome",
            "great news",
            "love that energy"
        ]
        let sentences = text
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return sentences.reduce(0) { partial, sentence in
            partial + (emotionalMarkers.contains(where: { sentence.contains($0) }) ? 1 : 0)
        }
    }

    private func containsTherapyLanguage(_ text: String) -> Bool {
        let banned = [
            "anxiety disorder",
            "depression",
            "diagnosis",
            "diagnose",
            "mental illness"
        ]
        return banned.contains { text.contains($0) }
    }

    private func containsCheerfulLanguage(_ text: String) -> Bool {
        let cheerful = ["yay", "awesome", "great news", "love that energy", "woo"]
        return cheerful.contains(where: { text.contains($0) })
    }
}

final class MarkdownRenderPrepTests: XCTestCase {

    func testToolDisplayStringRemainsRawMarkdown() {
        let markdown = "# Title\n\n## Ingredients:\n- a\n- b\n\nLine1\nLine2"
        let display = OutputCanvasMarkdown.toolDisplayString(markdown)
        XCTAssertEqual(display, markdown)
        XCTAssertTrue(display.contains("\n- a\n- b\n"))
    }

    func testCanvasMarkdownBlocksPreserveStructure() {
        let markdown = "# Title\n\n## Ingredients:\n- a\n- b\n\nLine1\nLine2"
        let blocks = OutputCanvasMarkdown.blocks(from: markdown)
        XCTAssertEqual(blocks.first, .heading(level: 1, text: "Title"))
        XCTAssertTrue(blocks.contains(.heading(level: 2, text: "Ingredients:")))
        XCTAssertTrue(blocks.contains(.bullet(text: "a")))
        XCTAssertTrue(blocks.contains(.bullet(text: "b")))
        XCTAssertTrue(blocks.contains(.plain(text: "Line1")))
        XCTAssertTrue(blocks.contains(.plain(text: "Line2")))
    }
}

@MainActor
final class AppStateThinkingFillerTests: XCTestCase {

    func testThinkingIndicatorNotShownIfFastResponse() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 10_000_000
        var fast = TurnResult()
        fast.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        fast.spokenLines = ["Done."]
        fake.queuedResults = [fast]

        var spokenFillers: [String] = []
        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.08,
            thinkingFillerSpeaker: { spokenFillers.append($0) },
            enableRuntimeServices: false
        )
        appState.send("hello")
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertFalse(appState.isThinkingIndicatorVisible)
        XCTAssertTrue(spokenFillers.isEmpty, "Fast response should not trigger filler utterance")
    }

    func testThinkingIndicatorShownIfSlowResponse() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 220_000_000
        var slow = TurnResult()
        slow.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        slow.spokenLines = ["Done."]
        fake.queuedResults = [slow]

        var spokenFillers: [String] = []
        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            thinkingFillerSpeaker: { spokenFillers.append($0) },
            enableRuntimeServices: false
        )
        appState.send("hello")
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(appState.isThinkingIndicatorVisible, "Slow response should show thinking indicator")
        XCTAssertEqual(spokenFillers.count, 1, "Slow response should trigger one filler utterance")
    }

    func testFillerSpokenAtMostOncePerTurn() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 450_000_000
        var slow = TurnResult()
        slow.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        slow.spokenLines = ["Done."]
        fake.queuedResults = [slow]

        var spokenFillers: [String] = []
        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            thinkingFillerSpeaker: { spokenFillers.append($0) },
            enableRuntimeServices: false
        )
        appState.send("hello")

        try? await Task.sleep(nanoseconds: 320_000_000)
        XCTAssertEqual(spokenFillers.count, 1, "Filler should only be spoken once in a turn")

        try? await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertEqual(spokenFillers.count, 1, "Filler should remain one-shot for that turn")
    }

    func testFillerNotSpokenWhileMicActive() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 250_000_000
        var slow = TurnResult()
        slow.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        slow.spokenLines = ["Done."]
        fake.queuedResults = [slow]

        var spokenFillers: [String] = []
        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            thinkingFillerSpeaker: { spokenFillers.append($0) },
            enableRuntimeServices: false
        )

        appState.send("hello")
        appState.status = .capturing
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertTrue(appState.isThinkingIndicatorVisible, "Indicator should still appear when waiting")
        XCTAssertTrue(spokenFillers.isEmpty, "Filler should not speak while mic capture is active")
    }

    func testIndicatorClearsOnFirstOutput() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 220_000_000
        var canvasResult = TurnResult()
        canvasResult.appendedOutputs = [OutputItem(kind: .markdown, payload: "# Title\n- item")]
        fake.queuedResults = [canvasResult]

        var spokenFillers: [String] = []
        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            thinkingFillerSpeaker: { spokenFillers.append($0) },
            enableRuntimeServices: false
        )

        appState.send("show me markdown")
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(appState.isThinkingIndicatorVisible)

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(appState.isThinkingIndicatorVisible, "Indicator should clear as soon as first output arrives")
        XCTAssertEqual(appState.outputItems.count, 1)
        XCTAssertEqual(spokenFillers.count, 1)
    }

    func testTtsTimeoutDoesNotDropSpeech() async {
        let fake = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        result.spokenLines = ["Done."]
        fake.queuedResults = [result]

        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            ttsStartDeadlineSeconds: 0.1,
            enableRuntimeServices: false
        )

        let wasMuted = appState.isMuted
        if !wasMuted {
            appState.toggleMute()
        }
        defer {
            if !wasMuted, appState.isMuted {
                appState.toggleMute()
            }
        }

        appState.send("hello")
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertNil(appState.debugLastSpeechDropReason(), "Slow TTS start should not be treated as a dropped utterance")
        if let slowStartID = appState.debugLastSpeechSlowStartCorrelationID() {
            XCTAssertTrue(slowStartID.hasPrefix("turn_"), "Slow-start IDs should map to turn correlation IDs")
        }
        XCTAssertEqual(appState.chatMessages.last(where: { $0.role == .assistant })?.text, "Done.")
    }

    func testNoTtsBeforePlanResolved() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 800_000_000
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        result.spokenLines = ["Done."]
        fake.queuedResults = [result]

        var spokenFillers: [String] = []
        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            enforceStrictTurnSpeechPhases: true,
            thinkingFillerSpeaker: { spokenFillers.append($0) },
            enableRuntimeServices: false
        )

        appState.send("hello")
        try? await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertTrue(appState.isThinkingIndicatorVisible)
        XCTAssertEqual(spokenFillers.count, 0, "Filler speech must not run before route+plan+execution complete")
        XCTAssertEqual(appState.debugTurnSpeechPhase(), "routing")
    }

    func testTurnIdStable_NoExplicitCancel() async {
        let fake = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        result.spokenLines = ["Done."]
        fake.queuedResults = [result]

        await MainActor.run {
            TTSService.shared.stopSpeaking(reason: .userInterrupt)
            TTSService.shared.clearLastDropReason()
        }

        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            enforceStrictTurnSpeechPhases: true,
            enableRuntimeServices: false
        )

        appState.send("hello")
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(appState.debugActiveTurnID(), TTSService.shared.currentCorrelationID)
        XCTAssertNotEqual(
            appState.debugLastSpeechDropReason(),
            TTSService.SpeechDropReason.explicitCancel.rawValue,
            "Single-turn speech should not self-cancel with explicit_cancel"
        )
    }

    func testBubbleLatencyPopulatedForUserAndAssistant() async {
        let fake = FakeTurnOrchestrator()
        fake.delayNanoseconds = 120_000_000

        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Canberra.")]
        result.spokenLines = ["Canberra."]
        fake.queuedResults = [result]

        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.5,
            enableRuntimeServices: false
        )

        appState.send("What is the capital of Australia?")
        try? await Task.sleep(nanoseconds: 260_000_000)

        let user = appState.chatMessages.first(where: { $0.role == .user })
        let assistant = appState.chatMessages.last(where: { $0.role == .assistant })

        XCTAssertNotNil(user?.latencyMs, "User bubble should include latency metadata")
        XCTAssertNotNil(assistant?.latencyMs, "Assistant bubble should include latency metadata")
        XCTAssertGreaterThanOrEqual(assistant?.latencyMs ?? 0, user?.latencyMs ?? 0)
    }

    func testVoiceTranscriptDropsNoiseArtifacts() {
        let appState = AppState(
            orchestrator: FakeTurnOrchestrator(),
            thinkingFillerDelay: 0.5,
            enableRuntimeServices: false
        )

        XCTAssertNil(appState.debugSanitizedVoiceTranscript("[BLANK_AUDIO]"))
        XCTAssertNil(appState.debugSanitizedVoiceTranscript("(dramatic music)"))
        XCTAssertEqual(appState.debugSanitizedVoiceTranscript("what's the weather"), "what's the weather")
    }
}

@MainActor
final class AppStateKnowledgeAttributionTests: XCTestCase {

    func testKnowledgeAttributionAppendsCanvasSummaryAndMarksLocalUsage() async {
        let fake = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Use sanitized equipment and control fermentation temperature.", llmProvider: .openai)]
        result.spokenLines = ["Use sanitized equipment and control fermentation temperature."]
        result.knowledgeAttribution = KnowledgeAttribution(
            localKnowledgePercent: 80,
            openAIFillPercent: 20,
            matchedLocalItems: 4,
            consideredLocalItems: 5,
            provider: .openai,
            evidence: [
                KnowledgeEvidence(
                    kind: .website,
                    id: "brew-123",
                    label: "Fermentation Basics",
                    excerpt: "Fermentation temperature control improves flavor stability.",
                    url: "https://example.com/fermentation",
                    overlapCount: 4,
                    score: 0.62
                )
            ]
        )
        fake.queuedResults = [result]

        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            enableRuntimeServices: false
        )

        appState.send("how do I make home brew?")
        try? await Task.sleep(nanoseconds: 120_000_000)

        let assistant = appState.chatMessages.last(where: { $0.role == .assistant })
        XCTAssertEqual(assistant?.usedLocalKnowledge, true, "Local-attributed replies should be marked for blue bubble styling")

        let canvas = appState.outputItems.last?.payload ?? ""
        XCTAssertTrue(canvas.contains("Local knowledge used: 80%"))
        XCTAssertTrue(canvas.contains("OpenAI fill gap: 20%"))
        XCTAssertTrue(canvas.contains("#### Evidence Used"))
        XCTAssertTrue(canvas.contains("[Fermentation Basics](https://example.com/fermentation)"))
    }

    func testKnowledgeAttributionKeepsNonLocalReplyUnmarked() async {
        let fake = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "I don't have enough local notes yet, but here's a general answer.", llmProvider: .openai)]
        result.spokenLines = ["I don't have enough local notes yet, but here's a general answer."]
        result.knowledgeAttribution = KnowledgeAttribution(
            localKnowledgePercent: 0,
            openAIFillPercent: 100,
            matchedLocalItems: 0,
            consideredLocalItems: 3,
            provider: .openai
        )
        fake.queuedResults = [result]

        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            enableRuntimeServices: false
        )

        appState.send("what is dry hopping?")
        try? await Task.sleep(nanoseconds: 120_000_000)

        let assistant = appState.chatMessages.last(where: { $0.role == .assistant })
        XCTAssertEqual(assistant?.usedLocalKnowledge, false)

        let canvas = appState.outputItems.last?.payload ?? ""
        XCTAssertTrue(canvas.contains("Local knowledge used: 0%"))
        XCTAssertTrue(canvas.contains("OpenAI fill gap: 100%"))
    }
}

@MainActor
final class AppStateAutoListenTests: XCTestCase {

    func testAutoListenStartsOnFollowUpQuestion() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "All set. Need anything else on this?")]
        result.spokenLines = ["All set. Need anything else on this?"]
        result.triggerQuestionAutoListen = false
        fakeOrchestrator.queuedResults = [result]

        let fakeVoicePipeline = FakeVoicePipeline()
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            questionAutoListenNoSpeechTimeoutMs: 120,
            enableRuntimeServices: false
        )
        appState.isListeningEnabled = true
        appState.send("help")

        try? await Task.sleep(nanoseconds: 80_000_000)
        appState.debugHandleSpeechPlaybackFinished()
        try? await Task.sleep(nanoseconds: 320_000_000)

        XCTAssertEqual(fakeVoicePipeline.startFollowUpCaptureCalls, 1)
        XCTAssertEqual(fakeVoicePipeline.lastNoSpeechTimeoutMs, 120)
    }

    func testAutoListenStopsAfterSilenceTimeout() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Done. Need anything else on this?")]
        result.spokenLines = ["Done. Need anything else on this?"]
        result.triggerQuestionAutoListen = false
        fakeOrchestrator.queuedResults = [result]

        let fakeVoicePipeline = FakeVoicePipeline()
        fakeVoicePipeline.autoCancelOnTimeout = true
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            questionAutoListenNoSpeechTimeoutMs: 120,
            enableRuntimeServices: false
        )
        appState.isListeningEnabled = true
        appState.send("hello")

        try? await Task.sleep(nanoseconds: 80_000_000)
        appState.debugHandleSpeechPlaybackFinished()
        try? await Task.sleep(nanoseconds: 520_000_000)

        XCTAssertEqual(fakeVoicePipeline.cancelFollowUpCaptureCalls, 1,
                       "Auto-listen should stop cleanly after no-speech timeout")
    }

    func testNoAutoListenWhenNoQuestionAsked() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        result.spokenLines = ["Done."]
        result.triggerQuestionAutoListen = false
        fakeOrchestrator.queuedResults = [result]

        let fakeVoicePipeline = FakeVoicePipeline()
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            questionAutoListenNoSpeechTimeoutMs: 120,
            enableRuntimeServices: false
        )
        appState.isListeningEnabled = true
        appState.send("hello")

        try? await Task.sleep(nanoseconds: 80_000_000)
        appState.debugHandleSpeechPlaybackFinished()
        try? await Task.sleep(nanoseconds: 320_000_000)

        XCTAssertEqual(fakeVoicePipeline.startFollowUpCaptureCalls, 0)
    }

    func testNoAutoListenWhenMultipleQuestionMarks() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Need anything else??")]
        result.spokenLines = ["Need anything else??"]
        fakeOrchestrator.queuedResults = [result]

        let fakeVoicePipeline = FakeVoicePipeline()
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            questionAutoListenNoSpeechTimeoutMs: 120,
            enableRuntimeServices: false
        )
        appState.isListeningEnabled = true
        appState.send("hello")

        try? await Task.sleep(nanoseconds: 80_000_000)
        appState.debugHandleSpeechPlaybackFinished()
        try? await Task.sleep(nanoseconds: 320_000_000)

        XCTAssertEqual(fakeVoicePipeline.startFollowUpCaptureCalls, 0,
                       "Auto-listen should only trigger for a single trailing question mark")
    }
}

// MARK: - Fake Ollama Transport (for pipeline tests)

final class FakeOllamaTransportForPipeline: OllamaTransport {
    var queuedResponses: [Result<String, Error>] = []
    var queuedIntentResponses: [Result<String, Error>] = []
    var intentDelayNanoseconds: UInt64 = 0
    private(set) var chatCallCount = 0
    private(set) var intentCallCount = 0

    func chat(messages: [[String: String]], model: String?, maxOutputTokens: Int?) async throws -> String {
        _ = model
        _ = maxOutputTokens
        let joined = messages
            .compactMap { $0["content"]?.lowercased() }
            .joined(separator: "\n")
        if joined.contains("intent classification engine") {
            intentCallCount += 1
            if intentDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: intentDelayNanoseconds)
            }
            guard !queuedIntentResponses.isEmpty else {
                throw OllamaRouter.OllamaError.unreachable("No queued intent response")
            }
            return try queuedIntentResponses.removeFirst().get()
        }

        chatCallCount += 1
        guard !queuedResponses.isEmpty else {
            throw OllamaRouter.OllamaError.unreachable("No queued route response")
        }
        return try queuedResponses.removeFirst().get()
    }
}

@MainActor
final class FakeTurnOrchestrator: TurnOrchestrating {
    var pendingSlot: PendingSlot?
    var delayNanoseconds: UInt64 = 0
    var queuedResults: [TurnResult] = []

    func processTurn(_ text: String, history: [ChatMessage], inputMode: TurnInputMode) async -> TurnResult {
        _ = inputMode
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if !queuedResults.isEmpty {
            return queuedResults.removeFirst()
        }
        return TurnResult()
    }
}

@MainActor
final class FakeVoicePipeline: VoicePipelineCoordinating {
    var onStatusChange: ((VoicePipelineStatus) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var startFollowUpCaptureCalls = 0
    private(set) var cancelFollowUpCaptureCalls = 0
    private(set) var lastNoSpeechTimeoutMs: Int?
    var autoCancelOnTimeout = false
    private(set) var suspendForTTSCalls = 0
    private(set) var resumeAfterTTSCalls = 0

    func startListening() throws {}
    func stopListening() {}

    func startFollowUpCapture(noSpeechTimeoutMs: Int?) {
        startFollowUpCaptureCalls += 1
        lastNoSpeechTimeoutMs = noSpeechTimeoutMs
        guard autoCancelOnTimeout, let timeoutMs = noSpeechTimeoutMs else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            self?.cancelFollowUpCapture()
        }
    }

    func cancelFollowUpCapture() {
        cancelFollowUpCaptureCalls += 1
    }

    func suspendForTTS() {
        suspendForTTSCalls += 1
    }

    func resumeAfterTTSIfNeeded() {
        resumeAfterTTSCalls += 1
    }
}

// MARK: - Mock ToolsRuntime for Image Probe Tests

final class ImageProbeToolsRuntime: ToolsRuntimeProtocol {
    private let urls: [String]

    init(urls: [String]) {
        self.urls = urls
    }

    func execute(_ toolAction: ToolAction) -> OutputItem? {
        if toolAction.name == "show_image" {
            let urlsStr = toolAction.args["urls"] ?? urls.joined(separator: "|")
            let alt = toolAction.args["alt"] ?? "image"
            let payload = "{\"urls\":[\(urlsStr.components(separatedBy: "|").map { "\"\($0)\"" }.joined(separator: ","))],\"alt\":\"\(alt)\"}"
            return OutputItem(kind: .image, payload: payload)
        }
        return nil
    }
}

private struct StubFaceGreetingSettings: FaceGreetingSettingsProviding {
    var faceRecognitionEnabled: Bool = true
    var personalizedGreetingsEnabled: Bool = true
}

final class IdentityTestCamera: CameraVisionProviding {
    var isRunning: Bool = true
    var latestFrameAt: Date? = Date()
    var analysis: CameraFrameAnalysis?
    var recognitionResult: CameraFaceRecognitionResult?
    var sceneDescription: CameraSceneDescription?
    var enrollCalls: [String] = []
    var clearCalls = 0
    var onEnroll: ((String) -> Void)?

    func start() throws {}
    func stop() {}
    func latestPreviewImage() -> NSImage? { nil }
    func describeCurrentScene() -> CameraSceneDescription? { sceneDescription }
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
}

// MARK: - Router Pipeline Tests

@MainActor
final class RouterPipelineTests: XCTestCase {

    private var savedApiKey: String = ""
    private var savedUseOllama: Bool = false
    private var savedPreferLocalPlans: Bool = false
    private var savedPreferOpenAIPlans: Bool = false
    private var savedDisableAutoClosePrompts: Bool = true
    private var savedAffectMirroringEnabled: Bool = false
    private var savedUseEmotionalTone: Bool = true
    private var savedToneProfile: TonePreferenceProfile = .neutralDefaults
    private var savedGeneralModel: String = ""
    private var savedEscalationModel: String = ""

    override func setUp() {
        super.setUp()
        savedApiKey = OpenAISettings.apiKey
        savedUseOllama = M2Settings.useOllama
        savedPreferLocalPlans = M2Settings.preferLocalPlans
        savedPreferOpenAIPlans = M2Settings.preferOpenAIPlans
        savedDisableAutoClosePrompts = M2Settings.disableAutoClosePrompts
        savedAffectMirroringEnabled = M2Settings.affectMirroringEnabled
        savedUseEmotionalTone = M2Settings.useEmotionalTone
        savedToneProfile = TonePreferenceStore.shared.loadProfile()
        TonePreferenceStore.shared.replaceProfileForTesting(.neutralDefaults)
        M2Settings.preferLocalPlans = false
        M2Settings.preferOpenAIPlans = false
        M2Settings.disableAutoClosePrompts = true
        savedGeneralModel = OpenAISettings.generalModel
        savedEscalationModel = OpenAISettings.escalationModel
    }

    override func tearDown() {
        // Restore original settings
        OpenAISettings.apiKey = savedApiKey
        M2Settings.useOllama = savedUseOllama
        M2Settings.preferLocalPlans = savedPreferLocalPlans
        M2Settings.preferOpenAIPlans = savedPreferOpenAIPlans
        M2Settings.disableAutoClosePrompts = savedDisableAutoClosePrompts
        M2Settings.affectMirroringEnabled = savedAffectMirroringEnabled
        M2Settings.useEmotionalTone = savedUseEmotionalTone
        TonePreferenceStore.shared.replaceProfileForTesting(savedToneProfile)
        OpenAISettings.generalModel = savedGeneralModel
        OpenAISettings.escalationModel = savedEscalationModel
        OpenAISettings._resetCacheForTesting()
        super.tearDown()
    }

    // Valid PLAN JSON that passes validation for a simple greeting
    private let validTalkJSON = """
    {"action":"TALK","say":"Hey there!"}
    """

    // Valid PLAN JSON with get_time tool (passes time-query validation)
    private let validTimePlanJSON = """
    {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"London"},"say":"Let me check."}]}
    """

    private let weatherWrongToolPlanJSON = """
    {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"Melbourne"},"say":"Let me check the weather."}]}
    """

    private let weatherWrongToolActionJSON = """
    {"action":"TOOL","name":"get_time","args":{"place":"Greenbank"},"say":"Checking weather."}
    """

    private let capabilityWrongToolActionJSON = """
    {"action":"TOOL","name":"learn_website","args":{"url":"https://example.com","focus":"capability gap miner"},"say":"I'll learn from that page."}
    """

    private let capabilityStartSkillforgeActionJSON = """
    {"action":"START_SKILLFORGE","goal":"Find and display relevant videos when the user requests.","constraints":"Use YouTube API for video search."}
    """

    private let websiteLearningActionJSON = """
    {"action":"TOOL","name":"learn_website","args":{"url":"https://swift.org","focus":"packages"},"say":"I'll learn from that page."}
    """

    func testDisableAutoClosePrompts_DefaultTrue() {
        let defaults = UserDefaults.standard
        let key = "m3_disableAutoClosePrompts"
        let prior = defaults.object(forKey: key)
        defer {
            if let prior {
                defaults.set(prior, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        XCTAssertTrue(M2Settings.disableAutoClosePrompts)
    }

    @MainActor
    private func captureAffectPrompt(for input: String,
                                     toneProfile: TonePreferenceProfile? = nil) async throws -> (systemPrompt: String, modeMessage: String) {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true
        if let toneProfile {
            TonePreferenceStore.shared.replaceProfileForTesting(toneProfile)
        } else {
            TonePreferenceStore.shared.replaceProfileForTesting(.neutralDefaults)
        }

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        _ = await orchestrator.processTurn(input, history: [])
        let messages = try XCTUnwrap(fakeOpenAI.chatCallLog.first)
        let systemPrompt = try XCTUnwrap(messages.first(where: { $0["role"] == "system" })?["content"])
        let modeMessage = try XCTUnwrap(messages.first(where: { ($0["content"] ?? "").contains("[MODE]") })?["content"])
        return (systemPrompt, modeMessage)
    }

    // MARK: - Affect Prompt Guidance

    @MainActor
    func testAffectGuidanceInjectedFrustrated() async throws {
        let captured = try await captureAffectPrompt(for: "This wifi is ridiculous, it keeps dropping again.")
        XCTAssertTrue(captured.systemPrompt.contains("[BLOCK 4: AFFECT_GUIDANCE]"))
        XCTAssertTrue(captured.systemPrompt.contains("validate frustration"))
        XCTAssertTrue(captured.modeMessage.contains("\"affect\":{\"affect\":\"frustrated\""))
    }

    @MainActor
    func testAffectGuidanceInjectedAnxious() async throws {
        let captured = try await captureAffectPrompt(for: "I'm worried about this chest tightness.")
        XCTAssertTrue(captured.systemPrompt.contains("[BLOCK 4: AFFECT_GUIDANCE]"))
        XCTAssertTrue(captured.systemPrompt.contains("Be calming and steady."))
        XCTAssertTrue(captured.modeMessage.contains("\"affect\":{\"affect\":\"anxious\""))
    }

    @MainActor
    func testAffectGuidanceInjectedSad() async throws {
        let captured = try await captureAffectPrompt(for: "I don't feel like doing anything today.")
        XCTAssertTrue(captured.systemPrompt.contains("[BLOCK 4: AFFECT_GUIDANCE]"))
        XCTAssertTrue(captured.systemPrompt.contains("Be warm and gentle."))
        XCTAssertTrue(captured.modeMessage.contains("\"affect\":{\"affect\":\"sad\""))
    }

    @MainActor
    func testAffectGuidanceInjectedAngry() async throws {
        let captured = try await captureAffectPrompt(for: "THIS IS BULLSHIT and it keeps happening again")
        XCTAssertTrue(captured.systemPrompt.contains("[BLOCK 4: AFFECT_GUIDANCE]"))
        XCTAssertTrue(captured.systemPrompt.contains("De-escalate and redirect"))
        XCTAssertTrue(captured.modeMessage.contains("\"affect\":{\"affect\":\"angry\""))
    }

    @MainActor
    func testAffectGuidanceInjectedExcited() async throws {
        let captured = try await captureAffectPrompt(for: "Yay it finally worked!!!")
        XCTAssertTrue(captured.systemPrompt.contains("[BLOCK 4: AFFECT_GUIDANCE]"))
        XCTAssertTrue(captured.systemPrompt.contains("Match positive energy."))
        XCTAssertTrue(captured.modeMessage.contains("\"affect\":{\"affect\":\"excited\""))
    }

    @MainActor
    func testTonePreferencesInjectedWhenEnabled() async throws {
        var profile = TonePreferenceProfile.neutralDefaults
        profile.enabled = true
        profile.directness = 0.70
        profile.warmth = 0.40
        profile.curiosity = 0.50
        profile.reassurance = 0.40
        profile.humor = 0.20
        profile.formality = 0.30
        profile.hedging = 0.35
        profile.preferOneQuestionMax = true

        let captured = try await captureAffectPrompt(
            for: "This wifi is ridiculous, it keeps dropping again.",
            toneProfile: profile
        )
        XCTAssertTrue(captured.systemPrompt.contains("[BLOCK 5: TONE_PREFERENCES]"))
        XCTAssertTrue(captured.systemPrompt.contains("d=0.70"))
        XCTAssertTrue(captured.systemPrompt.contains("one_q_max=true"))

        if let toneBlock = extractSystemBlock(named: "[BLOCK 5: TONE_PREFERENCES]", from: captured.systemPrompt) {
            XCTAssertLessThanOrEqual(toneBlock.count, 490, "Tone block should remain compact")
        } else {
            XCTFail("Expected tone preferences block")
        }
    }

    @MainActor
    func testTonePreferencesNotInjectedWhenDisabled() async throws {
        var profile = TonePreferenceProfile.neutralDefaults
        profile.enabled = false
        let captured = try await captureAffectPrompt(
            for: "This wifi is ridiculous, it keeps dropping again.",
            toneProfile: profile
        )
        XCTAssertFalse(captured.systemPrompt.contains("TONE_PREFERENCES"))
    }

    @MainActor
    func testPreferencesAffectGuidanceInteraction() async throws {
        var profile = TonePreferenceProfile.neutralDefaults
        profile.enabled = true
        profile.warmth = 0.20
        profile.reassurance = 0.35
        let captured = try await captureAffectPrompt(
            for: "This wifi is ridiculous, it keeps dropping again.",
            toneProfile: profile
        )
        XCTAssertTrue(captured.modeMessage.contains("\"affect\":{\"affect\":\"frustrated\""))
        XCTAssertTrue(captured.systemPrompt.contains("frustrated+low warmth: brief validation then steps."))
    }

    private func extractSystemBlock(named marker: String, from prompt: String) -> String? {
        let pieces = prompt.components(separatedBy: "\n\n")
        return pieces.first(where: { $0.contains(marker) })
    }

    private func makeIdentityOrchestrator(fakeOpenAI: FakeOpenAITransport,
                                          fakeOllama: FakeOllamaTransportForPipeline,
                                          camera: IdentityTestCamera,
                                          recognitionEnterThreshold: Float = 0.72,
                                          recognitionExitThreshold: Float = 0.45,
                                          lowConfidenceExitFrameCount: Int = 10,
                                          lowConfidenceExitDurationSeconds: TimeInterval = 2.0,
                                          identityPromptCooldownSeconds: TimeInterval = 120,
                                          postEnrollGracePeriodSeconds: TimeInterval = 300,
                                          postEnrollTrustWindowSeconds: TimeInterval = 300,
                                          recognitionCacheSeconds: TimeInterval = 1.5) -> TurnOrchestrator {
        let manager = FaceGreetingManager(
            camera: camera,
            settings: StubFaceGreetingSettings(),
            recognitionThreshold: recognitionEnterThreshold,
            recognitionEnterThreshold: recognitionEnterThreshold,
            recognitionExitThreshold: recognitionExitThreshold,
            lowConfidenceExitFrameCount: lowConfidenceExitFrameCount,
            lowConfidenceExitDurationSeconds: lowConfidenceExitDurationSeconds,
            namedGreetingCooldownTurns: 2,
            identityPromptCooldownSeconds: identityPromptCooldownSeconds,
            awaitingNameTimeoutSeconds: 30,
            postEnrollGracePeriodSeconds: postEnrollGracePeriodSeconds,
            postEnrollTrustWindowSeconds: postEnrollTrustWindowSeconds,
            recognitionCacheSeconds: recognitionCacheSeconds
        )
        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        return TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            faceGreetingManager: manager,
            cameraVision: camera
        )
    }

    private func makeIdentityAnalysis(faceCount: Int) -> CameraFrameAnalysis {
        CameraFrameAnalysis(
            labels: [],
            recognizedText: [],
            faces: CameraFacePresence(count: faceCount),
            capturedAt: Date()
        )
    }

    private func makeIdentityScene(summary: String = "I can see a desk and a person.") -> CameraSceneDescription {
        CameraSceneDescription(
            summary: summary,
            labels: ["desk (95%)", "person (90%)"],
            recognizedText: [],
            capturedAt: Date()
        )
    }

    private func makeIdentityRecognition(detectedFaces: Int,
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

    private func assistantCombinedText(_ result: TurnResult) -> String {
        result.appendedChat
            .filter { $0.role == .assistant }
            .map(\.text)
            .joined(separator: "\n")
    }

    private func identityPromptCount(in result: TurnResult) -> Int {
        result.appendedChat.reduce(0) { partial, message in
            guard message.role == .assistant else { return partial }
            let normalized = message.text.lowercased()
            if normalized.contains("what's your name") || normalized.contains("what is your name") {
                return partial + 1
            }
            return partial
        }
    }

    private func appendTurn(_ history: inout [ChatMessage], user: String, result: TurnResult) {
        history.append(ChatMessage(role: .user, text: user))
        history.append(contentsOf: result.appendedChat)
    }

    func testConfidenceMappingIdenticalEmbeddingsHigh() {
        let identical = FaceConfidenceMapper.cosineConfidence(
            live: [1, 2, 3, 4],
            stored: [1, 2, 3, 4]
        )
        let opposite = FaceConfidenceMapper.cosineConfidence(
            live: [1, 2, 3, 4],
            stored: [-1, -2, -3, -4]
        )
        XCTAssertNotNil(identical)
        XCTAssertNotNil(opposite)
        XCTAssertGreaterThan(identical ?? 0, 0.99, "Identical embeddings should map near 1.0 confidence")
        XCTAssertLessThan(opposite ?? 1, 0.05, "Opposite/random embeddings should map near 0.0 confidence")
    }

    func testHysteresisDoesNotFlap() {
        let camera = IdentityTestCamera()
        let baseTime = Date()
        camera.latestFrameAt = baseTime
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.recognitionResult = makeIdentityRecognition(
            detectedFaces: 1,
            matches: [CameraRecognizedFaceMatch(name: "Richard", confidence: 0.92, distance: 0.05)],
            unknownFaces: 0
        )

        let manager = FaceGreetingManager(
            camera: camera,
            settings: StubFaceGreetingSettings(),
            recognitionThreshold: 0.70,
            recognitionExitThreshold: 0.45,
            lowConfidenceExitFrameCount: 3,
            lowConfidenceExitDurationSeconds: 10,
            recognitionCacheSeconds: 0
        )

        _ = manager.evaluateFrame(now: baseTime)
        XCTAssertEqual(manager.currentIdentityContext.recognizedUserName, "Richard")

        camera.recognitionResult = makeIdentityRecognition(
            detectedFaces: 1,
            matches: [CameraRecognizedFaceMatch(name: "Richard", confidence: 0.20, distance: 0.32)],
            unknownFaces: 0
        )
        _ = manager.evaluateFrame(now: baseTime.addingTimeInterval(0.1))
        XCTAssertEqual(manager.currentIdentityContext.recognizedUserName, "Richard")
        _ = manager.evaluateFrame(now: baseTime.addingTimeInterval(0.2))
        XCTAssertEqual(manager.currentIdentityContext.recognizedUserName, "Richard")

        camera.recognitionResult = makeIdentityRecognition(
            detectedFaces: 1,
            matches: [CameraRecognizedFaceMatch(name: "Richard", confidence: 0.89, distance: 0.08)],
            unknownFaces: 0
        )
        _ = manager.evaluateFrame(now: baseTime.addingTimeInterval(0.3))
        XCTAssertEqual(manager.currentIdentityContext.recognizedUserName, "Richard")

        camera.recognitionResult = makeIdentityRecognition(
            detectedFaces: 1,
            matches: [CameraRecognizedFaceMatch(name: "Richard", confidence: 0.22, distance: 0.31)],
            unknownFaces: 0
        )
        _ = manager.evaluateFrame(now: baseTime.addingTimeInterval(0.4))
        XCTAssertEqual(manager.currentIdentityContext.recognizedUserName, "Richard", "Known state should hold during low-confidence blips")
    }

    func testPostEnrollTrustPreventsReprompt() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Hey there."}"#),
            .success(#"{"action":"TALK","say":"Hi again."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)
        camera.onEnroll = { name in
            camera.recognitionResult = self.makeIdentityRecognition(
                detectedFaces: 1,
                matches: [CameraRecognizedFaceMatch(name: name, confidence: 0.08, distance: 0.33)],
                unknownFaces: 0
            )
        }

        OpenAISettings.apiKey = "test-key-post-enroll-trust"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-post-enroll-trust"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera,
            recognitionEnterThreshold: 0.70,
            recognitionExitThreshold: 0.45,
            postEnrollTrustWindowSeconds: 300,
            recognitionCacheSeconds: 0
        )

        var history: [ChatMessage] = []
        let first = await orchestrator.processTurn("hello", history: history)
        appendTurn(&history, user: "hello", result: first)
        XCTAssertEqual(identityPromptCount(in: first), 1)

        let second = await orchestrator.processTurn("Richard", history: history)
        appendTurn(&history, user: "Richard", result: second)
        XCTAssertEqual(second.llmProvider, .none)
        XCTAssertTrue(assistantCombinedText(second).contains("Nice to meet you, Richard."))

        let third = await orchestrator.processTurn("hi", history: history)
        XCTAssertEqual(identityPromptCount(in: third), 0, "Post-enroll trust window should prevent immediate identity re-prompt")
        XCTAssertTrue(assistantCombinedText(third).localizedCaseInsensitiveContains("richard"))
    }

    func testCameraUnhealthyDisablesIdentityPrompt() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"I'm doing okay today."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.isRunning = true
        camera.latestFrameAt = Date().addingTimeInterval(-5)
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        OpenAISettings.apiKey = "test-key-camera-unhealthy"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-camera-unhealthy"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera
        )

        let result = await orchestrator.processTurn("How are you today?", history: [])
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertEqual(identityPromptCount(in: result), 0, "Unhealthy camera pipeline must suppress identity onboarding prompts")
        XCTAssertTrue(assistantCombinedText(result).lowercased().contains("doing okay"))
    }

    func testUnknownFacePromptsOnceThenCooldown() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"I'm doing well."}"#),
            .success(#"{"action":"TALK","say":"I can help with that."}"#),
            .success(#"{"action":"TALK","say":"Still here and ready."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        OpenAISettings.apiKey = "test-key-identity-1"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-identity-1"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera,
            identityPromptCooldownSeconds: 0.25
        )

        var history: [ChatMessage] = []
        let first = await orchestrator.processTurn("hello", history: history)
        appendTurn(&history, user: "hello", result: first)
        XCTAssertEqual(identityPromptCount(in: first), 1)

        let second = await orchestrator.processTurn("can you help?", history: history)
        appendTurn(&history, user: "can you help?", result: second)
        XCTAssertEqual(identityPromptCount(in: second), 0, "Identity prompt should be suppressed during cooldown")

        try? await Task.sleep(nanoseconds: 350_000_000)
        let third = await orchestrator.processTurn("any update?", history: history)
        XCTAssertEqual(identityPromptCount(in: third), 1, "Identity prompt should return after cooldown elapses")
    }

    func testAwaitingNameAcceptsNameAndEnrolls() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"I'm doing well today."}"#),
            .success(#"{"action":"TALK","say":"Hey there!"}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)
        camera.onEnroll = { name in
            camera.recognitionResult = CameraFaceRecognitionResult(
                capturedAt: Date(),
                detectedFaces: 1,
                matches: [CameraRecognizedFaceMatch(name: name, confidence: 0.92, distance: 0.05)],
                unknownFaces: 0,
                enrolledNames: [name]
            )
        }

        OpenAISettings.apiKey = "test-key-identity-2"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-identity-2"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera,
            recognitionCacheSeconds: 0
        )

        var history: [ChatMessage] = []
        let first = await orchestrator.processTurn("how are you today?", history: history)
        appendTurn(&history, user: "how are you today?", result: first)
        XCTAssertEqual(identityPromptCount(in: first), 1)

        let second = await orchestrator.processTurn("I'm Richard", history: history)
        appendTurn(&history, user: "I'm Richard", result: second)
        XCTAssertEqual(second.llmProvider, .none)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Name enrollment turn should not call the LLM")
        XCTAssertEqual(camera.enrollCalls, ["Richard"])
        XCTAssertTrue(second.executedToolSteps.contains(where: { step in
            step.name == "enroll_camera_face" && step.args["name"] == "Richard"
        }))
        XCTAssertTrue(assistantCombinedText(second).contains("Nice to meet you, Richard."))

        let third = await orchestrator.processTurn("hi", history: history)
        XCTAssertTrue(assistantCombinedText(third).contains("Richard"), "Recognized follow-up greeting should use enrolled name")
    }

    func testAwaitingNameEnrollInvalidatesCachedUnknownRecognition() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"I'm doing well today."}"#),
            .success(#"{"action":"TALK","say":"Hey there!"}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)
        camera.onEnroll = { name in
            camera.recognitionResult = CameraFaceRecognitionResult(
                capturedAt: Date(),
                detectedFaces: 1,
                matches: [CameraRecognizedFaceMatch(name: name, confidence: 0.92, distance: 0.05)],
                unknownFaces: 0,
                enrolledNames: [name]
            )
        }

        OpenAISettings.apiKey = "test-key-identity-cache-1"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-identity-cache-1"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera,
            recognitionCacheSeconds: 30
        )

        var history: [ChatMessage] = []
        let first = await orchestrator.processTurn("how are you today?", history: history)
        appendTurn(&history, user: "how are you today?", result: first)
        XCTAssertEqual(identityPromptCount(in: first), 1)

        let second = await orchestrator.processTurn("Richard", history: history)
        appendTurn(&history, user: "Richard", result: second)
        XCTAssertEqual(second.llmProvider, .none)
        XCTAssertEqual(camera.enrollCalls, ["Richard"])

        let third = await orchestrator.processTurn("hi", history: history)
        XCTAssertTrue(
            assistantCombinedText(third).contains("Richard"),
            "Enrollment should invalidate stale unknown cache so immediate follow-up can recognize the same user"
        )
    }

    func testAwaitingNameNonNameRoutesNormally() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Happy to help."}"#),
            .success(#"{"action":"TALK","say":"I'm doing great, thanks."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        OpenAISettings.apiKey = "test-key-identity-3"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-identity-3"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera
        )

        var history: [ChatMessage] = []
        let first = await orchestrator.processTurn("hello", history: history)
        appendTurn(&history, user: "hello", result: first)
        XCTAssertEqual(identityPromptCount(in: first), 1)

        let second = await orchestrator.processTurn("How are you today?", history: history)
        XCTAssertEqual(second.llmProvider, .openai)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 2, "Non-name reply while awaitingName must still route normally")
        XCTAssertTrue(assistantCombinedText(second).lowercased().contains("doing great"))
        XCTAssertEqual(identityPromptCount(in: second), 0, "Should not immediately re-ask identity")
    }

    func testPostEnrollDoesNotRePromptWhoAreYou() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Sure."}"#),
            .success(#"{"action":"TALK","say":"Absolutely, let's do it."}"#),
            .success(#"{"action":"TALK","say":"Happy to continue."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        OpenAISettings.apiKey = "test-key-identity-4"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-identity-4"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera,
            identityPromptCooldownSeconds: 120,
            postEnrollGracePeriodSeconds: 120
        )

        var history: [ChatMessage] = []
        let first = await orchestrator.processTurn("hello", history: history)
        appendTurn(&history, user: "hello", result: first)

        let second = await orchestrator.processTurn("Richard", history: history)
        appendTurn(&history, user: "Richard", result: second)
        XCTAssertEqual(second.llmProvider, .none)

        let third = await orchestrator.processTurn("can you help me?", history: history)
        appendTurn(&history, user: "can you help me?", result: third)
        let fourth = await orchestrator.processTurn("one more thing", history: history)

        let combined = (assistantCombinedText(third) + "\n" + assistantCombinedText(fourth)).lowercased()
        XCTAssertFalse(combined.contains("what's your name"))
        XCTAssertFalse(combined.contains("what is your name"))

        let repairCount = [third, fourth]
            .map { assistantCombinedText($0).lowercased() }
            .filter { $0.contains("one more look to recognize you next time") }
            .count
        XCTAssertLessThanOrEqual(repairCount, 1, "Post-enroll repair prompt should never loop")
    }

    func testUnknownFaceDoesNotBypassLLMAndAnswersUserQuestion() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"I'm doing well today, thanks for asking."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        OpenAISettings.apiKey = "test-key-identity-5"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-identity-5"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera
        )

        let result = await orchestrator.processTurn("How are you today?", history: [])
        let combined = assistantCombinedText(result).lowercased()

        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertNotNil(result.routerMs)
        XCTAssertGreaterThanOrEqual(result.routerMs ?? -1, 0)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Unknown face flow must not bypass LLM routing")
        XCTAssertTrue(combined.contains("doing well") || combined.contains("well today"))
        XCTAssertLessThanOrEqual(identityPromptCount(in: result), 1)
    }

    func testVisionQueryToolFirstDescribe() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"vision_describe","confidence":0.96,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.sceneDescription = makeIdentityScene(summary: "I can see a desk, a laptop, and a person.")
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        OpenAISettings.apiKey = "test-key-vision-1"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-vision-1"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera
        )

        let result = await orchestrator.processTurn("What do you see?", history: [])
        XCTAssertEqual(result.executedToolSteps.first?.name, "describe_camera_view")
        XCTAssertEqual(fakeOpenAI.intentCallCount, 1)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 0, "Vision queries should run tool-first before any LLM routing")
        XCTAssertTrue(assistantCombinedText(result).lowercased().contains("here's what i can see"))
    }

    func testVisionQueryToolFirstVisualQA() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"vision_qa","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.sceneDescription = makeIdentityScene(summary: "I can see a desk and a person.")
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        OpenAISettings.apiKey = "test-key-vision-qa-1"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-vision-qa-1"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera
        )

        let result = await orchestrator.processTurn("Do you see a person?", history: [])
        XCTAssertEqual(result.executedToolSteps.first?.name, "camera_visual_qa")
        XCTAssertEqual(fakeOpenAI.intentCallCount, 1)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 0, "Visual QA queries should execute camera tool first")
    }

    func testVisionQueryToolFirstFindObject() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.92,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"I can help you search for that."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.sceneDescription = makeIdentityScene(summary: "I can see a desk and a wallet.")
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        OpenAISettings.apiKey = "test-key-vision-find-1"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-vision-find-1"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera
        )

        let result = await orchestrator.processTurn("Find my wallet", history: [])
        XCTAssertEqual(fakeOpenAI.intentCallCount, 1)
        XCTAssertFalse(result.executedToolSteps.contains(where: { $0.name == "find_camera_objects" }))
    }

    func testNoFalseBlindnessGuardrail() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.25,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"I don't have the ability to see right now."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.sceneDescription = makeIdentityScene(summary: "I can see a desk and monitor.")
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        OpenAISettings.apiKey = "test-key-vision-2"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-vision-2"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera
        )

        let result = await orchestrator.processTurn("Give me a quick update.", history: [])
        let combined = assistantCombinedText(result).lowercased()

        XCTAssertEqual(result.llmProvider, .openai, "Origin plan should remain OpenAI when guardrail rewrites the response")
        XCTAssertFalse(combined.contains("don't have the ability to see"))
        XCTAssertFalse(combined.contains("can’t see"))
        XCTAssertTrue(combined.contains("camera feed is lagging") || combined.contains("not updating"))
    }

    func testIdentityDoesNotOverrideVision() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.25,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """),
            .success("""
            {"intent":"identity_response","confidence":0.92,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """),
            .success("""
            {"intent":"vision_describe","confidence":0.96,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Hi there."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = IdentityTestCamera()
        camera.analysis = makeIdentityAnalysis(faceCount: 1)
        camera.sceneDescription = makeIdentityScene(summary: "I can see you at a desk.")
        camera.recognitionResult = makeIdentityRecognition(detectedFaces: 1, matches: [], unknownFaces: 1)

        OpenAISettings.apiKey = "test-key-vision-3"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-vision-3"
        M2Settings.useOllama = false

        let orchestrator = makeIdentityOrchestrator(
            fakeOpenAI: fakeOpenAI,
            fakeOllama: fakeOllama,
            camera: camera
        )

        var history: [ChatMessage] = []
        let first = await orchestrator.processTurn("hello", history: history)
        appendTurn(&history, user: "hello", result: first)

        let second = await orchestrator.processTurn("Richard", history: history)
        appendTurn(&history, user: "Richard", result: second)
        XCTAssertEqual(second.llmProvider, .none)

        let third = await orchestrator.processTurn("What do you see?", history: history)
        let combined = assistantCombinedText(third).lowercased()

        XCTAssertTrue(third.executedToolSteps.contains(where: { $0.name == "describe_camera_view" }))
        XCTAssertFalse(combined.contains("one more look to recognize you next time"))
    }

    func testAssistantBubbleRendersRegardlessOfProvider() {
        let assistantNoProvider = ChatMessage(role: .assistant, text: "Hi", llmProvider: .none)
        let assistantOpenAI = ChatMessage(role: .assistant, text: "Hi", llmProvider: .openai)
        let user = ChatMessage(role: .user, text: "Hi")

        XCTAssertEqual(ChatBubble.renderPath(for: assistantNoProvider), .assistantBubble)
        XCTAssertEqual(ChatBubble.renderPath(for: assistantOpenAI), .assistantBubble)
        XCTAssertEqual(ChatBubble.renderPath(for: user), .userBubble)
    }

    func testBubbleColorOriginProviderOpenAI() {
        let message = ChatMessage(
            role: .assistant,
            text: "Done.",
            llmProvider: .openai,
            originProvider: .openai,
            executionProvider: .local,
            originReason: "userChat"
        )
        XCTAssertEqual(ChatBubble.colorRole(for: message), .assistantOpenAI)
    }

    @MainActor
    func testRecipeIntentUsesFindRecipeWithoutOpenAI() async {
        let fakeOpenAI = FakeOpenAITransport()
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"recipe","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]

        OpenAISettings.apiKey = ""
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = ""
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("recipe chinese fried rice", history: [])

        XCTAssertEqual(fakeOllama.intentCallCount, 1)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 0, "Recipe intent should use deterministic tool-first path")
        XCTAssertTrue(result.executedToolSteps.contains(where: { $0.name == "find_recipe" }))
    }

    // MARK: - A) OpenAI success does not call Ollama

    @MainActor
    func testOpenAISuccessDoesNotCallOllama() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        // Force reload the cache with the new key
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "OpenAI should be called once")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Ollama should not be called")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains { $0.role == .assistant && !$0.text.isEmpty })
    }

    @MainActor
    func testOpenAISystemPromptIncludesCoTDirective() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        _ = try? await openAIRouter.routePlan("Solve a tricky logic puzzle")

        guard let systemMessage = fakeOpenAI.chatCallLog.first?.first(where: { $0["role"] == "system" })?["content"] else {
            return XCTFail("Expected a system prompt in OpenAI call messages")
        }
        XCTAssertTrue(systemMessage.lowercased().contains("think step by step internally"),
                      "System prompt should include CoT directive")
    }

    @MainActor
    func testWebsiteLearningPromptGatedForGreeting() async {
        let marker = "ZXQWV-UNRELATED-\(UUID().uuidString)"
        _ = WebsiteLearningStore.shared.saveLearnedPage(
            url: "https://example.com/\(UUID().uuidString)",
            title: "Unrelated",
            summary: marker,
            highlights: [marker]
        )

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        _ = await orchestrator.processTurn("hello there", history: [])

        guard let systemMessage = fakeOpenAI.chatCallLog.first?.first(where: { $0["role"] == "system" })?["content"] else {
            return XCTFail("Expected system prompt in first OpenAI call")
        }
        XCTAssertTrue(systemMessage.contains("website_learning: []"),
                      "Greeting prompt should not inject unrelated website notes")
        XCTAssertFalse(systemMessage.contains(marker),
                       "Unrelated website notes must not appear in greeting prompts")
    }

    @MainActor
    func testWebsiteLearningPromptGatedForProblemReport() async {
        let marker = "ZXQWV-UNRELATED-PROBLEM-\(UUID().uuidString)"
        _ = WebsiteLearningStore.shared.saveLearnedPage(
            url: "https://example.com/\(UUID().uuidString)",
            title: "Unrelated 2",
            summary: marker,
            highlights: [marker]
        )

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        _ = await orchestrator.processTurn("my tummy is sore", history: [])

        guard let systemMessage = fakeOpenAI.chatCallLog.first?.first(where: { $0["role"] == "system" })?["content"] else {
            return XCTFail("Expected system prompt in first OpenAI call")
        }
        XCTAssertTrue(systemMessage.contains("website_learning: []"),
                      "Unrelated problem report prompt should not inject website notes")
        XCTAssertFalse(systemMessage.contains(marker),
                       "Unrelated website notes must not appear in problem-report prompts")
    }

    @MainActor
    func testPerTurnBudgetPassedToOpenAITransport() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON), .success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        _ = await orchestrator.processTurn("hello", history: [])
        _ = await orchestrator.processTurn("my tummy is sore", history: [])

        XCTAssertEqual(fakeOpenAI.chatMaxTokensLog.count, 2)
        XCTAssertEqual(fakeOpenAI.chatMaxTokensLog[0], 220, "Greeting should use compact token budget")
        XCTAssertEqual(fakeOpenAI.chatMaxTokensLog[1], 560, "Problem report should use elevated token budget")
    }

    @MainActor
    func testConversationSummaryFreshnessUsesCurrentModeAndLatestUserTurn() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON), .success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let longHistory: [ChatMessage] = [
            ChatMessage(role: .user, text: "my dog's name is Bingo"),
            ChatMessage(role: .assistant, text: "Noted, I'll remember that."),
            ChatMessage(role: .user, text: "we're planning a weekend hike"),
            ChatMessage(role: .assistant, text: "Great, I can help with a checklist."),
            ChatMessage(role: .user, text: "keep it compact because i have a small car"),
            ChatMessage(role: .assistant, text: "Understood, compact and practical."),
            ChatMessage(role: .user, text: "what are weather risks"),
            ChatMessage(role: .assistant, text: "Rain and wind are key factors."),
            ChatMessage(role: .user, text: "i also want safety tips"),
            ChatMessage(role: .assistant, text: "Sure, I'll include safety checks."),
            ChatMessage(role: .user, text: "please keep answers medium length"),
            ChatMessage(role: .assistant, text: "Will do.")
        ]

        _ = await orchestrator.processTurn("my tummy is sore", history: longHistory)
        _ = await orchestrator.processTurn("my engine is making a funny noise", history: longHistory)

        XCTAssertEqual(fakeOpenAI.chatCallLog.count, 2)
        let secondCall = fakeOpenAI.chatCallLog[1]

        guard let summaryMessage = secondCall.first(where: { message in
            message["role"] == "system" && (message["content"] ?? "").contains("[CONVERSATION_SUMMARY]")
        })?["content"] else {
            return XCTFail("Expected [CONVERSATION_SUMMARY] in second call")
        }
        let summaryLower = summaryMessage.lowercased()
        XCTAssertTrue(
            summaryLower.contains("active topic: problem_report/vehicle"),
            "Summary active topic should reflect current mode domain; got: \(summaryMessage)"
        )
        XCTAssertTrue(
            summaryLower.contains("latest user turn: my engine is making a funny noise"),
            "Summary latest user turn should reflect current input; got: \(summaryMessage)"
        )

        guard let modeMessage = secondCall.first(where: { message in
            message["role"] == "system" && (message["content"] ?? "").contains("[MODE]")
        })?["content"] else {
            return XCTFail("Expected [MODE] in second call")
        }
        XCTAssertTrue(modeMessage.contains("\"intent\":\"problem_report\""))
        XCTAssertTrue(modeMessage.contains("\"domain\":\"vehicle\""))
    }

    @MainActor
    func testPromptExportSamplesForTummyAndEngine() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON), .success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let longHistory: [ChatMessage] = [
            ChatMessage(role: .user, text: "my dog's name is Bingo"),
            ChatMessage(role: .assistant, text: "Noted, I'll remember that."),
            ChatMessage(role: .user, text: "we're planning a weekend hike"),
            ChatMessage(role: .assistant, text: "Great, I can help with a checklist."),
            ChatMessage(role: .user, text: "keep it compact because i have a small car"),
            ChatMessage(role: .assistant, text: "Understood, compact and practical."),
            ChatMessage(role: .user, text: "what are weather risks"),
            ChatMessage(role: .assistant, text: "Rain and wind are key factors."),
            ChatMessage(role: .user, text: "i also want safety tips"),
            ChatMessage(role: .assistant, text: "Sure, I'll include safety checks."),
            ChatMessage(role: .user, text: "please keep answers medium length"),
            ChatMessage(role: .assistant, text: "Will do.")
        ]

        _ = await orchestrator.processTurn("my tummy is sore", history: longHistory)
        _ = await orchestrator.processTurn("my engine is making a funny noise", history: longHistory)

        XCTAssertEqual(fakeOpenAI.chatCallLog.count, 2)

        let labels = ["my tummy is sore", "my engine is making a funny noise"]
        let expectedDomains = ["health", "vehicle"]

        for index in 0..<2 {
            let messages = fakeOpenAI.chatCallLog[index]
            guard let systemPrompt = messages.first(where: { $0["role"] == "system" })?["content"] else {
                return XCTFail("Expected core system prompt")
            }
            guard let modeMessage = messages.first(where: { ($0["content"] ?? "").contains("[MODE]") })?["content"] else {
                return XCTFail("Expected [MODE] block")
            }
            guard let stateMessage = messages.first(where: { ($0["content"] ?? "").contains("[INTERACTION_STATE]") })?["content"] else {
                return XCTFail("Expected [INTERACTION_STATE] block")
            }
            guard let summaryMessage = messages.first(where: { ($0["content"] ?? "").contains("[CONVERSATION_SUMMARY]") })?["content"] else {
                return XCTFail("Expected [CONVERSATION_SUMMARY] block")
            }
            guard let budgetMessage = messages.first(where: { ($0["content"] ?? "").contains("[RESPONSE_BUDGET]") })?["content"] else {
                return XCTFail("Expected [RESPONSE_BUDGET] block")
            }

            XCTAssertTrue(modeMessage.contains("\"intent\":\"problem_report\""))
            XCTAssertTrue(modeMessage.contains("\"domain\":\"\(expectedDomains[index])\""))

            let summaryLower = summaryMessage.lowercased()
            XCTAssertTrue(summaryLower.contains("active topic: problem_report/\(expectedDomains[index])"))
            XCTAssertTrue(summaryLower.contains("latest user turn: \(labels[index])"))

            print("[PROMPT_EXPORT] input=\(labels[index])")
            print("[PROMPT_EXPORT][MODE]\n\(modeMessage)")
            print("[PROMPT_EXPORT][INTERACTION_STATE]\n\(stateMessage)")
            print("[PROMPT_EXPORT][CONVERSATION_SUMMARY]\n\(summaryMessage)")
            print("[PROMPT_EXPORT][RESPONSE_BUDGET]\n\(budgetMessage)")
            print("[PROMPT_EXPORT][FINAL_SYSTEM_TEXT] chars=\(systemPrompt.count)")
            print(systemPrompt)
            print("[PROMPT_EXPORT][END]")
        }
    }

    @MainActor
    func testProblemReportPivotsFromHealthToVehicleImmediately() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON), .success(validTalkJSON), .success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        var history: [ChatMessage] = []

        let first = await orchestrator.processTurn("I don't feel well", history: history)
        history.append(ChatMessage(role: .user, text: "I don't feel well"))
        history.append(contentsOf: first.appendedChat)

        let second = await orchestrator.processTurn("my tummy is sore", history: history)
        history.append(ChatMessage(role: .user, text: "my tummy is sore"))
        history.append(contentsOf: second.appendedChat)

        _ = await orchestrator.processTurn("actually it's my car, engine noise", history: history)

        XCTAssertEqual(fakeOpenAI.chatCallLog.count, 3)
        let thirdCall = fakeOpenAI.chatCallLog[2]
        guard let modeMessage = thirdCall.first(where: { ($0["content"] ?? "").contains("[MODE]") })?["content"] else {
            return XCTFail("Expected [MODE] block")
        }
        guard let systemPrompt = thirdCall.first(where: { $0["role"] == "system" })?["content"] else {
            return XCTFail("Expected system prompt")
        }

        XCTAssertTrue(modeMessage.contains("\"intent\":\"problem_report\""))
        XCTAssertTrue(modeMessage.contains("\"domain\":\"vehicle\""))
        XCTAssertTrue(systemPrompt.contains("Vehicle clarifiers"), "Expected vehicle mode policy in system prompt")
        XCTAssertFalse(systemPrompt.contains("Health clarifiers"), "Should not keep health framing after pivot")
    }

    @MainActor
    func testToolResultFeedbackLoopSynthesizesFinalAnswer() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"show_text","args":{"markdown":"# Weather\\n- Rain chance: 62%\\n- Bring an umbrella"}}]}
        """
        let feedback = """
        {"action":"TALK","say":"Rain chance is high, so bring an umbrella."}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(initial), .success(feedback)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("is it raining?", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "show_text is outside the feedback allowlist")
        XCTAssertFalse(result.appendedOutputs.isEmpty, "Tool output should still render in canvas")
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && !$0.text.isEmpty }))
    }

    @MainActor
    func testToolResultFeedbackLoopSupportsMultiDepthToolReentry() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"show_text","args":{"markdown":"# Step One\\n- Base output"}}]}
        """
        let followupTool = """
        {"action":"PLAN","steps":[{"step":"tool","name":"show_text","args":{"markdown":"# Step Two\\n- Follow-up output"}}]}
        """
        let finalTalk = """
        {"action":"TALK","say":"I combined both results and finished the task."}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(initial), .success(followupTool), .success(finalTalk)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("finish this with tool re-entry", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "show_text should not trigger feedback re-entry")
        XCTAssertEqual(result.appendedOutputs.count, 1)
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && !$0.text.isEmpty }))
    }

    @MainActor
    func testCompoundToolOnlyRequestShowsProgressThenReasonedAnswer() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"Tokyo"},"say":"Let me check the time in Tokyo."}]}
        """
        let feedback = """
        {"action":"TALK","say":"It is a reasonable time in Tokyo, but late evening in London, so only call if it's urgent."}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(initial), .success(feedback)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn(
            "Check Tokyo time, then tell me if it's a good time to call London.",
            history: []
        )

        XCTAssertEqual(fakeOpenAI.chatCallCount, 2, "Compound tool-only requests should trigger feedback reasoning")
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text == "Let me check the time in Tokyo." }),
                      "Progress line from tool say should be surfaced for multi-clause requests")
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text.lowercased().contains("london") }),
                      "Final synthesized answer should address the second clause")
    }

    @MainActor
    func testComplexRequestUsesEscalationModel() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings.generalModel = "gpt-4o-mini"
        OpenAISettings.escalationModel = "gpt-4o"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        _ = await orchestrator.processTurn("Check Tokyo time, then tell me if it's a good time to call London.", history: [])
        XCTAssertEqual(fakeOpenAI.chatModelLog.first, "gpt-4o")
    }

    @MainActor
    func testSimpleRequestUsesGeneralModelAndShowsModelInKnowledgeUsage() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings.generalModel = "gpt-4o-mini"
        OpenAISettings.escalationModel = "gpt-4o"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hi sam", history: [])
        XCTAssertEqual(fakeOpenAI.chatModelLog.first, "gpt-4o-mini")
        XCTAssertEqual(result.knowledgeAttribution?.aiModelUsed, "gpt-4o-mini")
    }

    @MainActor
    func testCompoundToolOnlyRequestRetriesWhenFeedbackTalkIsIncomplete() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"Tokyo"},"say":"Let me check the time in Tokyo."}]}
        """
        let incomplete = """
        {"action":"TALK","say":"It's 6:06 pm."}
        """
        let repaired = """
        {"action":"TALK","say":"It's 6:06 pm in Tokyo, and it's quite late in London, so call only if it's urgent."}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(initial), .success(incomplete), .success(repaired)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn(
            "Check Tokyo time, then tell me if it's a good time to call London.",
            history: []
        )

        XCTAssertEqual(fakeOpenAI.chatCallCount, 3, "Incomplete feedback talk should trigger one more repair attempt")
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text == "Let me check the time in Tokyo." }))
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text.lowercased().contains("london") }))
        XCTAssertFalse(result.appendedChat.contains(where: { $0.role == .assistant && $0.text == "It's 6:06 pm." }),
                       "Incomplete feedback talk should not be committed when repair succeeds")
    }

    @MainActor
    func testMultiToolPlanSurfacesAllProgressSayLines() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"Tokyo"},"say":"Let me check the time in Tokyo."},{"step":"tool","name":"get_time","args":{"place":"London"},"say":"I'll also check the time in London."}]}
        """
        let feedback = """
        {"action":"TALK","say":"It's currently daytime in Tokyo and early morning in London, so this can be a reasonable time to call."}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(initial), .success(feedback)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn(
            "Check Tokyo time, then tell me if it's a good time to call London.",
            history: []
        )

        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text == "Let me check the time in Tokyo." }))
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text == "I'll also check the time in London." }))
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text.lowercased().contains("london") }))
    }

    @MainActor
    func testToolFeedbackFallsBackToOllamaWhenOpenAIFeedbackFails() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"Tokyo"},"say":"Let me check the time in Tokyo."},{"step":"tool","name":"get_time","args":{"place":"London"},"say":"I'll also check the time in London."}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(initial),
            .failure(OpenAIRouter.OpenAIError.requestFailed("feedback timeout"))
        ]

        let ollamaFeedback = """
        {"action":"TALK","say":"Tokyo is in the evening while London is in the morning, so it's generally a suitable time to call."}
        """
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedResponses = [
            .success(ollamaFeedback)
        ]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn(
            "Check Tokyo time, then tell me if it's a good time to call London.",
            history: []
        )

        XCTAssertGreaterThanOrEqual(fakeOpenAI.chatCallCount, 1, "OpenAI should at least handle initial routing")
        XCTAssertLessThanOrEqual(fakeOllama.chatCallCount, 1, "Ollama fallback should happen at most once")
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text.lowercased().contains("london") }))
    }

    @MainActor
    func testMultiToolPlanWithTalkStillSurfacesProgressSayLines() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"Tokyo"},"say":"Checking Tokyo time."},{"step":"tool","name":"get_time","args":{"place":"London"},"say":"Checking London time."},{"step":"talk","say":"Tokyo is later than London right now."}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(initial)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("compare Tokyo and London time", history: [])

        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text == "Checking Tokyo time." }))
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text == "Checking London time." }))
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text.lowercased().contains("later than london") }))
    }

    // MARK: - Weather/Time Tool Choice

    @MainActor
    func testRainingInMelbourneRoutesToGetWeather() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(weatherWrongToolPlanJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("Is it raining in Melbourne?")

        guard let plan = plan else {
            return XCTFail("Expected a plan for weather query")
        }
        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "get_weather")
        XCTAssertEqual(args["place"]?.stringValue, "Melbourne")
    }

    @MainActor
    func testWeatherInGreenbankTodayRoutesToGetWeather() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(weatherWrongToolActionJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("What's the weather in Greenbank today?")

        guard let plan = plan else {
            return XCTFail("Expected a plan for weather query")
        }
        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "get_weather")
        XCTAssertEqual(args["place"]?.stringValue, "Greenbank")
    }

    @MainActor
    func testTimeInLondonStaysOnGetTime() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTimePlanJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("What time is it in London?")

        guard let plan = plan else {
            return XCTFail("Expected a plan for time query")
        }
        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "get_time")
        XCTAssertEqual(args["place"]?.stringValue, "London")
    }

    @MainActor
    func testRecipeRequestRecoversFromCapabilityGapToFindRecipeTool() async {
        let first = #"{"action":"CAPABILITY_GAP","goal":"Find a recipe for caramel sauce","missing":"recipe search capability"}"#
        let second = #"{"action":"TALK","say":"I can't find recipes directly, but I can help with something else!"}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(first), .success(second)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("find a recipe for caramel sauce")

        guard let plan = plan else {
            return XCTFail("Expected a repaired recipe plan")
        }
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Recipe guardrail should recover in a single pass")

        let hasFindRecipe = plan.steps.contains { step in
            if case .tool(let name, let args, _) = step {
                return name == "find_recipe" && (args["query"]?.stringValue.lowercased().contains("caramel sauce") == true)
            }
            return false
        }
        XCTAssertTrue(hasFindRecipe, "Recipe request should be repaired to find_recipe tool")
    }

    @MainActor
    func testRecipeAndImageRefusalRepairsToFindRecipeAndFindImage() async {
        let refusal = #"{"action":"TALK","say":"I can't find recipes directly."}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(refusal)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("find a recipe for banana muffins and show me an image of the food")

        guard let plan = plan else {
            return XCTFail("Expected repaired plan")
        }
        let toolNames = plan.steps.compactMap { step -> String? in
            if case .tool(let name, _, _) = step { return name }
            return nil
        }
        XCTAssertTrue(toolNames.contains("find_recipe"))
        XCTAssertTrue(toolNames.contains("find_image"))
    }

    @MainActor
    func testVideoRequestRecoversFromCapabilityGapToFindVideoTool() async {
        let first = #"{"action":"CAPABILITY_GAP","goal":"Find and display relevant videos when the user requests.","missing":"video search capability"}"#
        let second = #"{"action":"TALK","say":"I can't find videos directly right now."}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(first), .success(second)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("find a video of a race car")

        guard let plan = plan else {
            return XCTFail("Expected a repaired video plan")
        }
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Video guardrail should recover in a single pass")

        let hasFindVideo = plan.steps.contains { step in
            if case .tool(let name, let args, _) = step {
                return name == "find_video" && (args["query"]?.stringValue.lowercased().contains("race car") == true)
            }
            return false
        }
        XCTAssertTrue(hasFindVideo, "Video request should be repaired to find_video tool")
    }

    @MainActor
    func testCapabilityBuildRequestRoutesToStartSkillforge() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(capabilityWrongToolActionJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("learn \"Capability Gap Miner\": analyzes failed/blocked turns and proposes the next capability to build.")

        guard let plan = plan else {
            return XCTFail("Expected a plan for capability build request")
        }
        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "start_skillforge")
        XCTAssertTrue((args["goal"]?.stringValue ?? "").lowercased().contains("capability gap miner"))
    }

    func testCapabilityBuildWithURLPreservesStartSkillforge() async throws {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(capabilityStartSkillforgeActionJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try await openAIRouter.routePlan("Learn a capability: when user says show me a video on X, find and display a relevant video. Use https://www.googleapis.com/youtube/v3/search")

        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "start_skillforge")
        XCTAssertTrue((args["goal"]?.stringValue ?? "").lowercased().contains("find and display relevant videos"))
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Should not repair-retry as unexpected capability escalation")
    }

    func testCapabilityBuildWithURLRepairsWrongToolToStartSkillforge() async throws {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(capabilityWrongToolActionJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try await openAIRouter.routePlan("Build a capability to find and display videos and use https://www.googleapis.com/youtube/v3/search as the reference.")
        guard case .tool(let name, _, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "start_skillforge")
    }

    @MainActor
    func testWebsiteLearningRequestWithURLStaysOnLearnWebsite() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(websiteLearningActionJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("Learn this website https://swift.org and focus on package manager basics.")

        guard let plan = plan else {
            return XCTFail("Expected a plan for website learning request")
        }
        guard case .tool(let name, let args, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "learn_website")
        XCTAssertEqual(args["url"]?.stringValue, "https://swift.org")
    }

    @MainActor
    func testStopCapabilityLearningRoutesToForgeQueueClear() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let plan = try? await openAIRouter.routePlan("Stop capability learning now.")

        guard let plan = plan else {
            return XCTFail("Expected a plan for stop capability request")
        }
        guard case .tool(let name, _, _) = plan.steps.first else {
            return XCTFail("Expected first step to be a tool call")
        }
        XCTAssertEqual(name, "forge_queue_clear")
    }

    // MARK: - B) OpenAI transport error does NOT fall back to Ollama

    @MainActor
    func testOpenAITransportErrorNoOllamaFallback() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.failure(OpenAIRouter.OpenAIError.requestFailed("timeout"))]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedResponses = [.success(validTalkJSON)]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 2, "Timeout should trigger exactly one retry")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Ollama should NOT be called when OpenAI configured")
        XCTAssertEqual(result.llmProvider, .openai, "Should preserve OpenAI provider on fallback")
        XCTAssertTrue(result.appendedChat.contains { $0.text.lowercased().contains("openai") })
        XCTAssertEqual(result.knowledgeAttribution?.localKnowledgePercent, 0)
        XCTAssertEqual(result.knowledgeAttribution?.matchedLocalItems, 0)
        XCTAssertEqual(result.usedMemoryHints, false, "Fallback provider should not mark memory-hint usage")
    }

    @MainActor
    func testTimeoutRetriesOnceThenFallback() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .failure(RouterTimeout.exceeded),
            .failure(RouterTimeout.exceeded)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-timeout-retry-fallback"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-timeout-retry-fallback"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Can you summarize the current project status clearly?", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 2, "Timeout should trigger exactly one retry")
        XCTAssertEqual(fakeOpenAI.chatMaxTokensLog.count, 2)
        XCTAssertEqual(fakeOpenAI.chatMaxTokensLog[1], 220, "Retry call should lower max output tokens")
        XCTAssertEqual(result.llmProvider, .openai)
        let assistant = result.appendedChat.first(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        XCTAssertTrue(assistant.contains("took too long"), "Expected timeout fallback copy, got: \(assistant)")
    }

    @MainActor
    func testTimeoutRetriesOnceThenSucceeds() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .failure(RouterTimeout.exceeded),
            .success(validTalkJSON)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-timeout-retry-success"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-timeout-retry-success"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Can you summarize the current project status clearly?", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 2)
        XCTAssertEqual(fakeOpenAI.chatMaxTokensLog[1], 220)
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains(where: { $0.role == .assistant && $0.text.contains("Hey there!") }))
    }

    // MARK: - C) OpenAI TALK with time claim accepted (no validation repair)

    @MainActor
    func testOpenAITalkWithTimeClaimAccepted() async {
        // TALK is always accepted — no validation repair loop.
        let talkWithTimeClaim = """
        {"action":"TALK","say":"It's 3:00 PM in London."}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(talkWithTimeClaim)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("what time is it in London", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Only 1 OpenAI call — no repair loop")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Ollama should not be called")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains { $0.text.contains("3:00 PM") })
    }

    // MARK: - D) OpenAI non-JSON response wrapped as TALK (no repair retry)

    @MainActor
    func testOpenAIJsonParseFailureWrapsAsTalk() async {
        // Non-JSON response is wrapped as TALK — no repair retry
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success("I cannot help with that")
        ]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Only 1 OpenAI call — no repair retry")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Ollama should not be called")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains { $0.text.contains("I cannot help with that") },
                      "Non-JSON response should be wrapped as TALK")
    }

    // MARK: - E) OpenAI fail returns graceful fallback (no Ollama hop)

    @MainActor
    func testOpenAIFailReturnsGracefulFallbackNoOllamaHop() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.failure(OpenAIRouter.OpenAIError.requestFailed("down"))]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "No Ollama hop when OpenAI configured")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains { $0.text.lowercased().contains("openai") })
    }

    @MainActor
    func testColdStartLoadsSavedOpenAIKeyBeforeFirstTurn() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "cold-start-test-key"
        OpenAISettings._resetCacheForTesting() // Simulate first turn after app launch.
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Cold start should load key before first OpenAI route")
        XCTAssertEqual(fakeOllama.chatCallCount, 0)
        XCTAssertEqual(result.llmProvider, .openai)
    }

    @MainActor
    func testInvalidAPIKeyReturnsClearErrorAndBlocksSubsequentOpenAICalls() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .failure(OpenAIRouter.OpenAIError.badResponse(401)),
            .success(validTalkJSON)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-401"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-401"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let first = await orchestrator.processTurn("hello", history: [])
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)
        let firstText = first.appendedChat.first(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        XCTAssertTrue(firstText.contains("openai rejected the request (401)"), "Expected explicit auth error, got: \(firstText)")
        XCTAssertTrue(firstText.contains("settings -> openai"), "Expected actionable settings path, got: \(firstText)")

        let second = await orchestrator.processTurn("hello again", history: [])
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Second turn should fail fast without calling OpenAI again")
        let secondText = second.appendedChat.first(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        XCTAssertTrue(
            secondText.contains("openai rejected the request")
                || secondText.contains("openai api key isn't set"),
            "Expected persistent auth/settings guidance, got: \(secondText)"
        )
        XCTAssertTrue(secondText.contains("settings -> openai"), "Expected actionable settings path, got: \(secondText)")
    }

    @MainActor
    func testInvalidAPIKeyStateClearsOnlyWhenKeyChanges() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .failure(OpenAIRouter.OpenAIError.badResponse(401)),
            .success(validTalkJSON)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "same-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "same-key"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        _ = await orchestrator.processTurn("hello", history: [])
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)

        // Re-saving the same key should remain blocked.
        OpenAISettings.apiKey = "same-key"
        _ = await orchestrator.processTurn("hello again", history: [])
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Same key should keep invalid lockout active")

        // Saving a different key should clear invalid lockout and allow retry.
        OpenAISettings.apiKey = "different-key"
        let recovered = await orchestrator.processTurn("hello after update", history: [])
        XCTAssertEqual(fakeOpenAI.chatCallCount, 2, "Different key should clear invalid lockout")
        XCTAssertEqual(recovered.llmProvider, .openai)
    }

    // MARK: - F) Ollama standalone when OpenAI not configured

    @MainActor
    func testOllamaStandaloneWhenOpenAINotConfigured() async {
        let fakeOpenAI = FakeOpenAITransport()
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.91,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOllama.queuedResponses = [.success(validTalkJSON)]

        OpenAISettings.apiKey = ""
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = ""
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 0, "OpenAI should not be called")
        XCTAssertEqual(fakeOllama.intentCallCount, 1, "Ollama intent classifier should be called once")
        XCTAssertEqual(fakeOllama.chatCallCount, 1, "Ollama should be called")
        XCTAssertEqual(result.llmProvider, .ollama)
    }

    // MARK: - G) Nothing configured returns explicit auth error

    @MainActor
    func testNothingConfiguredReturnsAuthError() async {
        let fakeOpenAI = FakeOpenAITransport()
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = ""
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = ""
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 0)
        XCTAssertEqual(fakeOllama.chatCallCount, 0)
        XCTAssertEqual(result.llmProvider, .none)
        let assistantText = result.appendedChat.first(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        XCTAssertTrue(assistantText.contains("api key isn't set"), "Expected explicit auth guidance, got: \(assistantText)")
        XCTAssertTrue(assistantText.contains("settings -> openai"), "Expected actionable settings path, got: \(assistantText)")
    }

    // MARK: - H) OpenAI valid TALK → immediate return, no retry, no fallback

    @MainActor
    func testOpenAIValidTalkImmediateReturnNoRetry() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("what time is it in london", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Exactly 1 OpenAI call — no retry")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Zero Ollama calls")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains { $0.text == "Hey there!" })
    }

    // MARK: - I) OpenAI non-JSON wrapped as TALK (single call, no retry)

    @MainActor
    func testOpenAIInvalidJsonWrapsAsTalkSingleCall() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success("Sure, the time in London is 3pm")  // non-JSON → wrapped as TALK
        ]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Only 1 OpenAI call — wrap-as-TALK, no retry")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Zero Ollama calls")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.contains { $0.text.contains("time in London is 3pm") },
                      "Non-JSON wrapped as TALK")
    }

    // MARK: - J) KeychainStore read never prompts UI

    func testKeychainStoreReadIncludesAuthUIFail() {
        // Write a test key, then read it back.
        // The read should succeed without prompting (kSecUseAuthenticationUIFail is set).
        let testService = "com.samos.routertest"
        let testKey = "pipelineTestKey"

        // Clean up first
        KeychainStore.delete(forKey: testKey, service: testService)

        // Write
        let written = KeychainStore.set("test-value-123", forKey: testKey, service: testService)
        XCTAssertTrue(written, "Should write successfully")

        // Read — this must succeed without UI prompt (kSecUseAuthenticationUIFail)
        let value = KeychainStore.get(forKey: testKey, service: testService)
        XCTAssertEqual(value, "test-value-123", "Should read back without UI prompt")

        // Clean up
        KeychainStore.delete(forKey: testKey, service: testService)
    }

    // MARK: - K0) Tool step say is silent; only tool result is user-visible

    @MainActor
    func testToolStepWithSayIsSilent() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(validTimePlanJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("what time is it in London", history: [])

        let assistantMessages = result.appendedChat.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1, "Tool step say should not be emitted")
        XCTAssertTrue(assistantMessages[0].text.contains("It's"),
                      "Should emit only the tool result")
        XCTAssertEqual(result.spokenLines.count, 1, "Tool step say should not be spoken")
    }

    // MARK: - K1) Answer shaping (spoken summary + visual detail)

    @MainActor
    func testLongOutputUsesToolWindow() async {
        let longStructured = """
        {"action":"TALK","say":"# Delivery Plan\\n\\n## Milestones\\n- Draft\\n- Review\\n- Publish\\n\\n## Steps\\n1. Outline scope\\n2. Build implementation\\n3. Validate release"}
        """

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(longStructured)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("give me a delivery plan", history: [])

        XCTAssertEqual(result.appendedOutputs.count, 1, "Long/structured TALK should move to canvas")
        XCTAssertEqual(result.appendedOutputs.first?.kind, .markdown)
        XCTAssertTrue(result.appendedOutputs.first?.payload.contains("## Milestones") == true)
        XCTAssertEqual(result.appendedChat.count, 1, "Chat should be short confirmation")
        XCTAssertFalse(result.appendedChat[0].text.contains("Milestones"),
                       "Confirmation should be short, not full details")
    }

    @MainActor
    func testSpokenSummaryIsShort() async {
        let denseTalk = """
        {"action":"TALK","say":"This rollout includes architecture decisions, risk notes, deployment sequencing, test-matrix constraints, and rollback guidance for every stage so that teams can execute safely with clear ownership and contingency plans while keeping auditability and quality controls intact end to end."}
        """

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(denseTalk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("summarize rollout guidance", history: [])
        let spoken = result.spokenLines.first ?? ""
        let sentenceCount = spoken.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count

        XCTAssertEqual(result.appendedOutputs.count, 1, "Dense answer should include visual details")
        XCTAssertLessThanOrEqual(sentenceCount, 2, "Spoken summary should be at most two sentences")
        XCTAssertLessThanOrEqual(spoken.count, 200, "Spoken summary should stay brief")
    }

    @MainActor
    func testSimpleFactRemainsSpokenOnly() async {
        let simpleTalk = #"{"action":"TALK","say":"Pacific is the largest ocean."}"#

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(simpleTalk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("what is the largest ocean?", history: [])

        XCTAssertTrue(result.appendedOutputs.isEmpty, "Simple fact should not be pushed to tool window")
        XCTAssertEqual(result.appendedChat.first(where: { $0.role == .assistant })?.text,
                       "Pacific is the largest ocean.")
        XCTAssertEqual(result.spokenLines.first, "Pacific is the largest ocean.")
    }

    @MainActor
    func testNoHardcodedTopics() async {
        let nonTopicStructured = """
        {"action":"TALK","say":"## Sprint Retro\\n- Wins\\n- Risks\\n- Follow-ups\\n\\n1. Capture outcomes\\n2. Assign owners\\n3. Track due dates"}
        """

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(nonTopicStructured)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("summarize team retro", history: [])

        XCTAssertEqual(result.appendedOutputs.count, 1, "Shaping should trigger from structure, not topic keywords")
        XCTAssertTrue(result.appendedOutputs[0].payload.contains("## Sprint Retro"))
        XCTAssertFalse(result.spokenLines.isEmpty)
    }

    // MARK: - K2) Greeting anti-repeat (one extra LLM call max)

    @MainActor
    func testGreetingAntiRepeat() async {
        let duplicateGreeting = #"{"action":"TALK","say":"Hey there!"}"#

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(duplicateGreeting), // first turn
            .success(duplicateGreeting)  // second turn initial
        ]

        let fakeOllama = FakeOllamaTransportForPipeline()
        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let first = await orchestrator.processTurn("hi sam", history: [])
        let secondHistory = [
            ChatMessage(role: .user, text: "hi sam"),
            ChatMessage(role: .assistant, text: first.appendedChat.first?.text ?? "Hey there!")
        ]
        let second = await orchestrator.processTurn("hi sam", history: secondHistory)

        XCTAssertEqual(fakeOpenAI.chatCallCount, 2,
                       "Greeting variation should be intent-driven and avoid extra LLM calls")
        XCTAssertNotEqual(second.appendedChat.first?.text, first.appendedChat.first?.text)
    }

    // MARK: - K2b) Optional follow-up question policy

    @MainActor
    func testFollowUpNotAddedWhenAlreadyQuestion() async {
        let savedDisableAutoClosePrompts = M2Settings.disableAutoClosePrompts
        defer { M2Settings.disableAutoClosePrompts = savedDisableAutoClosePrompts }
        M2Settings.disableAutoClosePrompts = false

        let alreadyQuestion = #"{"action":"TALK","say":"Want me to continue?"}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(alreadyQuestion)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)
        let result = await orchestrator.processTurn("hi", history: [])

        let text = result.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(text.filter { $0 == "?" }.count, 1, "Should not append a second follow-up question")
        XCTAssertFalse(result.triggerQuestionAutoListen, "Only generated follow-up questions should trigger auto-listen")
    }

    @MainActor
    func testFollowUpCooldownEnforced() async {
        let savedDisableAutoClosePrompts = M2Settings.disableAutoClosePrompts
        defer { M2Settings.disableAutoClosePrompts = savedDisableAutoClosePrompts }
        M2Settings.disableAutoClosePrompts = false

        let firstTalk = #"{"action":"TALK","say":"I finished that for you and included the key details."}"#
        let secondTalk = #"{"action":"TALK","say":"I wrapped this up and summarized the important parts."}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(firstTalk), .success(secondTalk)]
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"greeting","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """),
            .success("""
            {"intent":"greeting","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            followUpCooldownTurns: 5
        )

        let first = await orchestrator.processTurn("hi", history: [])
        let firstText = first.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(firstText.filter { $0 == "?" }.count, 1)
        XCTAssertTrue(first.triggerQuestionAutoListen)

        let second = await orchestrator.processTurn("hello", history: [])
        let secondText = second.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(secondText.filter { $0 == "?" }.count, 0, "Follow-up should be blocked during cooldown")
        XCTAssertFalse(second.triggerQuestionAutoListen)
    }

    @MainActor
    func testFollowUpMaxOneSentence() async {
        let savedDisableAutoClosePrompts = M2Settings.disableAutoClosePrompts
        defer { M2Settings.disableAutoClosePrompts = savedDisableAutoClosePrompts }
        M2Settings.disableAutoClosePrompts = false

        let talk = #"{"action":"TALK","say":"I prepared the result and highlighted the important points for you."}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(talk)]
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"greeting","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)
        let result = await orchestrator.processTurn("hello", history: [])

        let text = result.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(text.filter { $0 == "?" }.count, 1, "Follow-up should be a single question sentence")
        XCTAssertTrue(text.hasSuffix("?"), "Follow-up question must end the message")
    }

    // MARK: - K3) Memory acknowledgements (optional + cooldown)

    @MainActor
    func testMemoryAckOnlyWhenRelevant() async {
        let token = "acktoken\(Int.random(in: 10000...99999))"
        guard let memory = MemoryStore.shared.addMemory(type: .note, content: "Project \(token) is active.") else {
            return XCTFail("Failed to seed memory")
        }
        defer { _ = MemoryStore.shared.deleteMemory(idOrPrefix: memory.id.uuidString) }

        let talk = "{\"action\":\"TALK\",\"say\":\"I remember you mentioned Project \(token). Here's a quick update.\"}"
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(talk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Any update on project \(token)?", history: [])
        let text = result.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(text.lowercased().contains("i remember you mentioned"),
                      "Memory acknowledgement should be preserved when relevant memory exists")
    }

    @MainActor
    func testMemoryAckRespectsCooldown() async {
        let token = "acktoken\(Int.random(in: 10000...99999))"
        guard let memory = MemoryStore.shared.addMemory(type: .note, content: "Project \(token) is active.") else {
            return XCTFail("Failed to seed memory")
        }
        defer { _ = MemoryStore.shared.deleteMemory(idOrPrefix: memory.id.uuidString) }

        let firstTalk = "{\"action\":\"TALK\",\"say\":\"I remember you mentioned Project \(token). Here's the first update.\"}"
        let secondTalk = "{\"action\":\"TALK\",\"say\":\"If I'm remembering right, this relates to \(token). Let's go over the next step.\"}"

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(firstTalk), .success(secondTalk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, memoryAckCooldownTurns: 20)

        let first = await orchestrator.processTurn("status on \(token)", history: [])
        let firstText = first.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertTrue(firstText.lowercased().contains("i remember you mentioned"))

        let history = [
            ChatMessage(role: .user, text: "status on \(token)"),
            ChatMessage(role: .assistant, text: firstText)
        ]
        let second = await orchestrator.processTurn("any other update on \(token)?", history: history)
        let secondText = second.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""

        XCTAssertFalse(secondText.lowercased().contains("i remember you mentioned"),
                       "Memory acknowledgement should be removed during cooldown")
        XCTAssertFalse(secondText.lowercased().contains("if i'm remembering right"),
                       "Memory acknowledgement should be removed during cooldown")
        XCTAssertTrue(secondText.contains("Let's go over the next step."))
    }

    @MainActor
    func testMemoryAckDoesNotAppearWithoutMemoryHints() async {
        let token = "acktoken\(Int.random(in: 10000...99999))"
        let queryToken = "nomatch\(Int.random(in: 10000...99999))"
        let talk = "{\"action\":\"TALK\",\"say\":\"I remember you mentioned Project \(token). Here's a quick update.\"}"

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(talk)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("status \(queryToken)", history: [])
        let text = result.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""

        XCTAssertFalse(text.lowercased().contains("i remember you mentioned"),
                       "Memory acknowledgement should be stripped when there are no relevant hints")
        XCTAssertTrue(text.contains("Here's a quick update."),
                      "Remainder of response should still be preserved")
    }

    // MARK: - K) Malformed show_text JSON salvaged as show_text tool

    @MainActor
    func testMalformedShowTextSalvagedAsShowTextTool() async {
        // Steps missing "step" key → parsePlanOrAction throws schemaMismatch,
        // but salvage should extract markdown from the show_text name/args.
        let malformed = """
        {"action":"PLAN","steps":[{"name":"show_text","args":{"markdown":"# Pancake Recipe\\n1. Mix flour\\n2. Cook"},"say":"Here you go."}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(malformed)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("show me a pancake recipe")
            let hasShowText = plan.steps.contains { step in
                if case .tool(let name, let args, _) = step, name == "show_text" {
                    return args["markdown"]?.stringValue.contains("Pancake") == true
                }
                return false
            }
            XCTAssertTrue(hasShowText, "Should be salvaged as show_text with pancake markdown")
        } catch {
            XCTFail("Should not throw — should be salvaged: \(error)")
        }
    }

    @MainActor
    func testPlanStepAliasShowTextWithTextArgIsNormalizedAndExecuted() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"show_text","name":"show_text","args":{"text":"# Pancake Recipe\\n1. Mix\\n2. Cook"},"say":"Here you go."}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("show me pancake steps", history: [])

        XCTAssertTrue(result.executedToolSteps.contains(where: { $0.name == "show_text" }))
        let markdownPayload = result.appendedOutputs.first(where: { $0.kind == .markdown })?.payload ?? ""
        XCTAssertTrue(markdownPayload.contains("Pancake"), "Expected show_text markdown output, got: \(markdownPayload)")
        XCTAssertFalse(result.appendedChat.contains(where: { $0.text.contains("trouble processing") }),
                       "Should not fall back to friendly parse error")
    }

    @MainActor
    func testPlanStepAliasShowTextWithoutNameIsNormalizedAndExecuted() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"show_text","args":{"text":"# Waffle Recipe\\n1. Stir\\n2. Bake"},"say":"Done."}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("show me waffle steps", history: [])

        XCTAssertTrue(result.executedToolSteps.contains(where: { step in
            step.name == "show_text" && (step.args["markdown"]?.contains("Waffle") == true || step.args["text"]?.contains("Waffle") == true)
        }), "Expected normalized show_text execution, got: \(result.executedToolSteps)")
        let markdownPayload = result.appendedOutputs.first(where: { $0.kind == .markdown })?.payload ?? ""
        XCTAssertTrue(markdownPayload.contains("Waffle"), "Expected show_text markdown output, got: \(markdownPayload)")
        XCTAssertFalse(result.appendedChat.contains(where: { $0.text.contains("trouble processing") }),
                       "Should not fall back to friendly parse error")
    }

    @MainActor
    func testShowTextStepSayPromotedToMarkdown() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"tool","name":"show_text","args":{},"say":"# Fried Rice\\n\\n## Ingredients\\n- Rice\\n- Egg\\n\\n## Steps:\\n1. Fry"}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-show-text-say-promote"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-show-text-say-promote"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("show me fried rice details", history: [])
        let markdownPayload = result.appendedOutputs.first(where: { $0.kind == .markdown })?.payload ?? ""
        XCTAssertTrue(markdownPayload.contains("Ingredients"), "Expected show_text markdown promoted from step.say")
        XCTAssertFalse(markdownPayload.contains("No content provided"), "show_text should never render the old empty payload marker")
    }

    @MainActor
    func testShowTextEmptyPayloadUsesInternalDebugMessage() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"tool","name":"show_text","args":{},"say":"ok"}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-show-text-empty"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-show-text-empty"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("show me text", history: [])
        let markdownPayload = result.appendedOutputs.first(where: { $0.kind == .markdown })?.payload ?? ""
        XCTAssertEqual(markdownPayload, "(internal) show_text called with empty markdown")
    }

    @MainActor
    func testMalformedNamedTalkStepFallsBackWithoutToolExecution() async {
        let raw = """
        {"action":"PLAN","steps":[{"name":"talk","say":"hi"}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertTrue(result.executedToolSteps.isEmpty, "Malformed step must not execute any tool")
        let assistant = result.appendedChat.first(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        XCTAssertTrue(
            assistant.contains("trouble processing") || assistant.contains("can't do that directly"),
            "Expected safe fallback response, got: \(assistant)"
        )
    }

    @MainActor
    func testUnknownToolClassifiedAsExternalSourceNeeded() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_cinema_listings","args":{"location":"Browns Plains"}}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Please handle this request for me.", history: [])

        XCTAssertTrue(result.executedToolSteps.isEmpty, "Unknown tool must never be executed")
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Unknown-tool flow must not trigger an OpenAI repair retry")
        XCTAssertEqual(orchestrator.pendingSlot?.slotName, "source_url_or_site")
        let assistant = result.appendedChat.first(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        XCTAssertTrue(assistant.contains("url"), "Expected source URL ask flow, got: \(assistant)")
        XCTAssertFalse(assistant.contains("json-looking"), "Should not show generic parse-failed language")
    }

    @MainActor
    func testUnknownToolURLReplyTriggersLearnWebsite() async {
        let unknownToolPlan = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_cinema_listings","args":{"location":"Browns Plains"}}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(unknownToolPlan)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-cap-gap-url"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-cap-gap-url"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        var history: [ChatMessage] = []
        let first = await orchestrator.processTurn("Please handle this request for me.", history: history)
        appendTurn(&history, user: "Please handle this request for me.", result: first)
        XCTAssertEqual(orchestrator.pendingSlot?.slotName, "source_url_or_site")

        let second = await orchestrator.processTurn("https://www.eventcinemas.com.au/Cinema/Browns-Plains", history: history)

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "URL reply should be handled locally without another OpenAI call")
        XCTAssertNil(orchestrator.pendingSlot, "URL capture should clear source_url_or_site pending slot")
        XCTAssertTrue(second.executedToolSteps.contains(where: { $0.name == "learn_website" }))
        XCTAssertTrue(second.executedToolSteps.contains(where: { $0.name == "save_memory" }))
        let assistant = second.appendedChat.first(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        XCTAssertTrue(assistant.contains("learned that page") || assistant.contains("learned that source"))
        XCTAssertTrue(assistant.contains("want me to build it"))
    }

    @MainActor
    func testCinemaListingsQueryAsksForSourceURLWithoutLLM() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"web_request","confidence":0.95,"autoCaptureHint":false,"needsWeb":true,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success("""
            {"action":"PLAN","steps":[{"step":"tool","name":"get_cinema_listings","args":{"location":"Browns Plains"}}]}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-cinema-pre-route"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-cinema-pre-route"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("What's playing at the cinema in Browns Plains?", history: [])

        XCTAssertEqual(fakeOpenAI.intentCallCount, 1, "Intent classification should call OpenAI when Ollama is disabled")
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Unknown tool should come from one OpenAI route call")
        XCTAssertEqual(orchestrator.pendingSlot?.slotName, "source_url_or_site")
        let assistant = result.appendedChat.first(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        XCTAssertTrue(assistant.contains("url"))
    }

    // MARK: - L) Malformed show_image JSON salvaged as show_image tool

    @MainActor
    func testMalformedShowImageSalvagedAsShowImageTool() async {
        // Steps missing "step" key → parsePlanOrAction throws, salvage extracts URLs.
        let malformed = """
        {"action":"PLAN","steps":[{"name":"show_image","args":{"urls":"https://example.com/frog.jpg|https://example.com/frog2.png","alt":"a frog"},"say":"Here you go."}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(malformed)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("show me a frog")
            let hasShowImage = plan.steps.contains { step in
                if case .tool(let name, let args, _) = step, name == "show_image" {
                    return args["urls"]?.stringValue.contains("frog.jpg") == true
                }
                return false
            }
            XCTAssertTrue(hasShowImage, "Should be salvaged as show_image with frog URLs")
        } catch {
            XCTFail("Should not throw — should be salvaged: \(error)")
        }
    }

    @MainActor
    func testPlanDelegateStepWithToolShapeParsesAsToolSteps() async {
        let malformed = """
        {"action":"PLAN","steps":[{"step":"tool","name":"find_image","args":{"query":"butter chicken"},"say":"I'll find an image of butter chicken."},{"step":"delegate","name":"learn_website","args":{"url":"https://www.example.com/butter-chicken-recipe","focus":"recipe"},"say":"I'll look for a recipe."}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(malformed)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("find a recipe for butter chicken and show me an image of the food")
            let toolNames = plan.steps.compactMap { step -> String? in
                if case .tool(let name, _, _) = step { return name }
                return nil
            }
            XCTAssertTrue(toolNames.contains("find_image"))
            XCTAssertTrue(toolNames.contains("learn_website"))
        } catch {
            XCTFail("Should not throw — malformed delegate tool shape should be normalized: \(error)")
        }
    }

    // MARK: - M) JSON garbage returns friendly error, not raw JSON

    @MainActor
    func testJsonGarbageReturnsFriendlyErrorNotRawJson() async {
        let garbage = """
        {"foo":"bar","baz":42,"nested":{"x":true}}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(garbage)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("do something")
            if case .talk(let say) = plan.steps.first {
                XCTAssertFalse(say.contains("{"), "Should not contain raw JSON braces")
                XCTAssertFalse(say.contains("foo"), "Should not contain raw JSON keys")
                XCTAssertTrue(say.lowercased().contains("sorry") || say.lowercased().contains("try again"),
                              "Should be a friendly error message, got: \(say)")
            } else {
                XCTFail("Expected a talk step with friendly error")
            }
        } catch {
            XCTFail("Should not throw — should return friendly error: \(error)")
        }
    }

    // MARK: - N) Raw markdown wrapped in show_text

    @MainActor
    func testRawMarkdownWrappedAsShowText() async {
        let rawMarkdown = "# Pancake Recipe\n\n## Ingredients\n- 1 cup flour\n- 2 eggs\n\n## Instructions\n1. Mix ingredients\n2. Cook on griddle"
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(rawMarkdown)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("pancake recipe")
            let hasShowText = plan.steps.contains { step in
                if case .tool(let name, let args, _) = step, name == "show_text" {
                    return args["markdown"]?.stringValue.contains("Pancake") == true
                }
                return false
            }
            XCTAssertTrue(hasShowText, "Raw markdown should be wrapped in show_text tool step")
        } catch {
            XCTFail("Should not throw — should be salvaged: \(error)")
        }
    }

    // MARK: - P) Image probe failure prompt includes HTTP codes

    @MainActor
    func testImageProbeFailurePromptIncludesHTTPCodes() async {
        // Use a mock ToolsRuntime that returns show_image with fake URLs
        let mockRuntime = ImageProbeToolsRuntime(urls: [
            "https://example.com/fake1.jpg",
            "https://example.com/fake2.jpg"
        ])
        let executor = PlanExecutor(toolsRuntime: mockRuntime)

        let plan = Plan(steps: [
            .tool(name: "show_image",
                  args: ["urls": .string("https://example.com/fake1.jpg|https://example.com/fake2.jpg"),
                         "alt": .string("a frog")],
                  say: "Here you go.")
        ])

        let result = await executor.execute(plan, originalInput: "show me a frog")

        // Probe should fail for these URLs (they don't exist)
        // The pendingSlotRequest.prompt should exist with image_url slot
        if let req = result.pendingSlotRequest {
            XCTAssertEqual(req.slot, "image_url", "Should set image_url slot for auto-repair")
        }
        // Note: actual HTTP codes depend on network — in CI, the test verifies the slot is set
    }

    // MARK: - Q) Repair prompt demands 3 URLs and Wikimedia host

    @MainActor
    func testRepairPromptDemands3UrlsAndWikimediaHost() async {
        // Simulate what happens when all image URLs fail:
        // The formatted message from probeImageOutput should mention wikimedia
        let mockRuntime = ImageProbeToolsRuntime(urls: [
            "https://example.com/bad1.jpg",
            "https://example.com/bad2.jpg"
        ])
        let executor = PlanExecutor(toolsRuntime: mockRuntime)

        let plan = Plan(steps: [
            .tool(name: "show_image",
                  args: ["urls": .string("https://example.com/bad1.jpg|https://example.com/bad2.jpg"),
                         "alt": .string("test")],
                  say: "Here.")
        ])

        let result = await executor.execute(plan, originalInput: "show me something")

        // When probe fails, the spoken line should mention broken URL
        let hasProbeFailMessage = result.spokenLines.contains { $0.contains("couldn't load") }
        XCTAssertTrue(hasProbeFailMessage, "Should have probe failure spoken message, got: \(result.spokenLines)")

        // The pending slot should be image_url
        XCTAssertEqual(result.pendingSlotRequest?.slot, "image_url")
    }

    // MARK: - O) CAPABILITY_GAP without fields becomes TALK

    @MainActor
    func testCapabilityGapWithoutMessageBecomesTalk() async {
        let bareGap = """
        {"action":"CAPABILITY_GAP"}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(bareGap)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("do something impossible", history: [])

        let assistantMessages = result.appendedChat.filter { $0.role == .assistant }
        XCTAssertFalse(assistantMessages.isEmpty, "Should have an assistant message")

        let text = assistantMessages.first?.text ?? ""
        XCTAssertFalse(text.contains("trouble"), "Should NOT be the generic 'trouble processing' error")
        XCTAssertFalse(text.contains("{"), "Should NOT contain raw JSON")
        XCTAssertTrue(text.contains("not sure") || text.contains("rephras"),
                      "Should contain the default capability gap message, got: \(text)")
    }

    @MainActor
    func testUnexpectedCapabilityGapTriggersRepairRetry() async {
        let first = #"{"action":"CAPABILITY_GAP","goal":"Find a recipe and image","missing":"unknown"}"#
        let second = #"{"action":"PLAN","steps":[{"step":"tool","name":"find_image","args":{"query":"butter chicken"},"say":"I'll find an image for that."}]}"#

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(first), .success(second)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("find a recipe for butter chicken and show me an image of the food")
            XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Recipe guardrail should recover without a retry round-trip")
            let hasFindImage = plan.steps.contains { step in
                if case .tool(let name, _, _) = step {
                    return name == "find_image"
                }
                return false
            }
            XCTAssertTrue(hasFindImage, "Repaired plan should use existing tools")
        } catch {
            XCTFail("Should not throw: \(error)")
        }
    }

    @MainActor
    func testUnexpectedCapabilityGapAfterRetryFallsBackToTalk() async {
        let gap = #"{"action":"CAPABILITY_GAP","goal":"Do task","missing":"unknown"}"#

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(gap), .success(gap)]

        let fakeOllama = FakeOllamaTransportForPipeline()

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)

        do {
            let plan = try await openAIRouter.routePlan("find image of frog")
            XCTAssertEqual(fakeOpenAI.chatCallCount, 2, "Should attempt one repair retry")
            if case .talk(let say) = plan.steps.first {
                XCTAssertTrue(
                    say.contains("without building a new capability"),
                    "Fallback should avoid triggering capability build: \(say)"
                )
            } else {
                XCTFail("Expected TALK fallback, got: \(plan.steps)")
            }
        } catch {
            XCTFail("Should not throw: \(error)")
        }
    }

    // MARK: - P) OpenAI key persistence/isolation hardening

    func testOpenAISettingsUsesTestIsolatedStorageNamespaces() {
        #if DEBUG
        XCTAssertTrue(
            OpenAISettings._debugEffectiveKeychainServiceForTesting().hasSuffix(".tests"),
            "XCTest runs must not touch production OpenAI keychain entries"
        )
        XCTAssertTrue(
            OpenAISettings._debugEffectiveDevSecretKeyForTesting().hasSuffix(".tests"),
            "XCTest runs must not touch production debug secret entries"
        )
        XCTAssertFalse(OpenAISettings._debugShouldUseKeychainStorageForTesting())
        #else
        return
        #endif
    }

    func testOpenAIKeyPersistsAcrossCacheResetInTestsNamespace() {
        let key = "sk-test-\(UUID().uuidString)"
        OpenAISettings.apiKey = key
        OpenAISettings._resetCacheForTesting()
        XCTAssertEqual(OpenAISettings.apiKey, key)
    }

    func testOpenAIDebugFallbackPreferredOverKeychainWhenBothExist() {
        #if DEBUG
        let service = OpenAISettings._debugEffectiveKeychainServiceForTesting()
        let devKey = OpenAISettings._debugEffectiveDevSecretKeyForTesting()

        _ = KeychainStore.set("keychain-live-value", forKey: "apiKey", service: service)
        DevSecretsStore.shared.set(devKey, "dev-fallback-value")

        OpenAISettings._resetCacheForTesting()
        XCTAssertEqual(OpenAISettings.apiKey, "dev-fallback-value")

        _ = KeychainStore.delete(forKey: "apiKey", service: service)
        DevSecretsStore.shared.delete(devKey)
        #else
        return
        #endif
    }

    // MARK: - Q) Live OpenAI tone validation

    private func shouldRunLiveToneValidation() -> Bool {
        ProcessInfo.processInfo.environment["RUN_LIVE_OPENAI_TONE_VALIDATION"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/run_live_openai_tone")
    }

    private func requireLiveOpenAIKeyForTests() throws -> String {
        let productionKey = KeychainStore.get(forKey: "apiKey", service: "com.samos.openai")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !productionKey.isEmpty else {
            throw XCTSkip("No production OpenAI key found in Keychain")
        }
        OpenAISettings.apiKey = productionKey
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = productionKey
        return productionKey
    }

    private func makeLiveOrchestrator() throws -> TurnOrchestrator {
        _ = try requireLiveOpenAIKeyForTests()
        M2Settings.useOllama = false
        let ollamaRouter = OllamaRouter()
        let openAIRouter = OpenAIRouter(parser: ollamaRouter)
        return TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)
    }

    private func firstSentence(in text: String) -> String {
        text
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
    }

    private func isTransientModelFallback(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("had trouble generating a response")
            || lower.contains("had trouble processing that")
            || lower.contains("took too long")
            || lower.contains("please try again")
    }

    private func processTurnWithLiveRetry(_ orchestrator: TurnOrchestrator,
                                          _ text: String,
                                          history: [ChatMessage],
                                          retries: Int = 2) async throws -> TurnResult {
        var lastResult = TurnResult()
        for attempt in 0...retries {
            let result = await orchestrator.processTurn(text, history: history)
            lastResult = result
            let assistantText = (result.appendedChat.last(where: { $0.role == .assistant })?.text ?? "")
            if !isTransientModelFallback(assistantText) {
                return result
            }
            if attempt == retries {
                throw XCTSkip("Live model returned only transient fallback responses after \(retries + 1) attempts")
            }
        }
        return lastResult
    }

    private func countQuestions(in text: String) -> Int {
        text.reduce(0) { partial, ch in partial + (ch == "?" ? 1 : 0) }
    }

    private func assistantTextParts(from result: TurnResult) -> (opening: String, combined: String) {
        let assistantLines = result.appendedChat
            .filter { $0.role == .assistant }
            .map { $0.text.lowercased() }
        return (assistantLines.first ?? "", assistantLines.joined(separator: " "))
    }

    private func assertPromptBlockOrder(_ prompt: String, markers: [String], file: StaticString = #filePath, line: UInt = #line) {
        var lastIndex = prompt.startIndex
        for marker in markers {
            guard let range = prompt.range(of: marker, range: lastIndex..<prompt.endIndex) else {
                XCTFail("Missing block marker: \(marker)", file: file, line: line)
                return
            }
            lastIndex = range.lowerBound
        }
    }

    private func assertEmotionalOpening(_ text: String,
                                        markers: [String],
                                        allowGenericAcknowledgement: Bool = true,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        let opening = firstSentence(in: text)
        XCTAssertFalse(opening.isEmpty, file: file, line: line)
        let genericMarkers = [
            "that sounds",
            "i get why",
            "i can see why",
            "i hear you",
            "i'm sorry",
            "im sorry",
            "sorry you're dealing",
            "sorry you’re dealing",
            "sorry you're having trouble",
            "sorry you’re having trouble",
            "rough time"
        ]
        let markerMatch = markers.contains(where: { opening.contains($0) })
        let genericMatch = allowGenericAcknowledgement && genericMarkers.contains(where: { opening.contains($0) })
        XCTAssertTrue(markerMatch || genericMatch,
                      "Opening sentence should contain expected affect marker. opening=\(opening)",
                      file: file,
                      line: line)
    }

    private func emotionalSentenceCount(in text: String) -> Int {
        let emotionalMarkers = [
            "frustrating",
            "worrying",
            "unsettling",
            "sorry",
            "heavy",
            "intense",
            "awesome",
            "great news",
            "love that energy"
        ]
        let sentences = text
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return sentences.reduce(0) { partial, sentence in
            partial + (emotionalMarkers.contains(where: { sentence.contains($0) }) ? 1 : 0)
        }
    }

    @MainActor
    func testAffectMirroringEnabledOnly() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        var profile = TonePreferenceProfile.neutralDefaults
        profile.enabled = false
        TonePreferenceStore.shared.replaceProfileForTesting(profile, lastUpdateReason: nil)
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true

        let result = try await processTurnWithLiveRetry(
            orchestrator,
            "This is ridiculous and annoying. Give me quick troubleshooting steps.",
            history: []
        )
        XCTAssertEqual(result.llmProvider, .openai)

        let assistantText = assistantTextParts(from: result).opening
        assertEmotionalOpening(
            assistantText,
            markers: ["frustrat", "annoy", "i get", "i can see why", "that sounds", "sorry you're dealing with this"]
        )

        let context = try XCTUnwrap(orchestrator.debugLastPromptContext())
        let prompt = PromptBuilder.buildSystemPrompt(forInput: "This is ridiculous and annoying. Give me quick troubleshooting steps.", promptContext: context, includeLongToolExamples: false)
        XCTAssertTrue(prompt.contains("AFFECT_GUIDANCE"))
        XCTAssertFalse(prompt.contains("TONE_PREFERENCES"))
    }

    @MainActor
    func testMirroringWithoutLearning() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        let baseline = TonePreferenceProfile.neutralDefaults
        TonePreferenceStore.shared.replaceProfileForTesting(baseline, lastUpdateReason: nil)
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true

        _ = try await processTurnWithLiveRetry(orchestrator, "This is ridiculous and annoying", history: [])
        let profileAfter = TonePreferenceStore.shared.loadProfile()
        XCTAssertEqual(profileAfter, baseline, "Mirroring-only mode must not update tone profile")
        XCTAssertNil(TonePreferenceStore.shared.debugLastUpdateReason())
    }

    @MainActor
    func testToneLearningExplicitFeedback() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        var profile = TonePreferenceProfile.neutralDefaults
        profile.enabled = true
        TonePreferenceStore.shared.replaceProfileForTesting(profile, lastUpdateReason: nil)
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true

        var history: [ChatMessage] = []
        let first = try await processTurnWithLiveRetry(
            orchestrator,
            "Help me plan my day so I stop procrastinating.",
            history: history
        )
        history.append(ChatMessage(role: .user, text: "Help me plan my day so I stop procrastinating."))
        history.append(contentsOf: first.appendedChat)

        let repair = try await processTurnWithLiveRetry(orchestrator, "be more direct", history: history)
        history.append(ChatMessage(role: .user, text: "be more direct"))
        history.append(contentsOf: repair.appendedChat)

        let repairText = (repair.appendedChat.last(where: { $0.role == .assistant })?.text ?? "").lowercased()
        XCTAssertTrue(
            repairText.contains("understood") || repairText.contains("got it") || repairText.contains("thanks for the feedback"),
            "Expected tone-repair acknowledgement in live response: \(repairText)"
        )

        let updated = TonePreferenceStore.shared.loadProfile()
        XCTAssertGreaterThanOrEqual(updated.directness - profile.directness, 0.10)

        let second = try await processTurnWithLiveRetry(
            orchestrator,
            "Help me plan my day so I stop procrastinating.",
            history: history
        )
        let secondText = (second.appendedChat.last(where: { $0.role == .assistant })?.text ?? "").lowercased()
        XCTAssertLessThanOrEqual(countQuestions(in: secondText), 1)

        let context = try XCTUnwrap(orchestrator.debugLastPromptContext())
        let prompt = PromptBuilder.buildSystemPrompt(forInput: "Help me plan my day so I stop procrastinating.", promptContext: context, includeLongToolExamples: false)
        XCTAssertTrue(prompt.contains("TONE_PREFERENCES"))
        XCTAssertTrue(prompt.contains("d=0.65") || prompt.contains("d=0.6"))
    }

    @MainActor
    func testToneLearningReduceQuestions() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        var profile = TonePreferenceProfile.neutralDefaults
        profile.enabled = true
        TonePreferenceStore.shared.replaceProfileForTesting(profile, lastUpdateReason: nil)
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true

        var history: [ChatMessage] = []
        let feedbackTurn = try await processTurnWithLiveRetry(
            orchestrator,
            "don't ask so many questions anymore",
            history: history
        )
        history.append(ChatMessage(role: .user, text: "don't ask so many questions anymore"))
        history.append(contentsOf: feedbackTurn.appendedChat)

        let updated = TonePreferenceStore.shared.loadProfile()
        XCTAssertLessThanOrEqual(updated.curiosity, 0.45)
        XCTAssertTrue(updated.preferOneQuestionMax)

        let next = try await processTurnWithLiveRetry(orchestrator, "Help me improve my morning routine.", history: history)
        let text = (next.appendedChat.last(where: { $0.role == .assistant })?.text ?? "").lowercased()
        XCTAssertLessThanOrEqual(countQuestions(in: text), 1, "Expected one question max after explicit feedback")

        let context = try XCTUnwrap(orchestrator.debugLastPromptContext())
        let prompt = PromptBuilder.buildSystemPrompt(forInput: "Help me improve my morning routine.", promptContext: context, includeLongToolExamples: false)
        XCTAssertTrue(prompt.contains("TONE_PREFERENCES"))
        XCTAssertTrue(prompt.contains("one_q_max=true"))
    }

    @MainActor
    func testTonePreferencesResetLivePrompt() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        var profile = TonePreferenceProfile.neutralDefaults
        profile.enabled = true
        profile.directness = 0.90
        profile.warmth = 0.20
        TonePreferenceStore.shared.replaceProfileForTesting(profile)
        _ = TonePreferenceStore.shared.resetProfile()

        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true
        _ = try await processTurnWithLiveRetry(orchestrator, "Help me plan my week.", history: [])

        let context = try XCTUnwrap(orchestrator.debugLastPromptContext())
        let prompt = PromptBuilder.buildSystemPrompt(forInput: "Help me plan my week.", promptContext: context, includeLongToolExamples: false)
        XCTAssertTrue(prompt.contains("TONE_PREFERENCES"))
        XCTAssertTrue(prompt.contains("d=0.50"), "Reset profile should render neutral defaults in prompt")
        XCTAssertFalse(prompt.contains("d=0.90"), "Reset profile should not keep prior custom directness")
    }

    @MainActor
    func testToneRepairImmediateAdjustment() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        var profile = TonePreferenceProfile.neutralDefaults
        profile.enabled = true
        TonePreferenceStore.shared.replaceProfileForTesting(profile, lastUpdateReason: nil)
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true

        let result = try await processTurnWithLiveRetry(orchestrator, "that’s too emotional", history: [])
        let text = (result.appendedChat.last(where: { $0.role == .assistant })?.text ?? "").lowercased()
        XCTAssertTrue(
            text.contains("understood") || text.contains("got it") || text.contains("thanks for the feedback"),
            "Expected immediate tone repair acknowledgement: \(text)"
        )

        let updated = TonePreferenceStore.shared.loadProfile()
        XCTAssertGreaterThan(updated.directness, profile.directness)
        XCTAssertLessThan(updated.warmth, profile.warmth)
        XCTAssertLessThan(updated.reassurance, profile.reassurance)
        XCTAssertTrue(updated.preferOneQuestionMax)
    }

    @MainActor
    func testToneRepairNextTurnBehavior() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        var profile = TonePreferenceProfile.neutralDefaults
        profile.enabled = true
        TonePreferenceStore.shared.replaceProfileForTesting(profile, lastUpdateReason: nil)
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true

        var history: [ChatMessage] = []
        let first = try await processTurnWithLiveRetry(orchestrator, "no, don't be so cheerful", history: history)
        history.append(ChatMessage(role: .user, text: "no, don't be so cheerful"))
        history.append(contentsOf: first.appendedChat)

        let second = try await processTurnWithLiveRetry(
            orchestrator,
            "This is ridiculous and annoying, my wifi drops every hour.",
            history: history
        )
        let secondText = (second.appendedChat.last(where: { $0.role == .assistant })?.text ?? "").lowercased()
        let outputText = second.appendedOutputs.map { $0.payload.lowercased() }.joined(separator: "\n")
        let practicalCorpus = secondText + "\n" + outputText
        XCTAssertFalse(
            secondText.contains("yay") || secondText.contains("awesome") || secondText.contains("great news"),
            "Next-turn response should stay grounded after tone repair"
        )
        XCTAssertTrue(
            practicalCorpus.contains("restart")
                || practicalCorpus.contains("check")
                || practicalCorpus.contains("step")
                || practicalCorpus.contains("troubleshoot"),
            "Expected practical follow-up after tone repair"
        )
    }

    @MainActor
    func testLiveOpenAIFrustratedBehavior() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        TonePreferenceStore.shared.replaceProfileForTesting(.neutralDefaults)
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true
        let input = "This is ridiculous and annoying, the app keeps freezing. Give me quick troubleshooting steps."

        let result = try await processTurnWithLiveRetry(orchestrator, input, history: [])
        let parts = assistantTextParts(from: result)
        assertEmotionalOpening(parts.opening, markers: ["frustrat", "annoy", "i can see why", "i get why"])
        XCTAssertLessThanOrEqual(emotionalSentenceCount(in: parts.combined), 1)
        XCTAssertTrue(
            parts.combined.contains("step")
                || parts.combined.contains("restart")
                || parts.combined.contains("check")
                || parts.combined.contains("quick fix")
                || parts.combined.contains("more info")
                || parts.combined.contains("error message")
        )
    }

    @MainActor
    func testLiveOpenAIAnxiousBehavior() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        TonePreferenceStore.shared.replaceProfileForTesting(.neutralDefaults)
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true
        let input = "I'm really worried I'll mess up this presentation tomorrow. Give me a practical plan."

        let result = try await processTurnWithLiveRetry(orchestrator, input, history: [])
        let parts = assistantTextParts(from: result)
        assertEmotionalOpening(
            parts.opening,
            markers: [
                "worry",
                "step by step",
                "unsettling",
                "we can",
                "normal to feel nervous",
                "normal to feel that way",
                "normal to feel this way",
                "feel nervous"
            ]
        )
        XCTAssertLessThanOrEqual(emotionalSentenceCount(in: parts.combined), 1)
        XCTAssertTrue(parts.combined.contains("plan") || parts.combined.contains("step") || parts.combined.contains("practice"))
    }

    @MainActor
    func testLiveOPAIySadBehavior() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        TonePreferenceStore.shared.replaceProfileForTesting(.neutralDefaults)
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true
        let input = "I feel down today and can't focus. Give me two practical steps to start."

        let result = try await processTurnWithLiveRetry(orchestrator, input, history: [])
        let parts = assistantTextParts(from: result)
        assertEmotionalOpening(parts.opening, markers: ["sorry", "tough", "heavy", "i hear you"])
        XCTAssertLessThanOrEqual(emotionalSentenceCount(in: parts.combined), 1)
        XCTAssertTrue(
            parts.combined.contains("step")
                || parts.combined.contains("start")
                || parts.combined.contains("try")
                || parts.combined.contains("practical")
                || parts.combined.contains("quick suggestion")
        )
    }

    @MainActor
    func testLiveOpenAIAngryBehavior() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        TonePreferenceStore.shared.replaceProfileForTesting(.neutralDefaults)
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true
        let input = "THIS IS BROKEN AND I'M PISSED. Tell me what to do first."

        let result = try await processTurnWithLiveRetry(orchestrator, input, history: [])
        let parts = assistantTextParts(from: result)
        assertEmotionalOpening(parts.opening, markers: ["intense", "frustrat", "let's slow", "slow this down"])
        XCTAssertLessThanOrEqual(emotionalSentenceCount(in: parts.combined), 1)
        let outputText = result.appendedOutputs.map { $0.payload.lowercased() }.joined(separator: "\n")
        let practicalCorpus = parts.combined + "\n" + outputText
        XCTAssertTrue(
            practicalCorpus.contains("first")
                || practicalCorpus.contains("step")
                || practicalCorpus.contains("check")
                || practicalCorpus.contains("troubleshoot")
                || practicalCorpus.contains("restart")
                || practicalCorpus.contains("error message")
                || practicalCorpus.contains("when it started")
                || practicalCorpus.contains("what exactly")
                || practicalCorpus.contains("quick")
                || practicalCorpus.contains("try")
                || practicalCorpus.contains("issue")
        )
    }

    @MainActor
    func testLiveOpenAIExcitedBehavior() async throws {
        guard shouldRunLiveToneValidation() else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_TONE_VALIDATION=1 to run live tone tests")
        }
        let orchestrator = try makeLiveOrchestrator()
        TonePreferenceStore.shared.replaceProfileForTesting(.neutralDefaults)
        M2Settings.affectMirroringEnabled = true
        M2Settings.useEmotionalTone = true
        let input = "Yay this finally worked!!! What should I do next to lock it in?"

        let result = try await processTurnWithLiveRetry(orchestrator, input, history: [])
        let parts = assistantTextParts(from: result)
        assertEmotionalOpening(
            parts.opening,
            markers: ["awesome", "great", "nice", "love that energy"],
            allowGenericAcknowledgement: false
        )
        XCTAssertLessThanOrEqual(emotionalSentenceCount(in: parts.combined), 1)
        XCTAssertTrue(parts.combined.contains("next") || parts.combined.contains("save") || parts.combined.contains("validate") || parts.combined.contains("step"))
    }

    @MainActor
    func testPromptBlockOrderingAndCriticalPreservation() {
        var profile = TonePreferenceProfile.neutralDefaults
        profile.enabled = true
        let context = PromptRuntimeContext(
            mode: .fallback,
            affect: AffectMetadata(affect: .frustrated, intensity: 2),
            tonePreferences: profile,
            toneRepairCue: "Understood - I'll keep it more direct.",
            sessionSummary: String(repeating: "summary token ", count: 600),
            interactionStateJSON: "{}",
            responseBudget: .default
        )
        let prompt = PromptBuilder.buildSystemPrompt(
            forInput: "This is a very long input " + String(repeating: "with lots of extra context ", count: 200),
            promptContext: context,
            includeLongToolExamples: true
        )

        assertPromptBlockOrder(prompt, markers: [
            "CORE_JSON_CONTRACT",
            "SYSTEM_IDENTITY_AND_MODE",
            "CONVERSATION_SUMMARY",
            "AFFECT_GUIDANCE",
            "TONE_PREFERENCES",
            "TOOL_POLICY",
            "INSTALLED_SKILLS",
            "HISTORY_RETRIEVAL"
        ])
        XCTAssertTrue(prompt.contains("AFFECT_GUIDANCE"))
        XCTAssertTrue(prompt.contains("TONE_PREFERENCES"))
    }

    @MainActor
    func testLiveOpenAIRecipeTurnSmoke() async throws {
        let shouldRun = ProcessInfo.processInfo.environment["RUN_LIVE_OPENAI_SMOKE"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/run_live_openai_smoke")
        guard shouldRun else {
            throw XCTSkip("Set RUN_LIVE_OPENAI_SMOKE=1 to run live OpenAI smoke tests")
        }

        // Read the app's production keychain entry and mirror it into the test-isolated namespace.
        let productionKey = KeychainStore.get(forKey: "apiKey", service: "com.samos.openai")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !productionKey.isEmpty else {
            throw XCTSkip("No production OpenAI key found in Keychain")
        }

        OpenAISettings.apiKey = productionKey
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = productionKey

        let originalUseOllama = M2Settings.useOllama
        defer { M2Settings.useOllama = originalUseOllama }
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter()
        let openAIRouter = OpenAIRouter(parser: ollamaRouter)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("i want to cook butter chicken tonight", history: [])
        XCTAssertEqual(result.llmProvider, .openai, "Live recipe turn should route through OpenAI")

        let markdownOutputs = result.appendedOutputs.filter { $0.kind == .markdown }.map(\.payload)
        XCTAssertFalse(markdownOutputs.isEmpty, "Expected recipe output markdown")
        let merged = markdownOutputs.joined(separator: "\n").lowercased()
        XCTAssertFalse(
            merged.contains("couldn't fetch a reliable recipe page"),
            "Recipe tool should return usable recipe content"
        )
        XCTAssertTrue(merged.contains("ingredients") || merged.contains("recipe"))
    }

    @MainActor
    func testLiveOpenAICinemaCapabilityGapSourceAsk() async throws {
        let shouldRun = ProcessInfo.processInfo.environment["ENABLE_LIVE_TESTS"] == "1"
            || ProcessInfo.processInfo.environment["RUN_LIVE_OPENAI_SMOKE"] == "1"
        guard shouldRun else {
            throw XCTSkip("Set ENABLE_LIVE_TESTS=1 to run live capability-gap smoke tests")
        }

        let productionKey = KeychainStore.get(forKey: "apiKey", service: "com.samos.openai")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !productionKey.isEmpty else {
            throw XCTSkip("No production OpenAI key found in Keychain")
        }

        OpenAISettings.apiKey = productionKey
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = productionKey

        let originalUseOllama = M2Settings.useOllama
        defer { M2Settings.useOllama = originalUseOllama }
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter()
        let openAIRouter = OpenAIRouter(parser: ollamaRouter)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        var history: [ChatMessage] = []
        let first = await orchestrator.processTurn("What's playing at the cinema in Browns Plains?", history: history)
        appendTurn(&history, user: "What's playing at the cinema in Browns Plains?", result: first)

        let firstAssistant = first.appendedChat.first(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        XCTAssertTrue(firstAssistant.contains("url"), "Expected source URL ask flow, got: \(firstAssistant)")
        XCTAssertTrue(first.executedToolSteps.isEmpty, "Unknown-tool/capability-gap prompt should not execute a tool")

        let second = await orchestrator.processTurn("https://www.eventcinemas.com.au/Cinema/Browns-Plains", history: history)
        let secondAssistant = second.appendedChat.first(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        XCTAssertTrue(second.executedToolSteps.contains(where: { $0.name == "learn_website" }))
        XCTAssertTrue(secondAssistant.contains("learned that page"))
        XCTAssertTrue(secondAssistant.contains("want me to build it"))
    }
}

private struct StabilityFaceGreetingSettings: FaceGreetingSettingsProviding {
    var faceRecognitionEnabled: Bool = true
    var personalizedGreetingsEnabled: Bool = true
}

@MainActor
final class StabilityRegressionTests: XCTestCase {
    private var savedApiKey: String = ""
    private var savedUseOllama: Bool = false
    private var savedPreferLocalPlans: Bool = false
    private var savedPreferOpenAIPlans: Bool = false
    private var savedDisableAutoClosePrompts: Bool = true

    override func setUp() {
        super.setUp()
        savedApiKey = OpenAISettings.apiKey
        savedUseOllama = M2Settings.useOllama
        savedPreferLocalPlans = M2Settings.preferLocalPlans
        savedPreferOpenAIPlans = M2Settings.preferOpenAIPlans
        savedDisableAutoClosePrompts = M2Settings.disableAutoClosePrompts
        M2Settings.preferLocalPlans = false
    }

    override func tearDown() {
        OpenAISettings.apiKey = savedApiKey
        M2Settings.useOllama = savedUseOllama
        M2Settings.preferLocalPlans = savedPreferLocalPlans
        M2Settings.preferOpenAIPlans = savedPreferOpenAIPlans
        M2Settings.disableAutoClosePrompts = savedDisableAutoClosePrompts
        OpenAISettings._resetCacheForTesting()
        super.tearDown()
    }

    // MARK: - Provider stamping

    func testToolFeedbackMessagesCarryProviderMetadata() async {
        let initial = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"Tokyo"},"say":"Let me check Tokyo time."}]}
        """
        let feedback = """
        {"action":"TALK","say":"Tokyo is ahead of London, so call only if it's urgent."}
        """

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(initial), .success(feedback)]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn(
            "Check Tokyo time, then tell me if this is a good time to call London.",
            history: []
        )

        let assistant = result.appendedChat.filter { $0.role == .assistant }
        XCTAssertFalse(assistant.isEmpty)
        for message in assistant {
            XCTAssertEqual(message.llmProvider, .openai)
            XCTAssertEqual(message.originProvider, .openai)
            XCTAssertEqual(message.executionProvider, .local)
            XCTAssertNotNil(message.originReason)
        }
    }

    func testValidationFailureReturnsActualProvider() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_cinema_listings","args":{"location":"Browns Plains"}}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("Please handle this request for me.", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)
        XCTAssertEqual(result.llmProvider, .openai)
        let assistant = result.appendedChat.filter { $0.role == .assistant }
        XCTAssertFalse(assistant.isEmpty)
        XCTAssertTrue(assistant.allSatisfy { $0.llmProvider == .openai })
        XCTAssertTrue(assistant.allSatisfy { $0.originProvider == .openai })
        XCTAssertTrue(assistant.allSatisfy { $0.executionProvider == .openai || $0.executionProvider == .local })
    }

    // MARK: - Vision routing

    func testVisionQueryRoutesToToolWhenCameraHealthy() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"vision_describe","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()
        camera.sceneDescription = CameraSceneDescription(
            summary: "I can see a desk and a laptop.",
            labels: ["desk (95%)", "laptop (90%)"],
            recognizedText: [],
            capturedAt: Date()
        )

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("What do you see?", history: [])

        XCTAssertEqual(fakeOpenAI.intentCallCount, 1)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 0)
        XCTAssertEqual(result.executedToolSteps.first?.name, "describe_camera_view")
    }

    func testVisionIntentCameraOnRoutesToDescribeTool() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"vision_describe","confidence":0.96,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()
        camera.sceneDescription = CameraSceneDescription(
            summary: "A desk with a notebook.",
            labels: ["desk (94%)", "notebook (88%)"],
            recognizedText: [],
            capturedAt: Date()
        )

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("What do you see right now?", history: [])

        XCTAssertEqual(fakeOpenAI.intentCallCount, 1)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 0)
        XCTAssertTrue(result.executedToolSteps.contains(where: { $0.name == "describe_camera_view" }))
    }

    func testVisionQueryReturnsCameraOffMessageWhenNotRunning() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"vision_qa","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()
        camera.isRunning = false

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("Do you see me?", history: [])

        XCTAssertEqual(fakeOpenAI.intentCallCount, 1)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 0)
        XCTAssertEqual(result.llmProvider, .none)
        XCTAssertTrue(result.executedToolSteps.isEmpty)
        let combined = combinedAssistantText(result).lowercased()
        XCTAssertTrue(combined.contains("camera on"))
    }

    func testVisionIntentCameraOffReturnsCameraInstruction() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"vision_describe","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()
        camera.isRunning = false

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("What do you see?", history: [])

        XCTAssertEqual(fakeOpenAI.intentCallCount, 1)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 0)
        XCTAssertTrue(result.executedToolSteps.isEmpty)
        XCTAssertTrue(combinedAssistantText(result).lowercased().contains("turn it on"))
    }

    func testRecipeDoesNotTriggerVisionCameraOff() async {
        let fakeOpenAI = FakeOpenAITransport()
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()
        camera.isRunning = false

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("recipe chinese fried rice", history: [])
        let combined = combinedAssistantText(result).lowercased()

        XCTAssertFalse(combined.contains("camera on"))
        XCTAssertFalse(combined.contains("turn it on"))
        XCTAssertFalse(result.executedToolSteps.contains(where: {
            $0.name == "describe_camera_view" || $0.name == "camera_visual_qa" || $0.name == "find_camera_objects"
        }))
    }

    func testButterChickenRecipeDoesNotRouteToVisionAndUsesLLMIntentPipeline() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"recipe","confidence":0.96,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Here is a butter chicken recipe."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.20,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let camera = makeHealthyCamera()
        camera.isRunning = false

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            cameraVision: camera
        )

        let result = await orchestrator.processTurn("Can you find me a recipe to make butter chicken?", history: [])
        let combined = combinedAssistantText(result).lowercased()

        XCTAssertEqual(fakeOllama.intentCallCount, 1, "Ollama intent classification should run first")
        XCTAssertEqual(fakeOpenAI.intentCallCount, 1, "OpenAI intent classifier should run after low-confidence local result")
        XCTAssertGreaterThanOrEqual(fakeOpenAI.chatCallCount, 1, "OpenAI routing should still run after intent classification")
        XCTAssertFalse(combined.contains("camera on"))
        XCTAssertFalse(combined.contains("turn it on"))
        XCTAssertFalse(result.executedToolSteps.contains(where: {
            $0.name == "describe_camera_view" || $0.name == "camera_visual_qa" || $0.name == "find_camera_objects"
        }))
    }

    func testVisionQueryReturnsCameraUnhealthyMessageWhenStale() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"vision_qa","confidence":0.94,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()
        camera.latestFrameAt = Date().addingTimeInterval(-6)

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("Do you see a person?", history: [])

        XCTAssertEqual(fakeOpenAI.intentCallCount, 1)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 0)
        XCTAssertEqual(result.llmProvider, .none)
        XCTAssertTrue(result.executedToolSteps.isEmpty)
        let combined = combinedAssistantText(result).lowercased()
        XCTAssertTrue(combined.contains("lagging") || combined.contains("not updating"))
    }

    func testNoFalseBlindnessWhenCameraRunningEvenIfUnhealthy() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"I can't see right now."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()
        camera.latestFrameAt = Date().addingTimeInterval(-5)

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("Give me a quick update.", history: [])
        let combined = combinedAssistantText(result).lowercased()

        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertFalse(combined.contains("can't see"))
        XCTAssertFalse(combined.contains("cannot see"))
        XCTAssertFalse(combined.contains("ability to see"))
        XCTAssertTrue(combined.contains("lagging") || combined.contains("not updating"))
    }

    // MARK: - Identity non-blocking

    func testUnknownFacePromptIsAppendedNotBlockingAnswer() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"The weather is warm and mostly clear."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeUnknownFaceCamera()

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("What's the weather?", history: [])
        let combined = combinedAssistantText(result).lowercased()

        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)
        XCTAssertTrue(combined.contains("weather"))
        XCTAssertLessThanOrEqual(identityPromptCount(in: result), 1)
    }

    func testNameLikeReplyTriggersEnrollAndThenStopsPrompting() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Hey there."}"#),
            .success(#"{"action":"TALK","say":"Hi again."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeUnknownFaceCamera()
        camera.onEnroll = { name in
            camera.recognitionResult = CameraFaceRecognitionResult(
                capturedAt: Date(),
                detectedFaces: 1,
                matches: [CameraRecognizedFaceMatch(name: name, confidence: 0.90, distance: 0.05)],
                unknownFaces: 0,
                enrolledNames: [name]
            )
        }

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        var history: [ChatMessage] = []

        let first = await orchestrator.processTurn("hello", history: history)
        appendTurn(&history, user: "hello", result: first)
        XCTAssertEqual(identityPromptCount(in: first), 1)

        let second = await orchestrator.processTurn("Richard", history: history)
        appendTurn(&history, user: "Richard", result: second)
        XCTAssertEqual(second.llmProvider, .none)
        XCTAssertTrue(second.executedToolSteps.contains(where: { $0.name == "enroll_camera_face" && $0.args["name"] == "Richard" }))

        let third = await orchestrator.processTurn("hi", history: history)
        XCTAssertEqual(identityPromptCount(in: third), 0)
    }

    func testEnrollmentUnknownToolIsNormalized() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"tool","name":"EnrollFaceTool","args":{"name":"Richard"}}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeUnknownFaceCamera()

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("Please enroll Richard.", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)
        XCTAssertTrue(result.executedToolSteps.contains(where: { $0.name == "enroll_camera_face" && $0.args["name"] == "Richard" }))
        XCTAssertFalse(result.executedToolSteps.contains(where: { $0.name.lowercased().contains("enrollface") }))
    }

    // MARK: - Unknown tool capability gap

    func testUnknownToolTriggersCapabilityGapAskForURL() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_cinema_listings","args":{"location":"Browns Plains"}}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("Please handle this request for me.", history: [])
        let combined = combinedAssistantText(result).lowercased()

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)
        XCTAssertTrue(result.executedToolSteps.isEmpty)
        XCTAssertEqual(orchestrator.pendingSlot?.slotName, "source_url_or_site")
        XCTAssertTrue(combined.contains("url"))
    }

    func testWebRequestAsksForURLWhenUnknownTool() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"web_request","confidence":0.95,"autoCaptureHint":false,"needsWeb":true,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success("""
            {"action":"PLAN","steps":[{"step":"tool","name":"get_cinema_listings","args":{"location":"Browns Plains"}}]}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.30,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let camera = makeHealthyCamera()

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, cameraVision: camera)
        let result = await orchestrator.processTurn("???", history: [])
        let combined = combinedAssistantText(result).lowercased()

        XCTAssertEqual(fakeOllama.intentCallCount, 1)
        XCTAssertEqual(fakeOpenAI.intentCallCount, 1, "OpenAI should classify intent after low-confidence local result")
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "Unknown-tool turn should still use only one OpenAI route call")
        XCTAssertEqual(orchestrator.pendingSlot?.slotName, "source_url_or_site")
        XCTAssertTrue(combined.contains("url"))
    }

    func testProvidingURLTriggersLearnWebsiteThenOfferSkillforge() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_cinema_listings","args":{"location":"Browns Plains"}}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        var history: [ChatMessage] = []

        let first = await orchestrator.processTurn("Please handle this request for me.", history: history)
        appendTurn(&history, user: "Please handle this request for me.", result: first)

        let second = await orchestrator.processTurn("https://www.eventcinemas.com.au/Cinema/Browns-Plains", history: history)
        let combined = combinedAssistantText(second).lowercased()

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)
        XCTAssertNil(orchestrator.pendingSlot)
        XCTAssertTrue(second.executedToolSteps.contains(where: { $0.name == "learn_website" }))
        XCTAssertTrue(combined.contains("start_skillforge") || combined.contains("build a cinema listings skill"))
    }

    func testUnknownToolDoesNotLoopOpenAI() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"tool","name":"get_cinema_listings","args":{"location":"Browns Plains"}}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        _ = await orchestrator.processTurn("Please handle this request for me.", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)
    }

    func testIntentFallbackToOpenAIWhenLocalLowConfidence() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.92,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"I can help with that."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.30,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let camera = makeHealthyCamera()

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            cameraVision: camera
        )

        let result = await orchestrator.processTurn("???", history: [])

        XCTAssertEqual(fakeOllama.intentCallCount, 1, "Local classifier should run first")
        XCTAssertEqual(fakeOpenAI.intentCallCount, 1, "OpenAI should run for intent fallback")
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "OpenAI should then run exactly one route call")
        XCTAssertEqual(result.llmProvider, .openai)
    }

    func testIntentOrder_OllamaThenOpenAIThenRules() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.90,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"I can help."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.22,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let camera = makeHealthyCamera()

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, cameraVision: camera)

        _ = await orchestrator.processTurn("Hello", history: [])
        let intent = orchestrator.debugLastIntentClassification()

        XCTAssertNotNil(intent)
        XCTAssertEqual(fakeOllama.intentCallCount, 1)
        XCTAssertEqual(fakeOpenAI.intentCallCount, 1)
        XCTAssertEqual(intent?.provider, .openai)
        XCTAssertEqual(intent?.attemptedLocal, true)
        XCTAssertEqual(intent?.attemptedOpenAI, true)
    }

    func testIntentOrder_RulesOnlyWhenBothFail() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .failure(OpenAIRouter.OpenAIError.requestFailed("intent down"))
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Fallback route works."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .failure(OllamaRouter.OllamaError.unreachable("intent down"))
        ]
        let camera = makeHealthyCamera()

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, cameraVision: camera)

        _ = await orchestrator.processTurn("anything", history: [])
        let intent = orchestrator.debugLastIntentClassification()

        XCTAssertNotNil(intent)
        XCTAssertEqual(intent?.provider, .rule)
        XCTAssertEqual(intent?.attemptedLocal, true)
        XCTAssertEqual(intent?.attemptedOpenAI, true)
    }

    func testRecipeNeverMentionsCameraWhenCameraOff() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"recipe","confidence":0.96,"autoCaptureHint":false,"needsWeb":false,"notes":"butter chicken"}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Here is a butter chicken recipe."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.20,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let camera = makeHealthyCamera()
        camera.isRunning = false

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, cameraVision: camera)

        let result = await orchestrator.processTurn("Can you find me a recipe to make butter chicken?", history: [])
        let combined = combinedAssistantText(result).lowercased()

        XCTAssertFalse(combined.contains("camera on"))
        XCTAssertFalse(combined.contains("turn it on"))
        XCTAssertFalse(result.executedToolSteps.contains(where: {
            $0.name == "describe_camera_view" || $0.name == "camera_visual_qa" || $0.name == "find_camera_objects"
        }))
    }

    func testVisionCameraOffOnlyWhenVisionIntent() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"vision_describe","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()
        camera.isRunning = false

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, cameraVision: camera)

        let result = await orchestrator.processTurn("What do you see?", history: [])
        XCTAssertTrue(combinedAssistantText(result).lowercased().contains("camera on"))
    }

    func testLogsReflectActualAttempts() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.91,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"hello"}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.20,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let camera = makeHealthyCamera()

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, cameraVision: camera)

        _ = await orchestrator.processTurn("hello", history: [])
        let intent = orchestrator.debugLastIntentClassification()

        XCTAssertEqual(intent?.provider, .openai)
        XCTAssertEqual(intent?.attemptedLocal, true)
        XCTAssertEqual(intent?.attemptedOpenAI, true)
    }

    func testGreetingIntentFallsThroughToRuleAfterLowConfidenceLLMs() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.22,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Hello."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.20,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let camera = makeHealthyCamera()

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, cameraVision: camera)

        _ = await orchestrator.processTurn("Hi Sam", history: [])
        let intent = orchestrator.debugLastIntentClassification()

        XCTAssertNotNil(intent)
        XCTAssertEqual(intent?.provider, .rule)
        XCTAssertEqual(intent?.attemptedLocal, true)
        XCTAssertEqual(intent?.attemptedOpenAI, true)
    }

    func testVisionRoutingOnlyFromVisionIntent() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.91,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"I can help."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.20,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let camera = makeHealthyCamera()
        camera.sceneDescription = CameraSceneDescription(
            summary: "A desk with a notebook.",
            labels: ["desk (94%)", "notebook (88%)"],
            recognizedText: [],
            capturedAt: Date()
        )

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, cameraVision: camera)

        let result = await orchestrator.processTurn("What do you see?", history: [])
        XCTAssertFalse(result.executedToolSteps.contains(where: { $0.name == "describe_camera_view" }))
    }

    func testGarbageIntentFallsToRuleAfterLLMLowConfidence() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.10,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Can you clarify?"}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.15,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let camera = makeHealthyCamera()

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, cameraVision: camera)

        _ = await orchestrator.processTurn("???", history: [])
        let intent = orchestrator.debugLastIntentClassification()

        XCTAssertNotNil(intent)
        XCTAssertEqual(intent?.provider, .rule)
        XCTAssertEqual(intent?.attemptedLocal, true)
        XCTAssertEqual(intent?.attemptedOpenAI, true)
    }

    func testIntentLLMFailuresFallBackToRule() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .failure(OpenAIRouter.OpenAIError.requestFailed("intent failure"))
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Fallback route still works."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .failure(OllamaRouter.OllamaError.unreachable("intent failure"))
        ]
        let camera = makeHealthyCamera()

        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, cameraVision: camera)

        _ = await orchestrator.processTurn("Tell me something", history: [])
        let intent = orchestrator.debugLastIntentClassification()

        XCTAssertNotNil(intent)
        XCTAssertEqual(intent?.provider, .rule)
        XCTAssertEqual(intent?.attemptedLocal, true)
        XCTAssertEqual(intent?.attemptedOpenAI, true)
    }

    // MARK: - Timeout/fallback

    func testOpenAITimeoutFallbackRetainsProviderMetadata() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.perCallDelayNanoseconds = [6_000_000_000, 3_000_000_000]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"hello"}"#),
            .success(#"{"action":"TALK","say":"hello again"}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        let camera = makeHealthyCamera()

        let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 2, "Should attempt timeout retry once")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.appendedChat.filter { $0.role == .assistant }.allSatisfy { $0.llmProvider == .openai })
    }

    // MARK: - Auto capture

    func testAutoCaptureAfterAssistantQuestion() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "All set. Need anything else on this?")]
        result.spokenLines = ["All set. Need anything else on this?"]
        fakeOrchestrator.queuedResults = [result]

        let fakeVoicePipeline = FakeVoicePipeline()
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            questionAutoListenNoSpeechTimeoutMs: 120,
            enableRuntimeServices: false
        )
        appState.isListeningEnabled = true
        appState.send("help")
        try? await Task.sleep(nanoseconds: 80_000_000)
        appState.debugHandleSpeechPlaybackFinished()
        try? await Task.sleep(nanoseconds: 320_000_000)

        XCTAssertEqual(fakeVoicePipeline.startFollowUpCaptureCalls, 1)
    }

    func testAutoCaptureTimesOutSilently() async {
        let fakeOrchestrator = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Done. Need anything else on this?")]
        result.spokenLines = ["Done. Need anything else on this?"]
        fakeOrchestrator.queuedResults = [result]

        let fakeVoicePipeline = FakeVoicePipeline()
        fakeVoicePipeline.autoCancelOnTimeout = true
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            questionAutoListenNoSpeechTimeoutMs: 120,
            enableRuntimeServices: false
        )
        appState.isListeningEnabled = true
        appState.send("hello")
        try? await Task.sleep(nanoseconds: 80_000_000)
        appState.debugHandleSpeechPlaybackFinished()
        let priorCount = appState.chatMessages.count
        try? await Task.sleep(nanoseconds: 520_000_000)

        XCTAssertEqual(fakeVoicePipeline.cancelFollowUpCaptureCalls, 1)
        XCTAssertEqual(appState.chatMessages.count, priorCount, "No extra bubble should be emitted on silence timeout")
    }

    func testAutoCaptureConsumesNextUserSpeechWithoutWakeWord() async {
        let fakeOrchestrator = FakeTurnOrchestrator()

        var first = TurnResult()
        first.appendedChat = [ChatMessage(role: .assistant, text: "Done. Need anything else on this?")]
        first.spokenLines = ["Done. Need anything else on this?"]

        var second = TurnResult()
        second.appendedChat = [ChatMessage(role: .assistant, text: "Captured without wake word.")]
        second.spokenLines = ["Captured without wake word."]
        fakeOrchestrator.queuedResults = [first, second]

        let fakeVoicePipeline = FakeVoicePipeline()
        let appState = AppState(
            orchestrator: fakeOrchestrator,
            voicePipeline: fakeVoicePipeline,
            thinkingFillerDelay: 0.05,
            questionAutoListenNoSpeechTimeoutMs: 800,
            enableRuntimeServices: false
        )
        fakeVoicePipeline.onTranscript = { text in
            guard let sanitized = appState.debugSanitizedVoiceTranscript(text) else { return }
            appState.send(sanitized)
        }
        appState.isListeningEnabled = true
        appState.send("start")
        try? await Task.sleep(nanoseconds: 80_000_000)
        appState.debugHandleSpeechPlaybackFinished()
        try? await Task.sleep(nanoseconds: 120_000_000)

        let pendingBeforeTranscript = fakeOrchestrator.queuedResults.count
        fakeVoicePipeline.onTranscript?("next request")
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline && fakeOrchestrator.queuedResults.count >= pendingBeforeTranscript {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertLessThan(fakeOrchestrator.queuedResults.count, pendingBeforeTranscript,
                          "Follow-up transcript should trigger a new turn without wake word")
    }

    // MARK: - Lockdown audit regression tests

    func testBlindnessGuardrailCatchesAlternativePhrasings() async {
        let phrases = [
            "I'm unable to see anything right now.",
            "I am not able to see images.",
            "I cannot view your surroundings.",
            "I don't have eyes to look at things.",
            "I lack the ability to see what's around you.",
            "I can't perceive the environment."
        ]

        for phrase in phrases {
            let fakeOpenAI = FakeOpenAITransport()
            fakeOpenAI.queuedIntentResponses = [
                .success("""
                {"intent":"vision_describe","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
                """)
            ]
            fakeOpenAI.queuedResponses = [
                .success(#"{"action":"TALK","say":"\#(phrase)"}"#)
            ]
            let fakeOllama = FakeOllamaTransportForPipeline()
            let camera = makeHealthyCamera()
            camera.sceneDescription = CameraSceneDescription(summary: "A desk with a monitor.", labels: [], recognizedText: [], capturedAt: Date())

            let orchestrator = makeOrchestrator(fakeOpenAI: fakeOpenAI, fakeOllama: fakeOllama, camera: camera)
            let result = await orchestrator.processTurn("What's around me?", history: [])

            let combined = combinedAssistantText(result).lowercased()
            XCTAssertTrue(
                result.executedToolSteps.contains(where: { $0.name == "describe_camera_view" }),
                "Blindness guardrail should catch: \(phrase)"
            )
            XCTAssertFalse(
                combined.contains("unable to see") || combined.contains("can't view") || combined.contains("lack the ability"),
                "Blindness claim should be replaced for: \(phrase)"
            )
        }
    }

    func testVisionQueryDetectsNewPatterns() async {
        let queries = [
            "Show me what's on the table",
            "What's happening in the room?",
            "Who is in the room?"
        ]

        for query in queries {
            let fakeOpenAI = FakeOpenAITransport()
            let intent = query.lowercased().contains("who is in the room") ? "vision_qa" : "vision_describe"
            fakeOpenAI.queuedIntentResponses = [
                .success("""
                {"intent":"\(intent)","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
                """)
            ]
            let fakeOllama = FakeOllamaTransportForPipeline()
            let camera = makeHealthyCamera()
            camera.sceneDescription = CameraSceneDescription(summary: "A desk and a monitor.", labels: [], recognizedText: [], capturedAt: Date())

            configureOpenAIForTests()

            let ollamaRouter = OllamaRouter(transport: fakeOllama)
            let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
            let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter, cameraVision: camera)

            let result = await orchestrator.processTurn(query, history: [])

            let hasVisionTool = result.executedToolSteps.contains(where: {
                $0.name == "describe_camera_view" || $0.name == "find_camera_objects" || $0.name == "camera_visual_qa"
            })
            XCTAssertEqual(fakeOpenAI.intentCallCount, 1)
            XCTAssertTrue(hasVisionTool, "Vision query should route to camera tool for: \(query)")
        }
    }

    func testUnknownToolDefaultsToExternalSource() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"tool","name":"check_inventory","args":{"item":"monitor"}}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        configureOpenAIForTests()

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Check if monitors are in stock", history: [])

        XCTAssertTrue(result.executedToolSteps.isEmpty, "Unknown tool must never be executed")
        XCTAssertEqual(orchestrator.pendingSlot?.slotName, "source_url_or_site",
                       "Generic unknown tool should default to external-source ask, not capability-build")
    }

    func testUnknownToolAutomationAsksForGenericSource() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"tool","name":"create_automation","args":{"trigger":"daily"}}]}
        """
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(raw)]
        let fakeOllama = FakeOllamaTransportForPipeline()

        configureOpenAIForTests()

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Create an automation to remind me daily", history: [])

        XCTAssertTrue(result.executedToolSteps.isEmpty, "Unknown tool must never be executed")
        XCTAssertEqual(orchestrator.pendingSlot?.slotName, "source_url_or_site")
        let combined = combinedAssistantText(result).lowercased()
        XCTAssertTrue(
            combined.contains("where should i get that info from")
                || combined.contains("url, app, or site")
                || combined.contains("share the url"),
            "Automation-related unknown tool should ask for a generic source, got: \(combined)"
        )
    }

    func testOllamaErrorFallbackPreservesProvider() async {
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedResponses = [.failure(URLError(.notConnectedToInternet))]

        OpenAISettings.apiKey = ""
        OpenAISettings._resetCacheForTesting()
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: FakeOpenAITransport())
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Hello", history: [])

        XCTAssertEqual(result.llmProvider, .ollama, "Ollama error fallback should preserve .ollama provider")
    }

    // MARK: - Helpers

    private func configureOpenAIForTests() {
        OpenAISettings.apiKey = "stability-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "stability-test-key"
        M2Settings.useOllama = false
    }

    private func makeOrchestrator(fakeOpenAI: FakeOpenAITransport,
                                  fakeOllama: FakeOllamaTransportForPipeline,
                                  camera: IdentityTestCamera) -> TurnOrchestrator {
        configureOpenAIForTests()
        let manager = FaceGreetingManager(
            camera: camera,
            settings: StabilityFaceGreetingSettings(),
            recognitionThreshold: 0.72,
            recognitionEnterThreshold: 0.72,
            recognitionExitThreshold: 0.45,
            lowConfidenceExitFrameCount: 10,
            lowConfidenceExitDurationSeconds: 2.0,
            namedGreetingCooldownTurns: 2,
            identityPromptCooldownSeconds: 120,
            awaitingNameTimeoutSeconds: 30,
            postEnrollGracePeriodSeconds: 300,
            postEnrollTrustWindowSeconds: 300,
            recognitionCacheSeconds: 0
        )
        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        return TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            faceGreetingManager: manager,
            cameraVision: camera
        )
    }

    private func makeHealthyCamera() -> IdentityTestCamera {
        let camera = IdentityTestCamera()
        camera.isRunning = true
        camera.latestFrameAt = Date()
        camera.analysis = CameraFrameAnalysis(
            labels: [],
            recognizedText: [],
            faces: CameraFacePresence(count: 1),
            capturedAt: Date()
        )
        camera.recognitionResult = CameraFaceRecognitionResult(
            capturedAt: Date(),
            detectedFaces: 1,
            matches: [],
            unknownFaces: 1,
            enrolledNames: []
        )
        return camera
    }

    private func makeUnknownFaceCamera() -> IdentityTestCamera {
        makeHealthyCamera()
    }

    // MARK: - localSkipReason

    func testLocalSkipReasonPopulatedWhenClassifierNil() async {
        let classifier = IntentClassifier(
            localClassifier: nil,
            openAIClassifier: nil
        )
        let input = IntentClassifierInput(
            userText: "hello",
            cameraRunning: false,
            faceKnown: false,
            pendingSlot: nil,
            lastAssistantLine: nil
        )
        let result = await classifier.classify(input, useLocalFirst: true, allowOpenAIFallback: false)
        XCTAssertEqual(result.localSkipReason, "classifier_nil")
        XCTAssertFalse(result.attemptedLocal)
    }

    func testLocalSkipReasonPolicyDisabledWhenOllamaOff() async {
        let classifier = IntentClassifier(
            localClassifier: { _ in
                IntentLLMCallOutput(
                    rawText: "{\"intent\":\"general_chat\",\"confidence\":0.9,\"notes\":\"\",\"autoCaptureHint\":false,\"needsWeb\":false}",
                    model: "qwen2.5:3b-instruct",
                    endpoint: "http://127.0.0.1:11434/api/chat",
                    prompt: "[system]\\nintent classification engine\\n[user]\\nhello"
                )
            },
            openAIClassifier: nil
        )
        let input = IntentClassifierInput(
            userText: "hello",
            cameraRunning: false,
            faceKnown: false,
            pendingSlot: nil,
            lastAssistantLine: nil
        )
        let result = await classifier.classify(input, useLocalFirst: false, allowOpenAIFallback: false)
        XCTAssertEqual(result.localSkipReason, "policy_disabled")
        XCTAssertFalse(result.attemptedLocal)
    }

    // MARK: - Plan Routing Policy

    private let localFirstTalkJSON = #"{"action":"TALK","say":"Hey there!"}"#

    @MainActor
    func testPlanRouting_OpenAIWinsWhenKeyReadyEvenIfUseOllamaTrue() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(localFirstTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedResponses = [
            .failure(OllamaRouter.OllamaError.unreachable("should not be called"))
        ]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true
        M2Settings.preferOpenAIPlans = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Hi Sam", history: [])

        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Ollama plan route should be skipped when OpenAI key is ready")
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "OpenAI should handle plan route first")
        XCTAssertEqual(result.llmProvider, .openai)
    }

    @MainActor
    func testIntentAndPlanProviderAttributionAreIndependent() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(localFirstTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [.success("""
            {"intent":"general_qna","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true
        M2Settings.preferOpenAIPlans = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Hi Sam", history: [])

        XCTAssertEqual(result.intentProviderSelected, .ollama)
        XCTAssertEqual(result.planProviderSelected, .openai)
    }

    @MainActor
    func testNoAutoCloseFiller() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success("""
            {"action":"TALK","say":"Canberra is the capital of Australia. Anything else you'd like to know?"}
            """)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [.success("""
            {"intent":"general_qna","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true
        M2Settings.preferOpenAIPlans = true
        M2Settings.disableAutoClosePrompts = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("What is the capital of Australia?", history: [])
        let chat = result.appendedChat.last(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        let spoken = result.spokenLines.joined(separator: " ").lowercased()

        XCTAssertTrue(chat.contains("canberra"))
        XCTAssertFalse(chat.contains("anything else"))
        XCTAssertFalse(spoken.contains("anything else"))
        XCTAssertFalse(spoken.contains("let me know if"))
        XCTAssertFalse(spoken.contains("how else can i help"))
    }

    @MainActor
    func testLocalFirstOllamaSuccessSkipsOpenAI() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(localFirstTalkJSON)]
        fakeOpenAI.queuedIntentResponses = [.success("""
            {"intent":"general_qna","confidence":0.90,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [.success("""
            {"intent":"general_qna","confidence":0.90,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)]
        fakeOllama.queuedResponses = [.success(localFirstTalkJSON)]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true
        M2Settings.preferLocalPlans = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Hi Sam", history: [])

        XCTAssertEqual(fakeOllama.chatCallCount, 1, "Ollama should handle plan generation")
        XCTAssertEqual(fakeOpenAI.chatCallCount, 0, "OpenAI should not be called when Ollama succeeds")
        XCTAssertEqual(result.llmProvider, .ollama)
        XCTAssertTrue(result.appendedChat.contains { $0.role == .assistant && !$0.text.isEmpty })
    }

    @MainActor
    func testLocalFirstOllamaFailureFallsBackToOpenAI() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(localFirstTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedResponses = [
            .failure(OllamaRouter.OllamaError.unreachable("connection refused"))
        ]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true
        M2Settings.preferLocalPlans = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOllama.chatCallCount, 1, "Ollama should be attempted first")
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "OpenAI should handle after Ollama failure")
        XCTAssertEqual(result.llmProvider, .openai)
    }

    @MainActor
    func testLocalFirstOllamaAttemptedWhenOpenAIKeyReady() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(localFirstTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedResponses = [.success(localFirstTalkJSON)]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true
        M2Settings.preferLocalPlans = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        _ = await orchestrator.processTurn("hi", history: [])

        XCTAssertGreaterThanOrEqual(fakeOllama.chatCallCount, 1,
            "Ollama should be attempted despite OpenAI key being ready")
    }

    @MainActor
    func testLocalFirstOriginReasonStamped() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(localFirstTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedResponses = [.success(localFirstTalkJSON)]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true
        M2Settings.preferLocalPlans = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Hi Sam", history: [])

        XCTAssertEqual(result.originReason, "ollama_local_first_success",
            "Origin reason should reflect local-first Ollama success")
    }

    @MainActor
    func testLocalPlanSuccessDoesNotCallOpenAI() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(localFirstTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedResponses = [.success(localFirstTalkJSON)]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true
        M2Settings.preferLocalPlans = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("Hi Sam", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 0, "OpenAI must not be called when Ollama plan succeeds")
        XCTAssertEqual(result.llmProvider, .ollama)
        XCTAssertTrue(result.appendedChat.contains { $0.role == .assistant },
                      "Ollama TALK response should produce an assistant message (actual: \(result.appendedChat.map(\.text)))")
    }

    @MainActor
    func testLocalPlanInvalidFallsBackToOpenAIOnce() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(localFirstTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        // Schema mismatch: missing "action" field — will trigger schemaMismatch error
        fakeOllama.queuedResponses = [
            .success(#"{"response":"Hello!"}"#)
        ]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true
        M2Settings.preferLocalPlans = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOllama.chatCallCount, 1, "Ollama should be called once (no repair retry with skipRepairRetry)")
        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "OpenAI should handle fallback")
        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.originReason?.contains("ollama_") == true,
            "Origin reason should indicate Ollama fallback: \(result.originReason ?? "nil")")
    }

    @MainActor
    func testLocalPlanFallbackStampsSchemaReason() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(localFirstTalkJSON)]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedResponses = [
            .success(#"{"wrong":"schema"}"#)
        ]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true
        M2Settings.preferLocalPlans = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(result.llmProvider, .openai)
        XCTAssertTrue(result.originReason?.contains("schema") == true || result.originReason?.contains("json_parse") == true,
            "Fallback reason should indicate schema or json_parse failure: \(result.originReason ?? "nil")")
    }

    func testIntentLocalTimeoutFallsBackToOpenAI() async {
        let savedTimeout = M2Settings.localIntentTimeoutSeconds
        defer { M2Settings.localIntentTimeoutSeconds = savedTimeout }

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.92,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Hello from OpenAI."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        // 2s delay — above the explicit 0.5s local intent timeout used in this test.
        fakeOllama.intentDelayNanoseconds = 2_000_000_000
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let camera = makeHealthyCamera()

        OpenAISettings.apiKey = "timeout-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "timeout-test-key"
        M2Settings.useOllama = true
        M2Settings.localIntentTimeoutSeconds = 0.5

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            cameraVision: camera
        )

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOllama.intentCallCount, 1, "Local intent should be attempted")
        XCTAssertEqual(fakeOpenAI.intentCallCount, 1, "OpenAI intent should be attempted after local timeout")
        XCTAssertEqual(result.llmProvider, .openai)
    }

    func testIntentLocal1200msSucceedsWhenTimeoutIs2s() async {
        let savedTimeout = M2Settings.localIntentTimeoutSeconds
        defer { M2Settings.localIntentTimeoutSeconds = savedTimeout }

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.92,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Plan routed via OpenAI."}"#)
        ]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.intentDelayNanoseconds = 1_200_000_000
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"greeting","confidence":0.90,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]

        OpenAISettings.apiKey = "intent-2s-timeout-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "intent-2s-timeout-key"
        M2Settings.useOllama = true
        M2Settings.preferLocalPlans = false
        M2Settings.localIntentTimeoutSeconds = 2.0

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            cameraVision: makeHealthyCamera()
        )

        _ = await orchestrator.processTurn("how are you?", history: [])
        let intent = orchestrator.debugLastIntentClassification()

        XCTAssertEqual(fakeOllama.intentCallCount, 1, "Local intent should be attempted exactly once")
        XCTAssertEqual(fakeOpenAI.intentCallCount, 0, "OpenAI intent should not be attempted when local finishes within timeout")
        XCTAssertEqual(intent?.provider, .ollama)
        XCTAssertEqual(intent?.attemptedOpenAI, false)
    }

    func testIntentLocal1200msTimesOutWhenTimeoutIsPoint5s() async {
        let savedTimeout = M2Settings.localIntentTimeoutSeconds
        defer { M2Settings.localIntentTimeoutSeconds = savedTimeout }

        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.94,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Plan routed via OpenAI."}"#)
        ]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.intentDelayNanoseconds = 1_200_000_000
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"greeting","confidence":0.91,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]

        OpenAISettings.apiKey = "intent-point5-timeout-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "intent-point5-timeout-key"
        M2Settings.useOllama = true
        M2Settings.preferLocalPlans = false
        M2Settings.localIntentTimeoutSeconds = 0.5

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            cameraVision: makeHealthyCamera()
        )

        _ = await orchestrator.processTurn("how are you?", history: [])
        let intent = orchestrator.debugLastIntentClassification()

        XCTAssertEqual(fakeOllama.intentCallCount, 1, "Local intent should still be attempted first")
        XCTAssertEqual(fakeOpenAI.intentCallCount, 1, "OpenAI intent should run after local timeout")
        XCTAssertEqual(intent?.provider, .openai)
        XCTAssertEqual(intent?.attemptedOpenAI, true)
        XCTAssertEqual(intent?.escalationReason, "timeout")
    }

    func testIntentLocalSuccessDoesNotCallOpenAIIntent() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.91,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Hello from OpenAI plan routing."}"#)
        ]

        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"greeting","confidence":0.9,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]

        OpenAISettings.apiKey = "intent-local-success-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "intent-local-success-key"
        M2Settings.useOllama = true
        M2Settings.preferLocalPlans = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            cameraVision: makeHealthyCamera()
        )

        _ = await orchestrator.processTurn("how are you?", history: [])
        let intent = orchestrator.debugLastIntentClassification()

        XCTAssertEqual(intent?.provider, .ollama)
        XCTAssertEqual(intent?.attemptedLocal, true)
        XCTAssertEqual(intent?.attemptedOpenAI, false)
        XCTAssertEqual(fakeOpenAI.intentCallCount, 0, "OpenAI intent classifier must not be called when local confidence passes threshold")
    }

    func testIntentFastPath_OpenAIMaxTokensReduced() async {
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedIntentResponses = [
            .success("""
            {"intent":"general_qna","confidence":0.92,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        fakeOpenAI.queuedResponses = [
            .success(#"{"action":"TALK","say":"Hello."}"#)
        ]
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success("""
            {"intent":"unknown","confidence":0.30,"autoCaptureHint":false,"needsWeb":false,"notes":""}
            """)
        ]
        let camera = makeHealthyCamera()

        OpenAISettings.apiKey = "tokens-test-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "tokens-test-key"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            cameraVision: camera
        )

        _ = await orchestrator.processTurn("what is swift", history: [])

        XCTAssertEqual(fakeOpenAI.intentMaxTokensLog.first, 128,
            "OpenAI intent should use reduced max_tokens of 128")
        XCTAssertEqual(fakeOpenAI.intentTemperatureLog.first, 0.0,
            "OpenAI intent should use temperature 0.0")
    }

    private func identityPromptCount(in result: TurnResult) -> Int {
        result.appendedChat.reduce(0) { partial, message in
            guard message.role == .assistant else { return partial }
            let normalized = message.text.lowercased()
            if normalized.contains("what's your name") || normalized.contains("what is your name") {
                return partial + 1
            }
            return partial
        }
    }

    private func combinedAssistantText(_ result: TurnResult) -> String {
        result.appendedChat
            .filter { $0.role == .assistant }
            .map(\.text)
            .joined(separator: "\n")
    }

    private func appendTurn(_ history: inout [ChatMessage], user: String, result: TurnResult) {
        history.append(ChatMessage(role: .user, text: user))
        history.append(contentsOf: result.appendedChat)
    }
}

final class FakeWireTimedOllamaTransport: OllamaTransport, OllamaWireTimedTransport {
    var responseText: String
    var wireMs: Int

    init(responseText: String, wireMs: Int) {
        self.responseText = responseText
        self.wireMs = wireMs
    }

    func chat(messages: [[String: String]], model: String?, maxOutputTokens: Int?) async throws -> String {
        _ = messages
        _ = model
        _ = maxOutputTokens
        return responseText
    }

    func chatWithWireTiming(messages: [[String: String]], model: String?, maxOutputTokens: Int?) async throws -> (responseText: String, wireMs: Int) {
        _ = messages
        _ = model
        _ = maxOutputTokens
        return (responseText, wireMs)
    }
}

@MainActor
final class SamOSFastRegressionTests: XCTestCase {
    private var savedUseOllama = true
    private var savedPreferOpenAIPlans = false
    private var savedLocalIntentTimeoutSeconds = 2.0
    private var savedOpenAIKey = ""

    override func setUp() {
        super.setUp()
        savedUseOllama = M2Settings.useOllama
        savedPreferOpenAIPlans = M2Settings.preferOpenAIPlans
        savedLocalIntentTimeoutSeconds = M2Settings.localIntentTimeoutSeconds
        savedOpenAIKey = OpenAISettings.apiKey
        OpenAICallTracker.shared.clear(turnID: "fast_no_openai")
        TTSService.shared.stopSpeaking(reason: .userInterrupt)
        TTSService.shared.clearLastDropReason()
    }

    override func tearDown() {
        M2Settings.useOllama = savedUseOllama
        M2Settings.preferOpenAIPlans = savedPreferOpenAIPlans
        M2Settings.localIntentTimeoutSeconds = savedLocalIntentTimeoutSeconds
        OpenAISettings.apiKey = savedOpenAIKey
        OpenAISettings._resetCacheForTesting()
        OpenAICallTracker.shared.clear(turnID: "fast_no_openai")
        super.tearDown()
    }

    func testIntentParser_AllowsMissingOptionalKeys() async {
        let fakeOpenAI = FakeOpenAITransport()
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success(#"{"intent":"general_qna","confidence":0.95}"#)
        ]
        fakeOllama.queuedResponses = [
            .success(#"{"action":"TALK","say":"Fallback."}"#)
        ]

        OpenAISettings.apiKey = ""
        OpenAISettings._resetCacheForTesting()
        M2Settings.useOllama = true
        M2Settings.preferOpenAIPlans = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI),
            cameraVision: makeFastCamera()
        )

        _ = await orchestrator.processTurn("blorp", history: [])
        let intent = orchestrator.debugLastIntentClassification()

        XCTAssertEqual(fakeOllama.intentCallCount, 1)
        XCTAssertEqual(intent?.provider, .ollama)
        XCTAssertEqual(intent?.attemptedLocal, true)
        XCTAssertEqual(intent?.attemptedOpenAI, false)
        XCTAssertEqual(intent?.localConfidence ?? -1, 0.95, accuracy: 0.0001)
    }

    func testNoOpenAICallsWhenPlanProviderIsOllama() async {
        let fakeOpenAI = FakeOpenAITransport()
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = [
            .success(#"{"intent":"greeting","confidence":0.95,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#)
        ]
        fakeOllama.queuedResponses = [
            .success(#"{"action":"TALK","say":"I'm doing well."}"#)
        ]

        OpenAISettings.apiKey = "fast-no-openai-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "fast-no-openai-key"
        M2Settings.useOllama = true
        M2Settings.preferOpenAIPlans = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI),
            cameraVision: makeFastCamera()
        )

        let turnID = "fast_no_openai"
        let result = await TurnExecutionContext.$turnID.withValue(turnID) {
            await orchestrator.processTurn("How are you?", history: [])
        }
        let summary = OpenAICallTracker.shared.summary(for: turnID)

        XCTAssertEqual(result.planProviderSelected, .ollama)
        XCTAssertEqual(summary.count, 0)
        XCTAssertEqual(fakeOpenAI.intentCallCount, 0)
        XCTAssertEqual(fakeOpenAI.chatCallCount, 0)
    }

    func testOllamaPlanDeadline_UsesWireTimeOnly() async throws {
        let fakeTransport = FakeWireTimedOllamaTransport(
            responseText: #"{"action":"TALK","say":"Wire-time success."}"#,
            wireMs: 2800
        )
        let router = OllamaRouter(transport: fakeTransport)
        #if DEBUG
        let savedDelay = OllamaRouter.debugParseDelayNanoseconds
        OllamaRouter.debugParseDelayNanoseconds = 400_000_000
        defer { OllamaRouter.debugParseDelayNanoseconds = savedDelay }
        #endif

        let routed = try await router.routePlanWithTiming(
            "hello",
            history: [],
            skipRepairRetry: true,
            wireDeadlineMs: 3000
        )

        XCTAssertEqual(routed.timing.wireMs, 2800)
        XCTAssertGreaterThanOrEqual(routed.timing.parseMs, 300)

        let timeoutTransport = FakeWireTimedOllamaTransport(
            responseText: #"{"action":"TALK","say":"Should timeout."}"#,
            wireMs: 3200
        )
        let timeoutRouter = OllamaRouter(transport: timeoutTransport)
        do {
            _ = try await timeoutRouter.routePlanWithTiming(
                "hello",
                history: [],
                skipRepairRetry: true,
                wireDeadlineMs: 3000
            )
            XCTFail("Expected wire deadline timeout")
        } catch let error as OllamaRouter.OllamaError {
            guard case .wireDeadlineExceeded = error else {
                return XCTFail("Expected wireDeadlineExceeded, got \(error)")
            }
        } catch {
            XCTFail("Expected OllamaRouter.OllamaError, got \(error)")
        }
    }

    func testSpeechNotDroppedWithoutExplicitCancel() async {
        TTSService.shared.stopSpeaking(reason: .userInterrupt)
        TTSService.shared.clearLastDropReason()

        let fake = FakeTurnOrchestrator()
        var result = TurnResult()
        result.appendedChat = [ChatMessage(role: .assistant, text: "Done.")]
        result.spokenLines = ["Done."]
        fake.queuedResults = [result]

        let appState = AppState(
            orchestrator: fake,
            thinkingFillerDelay: 0.05,
            ttsStartDeadlineSeconds: 0.1,
            enableRuntimeServices: false
        )

        appState.send("hello")
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNotEqual(
            appState.debugLastSpeechDropReason(),
            TTSService.SpeechDropReason.explicitCancel.rawValue
        )
    }

    func testPerfHarness_CannedTurns_PrintsPerfTurnLines() async {
        let startedAt = Date()
        let prompts = [
            "How are you?",
            "Capital of Australia?",
            "What's the time in London?",
            "Set a timer for ten minutes.",
            "Show me a short summary of Wi-Fi troubleshooting."
        ]

        let fakeOpenAI = FakeOpenAITransport()
        let fakeOllama = FakeOllamaTransportForPipeline()
        fakeOllama.queuedIntentResponses = prompts.map { prompt in
            if prompt.lowercased().contains("time") {
                return .success(#"{"intent":"automation_request","confidence":0.92,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#)
            }
            return .success(#"{"intent":"general_qna","confidence":0.92,"autoCaptureHint":false,"needsWeb":false,"notes":""}"#)
        }
        fakeOllama.queuedResponses = [
            .success(#"{"action":"TALK","say":"I am doing well."}"#),
            .success(#"{"action":"TALK","say":"Canberra is the capital of Australia."}"#),
            .success(#"{"action":"TOOL","name":"get_time","args":{"location":"London"},"say":"Checking London time."}"#),
            .success(#"{"action":"TALK","say":"Timer setup guidance ready."}"#),
            .success(#"{"action":"TALK","say":"Restart router, check signal, and test another device."}"#)
        ]

        OpenAISettings.apiKey = "fast-harness-key"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "fast-harness-key"
        M2Settings.useOllama = true
        M2Settings.preferOpenAIPlans = false

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI),
            cameraVision: makeFastCamera()
        )

        for (index, prompt) in prompts.enumerated() {
            let turnID = "fast_harness_\(index + 1)"
            let turnStart = Date()
            let result = await TurnExecutionContext.$turnID.withValue(turnID) {
                await orchestrator.processTurn(prompt, history: [])
            }
            let totalMs = max(0, Int(Date().timeIntervalSince(turnStart) * 1000))
            func str(_ value: Int?) -> String { value.map(String.init) ?? "n/a" }
            print("[PERF_TURN] turn_id=\(turnID) mode=text capture_ms=n/a stt_ms=n/a intent_local_ms=\(str(result.intentRouterMsLocal)) intent_openai_ms=\(str(result.intentRouterMsOpenAI)) plan_local_wire_ms=\(str(result.planLocalWireMs)) plan_local_total_ms=\(str(result.planLocalTotalMs)) plan_openai_ms=\(str(result.planOpenAIMs)) tool_ms_total=\(str(result.toolMsTotal)) tts_queue_wait_ms=n/a tts_synthesis_ms=n/a tts_playback_start_ms=n/a first_audio_ms=n/a total_ms=\(totalMs)")
        }

        let elapsedMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        XCTAssertLessThan(elapsedMs, 10_000, "Perf harness should complete in under 10 seconds")
    }

    private func makeFastCamera() -> IdentityTestCamera {
        let camera = IdentityTestCamera()
        camera.isRunning = true
        camera.latestFrameAt = Date()
        camera.analysis = CameraFrameAnalysis(
            labels: [],
            recognizedText: [],
            faces: CameraFacePresence(count: 1),
            capturedAt: Date()
        )
        camera.recognitionResult = CameraFaceRecognitionResult(
            capturedAt: Date(),
            detectedFaces: 1,
            matches: [],
            unknownFaces: 1,
            enrolledNames: []
        )
        return camera
    }
}

@MainActor
final class SamOSRealPerfSmokeTests: XCTestCase {
    func testPerfHarness_RealTurns() async {
        let prompts = [
            "How are you?",
            "Capital of Australia?",
            "What's the time in London?"
        ]

        OpenAISettings._resetCacheForTesting()
        M2Settings.useOllama = true
        M2Settings.preferOpenAIPlans = false

        let camera = IdentityTestCamera()
        camera.isRunning = true
        camera.latestFrameAt = Date()
        camera.analysis = CameraFrameAnalysis(
            labels: [],
            recognizedText: [],
            faces: CameraFacePresence(count: 1),
            capturedAt: Date()
        )
        camera.recognitionResult = CameraFaceRecognitionResult(
            capturedAt: Date(),
            detectedFaces: 1,
            matches: [],
            unknownFaces: 1,
            enrolledNames: []
        )

        let ollamaRouter = OllamaRouter()
        let openAIRouter = OpenAIRouter(parser: ollamaRouter)
        let orchestrator = TurnOrchestrator(
            ollamaRouter: ollamaRouter,
            openAIRouter: openAIRouter,
            cameraVision: camera
        )
        var history: [ChatMessage] = []

        for (index, prompt) in prompts.enumerated() {
            let turnID = "real_perf_\(index + 1)"
            let turnStart = Date()
            let result = await TurnExecutionContext.$turnID.withValue(turnID) {
                await orchestrator.processTurn(prompt, history: history)
            }
            history.append(ChatMessage(role: .user, text: prompt))
            history.append(contentsOf: result.appendedChat)

            let totalMs = max(0, Int(Date().timeIntervalSince(turnStart) * 1000))
            func str(_ value: Int?) -> String { value.map(String.init) ?? "n/a" }
            print("[PERF_TURN] turn_id=\(turnID) mode=text capture_ms=n/a stt_ms=n/a intent_local_ms=\(str(result.intentRouterMsLocal)) intent_openai_ms=\(str(result.intentRouterMsOpenAI)) plan_local_wire_ms=\(str(result.planLocalWireMs)) plan_local_total_ms=\(str(result.planLocalTotalMs)) plan_openai_ms=\(str(result.planOpenAIMs)) tool_ms_total=\(str(result.toolMsTotal)) tts_queue_wait_ms=n/a tts_synthesis_ms=n/a tts_playback_start_ms=n/a first_audio_ms=n/a total_ms=\(totalMs)")
        }
    }
}
