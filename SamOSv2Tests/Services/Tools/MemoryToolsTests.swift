import XCTest
@testable import SamOSv2

final class MemoryToolsTests: XCTestCase {
    var mockStore: MockMemoryStore!

    override func setUp() {
        super.setUp()
        mockStore = MockMemoryStore()
    }

    func testSaveMemorySuccess() async {
        let tool = SaveMemoryTool(memoryStore: mockStore)
        XCTAssertEqual(tool.name, "save_memory")
        let result = await tool.execute(args: ["content": "User likes coffee", "type": "preference"])
        XCTAssertTrue(result.success)
    }

    func testSaveMemoryMissingContentFails() async {
        let tool = SaveMemoryTool(memoryStore: mockStore)
        let result = await tool.execute(args: [:])
        XCTAssertFalse(result.success)
    }

    func testSaveMemoryDefaultsToFact() async {
        let tool = SaveMemoryTool(memoryStore: mockStore)
        let result = await tool.execute(args: ["content": "Name is Richard"])
        XCTAssertTrue(result.success)
    }

    func testListMemories() async {
        let tool = ListMemoriesTool(memoryStore: mockStore)
        XCTAssertEqual(tool.name, "list_memories")
        let result = await tool.execute(args: [:])
        XCTAssertTrue(result.success)
    }

    func testDeleteMemorySuccess() async {
        let tool = DeleteMemoryTool(memoryStore: mockStore)
        XCTAssertEqual(tool.name, "delete_memory")
        let result = await tool.execute(args: ["id": "some-id"])
        XCTAssertTrue(result.success)
    }

    func testDeleteMemoryMissingIdFails() async {
        let tool = DeleteMemoryTool(memoryStore: mockStore)
        let result = await tool.execute(args: [:])
        XCTAssertFalse(result.success)
    }

    func testClearMemories() async {
        let tool = ClearMemoriesTool(memoryStore: mockStore)
        XCTAssertEqual(tool.name, "clear_memories")
        let result = await tool.execute(args: [:])
        XCTAssertTrue(result.success)
    }

    func testRecallAmbient() async {
        let tool = RecallAmbientTool()
        XCTAssertEqual(tool.name, "recall_ambient")
        let result = await tool.execute(args: [:])
        XCTAssertTrue(result.success)
    }
}
