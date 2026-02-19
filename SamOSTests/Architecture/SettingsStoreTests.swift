import XCTest
@testable import SamOS

final class SettingsStoreTests: XCTestCase {
    func testInMemorySettingsStorePersistsAssignedValues() {
        let store = InMemorySettingsStore()

        store.useOllama = false
        store.ollamaEndpoint = "http://localhost:15555"
        store.ollamaModel = "qwen2.5:7b"
        store.preferOpenAIPlans = true
        store.disableAutoClosePrompts = false
        store.ollamaCombinedTimeoutMs = 4200
        store.useEmotionalTone = false
        store.developerModeEnabled = true
        store.silenceThresholdDB = -30
        store.silenceDurationMs = 900
        store.captureBeepEnabled = false
        store.userName = "Richard"
        store.openAIPreferredModel = "gpt-5.2"

        XCTAssertFalse(store.useOllama)
        XCTAssertEqual(store.ollamaEndpoint, "http://localhost:15555")
        XCTAssertEqual(store.ollamaModel, "qwen2.5:7b")
        XCTAssertTrue(store.preferOpenAIPlans)
        XCTAssertFalse(store.disableAutoClosePrompts)
        XCTAssertEqual(store.ollamaCombinedTimeoutMs, 4200)
        XCTAssertFalse(store.useEmotionalTone)
        XCTAssertTrue(store.developerModeEnabled)
        XCTAssertEqual(store.silenceThresholdDB, -30, accuracy: 0.001)
        XCTAssertEqual(store.silenceDurationMs, 900)
        XCTAssertFalse(store.captureBeepEnabled)
        XCTAssertEqual(store.userName, "Richard")
        XCTAssertEqual(store.openAIPreferredModel, "gpt-5.2")

        let snapshot = store.snapshot
        XCTAssertEqual(snapshot.general.userName, "Richard")
        XCTAssertEqual(snapshot.openAI.preferredModel, "gpt-5.2")
    }
}
