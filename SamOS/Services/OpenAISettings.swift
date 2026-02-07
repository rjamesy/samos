import Foundation

/// Settings for OpenAI (SkillForge), using Keychain for the API key and UserDefaults for the model.
/// Follows the same pattern as ElevenLabsSettings.
enum OpenAISettings {

    // MARK: - Keychain identifiers

    private static let keychainService = "com.samos.openai"
    private static let keychainAccount = "apiKey"

    private enum Key {
        static let model = "openai_model"
        static let keySavedAt = "openai_keySavedAt"
    }

    private static let defaults = UserDefaults.standard

    // MARK: - API Key (Keychain + in-memory cache)

    private static var _cachedApiKey: String?
    private static var _cacheLoaded = false

    static var apiKey: String {
        get {
            if !_cacheLoaded { loadApiKeyCache() }
            return _cachedApiKey ?? ""
        }
        set {
            if newValue.isEmpty {
                if KeychainStore.useKeychain {
                    KeychainStore.delete(forKey: keychainAccount, service: keychainService)
                }
                _cachedApiKey = ""
                defaults.removeObject(forKey: Key.keySavedAt)
            } else {
                if KeychainStore.useKeychain {
                    KeychainStore.set(newValue, forKey: keychainAccount, service: keychainService)
                }
                _cachedApiKey = newValue
                defaults.set(Date(), forKey: Key.keySavedAt)
            }
            _cacheLoaded = true
        }
    }

    /// Timestamp when the API key was last saved. Stored in UserDefaults (not secret).
    static var keySavedAt: Date? {
        defaults.object(forKey: Key.keySavedAt) as? Date
    }

    /// Reads the API key from Keychain once.
    /// In DEBUG builds, falls back to `OPENAI_API_KEY` env var if Keychain is empty.
    private static func loadApiKeyCache() {
        defer { _cacheLoaded = true }

        guard KeychainStore.useKeychain else {
            _cachedApiKey = envFallback
            return
        }

        if let key = KeychainStore.get(forKey: keychainAccount, service: keychainService), !key.isEmpty {
            _cachedApiKey = key
            return
        }

        // No key found — try env var fallback
        _cachedApiKey = envFallback
    }

    /// In DEBUG builds, returns the `OPENAI_API_KEY` env var if set. Empty string otherwise.
    private static var envFallback: String {
        #if DEBUG
        if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envKey.isEmpty {
            print("[OpenAISettings] Using OPENAI_API_KEY from environment")
            return envKey
        }
        #endif
        return ""
    }

    // MARK: - Model

    static var model: String {
        get { defaults.string(forKey: Key.model) ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    // MARK: - Validation

    static var isConfigured: Bool {
        !apiKey.isEmpty
    }

    // MARK: - Testing Support

    static func _resetCacheForTesting() {
        _cachedApiKey = nil
        _cacheLoaded = false
    }
}
