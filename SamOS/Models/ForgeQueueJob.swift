import Foundation

// MARK: - Forge Queue Job

/// Persistent model for a SkillForge queue entry.
/// Stored in SQLite by SkillForgeQueueService; processed FIFO.
struct ForgeQueueJob: Identifiable, Equatable {
    let id: UUID
    let goal: String
    let constraints: String?
    var status: Status
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    enum Status: String {
        case queued
        case running
        case completed
        case failed
    }

    init(
        id: UUID = UUID(),
        goal: String,
        constraints: String? = nil,
        status: Status = .queued,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.goal = goal
        self.constraints = constraints
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
