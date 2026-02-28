import Foundation

/// State machine for an active alarm session.
/// Manages the lifecycle: ringing → snoozed → dismissed.
final class AlarmSession: @unchecked Sendable, Identifiable {
    let id: String
    let label: String
    let firedAt: Date

    enum State: String, Sendable {
        case ringing, snoozed, dismissed
    }

    private(set) var state: State = .ringing
    private var snoozeCount: Int = 0
    private var snoozeTask: Task<Void, Never>?

    init(id: String, label: String, firedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.firedAt = firedAt
    }

    /// Snooze the alarm for the given duration.
    func snooze(minutes: Int = 5, onRefire: @escaping @Sendable () -> Void) {
        guard state == .ringing else { return }
        state = .snoozed
        snoozeCount += 1

        snoozeTask = Task {
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            self.state = .ringing
            onRefire()
        }
    }

    /// Dismiss the alarm permanently.
    func dismiss() {
        state = .dismissed
        snoozeTask?.cancel()
        snoozeTask = nil
    }

    /// Get a display summary.
    var summary: String {
        switch state {
        case .ringing: return "Alarm '\(label)' is ringing!"
        case .snoozed: return "Alarm '\(label)' snoozed (x\(snoozeCount))"
        case .dismissed: return "Alarm '\(label)' dismissed"
        }
    }
}
