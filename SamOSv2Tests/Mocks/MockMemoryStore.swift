import Foundation
@testable import SamOSv2

/// In-memory mock of MemoryStoreProtocol for testing.
final class MockMemoryStore: MemoryStoreProtocol, @unchecked Sendable {
    var memories: [MemoryRow] = []
    var profileFacts: [ProfileFact] = []

    func addMemory(type: MemoryType, content: String, source: String) async throws -> MemoryRow {
        let row = MemoryRow(type: type, content: content, source: source)
        memories.append(row)
        return row
    }

    func listMemories(filterType: MemoryType?) async -> [MemoryRow] {
        if let type = filterType {
            return memories.filter { $0.type == type }
        }
        return memories
    }

    func searchMemories(query: String, limit: Int) async -> [MemoryRow] {
        let lower = query.lowercased()
        return memories
            .filter { $0.content.lowercased().contains(lower) }
            .prefix(limit)
            .map { $0 }
    }

    func deleteMemory(id: String) async throws {
        memories.removeAll { $0.id == id }
    }

    func clearMemories() async throws {
        memories.removeAll()
    }

    func coreIdentityFacts(maxItems: Int) async -> [ProfileFact] {
        Array(profileFacts.prefix(maxItems))
    }

    func temporalContext(query: String, maxChars: Int) async -> String {
        ""
    }

    func pruneExpired() async {}

    func upsertProfileFact(attribute: String, value: String, confidence: Double) async throws {
        if let idx = profileFacts.firstIndex(where: { $0.attribute == attribute }) {
            profileFacts[idx] = ProfileFact(attribute: attribute, value: value, confidence: confidence)
        } else {
            profileFacts.append(ProfileFact(attribute: attribute, value: value, confidence: confidence))
        }
    }

    func storeEmbedding(memoryId: String, embedding: Data) async {
        // No-op for tests
    }
}
