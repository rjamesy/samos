import Foundation

/// Auto-extracts memories from conversation. Debounced to 30s after last turn.
actor MemoryAutoSave {
    private let memoryStore: any MemoryStoreProtocol
    private let memorySearch: MemorySearch
    private let embeddingClient: OpenAIEmbeddingClient?
    private var lastSaveTime: Date = .distantPast

    init(memoryStore: any MemoryStoreProtocol, memorySearch: MemorySearch, embeddingClient: OpenAIEmbeddingClient? = nil) {
        self.memoryStore = memoryStore
        self.memorySearch = memorySearch
        self.embeddingClient = embeddingClient
    }

    /// Process a user message for auto-save patterns.
    func processMessage(_ text: String, role: MessageRole) async {
        guard role == .user else { return }

        // Debounce: skip if saved recently
        guard Date().timeIntervalSince(lastSaveTime) > 30 else { return }

        let lower = text.lowercased()

        // Detect explicit memory requests
        if let memory = extractExplicitMemory(lower, original: text) {
            await saveIfNotDuplicate(type: memory.type, content: memory.content, source: "explicit")
        }

        // Detect implicit facts
        if let fact = extractImplicitFact(lower, original: text) {
            await saveIfNotDuplicate(type: .fact, content: fact, source: "implicit")
        }

        // Detect preferences
        if let pref = extractPreference(lower, original: text) {
            await saveIfNotDuplicate(type: .preference, content: pref, source: "implicit")
        }
    }

    private func saveIfNotDuplicate(type: MemoryType, content: String, source: String) async {
        // Check for duplicates using search
        let existing = await memoryStore.searchMemories(query: content, limit: 3)
        for mem in existing {
            if await memorySearch.isDuplicate(content, mem.content) {
                return // Already have this memory
            }
        }

        let row = try? await memoryStore.addMemory(type: type, content: content, source: source)

        // Generate and store embedding (fire-and-forget)
        if let row, let client = embeddingClient {
            Task {
                guard let embedding = try? await client.embed(content) else { return }
                let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
                await memoryStore.storeEmbedding(memoryId: row.id, embedding: data)
            }
        }

        lastSaveTime = Date()
    }

    // MARK: - Extraction

    private struct ExtractedMemory {
        let type: MemoryType
        let content: String
    }

    private func extractExplicitMemory(_ lower: String, original: String) -> ExtractedMemory? {
        let patterns: [(String, MemoryType)] = [
            ("remember that ", .fact),
            ("remember i ", .fact),
            ("remember my ", .fact),
            ("don't forget ", .fact),
            ("note that ", .note),
            ("save a note ", .note),
        ]

        for (prefix, type) in patterns {
            if lower.hasPrefix(prefix) {
                let content = String(original.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    return ExtractedMemory(type: type, content: content)
                }
            }
        }
        return nil
    }

    private func extractImplicitFact(_ lower: String, original: String) -> String? {
        let factPatterns = [
            "my name is ", "i'm called ", "call me ",
            "i live in ", "i'm from ", "i moved to ",
            "my dog ", "my cat ", "my pet ",
            "i work at ", "i'm a ", "my job is ",
            "my birthday is ", "i was born ",
        ]
        for pattern in factPatterns {
            if lower.contains(pattern) {
                return original.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func extractPreference(_ lower: String, original: String) -> String? {
        let prefPatterns = [
            "i prefer ", "i like ", "i love ", "i hate ",
            "i don't like ", "i always ", "i never ",
            "my favorite ", "my favourite ",
        ]
        for pattern in prefPatterns {
            if lower.contains(pattern) {
                return original.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
