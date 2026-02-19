import XCTest
@testable import SamOS

@MainActor
final class SettingsReliabilityTests: XCTestCase {
    func testInMemorySnapshotReflectsRuntimeFields() {
        let store = InMemorySettingsStore()
        store.userName = "Richard"
        store.useEmotionalTone = false
        store.developerModeEnabled = true
        store.useKeychainStorage = true
        store.porcupineAccessKey = "pk_test"
        store.porcupineKeywordPath = "/tmp/hey-sam.ppn"
        store.porcupineSensitivity = 0.65
        store.whisperModelPath = "/tmp/whisper.bin"
        store.silenceThresholdDB = -31
        store.silenceDurationMs = 900
        store.captureBeepEnabled = false
        store.faceRecognitionEnabled = false
        store.personalizedGreetingsEnabled = false
        store.elevenLabsVoiceId = "voice_123"
        store.elevenLabsMuted = true
        store.elevenLabsUseStreaming = false
        store.useOllama = false
        store.ollamaEndpoint = "http://localhost:15555"
        store.ollamaModel = "qwen3:8b"
        store.preferOpenAIPlans = true
        store.disableAutoClosePrompts = false
        store.ollamaCombinedTimeoutMs = 4200
        store.samGatewayURL = "http://localhost:8002"
        store.openAIApiKey = "sk-test"
        store.openAIYouTubeApiKey = "yt-test"
        store.openAIPreferredModel = "gpt-5.2"
        store.openAIRealtimeModeEnabled = true
        store.openAIRealtimeUseClassicSTT = true
        store.openAIRealtimeModel = "gpt-realtime-preview"
        store.openAIRealtimeVoice = "verse"

        let snapshot = store.snapshot
        XCTAssertEqual(snapshot.general.userName, "Richard")
        XCTAssertFalse(snapshot.general.useEmotionalTone)
        XCTAssertTrue(snapshot.general.developerModeEnabled)
        XCTAssertTrue(snapshot.general.useKeychainStorage)
        XCTAssertEqual(snapshot.audioVisual.porcupineAccessKey, "pk_test")
        XCTAssertEqual(snapshot.audioVisual.porcupineKeywordPath, "/tmp/hey-sam.ppn")
        XCTAssertEqual(snapshot.audioVisual.porcupineSensitivity, 0.65, accuracy: 0.001)
        XCTAssertEqual(snapshot.audioVisual.whisperModelPath, "/tmp/whisper.bin")
        XCTAssertEqual(snapshot.audioVisual.silenceThresholdDB, -31, accuracy: 0.001)
        XCTAssertEqual(snapshot.audioVisual.silenceDurationMs, 900)
        XCTAssertFalse(snapshot.audioVisual.captureBeepEnabled)
        XCTAssertFalse(snapshot.audioVisual.faceRecognitionEnabled)
        XCTAssertFalse(snapshot.audioVisual.personalizedGreetingsEnabled)
        XCTAssertEqual(snapshot.audioVisual.elevenLabsVoiceId, "voice_123")
        XCTAssertTrue(snapshot.audioVisual.elevenLabsMuted)
        XCTAssertFalse(snapshot.audioVisual.elevenLabsUseStreaming)
        XCTAssertFalse(snapshot.aiRouting.useOllama)
        XCTAssertEqual(snapshot.aiRouting.ollamaEndpoint, "http://localhost:15555")
        XCTAssertEqual(snapshot.aiRouting.ollamaModel, "qwen3:8b")
        XCTAssertTrue(snapshot.aiRouting.preferOpenAIPlans)
        XCTAssertFalse(snapshot.aiRouting.disableAutoClosePrompts)
        XCTAssertEqual(snapshot.aiRouting.ollamaCombinedTimeoutMs, 4200)
        XCTAssertEqual(snapshot.aiRouting.samGatewayURL, "http://localhost:8002")
        XCTAssertEqual(snapshot.openAI.preferredModel, "gpt-5.2")
        XCTAssertTrue(snapshot.openAI.apiKeyConfigured)
        XCTAssertTrue(snapshot.openAI.youtubeConfigured)
        XCTAssertTrue(snapshot.openAI.realtimeModeEnabled)
        XCTAssertTrue(snapshot.openAI.realtimeUseClassicSTT)
        XCTAssertEqual(snapshot.openAI.realtimeModel, "gpt-realtime-preview")
        XCTAssertEqual(snapshot.openAI.realtimeVoice, "verse")
    }

    func testUserDefaultsStorePreferredModelUpdatesGeneralAndEscalation() {
        let savedGeneral = OpenAISettings.generalModel
        let savedEscalation = OpenAISettings.escalationModel
        defer {
            OpenAISettings.generalModel = savedGeneral
            OpenAISettings.escalationModel = savedEscalation
        }

        let store = UserDefaultsSettingsStore()
        store.openAIPreferredModel = "gpt-5.2"

        XCTAssertEqual(OpenAISettings.generalModel, "gpt-5.2")
        XCTAssertEqual(OpenAISettings.escalationModel, "gpt-5.2")
    }

    func testFallbackPolicyUsesCapturedSnapshotDeterministically() {
        let store = InMemorySettingsStore()
        store.useOllama = true
        let policy = FallbackPolicy(settingsStore: store)

        let firstSnapshot = store.snapshot
        XCTAssertEqual(
            policy.routeOrder(snapshot: firstSnapshot, openAIConfigured: true),
            [.ollama, .openai]
        )

        store.useOllama = false
        XCTAssertEqual(
            policy.routeOrder(snapshot: firstSnapshot, openAIConfigured: true),
            [.ollama, .openai]
        )
        XCTAssertEqual(
            policy.routeOrder(snapshot: store.snapshot, openAIConfigured: true),
            [.openai]
        )
    }

    func testUserDefaultsStoreReflectsDeveloperModeAndGateway() {
        let savedDev = M2Settings.developerModeEnabled
        let savedURL = M2Settings.samGatewayURL
        let savedPreferPlans = M2Settings.preferOpenAIPlans
        defer {
            M2Settings.developerModeEnabled = savedDev
            M2Settings.samGatewayURL = savedURL
            M2Settings.preferOpenAIPlans = savedPreferPlans
        }

        M2Settings.developerModeEnabled = true
        M2Settings.samGatewayURL = "http://localhost:8002"
        M2Settings.preferOpenAIPlans = true

        let snapshot = UserDefaultsSettingsStore().snapshot
        XCTAssertTrue(snapshot.general.developerModeEnabled)
        XCTAssertEqual(snapshot.aiRouting.samGatewayURL, "http://localhost:8002")
        XCTAssertTrue(snapshot.aiRouting.preferOpenAIPlans)
    }

    func testToneLearningEnableFlagPersists() {
        let savedProfile = TonePreferenceStore.shared.loadProfile()
        defer { TonePreferenceStore.shared.replaceProfileForTesting(savedProfile) }

        _ = TonePreferenceStore.shared.updateEnabled(false)
        XCTAssertFalse(TonePreferenceStore.shared.loadProfile().enabled)

        _ = TonePreferenceStore.shared.updateEnabled(true)
        XCTAssertTrue(TonePreferenceStore.shared.loadProfile().enabled)
    }

    func testUserDefaultsStoreUseKeychainStorageTogglePersists() {
        let saved = KeychainStore.useKeychain
        defer { KeychainStore.useKeychain = saved }

        let store = UserDefaultsSettingsStore()
        store.useKeychainStorage = false
        XCTAssertFalse(store.useKeychainStorage)

        store.useKeychainStorage = true
        XCTAssertTrue(store.useKeychainStorage)
    }

    func testCameraPreferencePersistsInUserDefaults() {
        let saved = AppState.userWantsCameraEnabled
        defer { AppState.userWantsCameraEnabled = saved }

        AppState.userWantsCameraEnabled = true
        XCTAssertTrue(AppState.userWantsCameraEnabled)

        AppState.userWantsCameraEnabled = false
        XCTAssertFalse(AppState.userWantsCameraEnabled)
    }

    func testSamSessionIdPersists() {
        let saved = M2Settings.samSessionId
        defer { M2Settings.samSessionId = saved }

        M2Settings.samSessionId = "session_abc"
        XCTAssertEqual(M2Settings.samSessionId, "session_abc")
    }

    func testOpenAIYouTubeAPIKeyPersists() {
        let saved = OpenAISettings.youtubeAPIKey
        defer { OpenAISettings.youtubeAPIKey = saved }

        OpenAISettings.youtubeAPIKey = "yt_abc"
        XCTAssertEqual(OpenAISettings.youtubeAPIKey, "yt_abc")
    }
}
