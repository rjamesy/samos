import XCTest
@testable import SamOSv2

final class PromptBuilderTests: XCTestCase {
    var settings: MockSettingsStore!
    var builder: PromptBuilder!

    override func setUp() {
        settings = MockSettingsStore()
        settings.setString("Richard", forKey: SettingsKey.userName)
        builder = PromptBuilder(settings: settings)
    }

    func testBuildSystemPromptContainsIdentity() {
        let prompt = builder.buildSystemPrompt(
            memoryBlock: "", engineContext: "", toolManifest: "",
            conversationHistory: "", currentState: "", temporalContext: ""
        )
        XCTAssertTrue(prompt.contains("Sam"))
        XCTAssertTrue(prompt.contains("Richard"))
    }

    func testBuildSystemPromptContainsResponseRules() {
        let prompt = builder.buildSystemPrompt(
            memoryBlock: "", engineContext: "", toolManifest: "",
            conversationHistory: "", currentState: "", temporalContext: ""
        )
        XCTAssertTrue(prompt.contains("TALK"))
        XCTAssertTrue(prompt.contains("TOOL"))
    }

    func testMemoryBlockIncluded() {
        let memoryBlock = "[IDENTITY FACTS]\n- name: Richard"
        let prompt = builder.buildSystemPrompt(
            memoryBlock: memoryBlock, engineContext: "", toolManifest: "",
            conversationHistory: "", currentState: "", temporalContext: ""
        )
        XCTAssertTrue(prompt.contains("name: Richard"))
    }

    func testToolManifestIncluded() {
        let manifest = "[AVAILABLE TOOLS]\n- get_time: Returns current time"
        let prompt = builder.buildSystemPrompt(
            memoryBlock: "", engineContext: "", toolManifest: manifest,
            conversationHistory: "", currentState: "", temporalContext: ""
        )
        XCTAssertTrue(prompt.contains("get_time"))
    }

    func testPromptStaysWithinBudget() {
        let longHistory = String(repeating: "a", count: 50_000)
        let prompt = builder.buildSystemPrompt(
            memoryBlock: "", engineContext: "", toolManifest: "",
            conversationHistory: longHistory, currentState: "", temporalContext: ""
        )
        XCTAssertLessThanOrEqual(prompt.count, AppConfig.totalPromptBudget + 1000) // Small buffer for joining
    }

    func testDefaultUserNameWhenNotSet() {
        let emptySettings = MockSettingsStore()
        let b = PromptBuilder(settings: emptySettings)
        let prompt = b.buildSystemPrompt(
            memoryBlock: "", engineContext: "", toolManifest: "",
            conversationHistory: "", currentState: "", temporalContext: ""
        )
        XCTAssertTrue(prompt.contains("there"))
    }
}
