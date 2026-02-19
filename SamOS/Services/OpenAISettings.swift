import Foundation
import AVFoundation
import CryptoKit

/// Settings for OpenAI (SkillForge), with DEBUG keys stored in app-local UserDefaults
/// (DevSecretsStore) to avoid Keychain prompts during development.
enum OpenAISettings {

    // MARK: - Keychain identifiers

    private static let keychainService = "com.samos.openai"
    private static let keychainAccount = "apiKey"
    private static let debugDevKey = "dev.openai.apiKey"

    private enum Key {
        static let model = "openai_model"
        static let escalationModel = "openai_escalation_model"
        static let keySavedAt = "openai_keySavedAt"
        static let invalidatedKeyFingerprint = "openai_invalidatedKeyFingerprint"
        static let lastAuthFailureStatusCode = "openai_lastAuthFailureStatusCode"
        static let realtimeModeEnabled = "openai_realtimeModeEnabled"
        static let realtimeUseClassicSTT = "openai_realtimeUseClassicSTT"
        static let realtimeModel = "openai_realtimeModel"
        static let realtimeVoice = "openai_realtimeVoice"
        static let youtubeAPIKey = "youtube_api_key"
    }

    private static let defaults = UserDefaults.standard

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static var effectiveKeychainService: String {
        #if DEBUG
        if isRunningTests {
            return "\(keychainService).tests"
        }
        #endif
        return keychainService
    }

    private static var effectiveDevSecretKey: String {
        #if DEBUG
        return isRunningTests ? "\(debugDevKey).tests" : debugDevKey
        #else
        return debugDevKey
        #endif
    }

    private static var shouldUseKeychainStorage: Bool {
        #if DEBUG
        // Keep development keys app-local to avoid macOS Keychain access prompts.
        return false
        #else
        return KeychainStore.useKeychain
        #endif
    }

    // MARK: - API Key (Keychain + in-memory cache)

    private static var _cachedApiKey: String?
    private static var _cacheLoaded = false
    private static var _invalidatedKeyFingerprint: String?
    private static var _lastAuthFailureStatusCode: Int?

    enum APIKeyStatus: Equatable {
        case missing
        case ready
        case invalid
    }

    static var apiKey: String {
        get {
            if !_cacheLoaded { loadApiKeyCache() }
            return _cachedApiKey ?? ""
        }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty {
                #if DEBUG
                DevSecretsStore.shared.delete(effectiveDevSecretKey)
                #endif
                if shouldUseKeychainStorage {
                    KeychainStore.delete(forKey: keychainAccount, service: effectiveKeychainService)
                }
                _cachedApiKey = ""
                clearInvalidatedKeyState()
                defaults.removeObject(forKey: Key.keySavedAt)
            } else {
                #if DEBUG
                DevSecretsStore.shared.set(effectiveDevSecretKey, normalized)
                #endif
                if shouldUseKeychainStorage {
                    _ = KeychainStore.set(normalized, forKey: keychainAccount, service: effectiveKeychainService)
                }
                let newFingerprint = keyFingerprint(for: normalized)
                if _invalidatedKeyFingerprint != newFingerprint {
                    clearInvalidatedKeyState()
                }
                _cachedApiKey = normalized
                defaults.set(Date(), forKey: Key.keySavedAt)
            }
            _cacheLoaded = true
        }
    }

    /// Timestamp when the API key was last saved. Stored in UserDefaults (not secret).
    static var keySavedAt: Date? {
        defaults.object(forKey: Key.keySavedAt) as? Date
    }

    /// Reads the API key once.
    /// DEBUG uses DevSecretsStore only.
    /// RELEASE uses Keychain.
    /// Both fall back to `OPENAI_API_KEY` env var when no persisted key exists.
    private static func loadApiKeyCache() {
        defer { _cacheLoaded = true }
        loadInvalidatedKeyStateIfNeeded()

        #if DEBUG
        if let key = DevSecretsStore.shared.get(effectiveDevSecretKey),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _cachedApiKey = key
            return
        }
        #endif

        #if !DEBUG
        if shouldUseKeychainStorage,
           let key = KeychainStore.get(forKey: keychainAccount, service: effectiveKeychainService),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _cachedApiKey = key
            return
        }
        #endif

        let fallback = envFallback
        _cachedApiKey = fallback
        if !fallback.isEmpty {
            #if DEBUG
            DevSecretsStore.shared.set(effectiveDevSecretKey, fallback)
            #endif
            if shouldUseKeychainStorage {
                _ = KeychainStore.set(fallback, forKey: keychainAccount, service: effectiveKeychainService)
            }
        }
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

    static let defaultPreferredModel = "gpt-5.2"

    /// Local fallback list used by Settings UI. Dynamic model discovery is intentionally disabled.
    static let preferredModelFallbacks: [String] = [
        "gpt-5.2",
        "gpt-5.1",
        "gpt-5",
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4o",
        "gpt-4o-mini"
    ]

    // Backward-compatible aliases used by existing UI/tests.
    static let generalModelOptions: [String] = [
        "gpt-5.2",
        "gpt-5.1",
        "gpt-5",
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4o",
        "gpt-4o-mini"
    ]

    static let escalationModelOptions: [String] = [
        "gpt-5.2",
        "gpt-5.1",
        "gpt-5",
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4o",
        "gpt-4o-mini"
    ]

    /// General/default chat model used for most requests.
    static var generalModel: String {
        get {
            let stored = defaults.string(forKey: Key.model)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultPreferredModel : stored
        }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(normalized.isEmpty ? defaultPreferredModel : normalized, forKey: Key.model)
        }
    }

    /// Higher-quality model used for complex tasks.
    static var escalationModel: String {
        get {
            let stored = defaults.string(forKey: Key.escalationModel)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? generalModel : stored
        }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(normalized.isEmpty ? generalModel : normalized, forKey: Key.escalationModel)
        }
    }

    /// Backward-compatible alias.
    static var model: String {
        get { generalModel }
        set { generalModel = newValue }
    }

    static var realtimeModeEnabled: Bool {
        get { defaults.bool(forKey: Key.realtimeModeEnabled) }
        set { defaults.set(newValue, forKey: Key.realtimeModeEnabled) }
    }

    /// When true and realtime mode is enabled, keep STT on classic/local Whisper.
    static var realtimeUseClassicSTT: Bool {
        get { defaults.bool(forKey: Key.realtimeUseClassicSTT) }
        set { defaults.set(newValue, forKey: Key.realtimeUseClassicSTT) }
    }

    static var realtimeModel: String {
        get { defaults.string(forKey: Key.realtimeModel) ?? "gpt-realtime" }
        set { defaults.set(newValue, forKey: Key.realtimeModel) }
    }

    static var realtimeVoice: String {
        get { defaults.string(forKey: Key.realtimeVoice) ?? "alloy" }
        set { defaults.set(newValue, forKey: Key.realtimeVoice) }
    }

    static var youtubeAPIKey: String {
        get {
            let stored = defaults.string(forKey: Key.youtubeAPIKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stored.isEmpty { return stored }
            #if DEBUG
            if let envKey = ProcessInfo.processInfo.environment["YOUTUBE_API_KEY"], !envKey.isEmpty {
                return envKey
            }
            #endif
            return ""
        }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty {
                defaults.removeObject(forKey: Key.youtubeAPIKey)
            } else {
                defaults.set(normalized, forKey: Key.youtubeAPIKey)
            }
        }
    }

    static var isYouTubeConfigured: Bool {
        !youtubeAPIKey.isEmpty
    }

    // MARK: - Validation

    static var isConfigured: Bool {
        apiKeyStatus == .ready
    }

    static var apiKeyStatus: APIKeyStatus {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .missing }
        let fingerprint = keyFingerprint(for: normalized)
        if _invalidatedKeyFingerprint == fingerprint {
            return .invalid
        }
        return .ready
    }

    static var hasStoredAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func preloadAPIKey() {
        _ = apiKey
    }

    static func markAPIKeyRejected(statusCode: Int) {
        guard statusCode == 401 || statusCode == 403 else { return }
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        _invalidatedKeyFingerprint = keyFingerprint(for: normalized)
        _lastAuthFailureStatusCode = statusCode
        defaults.set(_invalidatedKeyFingerprint, forKey: Key.invalidatedKeyFingerprint)
        defaults.set(statusCode, forKey: Key.lastAuthFailureStatusCode)
    }

    static func clearInvalidatedAPIKeyIfNeeded() {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            clearInvalidatedKeyState()
            return
        }
        let fingerprint = keyFingerprint(for: normalized)
        if _invalidatedKeyFingerprint != fingerprint {
            clearInvalidatedKeyState()
        }
    }

    static var authFailureStatusCode: Int? {
        _lastAuthFailureStatusCode
    }

    /// Explicit user-triggered re-check hook for Settings UI.
    static func retryInvalidatedAPIKey() {
        clearInvalidatedKeyState()
    }

    private static func loadInvalidatedKeyStateIfNeeded() {
        _invalidatedKeyFingerprint = defaults.string(forKey: Key.invalidatedKeyFingerprint)
        if let value = defaults.object(forKey: Key.lastAuthFailureStatusCode) as? NSNumber {
            _lastAuthFailureStatusCode = value.intValue
        } else {
            _lastAuthFailureStatusCode = nil
        }
    }

    private static func clearInvalidatedKeyState() {
        _invalidatedKeyFingerprint = nil
        _lastAuthFailureStatusCode = nil
        defaults.removeObject(forKey: Key.invalidatedKeyFingerprint)
        defaults.removeObject(forKey: Key.lastAuthFailureStatusCode)
    }

    private static func keyFingerprint(for key: String) -> String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Testing Support

    static func _resetCacheForTesting() {
        _cachedApiKey = nil
        _cacheLoaded = false
        clearInvalidatedKeyState()
    }

    static func _debugEffectiveKeychainServiceForTesting() -> String {
        effectiveKeychainService
    }

    static func _debugEffectiveDevSecretKeyForTesting() -> String {
        effectiveDevSecretKey
    }

    static func _debugShouldUseKeychainStorageForTesting() -> Bool {
        shouldUseKeychainStorage
    }
}

/// Lightweight OpenAI Realtime WebSocket client for voice I/O.
///
/// Classic mode remains Whisper + ElevenLabs.
/// Realtime mode uses this client for STT + TTS over WebSocket.
enum OpenAIRealtimeSocket {

    enum RealtimeError: Error, LocalizedError {
        case notConfigured
        case badWebSocketURL
        case missingTranscript
        case missingAudio
        case invalidEvent
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "OpenAI Realtime is not configured"
            case .badWebSocketURL:
                return "Invalid OpenAI Realtime WebSocket URL"
            case .missingTranscript:
                return "Realtime transcription returned no text"
            case .missingAudio:
                return "Realtime synthesis returned no audio"
            case .invalidEvent:
                return "Realtime API returned an invalid event"
            case .requestFailed(let message):
                return "Realtime request failed: \(message)"
            }
        }
    }

    private static let inputSampleRate: Double = 24_000
    private static let outputSampleRate: Int = 24_000

    static func transcribeWav(_ wavURL: URL) async throws -> String {
        guard OpenAISettings.isConfigured else { throw RealtimeError.notConfigured }

        let pcm = try convertWavToPCM16(url: wavURL, sampleRate: inputSampleRate)
        guard !pcm.isEmpty else { throw RealtimeError.missingTranscript }
        let requestID = OpenAIAPILogStore.shared.logHTTPRequest(
            service: "OpenAIRealtimeSocket.transcribeWav",
            endpoint: "wss://api.openai.com/v1/realtime",
            method: "WS",
            model: OpenAISettings.realtimeModel,
            timeoutSeconds: 30,
            payload: [
                "operation": "transcribe_wav",
                "voice": OpenAISettings.realtimeVoice,
                "input_audio_bytes": pcm.count
            ]
        )
        let startedAt = Date()

        let task = try makeWebSocketTask()
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        try await sendJSON([
            "type": "session.update",
            "session": [
                "input_audio_format": "pcm16",
                "voice": OpenAISettings.realtimeVoice,
                "input_audio_transcription": [
                    "model": "gpt-4o-mini-transcribe"
                ]
            ]
        ], on: task, requestID: requestID, service: "OpenAIRealtimeSocket.transcribeWav")

        // Use a single input_audio message instead of append/commit to avoid
        // "audio buffer empty" server errors on short clips.
        try await sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_audio",
                        "audio": pcm.base64EncodedString()
                    ]
                ]
            ]
        ], on: task, requestID: requestID, service: "OpenAIRealtimeSocket.transcribeWav")

        try await sendJSON([
            "type": "response.create",
            "response": [
                "modalities": ["text"],
                "instructions": "Transcribe the user's speech verbatim. Return only the transcript text."
            ]
        ], on: task, requestID: requestID, service: "OpenAIRealtimeSocket.transcribeWav")

        var transcript = ""

        while true {
            let event = try await receiveJSON(
                from: task,
                requestID: requestID,
                service: "OpenAIRealtimeSocket.transcribeWav"
            )
            let type = (event["type"] as? String ?? "").lowercased()

            if type == "error" {
                let message = extractString(from: event, preferredKeys: ["message", "error", "code"]) ?? "unknown error"
                OpenAIAPILogStore.shared.logHTTPError(
                    requestID: requestID,
                    service: "OpenAIRealtimeSocket.transcribeWav",
                    endpoint: "wss://api.openai.com/v1/realtime",
                    method: "WS",
                    model: OpenAISettings.realtimeModel,
                    statusCode: nil,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                    error: message,
                    responseData: nil
                )
                throw RealtimeError.requestFailed(message)
            }

            if type.contains("input_audio_transcription.completed") {
                if let full = extractString(from: event, preferredKeys: ["transcript", "text"]) {
                    transcript = full
                }
            } else if type.contains("response.output_text.done") || type.contains("response.output_text.delta") {
                if let chunk = extractString(from: event, preferredKeys: ["text", "delta"]), !chunk.isEmpty {
                    transcript += chunk
                }
            } else if type.contains("output_text.delta") || type.contains("response.text.delta") {
                if let delta = extractString(from: event, preferredKeys: ["delta"]) {
                    transcript += delta
                }
            } else if type.contains("output_text.done") || type.contains("response.text.done") {
                if let full = extractString(from: event, preferredKeys: ["text"]) {
                    transcript = full
                }
            } else if type == "response.done" {
                break
            }
        }

        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw RealtimeError.missingTranscript }
        OpenAIAPILogStore.shared.logRealtimeSummary(
            requestID: requestID,
            service: "OpenAIRealtimeSocket.transcribeWav",
            latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            note: "transcript_chars=\(cleaned.count)"
        )
        return cleaned
    }

    static func synthesizeSpeechData(_ text: String, mode: SpeechMode) async throws -> Data {
        guard OpenAISettings.isConfigured else { throw RealtimeError.notConfigured }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RealtimeError.missingAudio }
        let requestID = OpenAIAPILogStore.shared.logHTTPRequest(
            service: "OpenAIRealtimeSocket.synthesizeSpeechData",
            endpoint: "wss://api.openai.com/v1/realtime",
            method: "WS",
            model: OpenAISettings.realtimeModel,
            timeoutSeconds: 30,
            payload: [
                "operation": "synthesize_speech",
                "voice": OpenAISettings.realtimeVoice,
                "mode": mode == .confirm ? "confirm" : "answer",
                "text": trimmed
            ]
        )
        let startedAt = Date()

        let task = try makeWebSocketTask()
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        try await sendJSON([
            "type": "session.update",
            "session": [
                "output_audio_format": "pcm16",
                "voice": OpenAISettings.realtimeVoice
            ]
        ], on: task, requestID: requestID, service: "OpenAIRealtimeSocket.synthesizeSpeechData")

        try await sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": trimmed
                    ]
                ]
            ]
        ], on: task, requestID: requestID, service: "OpenAIRealtimeSocket.synthesizeSpeechData")

        let instructions: String
        switch mode {
        case .confirm:
            instructions = "Speak this text briefly and naturally."
        case .answer:
            instructions = "Speak this text naturally with clear pacing."
        }

        try await sendJSON([
            "type": "response.create",
            "response": [
                "modalities": ["audio", "text"],
                "instructions": instructions
            ]
        ], on: task, requestID: requestID, service: "OpenAIRealtimeSocket.synthesizeSpeechData")

        var audioBytes = Data()

        while true {
            let event = try await receiveJSON(
                from: task,
                requestID: requestID,
                service: "OpenAIRealtimeSocket.synthesizeSpeechData"
            )
            let type = (event["type"] as? String ?? "").lowercased()

            if type == "error" {
                let message = extractString(from: event, preferredKeys: ["message", "error", "code"]) ?? "unknown error"
                OpenAIAPILogStore.shared.logHTTPError(
                    requestID: requestID,
                    service: "OpenAIRealtimeSocket.synthesizeSpeechData",
                    endpoint: "wss://api.openai.com/v1/realtime",
                    method: "WS",
                    model: OpenAISettings.realtimeModel,
                    statusCode: nil,
                    latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                    error: message,
                    responseData: nil
                )
                throw RealtimeError.requestFailed(message)
            }

            if type.contains("audio.delta") {
                if let delta = extractString(from: event, preferredKeys: ["delta"]),
                   let chunk = Data(base64Encoded: delta) {
                    audioBytes.append(chunk)
                }
            } else if type == "response.done" {
                if audioBytes.isEmpty,
                   let full = extractString(from: event, preferredKeys: ["audio"]),
                   let chunk = Data(base64Encoded: full) {
                    audioBytes.append(chunk)
                }
                break
            }
        }

        guard !audioBytes.isEmpty else { throw RealtimeError.missingAudio }
        OpenAIAPILogStore.shared.logRealtimeSummary(
            requestID: requestID,
            service: "OpenAIRealtimeSocket.synthesizeSpeechData",
            latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            note: "audio_bytes=\(audioBytes.count)"
        )
        return wavDataFromPCM16(audioBytes, sampleRate: outputSampleRate, channels: 1)
    }

    // MARK: - WebSocket helpers

    private static func makeWebSocketTask() throws -> URLSessionWebSocketTask {
        guard let components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            throw RealtimeError.badWebSocketURL
        }
        var comps = components
        comps.queryItems = [URLQueryItem(name: "model", value: OpenAISettings.realtimeModel)]
        guard let url = comps.url else { throw RealtimeError.badWebSocketURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        return URLSession.shared.webSocketTask(with: request)
    }

    private static func sendJSON(_ payload: [String: Any],
                                 on task: URLSessionWebSocketTask,
                                 requestID: String? = nil,
                                 service: String? = nil) async throws {
        if let requestID, let service {
            OpenAIAPILogStore.shared.logRealtimeEvent(
                requestID: requestID,
                service: service,
                direction: "realtime_send",
                payload: payload
            )
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeError.invalidEvent
        }
        try await task.send(.string(text))
    }

    private static func receiveJSON(from task: URLSessionWebSocketTask,
                                    requestID: String? = nil,
                                    service: String? = nil) async throws -> [String: Any] {
        let message = try await withTimeout(seconds: 20) {
            try await task.receive()
        }

        let data: Data
        switch message {
        case .data(let raw):
            data = raw
        case .string(let text):
            guard let raw = text.data(using: .utf8) else {
                throw RealtimeError.invalidEvent
            }
            data = raw
        @unknown default:
            throw RealtimeError.invalidEvent
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealtimeError.invalidEvent
        }
        if let requestID, let service {
            OpenAIAPILogStore.shared.logRealtimeEvent(
                requestID: requestID,
                service: service,
                direction: "realtime_recv",
                payload: json
            )
        }
        return json
    }

    private static func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RealtimeError.requestFailed("timeout")
            }

            let result = try await group.next()
            group.cancelAll()
            guard let result else {
                throw RealtimeError.requestFailed("timeout")
            }
            return result
        }
    }

    // MARK: - Audio helpers

    private static func convertWavToPCM16(url: URL, sampleRate: Double) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: sourceBuffer)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw RealtimeError.requestFailed("audio conversion setup failed")
        }

        let ratio = sampleRate / sourceFormat.sampleRate
        let targetFrames = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * ratio)) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrames) else {
            throw RealtimeError.requestFailed("audio conversion buffer allocation failed")
        }

        var provided = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if provided {
                status.pointee = .endOfStream
                return nil
            }
            provided = true
            status.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            throw conversionError
        }

        guard let pcm = outputBuffer.int16ChannelData else {
            throw RealtimeError.requestFailed("audio conversion produced empty data")
        }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: pcm[0], count: byteCount)
    }

    private static func wavDataFromPCM16(_ pcm: Data, sampleRate: Int, channels: Int) -> Data {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(pcm.count)
        let riffSize = UInt32(36) + dataSize

        var data = Data(capacity: 44 + pcm.count)
        data.append("RIFF".data(using: .ascii)!)
        data.append(littleEndianBytes(riffSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(littleEndianBytes(UInt32(16)))
        data.append(littleEndianBytes(UInt16(1)))
        data.append(littleEndianBytes(UInt16(channels)))
        data.append(littleEndianBytes(UInt32(sampleRate)))
        data.append(littleEndianBytes(UInt32(byteRate)))
        data.append(littleEndianBytes(UInt16(blockAlign)))
        data.append(littleEndianBytes(UInt16(bitsPerSample)))
        data.append("data".data(using: .ascii)!)
        data.append(littleEndianBytes(dataSize))
        data.append(pcm)
        return data
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var le = value.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    // MARK: - JSON helpers

    private static func extractString(from payload: [String: Any], preferredKeys: [String]) -> String? {
        let lowered = Dictionary(uniqueKeysWithValues: preferredKeys.map { ($0.lowercased(), true) })
        return recursiveExtractString(value: payload, preferred: lowered)
    }

    private static func recursiveExtractString(value: Any, preferred: [String: Bool]) -> String? {
        if let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return string
        }

        if let dict = value as? [String: Any] {
            for (key, nested) in dict {
                if preferred[key.lowercased()] == true,
                   let found = recursiveExtractString(value: nested, preferred: preferred) {
                    return found
                }
            }
            for nested in dict.values {
                if let found = recursiveExtractString(value: nested, preferred: preferred) {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            for item in array {
                if let found = recursiveExtractString(value: item, preferred: preferred) {
                    return found
                }
            }
        }

        return nil
    }
}

private extension Data {
    func chunked(into chunkSize: Int) -> [Data] {
        guard chunkSize > 0, count > chunkSize else { return [self] }
        var chunks: [Data] = []
        chunks.reserveCapacity((count / chunkSize) + 1)

        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: chunkSize, limitedBy: endIndex) ?? endIndex
            chunks.append(self[index..<end])
            index = end
        }
        return chunks
    }
}
