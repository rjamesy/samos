import XCTest
@testable import SamOSv2

final class PlanTests: XCTestCase {

    // MARK: - CodableValue

    func testCodableValueString() throws {
        let json = Data("\"hello\"".utf8)
        let value = try JSONDecoder().decode(CodableValue.self, from: json)
        XCTAssertEqual(value, .string("hello"))
        XCTAssertEqual(value.stringValue, "hello")
    }

    func testCodableValueInt() throws {
        let json = Data("42".utf8)
        let value = try JSONDecoder().decode(CodableValue.self, from: json)
        XCTAssertEqual(value, .int(42))
        XCTAssertEqual(value.stringValue, "42")
    }

    func testCodableValueBool() throws {
        let json = Data("true".utf8)
        let value = try JSONDecoder().decode(CodableValue.self, from: json)
        XCTAssertEqual(value, .bool(true))
        XCTAssertEqual(value.stringValue, "true")
    }

    func testCodableValueNull() throws {
        let json = Data("null".utf8)
        let value = try JSONDecoder().decode(CodableValue.self, from: json)
        XCTAssertEqual(value, .null)
        XCTAssertEqual(value.stringValue, "")
    }

    // MARK: - PlanStep

    func testDecodeTalkStep() throws {
        let json = Data("""
        {"step":"talk","say":"Hello there!"}
        """.utf8)
        let step = try JSONDecoder().decode(PlanStep.self, from: json)
        XCTAssertEqual(step, .talk(say: "Hello there!"))
    }

    func testDecodeToolStep() throws {
        let json = Data("""
        {"step":"tool","name":"get_time","args":{"timezone":"EST"},"say":"Let me check"}
        """.utf8)
        let step = try JSONDecoder().decode(PlanStep.self, from: json)
        if case .tool(let name, let args, let say) = step {
            XCTAssertEqual(name, "get_time")
            XCTAssertEqual(args["timezone"], .string("EST"))
            XCTAssertEqual(say, "Let me check")
        } else {
            XCTFail("Expected tool step")
        }
    }

    func testDecodeToolStepWithNumericArgs() throws {
        let json = Data("""
        {"step":"tool","name":"timer","args":{"minutes":5}}
        """.utf8)
        let step = try JSONDecoder().decode(PlanStep.self, from: json)
        XCTAssertEqual(step.toolArgsAsStrings["minutes"], "5")
    }

    func testDecodeAskStep() throws {
        let json = Data("""
        {"step":"ask","slot":"city","prompt":"Which city?"}
        """.utf8)
        let step = try JSONDecoder().decode(PlanStep.self, from: json)
        XCTAssertEqual(step, .ask(slot: "city", prompt: "Which city?"))
    }

    func testDecodeDelegateStep() throws {
        let json = Data("""
        {"step":"delegate","task":"complex analysis","context":"needs deep thinking","say":"Let me think"}
        """.utf8)
        let step = try JSONDecoder().decode(PlanStep.self, from: json)
        if case .delegate(let task, let context, let say) = step {
            XCTAssertEqual(task, "complex analysis")
            XCTAssertEqual(context, "needs deep thinking")
            XCTAssertEqual(say, "Let me think")
        } else {
            XCTFail("Expected delegate step")
        }
    }

    // MARK: - Plan

    func testDecodePlan() throws {
        let json = Data("""
        {"steps":[{"step":"talk","say":"Hello"},{"step":"tool","name":"get_time","args":{}}]}
        """.utf8)
        let plan = try JSONDecoder().decode(Plan.self, from: json)
        XCTAssertEqual(plan.steps.count, 2)
    }

    func testPlanFromTalkAction() {
        let action = Action.talk(Talk(say: "Hello"))
        let plan = Plan.fromAction(action)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first, .talk(say: "Hello"))
    }

    func testPlanFromToolAction() {
        let action = Action.tool(ToolAction(name: "get_time", args: ["tz": "EST"], say: "Here"))
        let plan = Plan.fromAction(action)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.say, "Here")
    }
}
