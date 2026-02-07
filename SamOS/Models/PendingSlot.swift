import Foundation

/// Unified pending state for when Sam is waiting for additional user input.
/// Replaces both PendingClarification and PendingInteraction.
struct PendingSlot: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let expiresAt: Date
    let slotName: String
    let prompt: String
    let originalUserText: String
    var attempts: Int

    var isExpired: Bool { Date() >= expiresAt }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        slotName: String,
        prompt: String,
        originalUserText: String,
        attempts: Int = 0,
        ttl: TimeInterval = 600
    ) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(ttl)
        self.slotName = slotName
        self.prompt = prompt
        self.originalUserText = originalUserText
        self.attempts = attempts
    }
}
