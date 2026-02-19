import Foundation

protocol MemoryStoreContract {
    @discardableResult
    func addMemory(type: MemoryType,
                   content: String,
                   source: String?,
                   confidence: MemoryConfidence,
                   ttlDays: Int?,
                   sourceSnippet: String?,
                   tags: [String],
                   isResolved: Bool,
                   createdAt: Date,
                   lastSeenAt: Date?) -> MemoryRow?

    func listMemories(filterType: MemoryType?) -> [MemoryRow]
    func memoryContext(query: String, maxItems: Int, maxChars: Int) -> [MemoryRow]
    func clearMemories()
}

protocol MemoryCompressor {
    func compress(rows: [MemoryRow], now: Date) -> [MemoryRow]
}

protocol MemoryRetriever {
    func retrieve(query: String, limit: Int) -> [MemoryRow]
}

struct NoopMemoryCompressor: MemoryCompressor {
    func compress(rows: [MemoryRow], now: Date) -> [MemoryRow] {
        rows
    }
}

struct DefaultMemoryRetriever: MemoryRetriever {
    private let store: MemoryStoreContract

    init(store: MemoryStoreContract) {
        self.store = store
    }

    func retrieve(query: String, limit: Int) -> [MemoryRow] {
        store.memoryContext(query: query, maxItems: limit, maxChars: 1400)
    }
}

extension MemoryStore: MemoryStoreContract {
}
