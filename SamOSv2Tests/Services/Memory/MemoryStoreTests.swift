import XCTest
@testable import SamOSv2

final class MemoryStoreTests: XCTestCase {

    func testAddAndListMemories() async throws {
        let store = MockMemoryStore()
        let row = try await store.addMemory(type: .fact, content: "User's name is Richard", source: "test")
        XCTAssertEqual(row.type, .fact)
        XCTAssertEqual(row.content, "User's name is Richard")

        let all = await store.listMemories(filterType: nil)
        XCTAssertEqual(all.count, 1)
    }

    func testFilterByType() async throws {
        let store = MockMemoryStore()
        _ = try await store.addMemory(type: .fact, content: "Fact 1", source: "test")
        _ = try await store.addMemory(type: .preference, content: "Pref 1", source: "test")
        _ = try await store.addMemory(type: .note, content: "Note 1", source: "test")

        let facts = await store.listMemories(filterType: .fact)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.type, .fact)

        let prefs = await store.listMemories(filterType: .preference)
        XCTAssertEqual(prefs.count, 1)
    }

    func testSearchMemories() async throws {
        let store = MockMemoryStore()
        _ = try await store.addMemory(type: .fact, content: "Richard lives in Sydney", source: "test")
        _ = try await store.addMemory(type: .fact, content: "Dog named Buddy", source: "test")

        let results = await store.searchMemories(query: "sydney", limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first!.content.contains("Sydney"))
    }

    func testDeleteMemory() async throws {
        let store = MockMemoryStore()
        let row = try await store.addMemory(type: .fact, content: "Delete me", source: "test")
        try await store.deleteMemory(id: row.id)

        let all = await store.listMemories(filterType: nil)
        XCTAssertEqual(all.count, 0)
    }

    func testClearMemories() async throws {
        let store = MockMemoryStore()
        _ = try await store.addMemory(type: .fact, content: "A", source: "test")
        _ = try await store.addMemory(type: .fact, content: "B", source: "test")
        try await store.clearMemories()

        let all = await store.listMemories(filterType: nil)
        XCTAssertEqual(all.count, 0)
    }

    func testUpsertProfileFact() async throws {
        let store = MockMemoryStore()
        try await store.upsertProfileFact(attribute: "name", value: "Richard", confidence: 0.9)

        let facts = await store.coreIdentityFacts(maxItems: 8)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.attribute, "name")
        XCTAssertEqual(facts.first?.value, "Richard")

        // Upsert with new value
        try await store.upsertProfileFact(attribute: "name", value: "Rick", confidence: 0.95)
        let updated = await store.coreIdentityFacts(maxItems: 8)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.value, "Rick")
    }
}
