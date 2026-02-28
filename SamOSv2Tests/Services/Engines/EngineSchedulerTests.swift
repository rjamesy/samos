import XCTest
@testable import SamOSv2

/// Simple test engine for scheduler tests.
private final class TestEngine: IntelligenceEngine {
    let name: String
    let settingsKey: String
    let description = "Test engine"
    let output: String
    let delay: TimeInterval

    init(name: String, output: String, delay: TimeInterval = 0) {
        self.name = name
        self.settingsKey = "engine_\(name)"
        self.output = output
        self.delay = delay
    }

    func run(context: EngineTurnContext) async throws -> String {
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        return output
    }
}

/// Engine that always times out.
private final class SlowEngine: IntelligenceEngine {
    let name = "slow_engine"
    let settingsKey = "engine_slow_engine"
    let description = "Always times out"

    func run(context: EngineTurnContext) async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return "should never return"
    }
}

final class EngineSchedulerTests: XCTestCase {

    private func makeContext(_ message: String = "Hello") -> EngineTurnContext {
        EngineTurnContext(
            userText: message,
            assistantText: "",
            sessionId: "test"
        )
    }

    private func makeSettings(allEnabled: Bool = true) -> MockSettingsStore {
        let settings = MockSettingsStore()
        let engineKeys: [String] = [
            SettingsKey.engineCognitiveTrace, SettingsKey.engineWorldModel, SettingsKey.engineCuriosity,
            SettingsKey.engineLongitudinal, SettingsKey.engineBehavior, SettingsKey.engineCounterfactual,
            SettingsKey.engineTheoryOfMind, SettingsKey.engineNarrative, SettingsKey.engineCausal,
            SettingsKey.engineMetacognition, SettingsKey.enginePersonality, SettingsKey.engineSkillEvolution,
            "engine_slow_engine"
        ]
        for key in engineKeys {
            settings.setBool(allEnabled, forKey: key)
        }
        return settings
    }

    func testEmptyEnginesReturnsEmpty() async {
        let scheduler = EngineScheduler(settings: makeSettings())
        let result = await scheduler.runEngines(context: makeContext())
        XCTAssertTrue(result.contextBlock.isEmpty)
        XCTAssertTrue(result.activeNames.isEmpty)
    }

    func testRegisteredEngineProducesOutput() async {
        let scheduler = EngineScheduler(settings: makeSettings())
        await scheduler.registerEngine(TestEngine(name: "cognitive_trace", output: "[TRACE] test"))
        let result = await scheduler.runEngines(context: makeContext())
        XCTAssertEqual(result.activeNames.count, 1)
        XCTAssertEqual(result.activeNames.first, "cognitive_trace")
        XCTAssertTrue(result.contextBlock.contains("[TRACE] test"))
    }

    func testMultipleEnginesAllRun() async {
        let scheduler = EngineScheduler(settings: makeSettings())
        await scheduler.registerEngines([
            TestEngine(name: "cognitive_trace", output: "trace"),
            TestEngine(name: "world_model", output: "world"),
        ])
        let result = await scheduler.runEngines(context: makeContext())
        XCTAssertEqual(result.activeNames.count, 2)
    }

    func testDisabledEngineSkipped() async {
        let settings = makeSettings(allEnabled: false)
        let scheduler = EngineScheduler(settings: settings)
        await scheduler.registerEngine(TestEngine(name: "cognitive_trace", output: "trace"))
        let result = await scheduler.runEngines(context: makeContext())
        XCTAssertTrue(result.activeNames.isEmpty)
        let disabled = result.results.filter { $0.status == .disabled }
        XCTAssertEqual(disabled.count, 1)
    }

    func testTimeoutSkipsSlowEngine() async {
        let scheduler = EngineScheduler(settings: makeSettings(), timeoutSeconds: 0.1)
        await scheduler.registerEngine(SlowEngine())
        let result = await scheduler.runEngines(context: makeContext())
        XCTAssertTrue(result.activeNames.isEmpty)
        let timedOut = result.results.filter { $0.status == .timeout }
        XCTAssertEqual(timedOut.count, 1)
    }

    func testEmptyOutputFiltered() async {
        let scheduler = EngineScheduler(settings: makeSettings())
        await scheduler.registerEngine(TestEngine(name: "cognitive_trace", output: ""))
        let result = await scheduler.runEngines(context: makeContext())
        XCTAssertTrue(result.activeNames.isEmpty)
        let empty = result.results.filter { $0.status == .empty }
        XCTAssertEqual(empty.count, 1)
    }

    func testSummaryIncludesTimings() async {
        let scheduler = EngineScheduler(settings: makeSettings())
        await scheduler.registerEngine(TestEngine(name: "cognitive_trace", output: "trace"))
        let result = await scheduler.runEngines(context: makeContext())
        XCTAssertTrue(result.summary.contains("cognitive_trace"))
        XCTAssertTrue(result.summary.contains("ms"))
    }
}
