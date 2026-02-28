import Foundation

/// Protocol for app settings persistence.
protocol SettingsStoreProtocol: Sendable {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
    func bool(forKey key: String) -> Bool
    func setBool(_ value: Bool, forKey key: String)
    func double(forKey key: String) -> Double
    func setDouble(_ value: Double, forKey key: String)
    func hasValue(forKey key: String) -> Bool
}

/// Well-known settings keys.
enum SettingsKey {
    static let openaiAPIKey = "openai_api_key"
    static let openaiModel = "openai_model"
    static let elevenlabsAPIKey = "elevenlabs_api_key"
    static let elevenlabsVoiceID = "elevenlabs_voice_id"
    static let elevenlabsModelID = "elevenlabs_model_id"
    static let elevenlabsStreaming = "elevenlabs_streaming"
    static let elevenlabsMuted = "elevenlabs_muted"
    static let porcupineAccessKey = "porcupine_access_key"
    static let porcupineSensitivity = "porcupine_sensitivity"
    static let userName = "user_name"
    static let cameraEnabled = "camera_enabled"
    static let ambientListening = "ambient_listening"
    static let followUpTimeoutS = "follow_up_timeout_s"
    static let debugMemory = "debug_memory"
    static let debugPrompt = "debug_prompt"
    static let debugLatency = "debug_latency"
    static let engineCognitiveTrace = "engine_cognitive_trace"
    static let engineWorldModel = "engine_world_model"
    static let engineCuriosity = "engine_curiosity"
    static let engineLongitudinal = "engine_longitudinal"
    static let engineBehavior = "engine_behavior"
    static let engineCounterfactual = "engine_counterfactual"
    static let engineTheoryOfMind = "engine_theory_of_mind"
    static let engineNarrative = "engine_narrative"
    static let engineCausal = "engine_causal"
    static let engineMetacognition = "engine_metacognition"
    static let enginePersonality = "engine_personality"
    static let engineSkillEvolution = "engine_skill_evolution"
    static let youtubeAPIKey = "youtube_api_key"
    static let gmailOAuthToken = "gmail_oauth_token"
}
