import Foundation

/// Memory type categories.
enum MemoryType: String, Codable, CaseIterable, Sendable {
    case fact
    case preference
    case note
    case checkin
}

/// A single memory entry persisted in SQLite.
struct MemoryRow: Identifiable, Sendable {
    let id: String
    let type: MemoryType
    let content: String
    let source: String
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date?
    let isActive: Bool
    let accessCount: Int
    let lastAccessedAt: Date?

    /// Short ID for display (first 8 chars).
    var shortID: String {
        String(id.prefix(8)).lowercased()
    }

    init(
        id: String = UUID().uuidString,
        type: MemoryType,
        content: String,
        source: String = "conversation",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date? = nil,
        isActive: Bool = true,
        accessCount: Int = 0,
        lastAccessedAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.content = content
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.isActive = isActive
        self.accessCount = accessCount
        self.lastAccessedAt = lastAccessedAt
    }
}
