import Foundation

protocol Clock {
    var now: Date { get }
}

struct SystemClock: Clock {
    var now: Date { Date() }
}

struct TimingSpan: Equatable {
    let name: String
    let startedAt: Date
    let endedAt: Date

    var durationMs: Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt) * 1000))
    }
}

final class TimingTracer {
    private var starts: [String: Date] = [:]
    private(set) var spans: [TimingSpan] = []
    private let clock: Clock

    init(clock: Clock) {
        self.clock = clock
    }

    func begin(_ name: String) {
        starts[name] = clock.now
    }

    func end(_ name: String) {
        guard let startedAt = starts.removeValue(forKey: name) else { return }
        spans.append(TimingSpan(name: name, startedAt: startedAt, endedAt: clock.now))
    }

    func clear() {
        starts.removeAll()
        spans.removeAll()
    }
}
