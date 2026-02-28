import Foundation

/// Tracks open loops and upcoming tasks for proactive awareness.
actor ProactiveAwareness {
    private var openLoops: [OpenLoop] = []
    private var scheduler: TaskScheduler?

    struct OpenLoop: Sendable {
        let id: String
        let topic: String
        let createdAt: Date
        var resolved: Bool = false
    }

    func setScheduler(_ scheduler: TaskScheduler) {
        self.scheduler = scheduler
    }

    /// Record an open loop (something mentioned but not yet resolved).
    func trackLoop(topic: String) {
        let loop = OpenLoop(id: UUID().uuidString, topic: topic, createdAt: Date())
        openLoops.append(loop)
        if openLoops.count > 20 { openLoops.removeFirst() }
    }

    /// Resolve an open loop.
    func resolveLoop(id: String) {
        if let index = openLoops.firstIndex(where: { $0.id == id }) {
            openLoops[index].resolved = true
        }
    }

    /// Get active (unresolved) open loops.
    func activeLoops() -> [OpenLoop] {
        openLoops.filter { !$0.resolved }
    }

    /// Build a proactive context block.
    func buildContextBlock() async -> String {
        var lines: [String] = []

        // Open loops
        let active = activeLoops()
        if !active.isEmpty {
            lines.append("[OPEN LOOPS]")
            for loop in active.suffix(3) {
                let age = formatAge(loop.createdAt)
                lines.append("- \(loop.topic) (mentioned \(age))")
            }
        }

        // Upcoming scheduled tasks
        if let scheduler {
            let upcoming = await scheduler.activeTasks()
                .filter { $0.fireDate > Date() }
                .sorted { $0.fireDate < $1.fireDate }
                .prefix(3)

            if !upcoming.isEmpty {
                lines.append("[UPCOMING]")
                for task in upcoming {
                    let timeUntil = formatTimeUntil(task.fireDate)
                    lines.append("- \(task.type.rawValue): \(task.label) in \(timeUntil)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func formatAge(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }

    private func formatTimeUntil(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
