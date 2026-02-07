import Foundation

/// Memory type categories for v1.
enum MemoryType: String, Codable, CaseIterable {
    case fact
    case preference
    case note
}

/// A single memory entry persisted in SQLite.
struct MemoryRow: Identifiable {
    let id: UUID
    let createdAt: Date
    let type: MemoryType
    let content: String
    let source: String?
    let isActive: Bool

    /// Short ID for display (first 8 chars of UUID).
    var shortID: String {
        String(id.uuidString.prefix(8)).lowercased()
    }
}
