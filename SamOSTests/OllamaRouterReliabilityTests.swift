import XCTest
@testable import SamOS

// MARK: - sanitizeLLMText Tests

final class SanitizeLLMTextTests: XCTestCase {

    let router = OllamaRouter()

    func testStripsPythonTagToken() {
        let input = #"<|python_tag|>{"action":"TALK","say":"Hi"}"#
        let result = router.sanitizeLLMText(input)
        XCTAssertEqual(result, #"{"action":"TALK","say":"Hi"}"#)
    }

    func testStripsMultipleTokenMarkers() {
        let input = #"<|start|>{"action":"TALK","say":"hello"}<|end|>"#
        let result = router.sanitizeLLMText(input)
        XCTAssertEqual(result, #"{"action":"TALK","say":"hello"}"#)
    }

    func testStripsCodeFences() {
        let input = """
        ```json
        {"action":"TALK","say":"hello"}
        ```
        """
        let result = router.sanitizeLLMText(input)
        XCTAssertTrue(result.contains("\"action\""))
        XCTAssertFalse(result.contains("```"))
    }

    func testStripsCodeFencesWithoutLanguage() {
        let input = """
        ```
        {"action":"TALK","say":"hello"}
        ```
        """
        let result = router.sanitizeLLMText(input)
        XCTAssertTrue(result.contains("\"action\""))
        XCTAssertFalse(result.contains("```"))
    }

    func testTrimsWhitespace() {
        let input = "   \n  {\"action\":\"TALK\",\"say\":\"hi\"}  \n  "
        let result = router.sanitizeLLMText(input)
        XCTAssertTrue(result.hasPrefix("{"))
        XCTAssertTrue(result.hasSuffix("}"))
    }

    func testCleanTextUnchanged() {
        let input = #"{"action":"TALK","say":"hello"}"#
        let result = router.sanitizeLLMText(input)
        XCTAssertEqual(result, input)
    }

    func testCombinedTokenAndFences() {
        let input = """
        <|python_tag|>```json
        {"action":"TALK","say":"hi"}
        ```
        """
        let result = router.sanitizeLLMText(input)
        XCTAssertTrue(result.contains("\"action\""))
        XCTAssertFalse(result.contains("<|"))
        XCTAssertFalse(result.contains("```"))
    }
}

// MARK: - jsonParseFailed Repair Retry Tests

final class JsonParseFailedRetryTests: XCTestCase {

    func testJsonParseFailedTriggersRepairRetry() async throws {
        let fake = FakeTransport(responses: [
            // First call: garbage non-JSON
            "I cannot help with that",
            // Repair call: valid TALK
            #"{"action":"TALK","say":"Hey! How can I help?"}"#
        ])
        let router = OllamaRouter(transport: fake)

        let plan = try await router.routePlan("hello")
        XCTAssertEqual(plan.steps.count, 1)
        if case .talk(let say) = plan.steps[0] {
            XCTAssertEqual(say, "Hey! How can I help?")
        } else {
            XCTFail("Expected talk step, got \(plan.steps[0])")
        }
        // Should have made 2 calls: original + repair retry
        XCTAssertEqual(fake.chatCallLog.count, 2)
        // Second call should contain [REPAIR] block
        let repairMessages = fake.chatCallLog[1]
        XCTAssertTrue(repairMessages.contains { $0["content"]?.contains("[REPAIR]") == true },
                      "Repair call should include [REPAIR] block")
    }

    func testJsonParseFailedDoubleFailurePropagates() async throws {
        let fake = FakeTransport(responses: [
            "not json at all",
            "still not json"
        ])
        let router = OllamaRouter(transport: fake)

        do {
            _ = try await router.routePlan("hello")
            XCTFail("Should have thrown after double failure")
        } catch let error as OllamaRouter.OllamaError {
            // Second failure propagates (could be jsonParseFailed or schemaMismatch depending on content)
            switch error {
            case .jsonParseFailed, .schemaMismatch:
                break // Expected
            default:
                XCTFail("Expected jsonParseFailed or schemaMismatch, got \(error)")
            }
        }
        XCTAssertEqual(fake.chatCallLog.count, 2)
    }

    func testJsonParseFailedRepairBlockIncludesRawSnippet() async throws {
        let fake = FakeTransport(responses: [
            "Here is my answer about frogs",
            #"{"action":"TALK","say":"Hi!"}"#
        ])
        let router = OllamaRouter(transport: fake)

        _ = try await router.routePlan("hello")
        XCTAssertEqual(fake.chatCallLog.count, 2)
        let repairMessages = fake.chatCallLog[1]
        let repairContent = repairMessages.first { $0["content"]?.contains("[REPAIR]") == true }?["content"] ?? ""
        XCTAssertTrue(repairContent.contains("not valid JSON"),
                      "Repair block should mention invalid JSON")
        XCTAssertTrue(repairContent.contains("raw output"),
                      "Repair block should include raw snippet")
    }

    func testTokenGarbageBeforeJsonStillParses() async throws {
        // sanitizeLLMText should strip the token, then JSON parses normally — no repair needed
        let fake = FakeTransport(responses: [
            #"<|python_tag|>{"action":"TALK","say":"hello"}"#
        ])
        let router = OllamaRouter(transport: fake)

        let plan = try await router.routePlan("say hi")
        XCTAssertEqual(plan.steps.count, 1)
        if case .talk(let say) = plan.steps[0] {
            XCTAssertEqual(say, "hello")
        } else {
            XCTFail("Expected talk step")
        }
        // Only 1 call — sanitize handled it, no repair needed
        XCTAssertEqual(fake.chatCallLog.count, 1)
    }
}

// MARK: - ActionValidator Time-Query Rule Tests

final class ActionValidatorTimeQueryTests: XCTestCase {

    func testTimeQueryWithTalkOnlyPassesValidation() {
        // TALK is always accepted — no time-query enforcement rule.
        let plan = Plan(steps: [.talk(say: "I think it might be around 3pm.")])
        XCTAssertNil(ActionValidator.validatePlan(plan, userInput: "what time is it in london"),
                     "TALK is always accepted, even for time queries")
    }

    func testTimeQueryWithGetTimePassesValidation() {
        let plan = Plan(steps: [
            .tool(name: "get_time", args: ["place": .string("London")], say: "Here's the time.")
        ])
        let failure = ActionValidator.validatePlan(plan, userInput: "what time is it in london")
        XCTAssertNil(failure, "Time query with get_time tool should pass")
    }

    func testTimeQueryWithTalkCapabilityPassesValidation() {
        // TALK is always accepted — no time-query enforcement rule.
        let plan = Plan(steps: [.talk(say: "I don't have that capability.")])
        XCTAssertNil(ActionValidator.validatePlan(plan, userInput: "what's the time"),
                     "TALK is always accepted, even for time queries")
    }

    func testNonTimeQueryWithTalkPassesValidation() {
        let plan = Plan(steps: [.talk(say: "Hey there! I'm doing great.")])
        let failure = ActionValidator.validatePlan(plan, userInput: "how are you doing")
        XCTAssertNil(failure, "Non-time TALK should pass validation")
    }

    func testTimeQueryPatternsDetected() {
        let queries = [
            "what time is it",
            "what's the time",
            "what is the time in tokyo",
            "current time",
            "time in new york",
            "what date is it",
            "what's the date",
            "what day is it",
            "current date",
            "What Time Is It In London",
        ]
        for query in queries {
            XCTAssertTrue(ActionValidator.isTimeQuery(query),
                          "Should detect as time query: \"\(query)\"")
        }
    }

    func testNonTimeQueriesNotDetected() {
        let queries = [
            "hello",
            "tell me a joke",
            "show me a picture of a frog",
            "set a timer for 5 minutes",
            "what is the meaning of life",
            "remember that my dog is named Bailey",
            "time to go",
            "it's about time",
        ]
        for query in queries {
            XCTAssertFalse(ActionValidator.isTimeQuery(query),
                           "Should NOT detect as time query: \"\(query)\"")
        }
    }

    func testTimeQueryWithNilUserInputSkipsRule() {
        let plan = Plan(steps: [.talk(say: "Some answer")])
        let failure = ActionValidator.validatePlan(plan, userInput: nil)
        XCTAssertNil(failure, "No userInput should skip time-query rule")
    }

    func testTimeQueryMultiStepPlanWithGetTimePasses() {
        let plan = Plan(steps: [
            .talk(say: "Let me check."),
            .tool(name: "get_time", args: ["place": .string("Tokyo")], say: "Here you go.")
        ])
        let failure = ActionValidator.validatePlan(plan, userInput: "what time is it in tokyo")
        XCTAssertNil(failure, "Multi-step plan with get_time should pass")
    }
}

// MARK: - Ollama Model & Inference Options Tests

final class OllamaModelConfigTests: XCTestCase {

    func testDefaultModelIsQwen() {
        // If user hasn't overridden via UserDefaults, the default should be qwen2.5:3b-instruct
        let defaults = UserDefaults.standard
        let key = "m3_ollamaModel"
        let saved = defaults.string(forKey: key)
        defaults.removeObject(forKey: key)
        defer { if let saved { defaults.set(saved, forKey: key) } }

        XCTAssertEqual(M2Settings.ollamaModel, "qwen2.5:3b-instruct")
    }

    func testInferenceOptionsPresent() {
        let opts = RealOllamaTransport.inferenceOptions
        XCTAssertEqual(opts["temperature"] as? Double, 0.1)
        XCTAssertEqual(opts["top_p"] as? Double, 0.9)
        XCTAssertEqual(opts["num_predict"] as? Int, 256)
    }
}
