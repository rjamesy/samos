import XCTest
@testable import SamOSv2

final class ResponseParserTests: XCTestCase {
    let parser = ResponseParser()

    func testParseTalkAction() {
        let json = """
        {"action":"TALK","say":"Hello there!"}
        """
        let plan = parser.parse(json)
        XCTAssertEqual(plan.steps.count, 1)
        if case .talk(let say) = plan.steps.first {
            XCTAssertEqual(say, "Hello there!")
        } else {
            XCTFail("Expected talk step")
        }
    }

    func testParseToolAction() {
        let json = """
        {"action":"TOOL","name":"get_time","args":{"timezone":"EST"},"say":"Checking time"}
        """
        let plan = parser.parse(json)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.say, "Checking time")
    }

    func testParsePlanWithSteps() {
        let json = """
        {"steps":[{"step":"talk","say":"Let me check"},{"step":"tool","name":"get_weather","args":{"city":"Sydney"}}]}
        """
        let plan = parser.parse(json)
        XCTAssertEqual(plan.steps.count, 2)
    }

    func testInvalidJSONFallsBackToTalk() {
        let text = "I don't understand that question format."
        let plan = parser.parse(text)
        XCTAssertEqual(plan.steps.count, 1)
        if case .talk(let say) = plan.steps.first {
            XCTAssertEqual(say, text)
        } else {
            XCTFail("Expected fallback to talk")
        }
    }

    func testEmptyResponseFallback() {
        let plan = parser.parse("")
        XCTAssertEqual(plan.steps.count, 1)
    }

    func testJSONInMarkdownFences() {
        let text = """
        ```json
        {"action":"TALK","say":"Found it"}
        ```
        """
        let plan = parser.parse(text)
        if case .talk(let say) = plan.steps.first {
            XCTAssertEqual(say, "Found it")
        } else {
            XCTFail("Expected talk step from markdown-fenced JSON")
        }
    }

    func testJSONWithPreamble() {
        let text = """
        Here is my response:
        {"action":"TALK","say":"Preamble test"}
        """
        let plan = parser.parse(text)
        if case .talk(let say) = plan.steps.first {
            XCTAssertEqual(say, "Preamble test")
        } else {
            XCTFail("Expected talk step from JSON with preamble")
        }
    }
}
