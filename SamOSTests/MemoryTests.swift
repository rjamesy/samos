import XCTest
@testable import SamOS

final class MemoryTests: XCTestCase {

    // MARK: - MemoryRow

    func testMemoryRowShortID() {
        let id = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let row = MemoryRow(id: id, createdAt: Date(), type: .fact, content: "test", source: nil, isActive: true)
        XCTAssertEqual(row.shortID, "a1b2c3d4")
    }

    func testMemoryTypeRawValues() {
        XCTAssertEqual(MemoryType.fact.rawValue, "fact")
        XCTAssertEqual(MemoryType.preference.rawValue, "preference")
        XCTAssertEqual(MemoryType.note.rawValue, "note")
        XCTAssertEqual(MemoryType.checkin.rawValue, "checkin")
    }

    func testMemoryTypeCaseIterable() {
        XCTAssertEqual(MemoryType.allCases.count, 4)
    }

    // MARK: - MemoryStore CRUD

    func testStoreIsAvailable() {
        XCTAssertTrue(MemoryStore.shared.isAvailable)
    }

    func testAddAndListMemory() {
        let content = "Test memory \(UUID().uuidString)"
        let row = MemoryStore.shared.addMemory(type: .fact, content: content, source: "test")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.type, .fact)
        XCTAssertEqual(row?.content, content)
        XCTAssertEqual(row?.source, "test")

        let memories = MemoryStore.shared.listMemories()
        XCTAssertTrue(memories.contains(where: { $0.content == content }))

        // Clean up
        if let id = row?.id {
            MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString)
        }
    }

    func testAddMemoryWithNilSource() {
        let content = "No source \(UUID().uuidString)"
        let row = MemoryStore.shared.addMemory(type: .note, content: content)
        XCTAssertNotNil(row)
        XCTAssertNil(row?.source)

        // Clean up
        if let id = row?.id {
            MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString)
        }
    }

    func testDeleteMemoryByFullID() {
        let content = "Delete me \(UUID().uuidString)"
        guard let row = MemoryStore.shared.addMemory(type: .preference, content: content) else {
            XCTFail("Failed to add memory")
            return
        }

        let deleted = MemoryStore.shared.deleteMemory(idOrPrefix: row.id.uuidString)
        XCTAssertTrue(deleted)

        let memories = MemoryStore.shared.listMemories()
        XCTAssertFalse(memories.contains(where: { $0.content == content }))
    }

    func testDeleteMemoryByPrefix() {
        let content = "Prefix delete \(UUID().uuidString)"
        guard let row = MemoryStore.shared.addMemory(type: .fact, content: content) else {
            XCTFail("Failed to add memory")
            return
        }

        let prefix = String(row.id.uuidString.prefix(8))
        let deleted = MemoryStore.shared.deleteMemory(idOrPrefix: prefix)
        XCTAssertTrue(deleted)

        let memories = MemoryStore.shared.listMemories()
        XCTAssertFalse(memories.contains(where: { $0.content == content }))
    }

    func testDeleteNonexistentMemory() {
        let deleted = MemoryStore.shared.deleteMemory(idOrPrefix: "00000000-0000-0000-0000-000000000000")
        XCTAssertFalse(deleted)
    }

    func testDeleteMemoryPrefixWithQuoteDoesNotDeleteRows() {
        let content = "Injection guard \(UUID().uuidString)"
        guard let row = MemoryStore.shared.addMemory(type: .fact, content: content) else {
            return XCTFail("Failed to add memory")
        }
        defer { MemoryStore.shared.deleteMemory(idOrPrefix: row.id.uuidString) }

        let deleted = MemoryStore.shared.deleteMemory(idOrPrefix: "' OR 1=1 --")
        XCTAssertFalse(deleted, "Quoted prefix should not match any record")
        XCTAssertTrue(MemoryStore.shared.listMemories().contains(where: { $0.id == row.id }),
                      "Original row should remain active")
    }

    func testFilterByType() {
        let factContent = "Fact filter test \(UUID().uuidString)"
        let noteContent = "Note filter test \(UUID().uuidString)"
        let fact = MemoryStore.shared.addMemory(type: .fact, content: factContent)
        let note = MemoryStore.shared.addMemory(type: .note, content: noteContent)

        let facts = MemoryStore.shared.listMemories(filterType: .fact)
        XCTAssertTrue(facts.contains(where: { $0.content == factContent }))
        XCTAssertFalse(facts.contains(where: { $0.content == noteContent }))

        let notes = MemoryStore.shared.listMemories(filterType: .note)
        XCTAssertTrue(notes.contains(where: { $0.content == noteContent }))
        XCTAssertFalse(notes.contains(where: { $0.content == factContent }))

        // Clean up
        if let id = fact?.id { MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString) }
        if let id = note?.id { MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString) }
    }

    func testRecentMemoriesLimit() {
        var ids: [UUID] = []
        for i in 0..<3 {
            if let row = MemoryStore.shared.addMemory(type: .note, content: "Recent test \(i) \(UUID().uuidString)") {
                ids.append(row.id)
            }
        }

        let recent = MemoryStore.shared.recentMemories(limit: 2)
        XCTAssertLessThanOrEqual(recent.count, 2)

        // Clean up
        for id in ids {
            MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString)
        }
    }

    // MARK: - Search

    func testSearchFindsDog() {
        let row = MemoryStore.shared.addMemory(type: .fact, content: "Your dog's name is Bailey")
        defer { if let id = row?.id { MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString) } }

        let results = MemoryStore.shared.searchMemories(query: "What is my dog's name?")
        XCTAssertTrue(results.contains(where: { $0.content.contains("Bailey") }))
    }

    func testSearchFindsBreed() {
        let row = MemoryStore.shared.addMemory(type: .fact, content: "Bailey the dog is a golden retriever")
        defer { if let id = row?.id { MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString) } }

        let results = MemoryStore.shared.searchMemories(query: "What type of dog do I have?")
        XCTAssertTrue(results.contains(where: { $0.content.contains("golden retriever") }))
    }

    func testSearchReturnsEmptyForUnrelated() {
        let row = MemoryStore.shared.addMemory(type: .fact, content: "Your dog's name is Bailey")
        defer { if let id = row?.id { MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString) } }

        let results = MemoryStore.shared.searchMemories(query: "What's the weather?")
        XCTAssertFalse(results.contains(where: { $0.content.contains("Bailey") }))
    }

    func testSearchRanksFactsHigher() {
        let fact = MemoryStore.shared.addMemory(type: .fact, content: "Your cat's name is Whiskers")
        let note = MemoryStore.shared.addMemory(type: .note, content: "Thinking about getting a cat toy")
        defer {
            if let id = fact?.id { MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString) }
            if let id = note?.id { MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString) }
        }

        let results = MemoryStore.shared.searchMemories(query: "Tell me about my cat")
        // Fact should rank higher because of type bonus
        if results.count >= 2 {
            XCTAssertTrue(results[0].content.contains("Whiskers"))
        }
    }

    func testSearchMatchesStemmedQueryTerms() {
        let row = MemoryStore.shared.addMemory(
            type: .note,
            content: "Fermentation temperature control improves homemade beer consistency."
        )
        defer { if let id = row?.id { MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString) } }

        let results = MemoryStore.shared.searchMemories(query: "tips for fermenting beer temp control")
        XCTAssertTrue(
            results.contains(where: { $0.content.lowercased().contains("fermentation temperature control") }),
            "Retriever should match stemmed/variant query terms"
        )
    }

    func testSearchSkipsLowValueWebsiteLearningNoise() {
        let noisy = MemoryStore.shared.addMemory(
            type: .note,
            content: "From www.cheeseshop.com: Loading your experience... This won't take long. We're getting things ready",
            source: "website_learning"
        )
        let valid = MemoryStore.shared.addMemory(
            type: .note,
            content: "From wikipedia.org: Tokyo is 9 hours ahead of UTC.",
            source: "website_learning"
        )
        defer {
            if let id = noisy?.id { MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString) }
            if let id = valid?.id { MemoryStore.shared.deleteMemory(idOrPrefix: id.uuidString) }
        }

        let noiseQuery = MemoryStore.shared.searchMemories(query: "this took long")
        XCTAssertFalse(
            noiseQuery.contains(where: { $0.content.lowercased().contains("loading your experience") }),
            "Boilerplate website-loading memories should not be returned."
        )

        let realQuery = MemoryStore.shared.searchMemories(query: "tokyo utc")
        XCTAssertTrue(
            realQuery.contains(where: { $0.content.lowercased().contains("tokyo is 9 hours") }),
            "Legitimate website learning notes should remain searchable."
        )
    }

    func testTokenizeStripsStopwords() {
        let tokens = MemoryStore.shared.tokenize("What is my dog's name?")
        XCTAssertFalse(tokens.contains("what"))
        XCTAssertFalse(tokens.contains("is"))
        XCTAssertFalse(tokens.contains("my"))
        XCTAssertTrue(tokens.contains("dog"))
        XCTAssertTrue(tokens.contains("name"))
    }

    // MARK: - Save Memory Tool

    func testSaveMemoryToolValid() {
        let tool = SaveMemoryTool()
        let output = tool.execute(args: ["type": "fact", "content": "Tool test \(UUID().uuidString)"])
        XCTAssertEqual(output.kind, .markdown)
        XCTAssert(output.payload.contains("Saved"))
        XCTAssert(output.payload.contains("fact"))
    }

    func testSaveMemoryToolInvalidType() {
        let tool = SaveMemoryTool()
        let output = tool.execute(args: ["type": "invalid", "content": "test"])
        XCTAssert(output.payload.contains("Memory Error"))
        XCTAssert(output.payload.contains("Invalid type"))
    }

    func testSaveMemoryToolEmptyContentIsFriendly() {
        let tool = SaveMemoryTool()
        let output = tool.execute(args: ["type": "fact", "content": ""])
        // Should NOT contain "Memory Error" — should be a friendly prompt
        XCTAssertFalse(output.payload.contains("Memory Error"))
        XCTAssert(output.payload.contains("what would you like me to remember"))
    }

    func testSaveMemoryToolWhitespaceOnlyIsFriendly() {
        let tool = SaveMemoryTool()
        let output = tool.execute(args: ["type": "fact", "content": "   "])
        XCTAssertFalse(output.payload.contains("Memory Error"))
        XCTAssert(output.payload.contains("what would you like me to remember"))
    }

    func testSaveMemoryToolMissingContentIsFriendly() {
        let tool = SaveMemoryTool()
        let output = tool.execute(args: ["type": "fact"])
        XCTAssertFalse(output.payload.contains("Memory Error"))
        XCTAssert(output.payload.contains("what would you like me to remember"))
    }

    // MARK: - Compound Splitting

    func testSplitCompoundDogFact() {
        let parts = SaveMemoryTool.splitCompoundContent("my dog's name is Bailey and he's a golden retriever")
        XCTAssertEqual(parts.count, 2)
        XCTAssert(parts[0].contains("dog"))
        XCTAssert(parts[0].contains("Bailey"))
        XCTAssert(parts[1].contains("Bailey"))
        XCTAssert(parts[1].contains("golden retriever"))
    }

    func testSplitSimpleSentenceUnsplit() {
        let parts = SaveMemoryTool.splitCompoundContent("I live in Australia")
        XCTAssertEqual(parts.count, 1)
    }

    func testSplitNormalizesMyToYour() {
        let parts = SaveMemoryTool.splitCompoundContent("my favourite color is blue")
        XCTAssertEqual(parts.count, 1)
        XCTAssert(parts[0].hasPrefix("Your"))
    }

    func testSplitEnsuresPeriod() {
        let parts = SaveMemoryTool.splitCompoundContent("I like pizza")
        XCTAssertEqual(parts.count, 1)
        XCTAssert(parts[0].hasSuffix("."))
    }

    func testSplitThreeParts() {
        let parts = SaveMemoryTool.splitCompoundContent("my name is Richard and I live in Australia and I work in tech")
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        XCTAssertLessThanOrEqual(parts.count, 3)
    }

    func testSplitPreservesAlreadyTerminated() {
        let parts = SaveMemoryTool.splitCompoundContent("I like cats!")
        XCTAssertEqual(parts.count, 1)
        XCTAssert(parts[0].hasSuffix("!"))
        XCTAssertFalse(parts[0].hasSuffix("!."))
    }

    func testResolvePronoun() {
        XCTAssertEqual(SaveMemoryTool.resolvePronoun(in: "he's a golden retriever", name: "Bailey"), "Bailey is a golden retriever")
        XCTAssertEqual(SaveMemoryTool.resolvePronoun(in: "she is very friendly", name: "Luna"), "Luna is very friendly")
        // No pronoun — return as-is
        XCTAssertEqual(SaveMemoryTool.resolvePronoun(in: "lives in Sydney", name: "Max"), "lives in Sydney")
    }

    func testNormalize() {
        XCTAssertEqual(SaveMemoryTool.normalize("my dog is cute"), "Your dog is cute.")
        XCTAssertEqual(SaveMemoryTool.normalize("hello world"), "Hello world.")
        XCTAssertEqual(SaveMemoryTool.normalize("Already done."), "Already done.")
    }

    // MARK: - List Memories Tool

    func testListMemoriesTool() {
        let tool = ListMemoriesTool()
        let output = tool.execute(args: [:])
        XCTAssertEqual(output.kind, .markdown)
    }

    func testListMemoriesToolWithFilter() {
        let tool = ListMemoriesTool()
        let output = tool.execute(args: ["type": "preference"])
        XCTAssertEqual(output.kind, .markdown)
    }

    // MARK: - Delete Memory Tool

    func testDeleteMemoryToolNoID() {
        let tool = DeleteMemoryTool()
        let output = tool.execute(args: [:])
        XCTAssert(output.payload.contains("Memory Error"))
        XCTAssert(output.payload.contains("No ID"))
    }

    func testDeleteMemoryToolInvalidID() {
        let tool = DeleteMemoryTool()
        let output = tool.execute(args: ["id": "nonexistent"])
        XCTAssert(output.payload.contains("Memory Error"))
    }

    // MARK: - Clear Memories Tool

    func testClearMemoriesTool() {
        let tool = ClearMemoriesTool()
        let output = tool.execute(args: [:])
        XCTAssertEqual(output.kind, .markdown)
        XCTAssert(output.payload.contains("cleared"))
    }

    // MARK: - Canonicalization

    func testCanonicalizeBasic() {
        let store = MemoryStore.shared
        XCTAssertEqual(store.canonicalize("Your dog's name is Bailey."), "dog name bailey")
        XCTAssertEqual(store.canonicalize("your dog's name is bailey"), "dog name bailey")
        XCTAssertEqual(store.canonicalize("MY DOG'S NAME IS BAILEY!"), "dog name bailey")
    }

    func testCanonicalizeStripsNoise() {
        let store = MemoryStore.shared
        // Articles, pronouns, filler words all stripped
        XCTAssertEqual(store.canonicalize("I really like the colour blue"), "like colour blue")
        XCTAssertEqual(store.canonicalize("Your name is Richard."), "name richard")
    }

    func testCanonicalizePunctuationVariants() {
        let store = MemoryStore.shared
        // Different punctuation/casing → same canonical form
        let a = store.canonicalize("Your dog's name is Bailey.")
        let b = store.canonicalize("Your dog's name is Bailey!")
        let c = store.canonicalize("your dog's name is bailey")
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
    }

    // MARK: - Deduplication

    func testExactDuplicateNotInserted() {
        let tool = SaveMemoryTool()
        let unique = UUID().uuidString.prefix(8)
        let content = "Your dog's name is Fido\(unique)."

        let first = tool.execute(args: ["type": "fact", "content": content])
        XCTAssert(first.payload.contains("Saved"))

        let second = tool.execute(args: ["type": "fact", "content": content])
        XCTAssert(second.payload.contains("already have that"))

        // Only one active row
        let matches = MemoryStore.shared.listMemories(filterType: .fact)
            .filter { $0.content.contains("Fido\(unique)") }
        XCTAssertEqual(matches.count, 1)

        // Clean up
        for m in matches { MemoryStore.shared.deleteMemory(idOrPrefix: m.id.uuidString) }
    }

    func testDuplicateIgnoresCasingAndPunctuation() {
        let tool = SaveMemoryTool()
        let unique = UUID().uuidString.prefix(8)

        let first = tool.execute(args: ["type": "fact", "content": "Your name is Zed\(unique)."])
        XCTAssert(first.payload.contains("Saved"))

        // Same content, different casing/punctuation
        let second = tool.execute(args: ["type": "fact", "content": "your name is zed\(unique)"])
        XCTAssert(second.payload.contains("already have that"))

        // Clean up
        let matches = MemoryStore.shared.listMemories(filterType: .fact)
            .filter { $0.content.lowercased().contains("zed\(unique.lowercased())") }
        for m in matches { MemoryStore.shared.deleteMemory(idOrPrefix: m.id.uuidString) }
    }

    func testRefinementUpdatesExisting() {
        let tool = SaveMemoryTool()
        let unique = UUID().uuidString.prefix(8)

        // Save a simple fact
        let first = tool.execute(args: ["type": "fact", "content": "Rex\(unique) is a dog."])
        XCTAssert(first.payload.contains("Saved"))

        // Save a refined version (superset of the original — adds breed info)
        let second = tool.execute(args: ["type": "fact", "content": "Rex\(unique) is a dog, specifically a labrador."])
        XCTAssert(second.payload.contains("Updated"))

        // Only one active row, and it's the refined version
        let matches = MemoryStore.shared.listMemories(filterType: .fact)
            .filter { $0.content.contains("Rex\(unique)") }
        XCTAssertEqual(matches.count, 1)
        XCTAssert(matches[0].content.contains("labrador"))

        // Clean up
        for m in matches { MemoryStore.shared.deleteMemory(idOrPrefix: m.id.uuidString) }
    }

    // MARK: - High-Value Fact Protection

    func testHighValueNameReplaced() {
        let tool = SaveMemoryTool()
        let unique = UUID().uuidString.prefix(8)

        let first = tool.execute(args: ["type": "fact", "content": "Your name is Alpha\(unique)."])
        XCTAssert(first.payload.contains("Saved"))

        let second = tool.execute(args: ["type": "fact", "content": "Your name is Beta\(unique)."])
        XCTAssert(second.payload.contains("Updated"))

        // Only one active "name" memory
        let matches = MemoryStore.shared.listMemories(filterType: .fact)
            .filter { $0.content.lowercased().contains("name is") &&
                     ($0.content.contains("Alpha\(unique)") || $0.content.contains("Beta\(unique)")) }
        XCTAssertEqual(matches.count, 1)
        XCTAssert(matches[0].content.contains("Beta\(unique)"))

        // Clean up
        for m in matches { MemoryStore.shared.deleteMemory(idOrPrefix: m.id.uuidString) }
    }

    func testHighValueSameNameIsDuplicate() {
        let tool = SaveMemoryTool()
        let unique = UUID().uuidString.prefix(8)

        let first = tool.execute(args: ["type": "fact", "content": "Your name is Same\(unique)."])
        XCTAssert(first.payload.contains("Saved"))

        let second = tool.execute(args: ["type": "fact", "content": "Your name is Same\(unique)."])
        XCTAssert(second.payload.contains("already have that"))

        // Clean up
        let matches = MemoryStore.shared.listMemories(filterType: .fact)
            .filter { $0.content.contains("Same\(unique)") }
        for m in matches { MemoryStore.shared.deleteMemory(idOrPrefix: m.id.uuidString) }
    }

    // MARK: - Tool Registration

    func testMemoryToolsRegistered() {
        XCTAssertNotNil(ToolRegistry.shared.get("save_memory"))
        XCTAssertNotNil(ToolRegistry.shared.get("list_memories"))
        XCTAssertNotNil(ToolRegistry.shared.get("delete_memory"))
        XCTAssertNotNil(ToolRegistry.shared.get("clear_memories"))
    }
}
