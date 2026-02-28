import XCTest
@testable import SamOSv2

final class MemoryInjectorTests: XCTestCase {

    func testEmptyStoreReturnsEmptyBlock() async {
        let store = MockMemoryStore()
        let injector = MemoryInjector(memoryStore: store)

        let block = await injector.buildMemoryBlock(query: "hello")
        XCTAssertTrue(block.isEmpty)
    }

    func testIdentityFactsAlwaysIncluded() async {
        let store = MockMemoryStore()
        store.profileFacts = [
            ProfileFact(attribute: "name", value: "Richard"),
            ProfileFact(attribute: "location", value: "Sydney"),
        ]
        let injector = MemoryInjector(memoryStore: store)

        let block = await injector.buildMemoryBlock(query: "what's the weather?")
        XCTAssertTrue(block.contains("name: Richard"))
        XCTAssertTrue(block.contains("location: Sydney"))
        XCTAssertTrue(block.contains("[IDENTITY FACTS]"))
    }

    func testQueryRelevantMemoriesIncluded() async throws {
        let store = MockMemoryStore()
        _ = try await store.addMemory(type: .fact, content: "User likes coffee", source: "test")
        let injector = MemoryInjector(memoryStore: store)

        let block = await injector.buildMemoryBlock(query: "coffee")
        XCTAssertTrue(block.contains("coffee"))
        XCTAssertTrue(block.contains("[RELEVANT MEMORIES]"))
    }

    func testNoRelevantMemoriesOmitsSection() async throws {
        let store = MockMemoryStore()
        _ = try await store.addMemory(type: .fact, content: "User likes tea", source: "test")
        let injector = MemoryInjector(memoryStore: store)

        let block = await injector.buildMemoryBlock(query: "xyz123")
        XCTAssertFalse(block.contains("[RELEVANT MEMORIES]"))
    }
}
