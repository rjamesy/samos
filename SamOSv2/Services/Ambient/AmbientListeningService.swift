import Foundation

/// Always-on ambient listening mode.
/// Maintains a ring buffer of recent audio transcriptions and categorizes them.
actor AmbientListeningService {
    private let settings: SettingsStoreProtocol
    private var ringBuffer: [AmbientEntry] = []
    private let maxEntries = 50
    private(set) var isActive = false

    struct AmbientEntry: Sendable {
        let text: String
        let category: Category
        let timestamp: Date

        enum Category: String, Sendable {
            case conversation, music, tv, silence, noise, other
        }
    }

    init(settings: SettingsStoreProtocol) {
        self.settings = settings
    }

    func start() {
        guard settings.bool(forKey: SettingsKey.ambientListening) else { return }
        isActive = true
    }

    func stop() {
        isActive = false
    }

    /// Record a new ambient observation.
    func record(text: String, category: AmbientEntry.Category = .other) {
        guard isActive else { return }
        let entry = AmbientEntry(text: text, category: category, timestamp: Date())
        ringBuffer.append(entry)
        if ringBuffer.count > maxEntries {
            ringBuffer.removeFirst(ringBuffer.count - maxEntries)
        }
    }

    /// Get recent ambient observations for prompt injection.
    func recentObservations(maxItems: Int = 5) -> [AmbientEntry] {
        Array(ringBuffer.suffix(maxItems))
    }

    /// Build a context block for system prompt injection.
    func buildContextBlock() -> String {
        let recent = recentObservations()
        guard !recent.isEmpty else { return "" }

        var lines = ["[AMBIENT CONTEXT]"]
        for entry in recent {
            let timeAgo = formatTimeAgo(entry.timestamp)
            lines.append("- [\(entry.category.rawValue)] \(timeAgo): \(entry.text)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatTimeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
