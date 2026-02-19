import Foundation

enum SettingsKey: String, CaseIterable {
    // General
    case userName = "m2_userName"
    case useEmotionalTone = "m3_useEmotionalTone"
    case toneLearningEnabled = "tone_profile_enabled"
    case useKeychainStorage = "samos_useKeychain"
    case developerModeEnabled = "m3_developerModeEnabled"

    // Audio/Visual
    case porcupineAccessKey = "m2_porcupineAccessKey"
    case porcupineKeywordPath = "m2_porcupineKeywordPath"
    case porcupineSensitivity = "m2_porcupineSensitivity"
    case whisperModelPath = "m2_whisperModelPath"
    case silenceThresholdDB = "m2_silenceThresholdDB"
    case silenceDurationMs = "m2_silenceDurationMs"
    case captureBeepEnabled = "m2_captureBeepEnabled"
    case elevenLabsApiKey = "elevenlabs_apiKey"
    case elevenLabsVoiceId = "elevenlabs_voiceId"
    case elevenLabsMuted = "elevenlabs_isMuted"
    case elevenLabsUseStreaming = "elevenlabs_useStreaming"
    case cameraEnabled = "samos_userWantsCameraEnabled"
    case faceRecognitionEnabled = "m3_faceRecognitionEnabled"
    case personalizedGreetingsEnabled = "m3_personalizedGreetingsEnabled"

    // AI Learning / Routing
    case samGatewayURL = "sam_gatewayURL"
    case samSessionId = "sam_sessionId"
    case useOllama = "m3_useOllama"
    case ollamaEndpoint = "m3_ollamaEndpoint"
    case ollamaModel = "m3_ollamaModel"
    case preferOpenAIPlans = "m3_preferOpenAIPlans"
    case disableAutoClosePrompts = "m3_disableAutoClosePrompts"
    case ollamaCombinedTimeoutMs = "m3_ollamaCombinedTimeoutMs"

    // OpenAI
    case openAIApiKey = "openai_apiKey"
    case youtubeAPIKey = "youtube_api_key"
    case openAIPreferredModel = "openai_model"
    case openAIRealtimeModeEnabled = "openai_realtimeModeEnabled"
    case openAIRealtimeUseClassicSTT = "openai_realtimeUseClassicSTT"
    case openAIRealtimeModel = "openai_realtimeModel"
    case openAIRealtimeVoice = "openai_realtimeVoice"
}

