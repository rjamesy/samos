import Foundation

/// App-wide constants and configuration.
enum AppConfig {
    static let appName = "SamOSv2"
    static let version = "2.0.0"
    static let bundleID = "com.samosv2.SamOSv2"

    // MARK: - Token / Character Budgets

    /// Total system prompt character budget.
    static let totalPromptBudget = 32_000

    /// Per-block budgets (characters).
    enum PromptBudget {
        static let identity = 3_000
        static let responseRules = 1_500
        static let toolManifest = 4_000
        static let memory = 6_000
        static let engineContext = 4_000
        static let affectTone = 1_000
        static let currentState = 500
        static let conversationHistory = 10_000
        static let temporalEpisode = 2_000
    }

    // MARK: - Memory

    /// Maximum number of identity facts always injected.
    static let maxIdentityFacts = 8
    /// Maximum query-relevant memories.
    static let maxQueryMemories = 12
    /// Maximum chars for query-relevant memory block.
    static let maxQueryMemoryChars = 2_000
    /// Maximum chars for temporal context.
    static let maxTemporalChars = 3_000

    // MARK: - LLM

    /// Default OpenAI model.
    static let defaultModel = "gpt-4o"
    /// Maximum completion tokens.
    static let maxCompletionTokens = 2_000
    /// Default temperature.
    static let defaultTemperature = 0.9
    /// Request timeout in seconds.
    static let llmTimeoutSeconds: TimeInterval = 30

    // MARK: - TTS

    /// Default ElevenLabs model.
    static let defaultTTSModel = "eleven_turbo_v2"
    /// TTS audio cache size.
    static let ttsCacheSize = 40

    // MARK: - Engines

    /// Max concurrent intelligence engines.
    static let maxConcurrentEngines = 3
    /// Engine timeout in seconds.
    static let engineTimeoutSeconds: TimeInterval = 10

    // MARK: - Voice

    /// Follow-up timeout after response (seconds).
    static let defaultFollowUpTimeout: TimeInterval = 8.0
    /// Default Porcupine sensitivity.
    static let defaultWakeWordSensitivity: Double = 0.5

    // MARK: - Database

    /// Database filename.
    static let databaseFilename = "samosv2.db"

    /// Schema version for migrations.
    static let schemaVersion = 1

    // MARK: - Memory Expiry (days)

    enum MemoryTTL {
        static let fact = 365
        static let preference = 365
        static let note = 90
        static let checkin = 7
    }

    // MARK: - Chat

    /// Maximum characters in a single chat message.
    static let maxChatMessageLength = 4_000
}
