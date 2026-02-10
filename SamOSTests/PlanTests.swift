import XCTest
@testable import SamOS

final class PlanTests: XCTestCase {

    // MARK: - CodableValue Decode

    func testCodableValueString() throws {
        let data = Data(#""hello""#.utf8)
        let val = try JSONDecoder().decode(CodableValue.self, from: data)
        XCTAssertEqual(val, .string("hello"))
        XCTAssertEqual(val.stringValue, "hello")
    }

    func testCodableValueInt() throws {
        let data = Data("42".utf8)
        let val = try JSONDecoder().decode(CodableValue.self, from: data)
        XCTAssertEqual(val, .int(42))
        XCTAssertEqual(val.stringValue, "42")
    }

    func testCodableValueDouble() throws {
        let data = Data("3.14".utf8)
        let val = try JSONDecoder().decode(CodableValue.self, from: data)
        XCTAssertEqual(val, .double(3.14))
        XCTAssertEqual(val.stringValue, "3.14")
    }

    func testCodableValueBool() throws {
        let data = Data("true".utf8)
        let val = try JSONDecoder().decode(CodableValue.self, from: data)
        XCTAssertEqual(val, .bool(true))
        XCTAssertEqual(val.stringValue, "true")
    }

    func testCodableValueNull() throws {
        let data = Data("null".utf8)
        let val = try JSONDecoder().decode(CodableValue.self, from: data)
        XCTAssertEqual(val, .null)
        XCTAssertEqual(val.stringValue, "")
    }

    // MARK: - PlanStep Decode

    func testDecodeTalkStep() throws {
        let json = #"{"step":"talk","say":"Hello there!"}"#
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(json.utf8))
        XCTAssertEqual(step, .talk(say: "Hello there!"))
    }

    func testDecodeToolStep() throws {
        let json = #"{"step":"tool","name":"show_image","args":{"urls":"https://example.com/img.jpg","alt":"a frog"},"say":"Here you go."}"#
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(json.utf8))
        if case .tool(let name, let args, let say) = step {
            XCTAssertEqual(name, "show_image")
            XCTAssertEqual(args["urls"], .string("https://example.com/img.jpg"))
            XCTAssertEqual(args["alt"], .string("a frog"))
            XCTAssertEqual(say, "Here you go.")
        } else {
            XCTFail("Expected tool step")
        }
    }

    func testDecodeToolStepWithNumericArgs() throws {
        let json = #"{"step":"tool","name":"schedule_task","args":{"in_seconds":60,"label":"timer"}}"#
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(json.utf8))
        if case .tool(let name, let args, _) = step {
            XCTAssertEqual(name, "schedule_task")
            XCTAssertEqual(args["in_seconds"], .int(60))
            XCTAssertEqual(args["in_seconds"]?.stringValue, "60")
        } else {
            XCTFail("Expected tool step")
        }
    }

    func testDecodeAskStep() throws {
        let json = #"{"step":"ask","slot":"time","prompt":"What time should I set the alarm for?"}"#
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(json.utf8))
        XCTAssertEqual(step, .ask(slot: "time", prompt: "What time should I set the alarm for?"))
    }

    func testDecodeAskStepWithSlotsArray() throws {
        let json = #"{"step":"ask","slots":["time","timezone"],"prompt":"What time and timezone?"}"#
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(json.utf8))
        XCTAssertEqual(step, .ask(slot: "time,timezone", prompt: "What time and timezone?"))
    }

    func testDecodeAskStepNormalizesCommaSeparatedSlot() throws {
        let json = #"{"step":"ask","slot":" time, timezone ","prompt":"Need details"}"#
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(json.utf8))
        XCTAssertEqual(step, .ask(slot: "time,timezone", prompt: "Need details"))
    }

    func testDecodeDelegateStep() throws {
        let json = #"{"step":"delegate","task":"complex analysis","context":"user data","say":"Let me hand this off."}"#
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(json.utf8))
        if case .delegate(let task, let context, let say) = step {
            XCTAssertEqual(task, "complex analysis")
            XCTAssertEqual(context, "user data")
            XCTAssertEqual(say, "Let me hand this off.")
        } else {
            XCTFail("Expected delegate step")
        }
    }

    func testToolArgsAsStrings() throws {
        let json = #"{"step":"tool","name":"schedule_task","args":{"in_seconds":60,"label":"timer","active":true}}"#
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(json.utf8))
        let strings = step.toolArgsAsStrings
        XCTAssertEqual(strings["in_seconds"], "60")
        XCTAssertEqual(strings["label"], "timer")
        XCTAssertEqual(strings["active"], "true")
    }

    func testToolArgsAsStringsNonToolStep() {
        let step = PlanStep.talk(say: "hi")
        XCTAssertTrue(step.toolArgsAsStrings.isEmpty)
    }

    // MARK: - Plan Decode

    func testDecodePlan() throws {
        let json = """
        {"action":"PLAN","say":"Sure.","steps":[
            {"step":"tool","name":"get_time","args":{},"say":"Let me check."},
            {"step":"talk","say":"Here's the time."}
        ]}
        """
        let plan = try JSONDecoder().decode(Plan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.say, "Sure.")
        XCTAssertEqual(plan.steps.count, 2)
    }

    func testDecodePlanWithAskStep() throws {
        let json = """
        {"action":"PLAN","say":"What time?","steps":[
            {"step":"ask","slot":"time","prompt":"What time should I set the alarm for?"}
        ]}
        """
        let plan = try JSONDecoder().decode(Plan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.steps.count, 1)
        if case .ask(let slot, let prompt) = plan.steps[0] {
            XCTAssertEqual(slot, "time")
            XCTAssertEqual(prompt, "What time should I set the alarm for?")
        } else {
            XCTFail("Expected ask step")
        }
    }

    // MARK: - Plan.fromAction()

    func testFromActionTalk() {
        let action = Action.talk(Talk(say: "Hello!"))
        let plan = Plan.fromAction(action)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps[0], .talk(say: "Hello!"))
    }

    func testFromActionTool() {
        let action = Action.tool(ToolAction(name: "get_time", args: ["timezone": "UTC"], say: "Checking."))
        let plan = Plan.fromAction(action)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.say, "Checking.")
        if case .tool(let name, let args, let say) = plan.steps[0] {
            XCTAssertEqual(name, "get_time")
            XCTAssertEqual(args["timezone"], .string("UTC"))
            XCTAssertNil(say)
        } else {
            XCTFail("Expected tool step")
        }
    }

    func testFromActionDelegate() {
        let action = Action.delegateOpenAI(DelegateOpenAI(task: "analyze", context: "ctx", say: "On it."))
        let plan = Plan.fromAction(action)
        XCTAssertEqual(plan.steps.count, 1)
        if case .delegate(let task, let context, let say) = plan.steps[0] {
            XCTAssertEqual(task, "analyze")
            XCTAssertEqual(context, "ctx")
            XCTAssertEqual(say, "On it.")
        } else {
            XCTFail("Expected delegate step")
        }
    }

    func testFromActionCapabilityGap() {
        let action = Action.capabilityGap(CapabilityGap(goal: "play music", missing: "music player", say: "I can't do that."))
        let plan = Plan.fromAction(action)
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0], .talk(say: "I can't do that."))
        if case .delegate(let task, _, _) = plan.steps[1] {
            XCTAssertTrue(task.contains("capability_gap"))
        } else {
            XCTFail("Expected delegate step for capability gap")
        }
    }

    func testFromActionCapabilityGapNoSay() {
        let action = Action.capabilityGap(CapabilityGap(goal: "play music", missing: "music player"))
        let plan = Plan.fromAction(action)
        XCTAssertEqual(plan.steps.count, 1) // no talk step since say is nil
        if case .delegate(let task, _, _) = plan.steps[0] {
            XCTAssertTrue(task.contains("capability_gap"))
        } else {
            XCTFail("Expected delegate step")
        }
    }

    // MARK: - Step case-insensitive

    func testStepTypeCaseInsensitive() throws {
        let json = #"{"step":"TOOL","name":"get_time","args":{}}"#
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(json.utf8))
        if case .tool(let name, _, _) = step {
            XCTAssertEqual(name, "get_time")
        } else {
            XCTFail("Expected tool step with uppercase TOOL")
        }
    }
}
