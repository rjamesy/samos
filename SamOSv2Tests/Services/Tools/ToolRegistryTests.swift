import XCTest
@testable import SamOSv2

final class ToolRegistryTests: XCTestCase {
    var registry: ToolRegistry!
    var mockMemory: MockMemoryStore!

    override func setUp() {
        super.setUp()
        registry = ToolRegistry()
        mockMemory = MockMemoryStore()
    }

    // MARK: - Registration

    func testRegisterTool() {
        let tool = MockTool(name: "test_tool", description: "A test")
        registry.register(tool)
        XCTAssertNotNil(registry.get("test_tool"))
    }

    func testGetUnregisteredReturnsNil() {
        XCTAssertNil(registry.get("nonexistent"))
    }

    func testAllToolsReturnsRegistered() {
        registry.register(MockTool(name: "a", description: ""))
        registry.register(MockTool(name: "b", description: ""))
        XCTAssertEqual(registry.allTools.count, 2)
    }

    // MARK: - Alias Normalization

    func testDirectNameMatch() {
        registry.register(MockTool(name: "get_weather", description: ""))
        XCTAssertEqual(registry.normalizeToolName("get_weather"), "get_weather")
    }

    func testCaseInsensitiveMatch() {
        registry.register(MockTool(name: "get_weather", description: ""))
        XCTAssertEqual(registry.normalizeToolName("Get_Weather"), "get_weather")
    }

    func testDashToUnderscoreNormalization() {
        registry.register(MockTool(name: "get_weather", description: ""))
        XCTAssertEqual(registry.normalizeToolName("get-weather"), "get_weather")
    }

    func testSpaceToUnderscoreNormalization() {
        registry.register(MockTool(name: "get_weather", description: ""))
        XCTAssertEqual(registry.normalizeToolName("get weather"), "get_weather")
    }

    func testCamelCaseToSnakeCase() {
        registry.register(MockTool(name: "get_weather", description: ""))
        XCTAssertEqual(registry.normalizeToolName("getWeather"), "get_weather")
    }

    func testAliasMatch() {
        registry.register(MockTool(name: "get_weather", description: ""))
        registry.registerAliases(["weather": "get_weather"])
        XCTAssertEqual(registry.normalizeToolName("weather"), "get_weather")
    }

    func testAliasIsCaseInsensitive() {
        registry.register(MockTool(name: "get_weather", description: ""))
        registry.registerAliases(["Weather": "get_weather"])
        XCTAssertEqual(registry.normalizeToolName("weather"), "get_weather")
    }

    func testUnknownNameReturnsNil() {
        XCTAssertNil(registry.normalizeToolName("totally_unknown"))
    }

    // MARK: - RegisterDefaults

    func testRegisterDefaultsPopulatesTools() {
        registry.registerDefaults(memoryStore: mockMemory)
        XCTAssertGreaterThan(registry.allTools.count, 30, "Should have 30+ core tools registered (optional services may add more)")
    }

    func testRegisterDefaultsPopulatesAliases() {
        registry.registerDefaults(memoryStore: mockMemory)
        // "weather" should resolve to "get_weather"
        XCTAssertNotNil(registry.get("weather"))
    }

    func testDefaultAliasWeather() {
        registry.registerDefaults(memoryStore: mockMemory)
        let tool = registry.get("weather")
        XCTAssertEqual(tool?.name, "get_weather")
    }

    func testDefaultAliasTime() {
        registry.registerDefaults(memoryStore: mockMemory)
        let tool = registry.get("clock")
        XCTAssertEqual(tool?.name, "get_time")
    }

    func testDefaultAliasRemember() {
        registry.registerDefaults(memoryStore: mockMemory)
        let tool = registry.get("remember")
        XCTAssertEqual(tool?.name, "save_memory")
    }

    func testDefaultAliasForget() {
        registry.registerDefaults(memoryStore: mockMemory)
        let tool = registry.get("forget")
        XCTAssertEqual(tool?.name, "delete_memory")
    }

    // MARK: - Tool Manifest

    func testBuildToolManifest() {
        registry.register(MockTool(name: "test_tool", description: "Does testing"))
        let manifest = registry.buildToolManifest()
        XCTAssertTrue(manifest.hasPrefix("[AVAILABLE TOOLS]"))
        XCTAssertTrue(manifest.contains("test_tool"))
        XCTAssertTrue(manifest.contains("Does testing"))
    }
}
