import Foundation

/// Contract for memory persistence and retrieval.
protocol MemoryStoreProtocol: Sendable {
    func addMemory(type: MemoryType, content: String, source: String) async throws -> MemoryRow
    func listMemories(filterType: MemoryType?) async -> [MemoryRow]
    func searchMemories(query: String, limit: Int) async -> [MemoryRow]
    func deleteMemory(id: String) async throws
    func clearMemories() async throws

    /// Core identity facts that are always injected into prompts.
    func coreIdentityFacts(maxItems: Int) async -> [ProfileFact]

    /// Temporal context for date-aware queries.
    func temporalContext(query: String, maxChars: Int) async -> String

    /// Prune expired memories.
    func pruneExpired() async

    /// Upsert a profile fact (user attribute).
    func upsertProfileFact(attribute: String, value: String, confidence: Double) async throws

    /// Store an embedding vector for a memory.
    func storeEmbedding(memoryId: String, embedding: Data) async
}

/// A user profile fact (name, pet, location, etc.).
struct ProfileFact: Sendable, Equatable {
    let id: String
    let attribute: String
    let value: String
    let confidence: Double
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String = UUID().uuidString,
        attribute: String,
        value: String,
        confidence: Double = 0.8,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.attribute = attribute
        self.value = value
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
