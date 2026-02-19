import Foundation

/// UserDefaults-backed configuration for M2/M3 services.
/// File paths use security-scoped bookmarks to persist sandbox access across launches.
enum M2Settings {

    // MARK: - Keys

    private enum Key {
        static let porcupineAccessKey = "m2_porcupineAccessKey"
        static let porcupineKeywordBookmark = "m2_porcupineKeywordBookmark"
        static let porcupineKeywordPath = "m2_porcupineKeywordPath"
        static let porcupineSensitivity = "m2_porcupineSensitivity"
        static let whisperModelBookmark = "m2_whisperModelBookmark"
        static let whisperModelPath = "m2_whisperModelPath"
        static let silenceThresholdDB = "m2_silenceThresholdDB"
        static let silenceDurationMs = "m2_silenceDurationMs"
        static let captureBeepEnabled = "m2_captureBeepEnabled"
        static let userName = "m2_userName"
        static let affectMirroringEnabled = "m3_affectMirroringEnabled"
        static let useEmotionalTone = "m3_useEmotionalTone"
        static let toneLearningNoticeShown = "m3_toneLearningNoticeShown"
        static let developerModeEnabled = "m3_developerModeEnabled"
        static let faceRecognitionEnabled = "m3_faceRecognitionEnabled"
        static let personalizedGreetingsEnabled = "m3_personalizedGreetingsEnabled"
        static let useOllama = "m3_useOllama"
        static let preferLocalPlans = "m3_preferLocalPlans"
        static let preferOpenAIPlans = "m3_preferOpenAIPlans"
        static let disableAutoClosePrompts = "m3_disableAutoClosePrompts"
        static let localIntentTimeoutSeconds = "m3_localIntentTimeoutSeconds"
        static let maxSpeakChars = "m3_maxSpeakChars"
        static let ollamaEndpoint = "m3_ollamaEndpoint"
        static let ollamaModel = "m3_ollamaModel"
        static let ollamaCombinedTimeoutMs = "m3_ollamaCombinedTimeoutMs"
        static let samGatewayURL = "sam_gatewayURL"
        static let samSessionId = "sam_sessionId"
    }

    private static let defaults = UserDefaults.standard

    // MARK: - Security-Scoped Bookmark API

    /// Saves a security-scoped bookmark for a URL selected via NSOpenPanel.
    static func saveBookmark(for url: URL, bookmarkKey: String, pathKey: String) {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: bookmarkKey)
            defaults.set(url.path, forKey: pathKey)
            defaults.synchronize()
        } catch {
            defaults.set(url.path, forKey: pathKey)
            defaults.synchronize()
        }
    }

    /// Resolves a security-scoped bookmark, returning the security-scoped URL
    /// with access already started. Returns nil if no bookmark exists or resolution fails.
    /// Caller must call `url.stopAccessingSecurityScopedResource()` when done.
    static func resolveBookmarkURL(bookmarkKey: String, pathKey: String) -> URL? {
        // Try bookmark first (persists across launches)
        if let data = defaults.data(forKey: bookmarkKey) {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if url.startAccessingSecurityScopedResource() {
                    if isStale {
                        saveBookmark(for: url, bookmarkKey: bookmarkKey, pathKey: pathKey)
                    }
                    return url
                }
            } catch {
                // Fall through to path fallback
            }
        }

        // Fallback: try the raw path (works during same session or Xcode debug)
        let path = defaults.string(forKey: pathKey) ?? ""
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    /// Returns the stored path string (without starting security-scoped access).
    /// Used for display only, NOT for file access.
    static func storedPath(pathKey: String) -> String {
        defaults.string(forKey: pathKey) ?? ""
    }

    // MARK: - User

    static var userName: String {
        get { defaults.string(forKey: Key.userName) ?? "there" }
        set { defaults.set(newValue, forKey: Key.userName) }
    }

    // MARK: - Porcupine

    static var porcupineAccessKey: String {
        get { defaults.string(forKey: Key.porcupineAccessKey) ?? "" }
        set { defaults.set(newValue, forKey: Key.porcupineAccessKey) }
    }

    /// Display path for Settings UI. Do NOT use for file access.
    static var porcupineKeywordDisplayPath: String {
        storedPath(pathKey: Key.porcupineKeywordPath)
    }

    /// Resolves the keyword file bookmark and starts security-scoped access.
    /// Returns the URL with access started. Caller must stop access when done.
    static func resolvePorcupineKeywordURL() -> URL? {
        resolveBookmarkURL(bookmarkKey: Key.porcupineKeywordBookmark, pathKey: Key.porcupineKeywordPath)
    }

    static func setPorcupineKeywordURL(_ url: URL) {
        saveBookmark(for: url, bookmarkKey: Key.porcupineKeywordBookmark, pathKey: Key.porcupineKeywordPath)
    }

    static var porcupineSensitivity: Float {
        get {
            let val = defaults.float(forKey: Key.porcupineSensitivity)
            return val == 0 ? 0.5 : val
        }
        set { defaults.set(newValue, forKey: Key.porcupineSensitivity) }
    }

    // MARK: - Whisper

    /// Display path for Settings UI. Do NOT use for file access.
    static var whisperModelDisplayPath: String {
        storedPath(pathKey: Key.whisperModelPath)
    }

    /// Resolves the whisper model bookmark and starts security-scoped access.
    /// Returns the URL with access started. Caller must stop access when done.
    static func resolveWhisperModelURL() -> URL? {
        resolveBookmarkURL(bookmarkKey: Key.whisperModelBookmark, pathKey: Key.whisperModelPath)
    }

    static func setWhisperModelURL(_ url: URL) {
        saveBookmark(for: url, bookmarkKey: Key.whisperModelBookmark, pathKey: Key.whisperModelPath)
    }

    // MARK: - Audio Capture

    static var silenceThresholdDB: Float {
        get {
            let val = defaults.float(forKey: Key.silenceThresholdDB)
            return val == 0 ? -34 : val
        }
        set { defaults.set(newValue, forKey: Key.silenceThresholdDB) }
    }

    static var silenceDurationMs: Int {
        get {
            let val = defaults.integer(forKey: Key.silenceDurationMs)
            return val == 0 ? 700 : val
        }
        set { defaults.set(newValue, forKey: Key.silenceDurationMs) }
    }

    // MARK: - Sound Cues

    static var captureBeepEnabled: Bool {
        get {
            // Default to true if never set
            if defaults.object(forKey: Key.captureBeepEnabled) == nil { return true }
            return defaults.bool(forKey: Key.captureBeepEnabled)
        }
        set { defaults.set(newValue, forKey: Key.captureBeepEnabled) }
    }

    // MARK: - Ollama (M3)

    /// Rollout gate for affect-aware tone mirroring. Defaults to OFF.
    static var affectMirroringEnabled: Bool {
        get { defaults.bool(forKey: Key.affectMirroringEnabled) }
        set { defaults.set(newValue, forKey: Key.affectMirroringEnabled) }
    }

    /// User preference for emotional tone adaptation when affect mirroring is enabled.
    static var useEmotionalTone: Bool {
        get {
            if defaults.object(forKey: Key.useEmotionalTone) == nil { return true }
            return defaults.bool(forKey: Key.useEmotionalTone)
        }
        set { defaults.set(newValue, forKey: Key.useEmotionalTone) }
    }

    static var toneLearningNoticeShown: Bool {
        get { defaults.bool(forKey: Key.toneLearningNoticeShown) }
        set { defaults.set(newValue, forKey: Key.toneLearningNoticeShown) }
    }

    /// Enables developer-only settings and diagnostics in the Settings UI.
    /// Defaults to false.
    static var developerModeEnabled: Bool {
        get { defaults.bool(forKey: Key.developerModeEnabled) }
        set { defaults.set(newValue, forKey: Key.developerModeEnabled) }
    }

    static var faceRecognitionEnabled: Bool {
        get {
            if defaults.object(forKey: Key.faceRecognitionEnabled) == nil { return true }
            return defaults.bool(forKey: Key.faceRecognitionEnabled)
        }
        set { defaults.set(newValue, forKey: Key.faceRecognitionEnabled) }
    }

    static var personalizedGreetingsEnabled: Bool {
        get {
            if defaults.object(forKey: Key.personalizedGreetingsEnabled) == nil { return true }
            return defaults.bool(forKey: Key.personalizedGreetingsEnabled)
        }
        set { defaults.set(newValue, forKey: Key.personalizedGreetingsEnabled) }
    }

    static var useOllama: Bool {
        get {
            if defaults.object(forKey: Key.useOllama) == nil {
                let legacyKeys = ["m2_useOllama", "useOllama"]
                for legacyKey in legacyKeys {
                    if let legacyValue = defaults.object(forKey: legacyKey) as? Bool {
                        defaults.set(legacyValue, forKey: Key.useOllama)
                        return legacyValue
                    }
                }
                return true
            }
            return defaults.bool(forKey: Key.useOllama)
        }
        set { defaults.set(newValue, forKey: Key.useOllama) }
    }

    /// Legacy setting retained for backwards compatibility with older tests/config paths.
    /// Plan routing no longer reads this value for default behavior.
    static var preferLocalPlans: Bool {
        get { defaults.bool(forKey: Key.preferLocalPlans) }
        set { defaults.set(newValue, forKey: Key.preferLocalPlans) }
    }

    /// Dev override: when true and OpenAI is configured, plan routing uses OpenAI-first order.
    /// Default is false so plans stay Ollama-first unless explicitly overridden.
    static var preferOpenAIPlans: Bool {
        get { defaults.bool(forKey: Key.preferOpenAIPlans) }
        set { defaults.set(newValue, forKey: Key.preferOpenAIPlans) }
    }

    /// When true, suppresses generic conversational soft closes (e.g. "Anything else?").
    /// Defaults to true for transactional replies.
    static var disableAutoClosePrompts: Bool {
        get {
            if defaults.object(forKey: Key.disableAutoClosePrompts) == nil { return true }
            return defaults.bool(forKey: Key.disableAutoClosePrompts)
        }
        set { defaults.set(newValue, forKey: Key.disableAutoClosePrompts) }
    }

    /// Timeout budget for local intent classification, in seconds.
    /// Defaults to 2.0s to accommodate small local models under audio load.
    static var localIntentTimeoutSeconds: Double {
        get {
            guard defaults.object(forKey: Key.localIntentTimeoutSeconds) != nil else { return 2.0 }
            let value = defaults.double(forKey: Key.localIntentTimeoutSeconds)
            return value > 0 ? value : 2.0
        }
        set { defaults.set(max(0.1, newValue), forKey: Key.localIntentTimeoutSeconds) }
    }

    /// Maximum characters spoken per turn when speech policy condenses tool-heavy responses.
    /// Defaults to 320 and is clamped to a safe 120...600 range.
    static var maxSpeakChars: Int {
        get {
            guard defaults.object(forKey: Key.maxSpeakChars) != nil else { return 320 }
            let value = defaults.integer(forKey: Key.maxSpeakChars)
            return min(600, max(120, value))
        }
        set { defaults.set(min(600, max(120, newValue)), forKey: Key.maxSpeakChars) }
    }

    static var ollamaEndpoint: String {
        get { defaults.string(forKey: Key.ollamaEndpoint) ?? "http://127.0.0.1:11434" }
        set { defaults.set(newValue, forKey: Key.ollamaEndpoint) }
    }

    static var ollamaModel: String {
        get { defaults.string(forKey: Key.ollamaModel) ?? "qwen2.5:3b-instruct" }
        set { defaults.set(newValue, forKey: Key.ollamaModel) }
    }

    /// Timeout for the combined Ollama intent+plan route call, in milliseconds.
    /// Defaults to 3500ms and is clamped to 500..10000.
    static var ollamaCombinedTimeoutMs: Int {
        get {
            guard defaults.object(forKey: Key.ollamaCombinedTimeoutMs) != nil else { return 3500 }
            let value = defaults.integer(forKey: Key.ollamaCombinedTimeoutMs)
            return min(10000, max(500, value))
        }
        set { defaults.set(min(10000, max(500, newValue)), forKey: Key.ollamaCombinedTimeoutMs) }
    }

    static var ollamaCombinedTimeoutIsUserOverridden: Bool {
        defaults.object(forKey: Key.ollamaCombinedTimeoutMs) != nil
    }

    // MARK: - Sam Gateway

    /// Base URL for the Sam gateway (e.g. "http://localhost:8002").
    /// When non-empty, all user input is routed to the gateway instead of
    /// the local Ollama/OpenAI pipeline.
    static var samGatewayURL: String {
        get { defaults.string(forKey: Key.samGatewayURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.samGatewayURL) }
    }

    /// Persisted session ID so conversation continues across app launches.
    static var samSessionId: String {
        get { defaults.string(forKey: Key.samSessionId) ?? "" }
        set { defaults.set(newValue, forKey: Key.samSessionId) }
    }

    /// True when the Sam gateway is configured and should be used.
    static var useSamGateway: Bool {
        !samGatewayURL.isEmpty
    }

    // MARK: - Validation

    static var isConfigured: Bool {
        !porcupineAccessKey.isEmpty
            && !porcupineKeywordDisplayPath.isEmpty
            && !whisperModelDisplayPath.isEmpty
    }
}
