import Foundation

// MARK: - SkillForge Job

/// Tracks the status and logs of a SkillForge build job.
struct SkillForgeJob: Identifiable {
    let id: UUID
    let goal: String
    var status: Status
    var logs: [LogEntry]
    let createdAt: Date
    var completedAt: Date?

    enum Status: String {
        case drafting
        case refining
        case implementing
        case testing
        case installing
        case completed
        case failed
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let ts: Date
        let message: String

        init(_ message: String) {
            self.ts = Date()
            self.message = message
        }
    }

    init(goal: String) {
        self.id = UUID()
        self.goal = goal
        self.status = .drafting
        self.logs = []
        self.createdAt = Date()
    }

    mutating func log(_ message: String) {
        logs.append(LogEntry(message))
    }

    mutating func complete() {
        status = .completed
        completedAt = Date()
    }

    mutating func fail(_ reason: String) {
        status = .failed
        completedAt = Date()
        log("Failed: \(reason)")
    }
}
