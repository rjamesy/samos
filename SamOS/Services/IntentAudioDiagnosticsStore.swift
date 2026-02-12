import Foundation

struct IntentAudioDiagnosticsSnapshot {
    let captureMs: Int?
    let sttMs: Int?
    let recentAudioError: String?
}

/// Lightweight cross-service diagnostics so intent routing logs can correlate
/// timeout behavior with recent audio pipeline pressure.
final class IntentAudioDiagnosticsStore {
    static let shared = IntentAudioDiagnosticsStore()

    private struct AudioErrorEntry {
        let timestamp: Date
        let message: String
    }

    private let lock = NSLock()
    private var lastCaptureMs: Int?
    private var lastSttMs: Int?
    private var lastTimingUpdatedAt: Date?
    private var recentErrors: [AudioErrorEntry] = []
    private let maxStoredErrors = 8

    private init() {}

    func recordTiming(captureMs: Int?, sttMs: Int?) {
        lock.lock()
        defer { lock.unlock() }
        lastCaptureMs = captureMs
        lastSttMs = sttMs
        lastTimingUpdatedAt = Date()
    }

    func recordAudioError(_ message: String) {
        let compact = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !compact.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        recentErrors.append(AudioErrorEntry(timestamp: Date(), message: compact))
        if recentErrors.count > maxStoredErrors {
            recentErrors.removeFirst(recentErrors.count - maxStoredErrors)
        }
    }

    func snapshot(maxAgeSeconds: TimeInterval = 20) -> IntentAudioDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        recentErrors = recentErrors.filter { now.timeIntervalSince($0.timestamp) <= maxAgeSeconds }
        let timingFresh = lastTimingUpdatedAt.map { now.timeIntervalSince($0) <= maxAgeSeconds } ?? false
        return IntentAudioDiagnosticsSnapshot(
            captureMs: timingFresh ? lastCaptureMs : nil,
            sttMs: timingFresh ? lastSttMs : nil,
            recentAudioError: recentErrors.last?.message
        )
    }
}
