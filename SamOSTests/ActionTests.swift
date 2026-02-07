import XCTest
@testable import SamOS

final class ActionTests: XCTestCase {

    // MARK: - TALK

    func testDecodeTalk() throws {
        let json = """
        {"action": "TALK", "say": "Hello there!"}
        """
        let action = try decode(json)
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk, got \(action)")
        }
        XCTAssertEqual(talk.say, "Hello there!")
    }

    func testDecodeTalkLowercase() throws {
        let json = """
        {"action": "talk", "say": "hello"}
        """
        let action = try decode(json)
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk, got \(action)")
        }
        XCTAssertEqual(talk.say, "hello")
    }

    func testDecodeTalkMixedCase() throws {
        let json = """
        {"action": "Talk", "say": "hi"}
        """
        let action = try decode(json)
        guard case .talk = action else {
            return XCTFail("Expected .talk")
        }
    }

    // MARK: - TOOL

    func testDecodeTool() throws {
        let json = """
        {"action": "TOOL", "name": "show_image", "args": {"url": "https://example.com/img.jpg", "alt": "A frog"}, "say": "Here you go"}
        """
        let action = try decode(json)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool, got \(action)")
        }
        XCTAssertEqual(tool.name, "show_image")
        XCTAssertEqual(tool.args["url"], "https://example.com/img.jpg")
        XCTAssertEqual(tool.args["alt"], "A frog")
        XCTAssertEqual(tool.say, "Here you go")
    }

    func testDecodeToolLowercase() throws {
        let json = """
        {"action": "tool", "name": "show_text", "args": {"markdown": "# Hello"}, "say": "Done"}
        """
        let action = try decode(json)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool")
        }
        XCTAssertEqual(tool.name, "show_text")
        XCTAssertEqual(tool.args["markdown"], "# Hello")
    }

    func testDecodeToolNoSay() throws {
        let json = """
        {"action": "TOOL", "name": "show_image", "args": {"url": "https://example.com/img.jpg", "alt": "test"}}
        """
        let action = try decode(json)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool")
        }
        XCTAssertNil(tool.say)
    }

    func testDecodeToolWithNumericArgs() throws {
        let json = """
        {"action": "TOOL", "name": "show_image", "args": {"url": "https://example.com/img.jpg", "width": 800}, "say": "Here"}
        """
        let action = try decode(json)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool")
        }
        XCTAssertEqual(tool.args["width"], "800")
        XCTAssertEqual(tool.args["url"], "https://example.com/img.jpg")
    }

    func testDecodeToolWithBoolArgs() throws {
        let json = """
        {"action": "TOOL", "name": "show_text", "args": {"markdown": "test", "fullscreen": true}, "say": "Done"}
        """
        let action = try decode(json)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool")
        }
        XCTAssertEqual(tool.args["fullscreen"], "true")
    }

    // MARK: - DELEGATE_OPENAI

    func testDecodeDelegateOpenAI() throws {
        let json = """
        {"action": "DELEGATE_OPENAI", "task": "Write a poem", "say": "Let me delegate this"}
        """
        let action = try decode(json)
        guard case .delegateOpenAI(let d) = action else {
            return XCTFail("Expected .delegateOpenAI")
        }
        XCTAssertEqual(d.task, "Write a poem")
        XCTAssertEqual(d.say, "Let me delegate this")
    }

    func testDecodeDelegateShorthand() throws {
        let json = """
        {"action": "DELEGATE", "task": "Complex task"}
        """
        let action = try decode(json)
        guard case .delegateOpenAI(let d) = action else {
            return XCTFail("Expected .delegateOpenAI for 'DELEGATE' shorthand")
        }
        XCTAssertEqual(d.task, "Complex task")
    }

    func testDecodeDelegateLowercase() throws {
        let json = """
        {"action": "delegate_openai", "task": "Something"}
        """
        let action = try decode(json)
        guard case .delegateOpenAI = action else {
            return XCTFail("Expected .delegateOpenAI")
        }
    }

    // MARK: - CAPABILITY_GAP

    func testDecodeCapabilityGap() throws {
        let json = """
        {"action": "CAPABILITY_GAP", "goal": "Play music", "missing": "Music playback capability", "say": "I can't do that yet"}
        """
        let action = try decode(json)
        guard case .capabilityGap(let gap) = action else {
            return XCTFail("Expected .capabilityGap")
        }
        XCTAssertEqual(gap.goal, "Play music")
        XCTAssertEqual(gap.missing, "Music playback capability")
        XCTAssertEqual(gap.say, "I can't do that yet")
    }

    func testDecodeCapabilityGapLowercase() throws {
        let json = """
        {"action": "capability_gap", "goal": "test", "missing": "test"}
        """
        let action = try decode(json)
        guard case .capabilityGap = action else {
            return XCTFail("Expected .capabilityGap")
        }
    }

    // MARK: - Error Cases

    func testDecodeUnknownActionThrows() {
        let json = """
        {"action": "UNKNOWN", "say": "hello"}
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeMissingActionKeyThrows() {
        let json = """
        {"say": "hello"}
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeEmptyStringThrows() {
        XCTAssertThrowsError(try decode(""))
    }

    func testDecodeGarbageTextThrows() {
        XCTAssertThrowsError(try decode("not json at all"))
    }

    func testDecodeToolMissingNameThrows() {
        let json = """
        {"action": "TOOL", "args": {"url": "test"}}
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeToolMissingArgsThrows() {
        let json = """
        {"action": "TOOL", "name": "show_image"}
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeTalkMissingSayThrows() {
        let json = """
        {"action": "TALK"}
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: - LLM Edge Cases

    func testDecodeWithExtraFields() throws {
        let json = """
        {"action": "TALK", "say": "Hello", "extra_field": "ignored", "confidence": 0.95}
        """
        let action = try decode(json)
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk")
        }
        XCTAssertEqual(talk.say, "Hello")
    }

    func testDecodeToolEmptyArgs() throws {
        let json = """
        {"action": "TOOL", "name": "show_text", "args": {}}
        """
        let action = try decode(json)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool")
        }
        XCTAssert(tool.args.isEmpty)
    }

    func testDecodeUnicodeContent() throws {
        let json = """
        {"action": "TALK", "say": "Here's your recipe: 🍛 Butter Chicken"}
        """
        let action = try decode(json)
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk")
        }
        XCTAssert(talk.say.contains("🍛"))
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> Action {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(Action.self, from: data)
    }
}
