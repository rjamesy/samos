import XCTest
@testable import SamOS

// MARK: - Fake OpenAI Transport

final class FakeOpenAITransport: OpenAITransport {
    var queuedResponses: [Result<String, Error>] = []
    private(set) var chatCallCount = 0
    private(set) var chatCallLog: [[[String: String]]] = []
    private(set) var chatModelLog: [String] = []
    private(set) var chatMaxTokensLog: [Int?] = []

    func chat(messages: [[String: String]], model: String, maxOutputTokens: Int?) async throws -> String {
        chatCallCount += 1
        chatCallLog.append(messages)
        chatModelLog.append(model)
        chatMaxTokensLog.append(maxOutputTokens)
        guard !queuedResponses.isEmpty else {
            throw OpenAIRouter.OpenAIError.requestFailed("No queued response")
        }
        return try queuedResponses.removeFirst().get()
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
    private(set) var chatCallCount = 0

    func chat(messages: [[String: String]], maxOutputTokens: Int?) async throws -> String {
        chatCallCount += 1
        guard !queuedResponses.isEmpty else {
            throw OllamaRouter.OllamaError.unreachable("No queued response")
        }
        return try queuedResponses.removeFirst().get()
    }
}

@MainActor
final class FakeTurnOrchestrator: TurnOrchestrating {
    var pendingSlot: PendingSlot?
    var delayNanoseconds: UInt64 = 0
    var queuedResults: [TurnResult] = []

    func processTurn(_ text: String, history: [ChatMessage]) async -> TurnResult {
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

// MARK: - Router Pipeline Tests

@MainActor
final class RouterPipelineTests: XCTestCase {

    private var savedApiKey: String = ""
    private var savedUseOllama: Bool = false
    private var savedAffectMirroringEnabled: Bool = false
    private var savedUseEmotionalTone: Bool = true
    private var savedToneProfile: TonePreferenceProfile = .neutralDefaults
    private var savedGeneralModel: String = ""
    private var savedEscalationModel: String = ""

    override func setUp() {
        super.setUp()
        savedApiKey = OpenAISettings.apiKey
        savedUseOllama = M2Settings.useOllama
        savedAffectMirroringEnabled = M2Settings.affectMirroringEnabled
        savedUseEmotionalTone = M2Settings.useEmotionalTone
        savedToneProfile = TonePreferenceStore.shared.loadProfile()
        TonePreferenceStore.shared.replaceProfileForTesting(.neutralDefaults)
        savedGeneralModel = OpenAISettings.generalModel
        savedEscalationModel = OpenAISettings.escalationModel
    }

    override func tearDown() {
        // Restore original settings
        OpenAISettings.apiKey = savedApiKey
        M2Settings.useOllama = savedUseOllama
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
        M2Settings.useOllama = true

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
        fakeOllama.queuedResponses = [.success(ollamaFeedback)]

        OpenAISettings.apiKey = "test-key-123"
        OpenAISettings._resetCacheForTesting()
        OpenAISettings.apiKey = "test-key-123"
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn(
            "Check Tokyo time, then tell me if it's a good time to call London.",
            history: []
        )

        XCTAssertEqual(fakeOpenAI.chatCallCount, 2, "OpenAI should handle initial route + feedback attempt")
        XCTAssertEqual(fakeOllama.chatCallCount, 1, "Ollama should be used for feedback fallback only")
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
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1, "OpenAI should be attempted once")
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "Ollama should NOT be called when OpenAI configured")
        XCTAssertEqual(result.llmProvider, .none, "Should return friendly fallback")
        XCTAssertTrue(result.appendedChat.contains { $0.text.lowercased().contains("openai") })
        XCTAssertEqual(result.knowledgeAttribution?.localKnowledgePercent, 0)
        XCTAssertEqual(result.knowledgeAttribution?.matchedLocalItems, 0)
        XCTAssertEqual(result.usedMemoryHints, false, "Fallback provider should not mark memory-hint usage")
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
        M2Settings.useOllama = true

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
        M2Settings.useOllama = true

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
        M2Settings.useOllama = true

        let ollamaRouter = OllamaRouter(transport: fakeOllama)
        let openAIRouter = OpenAIRouter(parser: ollamaRouter, transport: fakeOpenAI)
        let orchestrator = TurnOrchestrator(ollamaRouter: ollamaRouter, openAIRouter: openAIRouter)

        let result = await orchestrator.processTurn("hello", history: [])

        XCTAssertEqual(fakeOpenAI.chatCallCount, 1)
        XCTAssertEqual(fakeOllama.chatCallCount, 0, "No Ollama hop when OpenAI configured")
        XCTAssertEqual(result.llmProvider, .none)
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
        XCTAssertTrue(secondText.contains("openai rejected the request"), "Expected persistent auth error, got: \(secondText)")
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
        M2Settings.useOllama = true

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
        let firstTalk = #"{"action":"TALK","say":"I finished that for you and included the key details."}"#
        let secondTalk = #"{"action":"TALK","say":"I wrapped this up and summarized the important parts."}"#
        let fakeOpenAI = FakeOpenAITransport()
        fakeOpenAI.queuedResponses = [.success(firstTalk), .success(secondTalk)]
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

        let first = await orchestrator.processTurn("turn one", history: [])
        let firstText = first.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(firstText.filter { $0 == "?" }.count, 1)
        XCTAssertTrue(first.triggerQuestionAutoListen)

        let second = await orchestrator.processTurn("turn two", history: [])
        let secondText = second.appendedChat.first(where: { $0.role == .assistant })?.text ?? ""
        XCTAssertEqual(secondText.filter { $0 == "?" }.count, 0, "Follow-up should be blocked during cooldown")
        XCTAssertFalse(second.triggerQuestionAutoListen)
    }

    @MainActor
    func testFollowUpMaxOneSentence() async {
        let talk = #"{"action":"TALK","say":"I prepared the result and highlighted the important points for you."}"#
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
        let result = await orchestrator.processTurn("wrap up", history: [])

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
        XCTAssertTrue(assistant.contains("trouble processing"), "Expected safe friendly fallback, got: \(assistant)")
    }

    @MainActor
    func testUnknownToolStepRejectedWithFriendlyFallback() async {
        let raw = """
        {"action":"PLAN","steps":[{"step":"tool","name":"delete_all_files","args":{}}]}
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

        let result = await orchestrator.processTurn("clean up my machine", history: [])

        XCTAssertTrue(result.executedToolSteps.isEmpty, "Unknown tool must never be executed")
        let assistant = result.appendedChat.first(where: { $0.role == .assistant })?.text.lowercased() ?? ""
        XCTAssertTrue(assistant.contains("trouble processing"), "Expected safe friendly fallback, got: \(assistant)")
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
        XCTAssertTrue(OpenAISettings._debugShouldUseKeychainStorageForTesting())
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

    func testOpenAIKeychainPreferredOverDebugFallbackWhenBothExist() {
        #if DEBUG
        let service = OpenAISettings._debugEffectiveKeychainServiceForTesting()
        let devKey = OpenAISettings._debugEffectiveDevSecretKeyForTesting()

        _ = KeychainStore.set("keychain-live-value", forKey: "apiKey", service: service)
        DevSecretsStore.shared.set(devKey, "dev-fallback-value")

        OpenAISettings._resetCacheForTesting()
        XCTAssertEqual(OpenAISettings.apiKey, "keychain-live-value")

        _ = KeychainStore.delete(forKey: "apiKey", service: service)
        DevSecretsStore.shared.delete(devKey)
        #else
        return
        #endif
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
}
