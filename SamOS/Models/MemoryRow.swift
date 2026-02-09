import Foundation

/// Memory type categories for v1.
enum MemoryType: String, Codable, CaseIterable {
    case fact
    case preference
    case note
    case checkin
}

/// Confidence level for extracted memory quality.
enum MemoryConfidence: String, Codable, CaseIterable {
    case low
    case medium = "med"
    case high
}

/// A single memory entry persisted in SQLite.
struct MemoryRow: Identifiable {
    let id: UUID
    let createdAt: Date
    let lastSeenAt: Date
    let type: MemoryType
    let content: String
    let confidence: MemoryConfidence
    let ttlDays: Int
    let source: String?
    let sourceSnippet: String?
    let tags: [String]
    let isResolved: Bool
    let isActive: Bool

    /// Short ID for display (first 8 chars of UUID).
    var shortID: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        lastSeenAt: Date? = nil,
        type: MemoryType,
        content: String,
        confidence: MemoryConfidence = .medium,
        ttlDays: Int = 90,
        source: String? = nil,
        sourceSnippet: String? = nil,
        tags: [String] = [],
        isResolved: Bool = false,
        isActive: Bool = true
    ) {
        self.id = id
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt ?? createdAt
        self.type = type
        self.content = content
        self.confidence = confidence
        self.ttlDays = max(1, ttlDays)
        self.source = source
        self.sourceSnippet = sourceSnippet
        self.tags = tags
        self.isResolved = isResolved
        self.isActive = isActive
    }
}
