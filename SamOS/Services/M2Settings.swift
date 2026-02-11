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
        static let useOllama = "m3_useOllama"
        static let ollamaEndpoint = "m3_ollamaEndpoint"
        static let ollamaModel = "m3_ollamaModel"
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

    static var useOllama: Bool {
        get { defaults.bool(forKey: Key.useOllama) }
        set { defaults.set(newValue, forKey: Key.useOllama) }
    }

    static var ollamaEndpoint: String {
        get { defaults.string(forKey: Key.ollamaEndpoint) ?? "http://127.0.0.1:11434" }
        set { defaults.set(newValue, forKey: Key.ollamaEndpoint) }
    }

    static var ollamaModel: String {
        get { defaults.string(forKey: Key.ollamaModel) ?? "qwen2.5:7b-instruct" }
        set { defaults.set(newValue, forKey: Key.ollamaModel) }
    }

    // MARK: - Validation

    static var isConfigured: Bool {
        !porcupineAccessKey.isEmpty
            && !porcupineKeywordDisplayPath.isEmpty
            && !whisperModelDisplayPath.isEmpty
    }
}
