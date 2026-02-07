import Foundation

/// Controls voice_settings sent to ElevenLabs for different speech contexts.
enum SpeechMode {
    /// Short confirmations ("Got it", "One sec…") — faster, snappier delivery.
    case confirm
    /// Normal conversational answers — standard delivery.
    case answer

    var voiceSettings: [String: Any] {
        switch self {
        case .confirm:
            return [
                "stability": 0.35,
                "similarity_boost": 0.80,
                "style": 0.0,
                "use_speaker_boost": false,
            ]
        case .answer:
            return [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": true,
            ]
        }
    }
}

/// Settings for ElevenLabs TTS, using Keychain for the API key and UserDefaults for other values.
/// The API key is read from Keychain ONCE at startup and cached in memory to avoid repeated
/// Keychain access prompts.
enum ElevenLabsSettings {

    // MARK: - Keychain identifiers

    /// Stable service + account for the ElevenLabs API key.
    private static let keychainService = "com.samos.elevenlabs"
    private static let keychainAccount = "apiKey"

    /// Legacy location (pre-migration).
    private static let legacyService = "com.samos.app"
    private static let legacyAccount = "elevenlabs_api_key"

    private enum Key {
        static let voiceId = "elevenlabs_voiceId"
        static let modelId = "elevenlabs_modelId"
        static let isMuted = "elevenlabs_isMuted"
        static let useStreaming = "elevenlabs_useStreaming"
        static let keySavedAt = "elevenlabs_keySavedAt"
    }

    private static let defaults = UserDefaults.standard

    // MARK: - API Key (Keychain + in-memory cache)

    /// In-memory cache. Loaded once on first access.
    private static var _cachedApiKey: String?
    /// Whether the cache has been populated (distinguishes nil="not loaded" from ""="no key").
    private static var _cacheLoaded = false

    /// The ElevenLabs API key. Read from Keychain once, then served from memory.
    /// Setting this updates both the in-memory cache and the Keychain.
    static var apiKey: String {
        get {
            if !_cacheLoaded {
                loadApiKeyCache()
            }
            return _cachedApiKey ?? ""
        }
        set {
            // Write-through: update Keychain + cache
            if newValue.isEmpty {
                if useKeychain {
                    KeychainStore.delete(forKey: keychainAccount, service: keychainService)
                }
                _cachedApiKey = ""
                defaults.removeObject(forKey: Key.keySavedAt)
            } else {
                if useKeychain {
                    KeychainStore.set(newValue, forKey: keychainAccount, service: keychainService)
                }
                _cachedApiKey = newValue
                defaults.set(Date(), forKey: Key.keySavedAt)
            }
            _cacheLoaded = true
        }
    }

    /// Whether to persist keys in Keychain (delegates to KeychainStore.useKeychain).
    static var useKeychain: Bool { KeychainStore.useKeychain }

    /// Reads the API key from Keychain once. Migrates from legacy location if needed.
    /// In DEBUG builds, falls back to `ELEVENLABS_API_KEY` env var if Keychain is empty.
    /// Skips Keychain entirely if useKeychain is false.
    private static func loadApiKeyCache() {
        defer { _cacheLoaded = true }

        guard useKeychain else {
            _cachedApiKey = envFallback
            return
        }

        // Try new location first
        if let key = KeychainStore.get(forKey: keychainAccount, service: keychainService), !key.isEmpty {
            _cachedApiKey = key
            return
        }

        // Try legacy location and migrate
        if let legacyKey = KeychainStore.get(forKey: legacyAccount, service: legacyService), !legacyKey.isEmpty {
            KeychainStore.set(legacyKey, forKey: keychainAccount, service: keychainService)
            KeychainStore.delete(forKey: legacyAccount, service: legacyService)
            _cachedApiKey = legacyKey
            return
        }

        // No key found — try env var fallback
        _cachedApiKey = envFallback
    }

    /// In DEBUG builds, returns the `ELEVENLABS_API_KEY` env var if set. Empty string otherwise.
    private static var envFallback: String {
        #if DEBUG
        if let envKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !envKey.isEmpty {
            print("[ElevenLabsSettings] Using ELEVENLABS_API_KEY from environment")
            return envKey
        }
        #endif
        return ""
    }

    // MARK: - Voice & Model

    static var voiceId: String {
        get { defaults.string(forKey: Key.voiceId) ?? "JSWO6cw2AyFE324d5kEr" }
        set { defaults.set(newValue, forKey: Key.voiceId) }
    }

    static var modelId: String {
        get { defaults.string(forKey: Key.modelId) ?? "eleven_multilingual_v2" }
        set { defaults.set(newValue, forKey: Key.modelId) }
    }

    // MARK: - Mute

    static var isMuted: Bool {
        get { defaults.bool(forKey: Key.isMuted) }
        set { defaults.set(newValue, forKey: Key.isMuted) }
    }

    // MARK: - Streaming

    static var useStreaming: Bool {
        get {
            if defaults.object(forKey: Key.useStreaming) == nil { return true }
            return defaults.bool(forKey: Key.useStreaming)
        }
        set { defaults.set(newValue, forKey: Key.useStreaming) }
    }

    // MARK: - Key Metadata

    /// Timestamp when the API key was last saved. Stored in UserDefaults (not secret).
    static var keySavedAt: Date? {
        defaults.object(forKey: Key.keySavedAt) as? Date
    }

    // MARK: - Validation

    static var isConfigured: Bool {
        !apiKey.isEmpty && !voiceId.isEmpty
    }

    // MARK: - Testing Support

    /// Resets the in-memory cache, forcing the next read to hit Keychain.
    /// Only intended for use in tests.
    static func _resetCacheForTesting() {
        _cachedApiKey = nil
        _cacheLoaded = false
    }
}
