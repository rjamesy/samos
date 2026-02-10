import Foundation

/// Unified pending state for when Sam is waiting for additional user input.
/// Replaces both PendingClarification and PendingInteraction.
struct PendingSlot: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let expiresAt: Date
    let slotNames: [String]
    let prompt: String
    let originalUserText: String
    var attempts: Int

    var isExpired: Bool { Date() >= expiresAt }
    var slotName: String { slotNames.joined(separator: ",") }
    var primarySlotName: String { slotNames.first ?? "" }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        slotName: String,
        slotNames: [String]? = nil,
        prompt: String,
        originalUserText: String,
        attempts: Int = 0,
        ttl: TimeInterval = 600
    ) {
        let normalizedSlots = Self.normalizeSlotNames(slotNames ?? Self.parseSlotNames(slotName))
        let fallbackSlot = slotName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeFallbackSlot = fallbackSlot.isEmpty ? "unknown" : fallbackSlot
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(ttl)
        self.slotNames = normalizedSlots.isEmpty ? [safeFallbackSlot] : normalizedSlots
        self.prompt = prompt
        self.originalUserText = originalUserText
        self.attempts = attempts
    }

    private static func parseSlotNames(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeSlotNames(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                normalized.append(trimmed)
            }
        }
        return normalized
    }
}
