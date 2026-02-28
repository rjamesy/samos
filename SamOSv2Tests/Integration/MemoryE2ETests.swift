import XCTest
@testable import SamOSv2

final class MemoryE2ETests: XCTestCase {

    func testSaveAndRetrieveMemory() async throws {
        let store = MockMemoryStore()

        // Save a memory
        let row = try await store.addMemory(type: .fact, content: "User's name is Richard", source: "test")
        XCTAssertNotNil(row)

        // Retrieve it
        let all = await store.listMemories(filterType: nil)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.content, "User's name is Richard")
    }

    func testSearchFindsRelevant() async throws {
        let store = MockMemoryStore()
        try await store.addMemory(type: .fact, content: "User's name is Richard", source: "test")
        try await store.addMemory(type: .preference, content: "Likes coffee", source: "test")
        try await store.addMemory(type: .fact, content: "Has a dog named Max", source: "test")

        let results = await store.searchMemories(query: "dog", limit: 5)
        XCTAssertTrue(results.contains(where: { $0.content.contains("dog") }))
    }

    func testDeleteMemory() async throws {
        let store = MockMemoryStore()
        let row = try await store.addMemory(type: .fact, content: "Temporary", source: "test")
        let beforeDelete = await store.listMemories(filterType: nil)
        XCTAssertEqual(beforeDelete.count, 1)

        try await store.deleteMemory(id: row.id)
        let afterDelete = await store.listMemories(filterType: nil)
        XCTAssertEqual(afterDelete.count, 0)
    }

    func testClearAllMemories() async throws {
        let store = MockMemoryStore()
        try await store.addMemory(type: .fact, content: "A", source: "test")
        try await store.addMemory(type: .preference, content: "B", source: "test")
        let beforeClear = await store.listMemories(filterType: nil)
        XCTAssertEqual(beforeClear.count, 2)

        try await store.clearMemories()
        let afterClear = await store.listMemories(filterType: nil)
        XCTAssertEqual(afterClear.count, 0)
    }

    func testProfileFactUpsert() async throws {
        let store = MockMemoryStore()
        try await store.upsertProfileFact(attribute: "name", value: "Richard", confidence: 0.9)
        try await store.upsertProfileFact(attribute: "pet", value: "Max", confidence: 0.9)

        let facts = await store.coreIdentityFacts(maxItems: 8)
        XCTAssertEqual(facts.count, 2)

        // Upsert should update, not duplicate
        try await store.upsertProfileFact(attribute: "name", value: "Rich", confidence: 0.9)
        let updated = await store.coreIdentityFacts(maxItems: 8)
        XCTAssertEqual(updated.count, 2)
        XCTAssertTrue(updated.contains(where: { $0.value == "Rich" }))
    }

    func testMemoryInjectorBuildsBlock() async throws {
        let store = MockMemoryStore()
        try await store.addMemory(type: .fact, content: "User's name is Richard", source: "test")
        try await store.upsertProfileFact(attribute: "name", value: "Richard", confidence: 0.9)

        let injector = MemoryInjector(memoryStore: store)
        let block = await injector.buildMemoryBlock(query: "what is my name")
        XCTAssertTrue(block.contains("Richard"))
    }
}
