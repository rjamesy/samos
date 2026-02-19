import Foundation

struct SettingsSnapshot: Equatable {
    struct General: Equatable {
        var userName: String
        var useEmotionalTone: Bool
        var developerModeEnabled: Bool
        var useKeychainStorage: Bool
    }

    struct AudioVisual: Equatable {
        var porcupineAccessKey: String
        var porcupineKeywordPath: String
        var porcupineSensitivity: Float
        var whisperModelPath: String
        var silenceThresholdDB: Float
        var silenceDurationMs: Int
        var captureBeepEnabled: Bool
        var faceRecognitionEnabled: Bool
        var personalizedGreetingsEnabled: Bool
        var elevenLabsVoiceId: String
        var elevenLabsMuted: Bool
        var elevenLabsUseStreaming: Bool
    }

    struct AIRouting: Equatable {
        var useOllama: Bool
        var ollamaEndpoint: String
        var ollamaModel: String
        var preferOpenAIPlans: Bool
        var disableAutoClosePrompts: Bool
        var ollamaCombinedTimeoutMs: Int
        var samGatewayURL: String
    }

    struct OpenAI: Equatable {
        var preferredModel: String
        var apiKeyConfigured: Bool
        var youtubeConfigured: Bool
        var realtimeModeEnabled: Bool
        var realtimeUseClassicSTT: Bool
        var realtimeModel: String
        var realtimeVoice: String
    }

    var general: General
    var audioVisual: AudioVisual
    var aiRouting: AIRouting
    var openAI: OpenAI
}

protocol SettingsStore {
    // General
    var userName: String { get set }
    var useEmotionalTone: Bool { get set }
    var developerModeEnabled: Bool { get set }
    var useKeychainStorage: Bool { get set }

    // Audio/Visual
    var porcupineAccessKey: String { get set }
    var porcupineKeywordPath: String { get set }
    var porcupineSensitivity: Float { get set }
    var whisperModelPath: String { get set }
    var silenceThresholdDB: Float { get set }
    var silenceDurationMs: Int { get set }
    var captureBeepEnabled: Bool { get set }
    var faceRecognitionEnabled: Bool { get set }
    var personalizedGreetingsEnabled: Bool { get set }
    var elevenLabsVoiceId: String { get set }
    var elevenLabsMuted: Bool { get set }
    var elevenLabsUseStreaming: Bool { get set }

    // AI routing
    var useOllama: Bool { get set }
    var ollamaEndpoint: String { get set }
    var ollamaModel: String { get set }
    var preferOpenAIPlans: Bool { get set }
    var disableAutoClosePrompts: Bool { get set }
    var ollamaCombinedTimeoutMs: Int { get set }
    var samGatewayURL: String { get set }

    // OpenAI
    var openAIApiKey: String { get set }
    var openAIYouTubeApiKey: String { get set }
    var openAIPreferredModel: String { get set }
    var openAIRealtimeModeEnabled: Bool { get set }
    var openAIRealtimeUseClassicSTT: Bool { get set }
    var openAIRealtimeModel: String { get set }
    var openAIRealtimeVoice: String { get set }

    // Snapshot + coverage
    var snapshot: SettingsSnapshot { get }
    var supportedKeys: [SettingsKey] { get }
}

final class UserDefaultsSettingsStore: SettingsStore {
    var userName: String {
        get { M2Settings.userName }
        set { M2Settings.userName = newValue }
    }

    var useEmotionalTone: Bool {
        get { M2Settings.useEmotionalTone }
        set { M2Settings.useEmotionalTone = newValue }
    }

    var developerModeEnabled: Bool {
        get { M2Settings.developerModeEnabled }
        set { M2Settings.developerModeEnabled = newValue }
    }

    var useKeychainStorage: Bool {
        get { KeychainStore.useKeychain }
        set { KeychainStore.useKeychain = newValue }
    }

    var porcupineAccessKey: String {
        get { M2Settings.porcupineAccessKey }
        set { M2Settings.porcupineAccessKey = newValue }
    }

    var porcupineKeywordPath: String {
        get { M2Settings.porcupineKeywordDisplayPath }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            M2Settings.setPorcupineKeywordURL(URL(fileURLWithPath: trimmed))
        }
    }

    var porcupineSensitivity: Float {
        get { M2Settings.porcupineSensitivity }
        set { M2Settings.porcupineSensitivity = newValue }
    }

    var whisperModelPath: String {
        get { M2Settings.whisperModelDisplayPath }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            M2Settings.setWhisperModelURL(URL(fileURLWithPath: trimmed))
        }
    }

    var silenceThresholdDB: Float {
        get { M2Settings.silenceThresholdDB }
        set { M2Settings.silenceThresholdDB = newValue }
    }

    var silenceDurationMs: Int {
        get { M2Settings.silenceDurationMs }
        set { M2Settings.silenceDurationMs = newValue }
    }

    var captureBeepEnabled: Bool {
        get { M2Settings.captureBeepEnabled }
        set { M2Settings.captureBeepEnabled = newValue }
    }

    var faceRecognitionEnabled: Bool {
        get { M2Settings.faceRecognitionEnabled }
        set { M2Settings.faceRecognitionEnabled = newValue }
    }

    var personalizedGreetingsEnabled: Bool {
        get { M2Settings.personalizedGreetingsEnabled }
        set { M2Settings.personalizedGreetingsEnabled = newValue }
    }

    var elevenLabsVoiceId: String {
        get { ElevenLabsSettings.voiceId }
        set { ElevenLabsSettings.voiceId = newValue }
    }

    var elevenLabsMuted: Bool {
        get { ElevenLabsSettings.isMuted }
        set { ElevenLabsSettings.isMuted = newValue }
    }

    var elevenLabsUseStreaming: Bool {
        get { ElevenLabsSettings.useStreaming }
        set { ElevenLabsSettings.useStreaming = newValue }
    }

    var useOllama: Bool {
        get { M2Settings.useOllama }
        set { M2Settings.useOllama = newValue }
    }

    var ollamaEndpoint: String {
        get { M2Settings.ollamaEndpoint }
        set { M2Settings.ollamaEndpoint = newValue }
    }

    var ollamaModel: String {
        get { M2Settings.ollamaModel }
        set { M2Settings.ollamaModel = newValue }
    }

    var preferOpenAIPlans: Bool {
        get { M2Settings.preferOpenAIPlans }
        set { M2Settings.preferOpenAIPlans = newValue }
    }

    var disableAutoClosePrompts: Bool {
        get { M2Settings.disableAutoClosePrompts }
        set { M2Settings.disableAutoClosePrompts = newValue }
    }

    var ollamaCombinedTimeoutMs: Int {
        get { M2Settings.ollamaCombinedTimeoutMs }
        set { M2Settings.ollamaCombinedTimeoutMs = newValue }
    }

    var samGatewayURL: String {
        get { M2Settings.samGatewayURL }
        set { M2Settings.samGatewayURL = newValue }
    }

    var openAIApiKey: String {
        get { OpenAISettings.apiKey }
        set { OpenAISettings.apiKey = newValue }
    }

    var openAIYouTubeApiKey: String {
        get { OpenAISettings.youtubeAPIKey }
        set { OpenAISettings.youtubeAPIKey = newValue }
    }

    var openAIPreferredModel: String {
        get { OpenAISettings.generalModel }
        set {
            OpenAISettings.generalModel = newValue
            OpenAISettings.escalationModel = newValue
        }
    }

    var openAIRealtimeModeEnabled: Bool {
        get { OpenAISettings.realtimeModeEnabled }
        set { OpenAISettings.realtimeModeEnabled = newValue }
    }

    var openAIRealtimeUseClassicSTT: Bool {
        get { OpenAISettings.realtimeUseClassicSTT }
        set { OpenAISettings.realtimeUseClassicSTT = newValue }
    }

    var openAIRealtimeModel: String {
        get { OpenAISettings.realtimeModel }
        set { OpenAISettings.realtimeModel = newValue }
    }

    var openAIRealtimeVoice: String {
        get { OpenAISettings.realtimeVoice }
        set { OpenAISettings.realtimeVoice = newValue }
    }

    var snapshot: SettingsSnapshot {
        SettingsSnapshot(
            general: .init(
                userName: userName,
                useEmotionalTone: useEmotionalTone,
                developerModeEnabled: developerModeEnabled,
                useKeychainStorage: useKeychainStorage
            ),
            audioVisual: .init(
                porcupineAccessKey: porcupineAccessKey,
                porcupineKeywordPath: porcupineKeywordPath,
                porcupineSensitivity: porcupineSensitivity,
                whisperModelPath: whisperModelPath,
                silenceThresholdDB: silenceThresholdDB,
                silenceDurationMs: silenceDurationMs,
                captureBeepEnabled: captureBeepEnabled,
                faceRecognitionEnabled: faceRecognitionEnabled,
                personalizedGreetingsEnabled: personalizedGreetingsEnabled,
                elevenLabsVoiceId: elevenLabsVoiceId,
                elevenLabsMuted: elevenLabsMuted,
                elevenLabsUseStreaming: elevenLabsUseStreaming
            ),
            aiRouting: .init(
                useOllama: useOllama,
                ollamaEndpoint: ollamaEndpoint,
                ollamaModel: ollamaModel,
                preferOpenAIPlans: preferOpenAIPlans,
                disableAutoClosePrompts: disableAutoClosePrompts,
                ollamaCombinedTimeoutMs: ollamaCombinedTimeoutMs,
                samGatewayURL: samGatewayURL
            ),
            openAI: .init(
                preferredModel: openAIPreferredModel,
                apiKeyConfigured: OpenAISettings.apiKeyStatus == .ready,
                youtubeConfigured: OpenAISettings.isYouTubeConfigured,
                realtimeModeEnabled: openAIRealtimeModeEnabled,
                realtimeUseClassicSTT: openAIRealtimeUseClassicSTT,
                realtimeModel: openAIRealtimeModel,
                realtimeVoice: openAIRealtimeVoice
            )
        )
    }

    var supportedKeys: [SettingsKey] {
        SettingsKey.allCases
    }
}

final class InMemorySettingsStore: SettingsStore {
    var userName: String = "there"
    var useEmotionalTone: Bool = true
    var developerModeEnabled: Bool = false
    var useKeychainStorage: Bool = false

    var porcupineAccessKey: String = ""
    var porcupineKeywordPath: String = ""
    var porcupineSensitivity: Float = 0.5
    var whisperModelPath: String = ""
    var silenceThresholdDB: Float = -34
    var silenceDurationMs: Int = 700
    var captureBeepEnabled: Bool = true
    var faceRecognitionEnabled: Bool = true
    var personalizedGreetingsEnabled: Bool = true
    var elevenLabsVoiceId: String = "JSWO6cw2AyFE324d5kEr"
    var elevenLabsMuted: Bool = false
    var elevenLabsUseStreaming: Bool = true

    var useOllama: Bool = true
    var ollamaEndpoint: String = "http://127.0.0.1:11434"
    var ollamaModel: String = "qwen2.5:3b-instruct"
    var preferOpenAIPlans: Bool = false
    var disableAutoClosePrompts: Bool = true
    var ollamaCombinedTimeoutMs: Int = 3500
    var samGatewayURL: String = ""

    var openAIApiKey: String = ""
    var openAIYouTubeApiKey: String = ""
    var openAIPreferredModel: String = "gpt-5.2"
    var openAIRealtimeModeEnabled: Bool = false
    var openAIRealtimeUseClassicSTT: Bool = false
    var openAIRealtimeModel: String = "gpt-realtime"
    var openAIRealtimeVoice: String = "alloy"

    var snapshot: SettingsSnapshot {
        SettingsSnapshot(
            general: .init(
                userName: userName,
                useEmotionalTone: useEmotionalTone,
                developerModeEnabled: developerModeEnabled,
                useKeychainStorage: useKeychainStorage
            ),
            audioVisual: .init(
                porcupineAccessKey: porcupineAccessKey,
                porcupineKeywordPath: porcupineKeywordPath,
                porcupineSensitivity: porcupineSensitivity,
                whisperModelPath: whisperModelPath,
                silenceThresholdDB: silenceThresholdDB,
                silenceDurationMs: silenceDurationMs,
                captureBeepEnabled: captureBeepEnabled,
                faceRecognitionEnabled: faceRecognitionEnabled,
                personalizedGreetingsEnabled: personalizedGreetingsEnabled,
                elevenLabsVoiceId: elevenLabsVoiceId,
                elevenLabsMuted: elevenLabsMuted,
                elevenLabsUseStreaming: elevenLabsUseStreaming
            ),
            aiRouting: .init(
                useOllama: useOllama,
                ollamaEndpoint: ollamaEndpoint,
                ollamaModel: ollamaModel,
                preferOpenAIPlans: preferOpenAIPlans,
                disableAutoClosePrompts: disableAutoClosePrompts,
                ollamaCombinedTimeoutMs: ollamaCombinedTimeoutMs,
                samGatewayURL: samGatewayURL
            ),
            openAI: .init(
                preferredModel: openAIPreferredModel,
                apiKeyConfigured: !openAIApiKey.isEmpty,
                youtubeConfigured: !openAIYouTubeApiKey.isEmpty,
                realtimeModeEnabled: openAIRealtimeModeEnabled,
                realtimeUseClassicSTT: openAIRealtimeUseClassicSTT,
                realtimeModel: openAIRealtimeModel,
                realtimeVoice: openAIRealtimeVoice
            )
        )
    }

    var supportedKeys: [SettingsKey] {
        SettingsKey.allCases
    }
}
