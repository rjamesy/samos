import Foundation

struct STTDiagnosticsSnapshot {
    let selectedEngine: String
    let modelFound: Bool
    let prewarmed: Bool
    let lastError: String?
    let launchFallbackNote: String?
}

final class STTDiagnosticsStore {
    static let shared = STTDiagnosticsStore()

    private let lock = NSLock()
    private var selectedEngine: String = "whisper_cpp"
    private var modelFound = false
    private var prewarmed = false
    private var lastError: String?
    private var launchFallbackNote: String?

    private init() {}

    func snapshot() -> STTDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return STTDiagnosticsSnapshot(
            selectedEngine: selectedEngine,
            modelFound: modelFound,
            prewarmed: prewarmed,
            lastError: lastError,
            launchFallbackNote: launchFallbackNote
        )
    }

    func recordEngineSelection(realtimeModeEnabled: Bool, useClassicSTT: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if realtimeModeEnabled && !useClassicSTT {
            selectedEngine = "openai_realtime"
        } else {
            selectedEngine = "whisper_cpp"
        }
    }

    func recordModelFound(_ found: Bool) {
        lock.lock()
        defer { lock.unlock() }
        modelFound = found
        if !found {
            prewarmed = false
        }
    }

    func recordPrewarm(success: Bool, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        prewarmed = success
        if let error, !error.isEmpty {
            lastError = error
        } else if success {
            lastError = nil
        }
    }

    func recordError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        lastError = trimmed
    }

    func recordBundleFallbackOnce(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard launchFallbackNote == nil else { return }
        launchFallbackNote = trimmed
    }
}
