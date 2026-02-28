import Foundation

/// Builds the memory block for the system prompt.
/// Always injects identity facts. Query-relevant memories added within budget.
/// Uses embedding-powered hybrid search when available.
final class MemoryInjector: @unchecked Sendable {
    private let memoryStore: any MemoryStoreProtocol
    private let embeddingClient: OpenAIEmbeddingClient?
    private let memorySearch: MemorySearch?

    init(memoryStore: any MemoryStoreProtocol, embeddingClient: OpenAIEmbeddingClient? = nil, memorySearch: MemorySearch? = nil) {
        self.memoryStore = memoryStore
        self.embeddingClient = embeddingClient
        self.memorySearch = memorySearch
    }

    /// Build the memory injection block for the system prompt.
    func buildMemoryBlock(query: String) async -> String {
        var parts: [String] = []

        // 1. Always inject: core identity facts
        let facts = await memoryStore.coreIdentityFacts(maxItems: AppConfig.maxIdentityFacts)
        if !facts.isEmpty {
            let factLines = facts.map { "- \($0.attribute): \($0.value)" }.joined(separator: "\n")
            parts.append("[IDENTITY FACTS]\n\(factLines)")
        }

        // 2. Query-relevant memories (hybrid search with embeddings when available)
        if let search = memorySearch {
            let scored = await search.search(query: query, limit: AppConfig.maxQueryMemories)
            if !scored.isEmpty {
                var memBlock = "[RELEVANT MEMORIES]\n"
                var charCount = 0
                for mem in scored {
                    let line = "- [\(mem.type.rawValue)] \(mem.content)\n"
                    if charCount + line.count > AppConfig.maxQueryMemoryChars { break }
                    memBlock += line
                    charCount += line.count
                }
                parts.append(memBlock)
            }
        } else {
            // Fallback to basic search
            let memories = await memoryStore.searchMemories(query: query, limit: AppConfig.maxQueryMemories)
            if !memories.isEmpty {
                var memBlock = "[RELEVANT MEMORIES]\n"
                var charCount = 0
                for mem in memories {
                    let line = "- [\(mem.type.rawValue)] \(mem.content)\n"
                    if charCount + line.count > AppConfig.maxQueryMemoryChars { break }
                    memBlock += line
                    charCount += line.count
                }
                parts.append(memBlock)
            }
        }

        return parts.joined(separator: "\n\n")
    }
}
