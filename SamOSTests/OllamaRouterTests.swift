import XCTest
@testable import SamOS

final class OllamaRouterTests: XCTestCase {

    let router = OllamaRouter()

    // MARK: - extractJSON

    func testExtractJSONClean() {
        let input = """
        {"action": "TALK", "say": "hello"}
        """
        let result = router.extractJSON(from: input)
        XCTAssertEqual(result, input)
    }

    func testExtractJSONWithLeadingText() {
        let input = """
        Here is my response: {"action": "TALK", "say": "hello"}
        """
        let result = router.extractJSON(from: input)
        XCTAssertEqual(result, """
        {"action": "TALK", "say": "hello"}
        """)
    }

    func testExtractJSONWithTrailingText() {
        let input = """
        {"action": "TALK", "say": "hello"} Hope that helps!
        """
        let result = router.extractJSON(from: input)
        XCTAssertEqual(result, """
        {"action": "TALK", "say": "hello"}
        """)
    }

    func testExtractJSONWithWrappingText() {
        let input = """
        Sure! Here's the JSON: {"action": "TOOL", "name": "show_image", "args": {"url": "https://example.com"}} Let me know if you need anything else.
        """
        let result = router.extractJSON(from: input)
        XCTAssert(result.hasPrefix("{"))
        XCTAssert(result.hasSuffix("}"))
        // Verify it's valid JSON
        let data = result.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    func testExtractJSONWithMarkdownFence() {
        let input = """
        ```json
        {"action": "TALK", "say": "hello"}
        ```
        """
        let result = router.extractJSON(from: input)
        XCTAssert(result.hasPrefix("{"))
        XCTAssert(result.hasSuffix("}"))
    }

    func testExtractJSONNoJSON() {
        let input = "I cannot help with that request"
        let result = router.extractJSON(from: input)
        XCTAssertEqual(result, input) // Returns original text when no braces found
    }

    func testExtractJSONWithNestedBraces() {
        let input = """
        {"action": "TOOL", "name": "show_text", "args": {"markdown": "## Title\\n{code}"}, "say": "Done"}
        """
        let result = router.extractJSON(from: input)
        XCTAssert(result.hasPrefix("{"))
        XCTAssert(result.hasSuffix("}"))
    }

    func testExtractJSONEmptyString() {
        let result = router.extractJSON(from: "")
        XCTAssertEqual(result, "")
    }

    // MARK: - parseAction

    func testParseActionTalk() throws {
        let text = """
        {"action": "TALK", "say": "Hello world"}
        """
        let action = try router.parseAction(from: text)
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk")
        }
        XCTAssertEqual(talk.say, "Hello world")
    }

    func testParseActionTool() throws {
        let text = """
        {"action": "TOOL", "name": "show_image", "args": {"url": "https://example.com/frog.jpg", "alt": "A frog"}, "say": "Here's your frog"}
        """
        let action = try router.parseAction(from: text)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool")
        }
        XCTAssertEqual(tool.name, "show_image")
        XCTAssertEqual(tool.args["url"], "https://example.com/frog.jpg")
    }

    func testParseActionFromWrappedText() throws {
        let text = """
        Here is my JSON response: {"action": "TALK", "say": "wrapped"} That's it.
        """
        let action = try router.parseAction(from: text)
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk")
        }
        XCTAssertEqual(talk.say, "wrapped")
    }

    func testParseActionLowercaseAction() throws {
        let text = """
        {"action": "talk", "say": "lowercase"}
        """
        let action = try router.parseAction(from: text)
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk")
        }
        XCTAssertEqual(talk.say, "lowercase")
    }

    func testParseActionNoJSONThrows() {
        XCTAssertThrowsError(try router.parseAction(from: "I cannot help with that")) { error in
            XCTAssert(error is OllamaRouter.OllamaError)
        }
    }

    func testParseActionCapabilityGap() throws {
        let text = """
        {"action": "CAPABILITY_GAP", "goal": "Play Spotify", "missing": "Spotify API integration", "say": "I can't play music yet"}
        """
        let action = try router.parseAction(from: text)
        guard case .capabilityGap(let gap) = action else {
            return XCTFail("Expected .capabilityGap")
        }
        XCTAssertEqual(gap.goal, "Play Spotify")
        XCTAssertEqual(gap.missing, "Spotify API integration")
    }

    func testParseActionDelegateOpenAI() throws {
        let text = """
        {"action": "DELEGATE_OPENAI", "task": "Summarize long document", "say": "Delegating to a larger model"}
        """
        let action = try router.parseAction(from: text)
        guard case .delegateOpenAI(let d) = action else {
            return XCTFail("Expected .delegateOpenAI")
        }
        XCTAssertEqual(d.task, "Summarize long document")
    }

    // MARK: - Realistic LLM Responses

    func testParseRealisticOllamaGreeting() throws {
        // Actual-style Ollama response for "say hello"
        let text = """
        {"action":"TALK","say":"Hello! I'm Sam, your AI assistant. How can I help you today?"}
        """
        let action = try router.parseAction(from: text)
        guard case .talk = action else {
            return XCTFail("Expected .talk")
        }
    }

    func testParseRealisticOllamaImageRequest() throws {
        // Actual-style Ollama response for "show me a picture of a frog"
        let text = """
        {"action":"TOOL","name":"show_image","args":{"url":"https://upload.wikimedia.org/wikipedia/commons/thumb/e/ed/Lithobates_clamitans.jpg/1280px-Lithobates_clamitans.jpg","alt":"a frog"},"say":"Here's a picture of a frog for you!"}
        """
        let action = try router.parseAction(from: text)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool")
        }
        XCTAssertEqual(tool.name, "show_image")
    }

    func testParseOllamaResponseWithNewlines() throws {
        let text = """
        {
          "action": "TALK",
          "say": "Hello there! How can I help you?"
        }
        """
        let action = try router.parseAction(from: text)
        guard case .talk = action else {
            return XCTFail("Expected .talk")
        }
    }

    func testParseToolWithMixedArgTypes() throws {
        // LLM returns a number for one of the args
        let text = """
        {"action": "TOOL", "name": "show_image", "args": {"url": "https://example.com/img.jpg", "alt": "test", "width": 640, "fullscreen": false}, "say": "Here"}
        """
        let action = try router.parseAction(from: text)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool")
        }
        XCTAssertEqual(tool.args["width"], "640")
        XCTAssertEqual(tool.args["fullscreen"], "false")
        XCTAssertEqual(tool.args["url"], "https://example.com/img.jpg")
    }

    // MARK: - Real LLM Deviation Tests (from actual Ollama responses)

    func testParseToolNameAsAction() throws {
        // ACTUAL Ollama response: LLM used tool name as action, args at top level
        let text = """
        {"action": "show_image", "name": "green_frog.jpg", "url": "https://commons.wikimedia.org/wiki/File:Green_frog.jpg", "alt": "A green frog sitting on a lily pad"}
        """
        let action = try router.parseAction(from: text)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool, got \(action)")
        }
        XCTAssertEqual(tool.name, "show_image")
        XCTAssertNotNil(tool.args["url"])
        XCTAssertNotNil(tool.args["alt"])
    }

    func testParseShowTextAsAction() throws {
        // LLM returns tool name "show_text" as the action type
        let text = """
        {"action": "show_text", "markdown": "# Recipe\\nHere is the recipe", "say": "Here's your recipe"}
        """
        let action = try router.parseAction(from: text)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool, got \(action)")
        }
        XCTAssertEqual(tool.name, "show_text")
        XCTAssertNotNil(tool.args["markdown"])
        XCTAssertEqual(tool.say, "Here's your recipe")
    }

    func testParseToolWithFlatArgs() throws {
        // LLM puts args at top level instead of nested in "args"
        let text = """
        {"action": "TOOL", "name": "show_image", "url": "https://example.com/frog.jpg", "alt": "A frog", "say": "Here you go"}
        """
        let action = try router.parseAction(from: text)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool, got \(action)")
        }
        XCTAssertEqual(tool.name, "show_image")
        XCTAssertEqual(tool.args["url"], "https://example.com/frog.jpg")
        XCTAssertEqual(tool.args["alt"], "A frog")
        XCTAssertEqual(tool.say, "Here you go")
    }

    func testParseResponseWithSayOnly() throws {
        // LLM returns just a "say" field with no action
        let text = """
        {"say": "Hello! How can I help you today?"}
        """
        let action = try router.parseAction(from: text)
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk fallback, got \(action)")
        }
        XCTAssertEqual(talk.say, "Hello! How can I help you today?")
    }

    func testParseResponseWithResponseField() throws {
        // LLM uses "response" instead of "say"
        let text = """
        {"response": "I can help with that!"}
        """
        let action = try router.parseAction(from: text)
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk fallback, got \(action)")
        }
        XCTAssertEqual(talk.say, "I can help with that!")
    }

    func testParseToolFieldInsteadOfAction() throws {
        // LLM uses "tool" key instead of "action": "TOOL"
        let text = """
        {"tool": "show_image", "args": {"url": "https://example.com/cat.jpg", "alt": "A cat"}, "say": "Here"}
        """
        let action = try router.parseAction(from: text)
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool, got \(action)")
        }
        XCTAssertEqual(tool.name, "show_image")
    }

    // MARK: - normalizeActionJSON

    func testNormalizeToolNameAsAction() {
        let input: [String: Any] = [
            "action": "show_image",
            "url": "https://example.com/img.jpg",
            "alt": "test"
        ]
        let result = router.normalizeActionJSON(input)
        XCTAssertEqual(result["action"] as? String, "TOOL")
        XCTAssertEqual(result["name"] as? String, "show_image")
        XCTAssertNotNil(result["args"])
        let args = result["args"] as? [String: Any]
        XCTAssertEqual(args?["url"] as? String, "https://example.com/img.jpg")
    }

    func testNormalizeAlreadyCorrect() {
        let input: [String: Any] = [
            "action": "TALK",
            "say": "hello"
        ]
        let result = router.normalizeActionJSON(input)
        XCTAssertEqual(result["action"] as? String, "TALK")
        XCTAssertEqual(result["say"] as? String, "hello")
    }

    func testNormalizeSayMovedFromArgsToTopLevel() {
        let input: [String: Any] = [
            "action": "TOOL",
            "name": "show_text",
            "args": [
                "markdown": "# Banana Bread\nMix flour, sugar, and bananas.",
                "say": "Here's a tasty banana bread recipe."
            ] as [String: Any]
        ]
        let result = router.normalizeActionJSON(input)
        // "say" should be at the top level
        XCTAssertEqual(result["say"] as? String, "Here's a tasty banana bread recipe.")
        // "say" should NOT remain inside args
        let args = result["args"] as? [String: Any]
        XCTAssertNil(args?["say"])
        // "markdown" should be untouched inside args
        XCTAssertEqual(args?["markdown"] as? String, "# Banana Bread\nMix flour, sugar, and bananas.")
    }

    func testNormalizeFlatArgsForTool() {
        let input: [String: Any] = [
            "action": "TOOL",
            "name": "show_image",
            "url": "https://example.com",
            "alt": "test",
            "say": "Here"
        ]
        let result = router.normalizeActionJSON(input)
        XCTAssertNotNil(result["args"])
        let args = result["args"] as? [String: Any]
        XCTAssertEqual(args?["url"] as? String, "https://example.com")
        XCTAssertEqual(args?["alt"] as? String, "test")
        // "say" should NOT be in args
        XCTAssertNil(args?["say"])
    }

    func testNormalizeShowTextTextArgToMarkdown() {
        let input: [String: Any] = [
            "action": "PLAN",
            "steps": [
                [
                    "step": "show_text",
                    "args": [
                        "text": "# Recipe\n- mix"
                    ]
                ]
            ]
        ]

        let result = router.normalizeActionJSON(input)
        let steps = result["steps"] as? [[String: Any]]
        let first = steps?.first
        XCTAssertEqual(first?["step"] as? String, "tool")
        XCTAssertEqual(first?["name"] as? String, "show_text")
        let args = first?["args"] as? [String: Any]
        XCTAssertEqual(args?["markdown"] as? String, "# Recipe\n- mix")
    }

    func testNormalizeShowTextContentArgToMarkdown() {
        let input: [String: Any] = [
            "action": "PLAN",
            "steps": [
                [
                    "step": "show_text",
                    "args": [
                        "content": "# Recipe\n- simmer"
                    ]
                ]
            ]
        ]

        let result = router.normalizeActionJSON(input)
        let steps = result["steps"] as? [[String: Any]]
        let first = steps?.first
        XCTAssertEqual(first?["step"] as? String, "tool")
        XCTAssertEqual(first?["name"] as? String, "show_text")
        let args = first?["args"] as? [String: Any]
        XCTAssertEqual(args?["markdown"] as? String, "# Recipe\n- simmer")
    }

    // MARK: - extractJSON Preference for "action"

    func testExtractJSONPrefersActionObject() {
        let text = #"{} {"action":"TALK","say":"hi"}"#
        let result = router.extractJSON(from: text)
        XCTAssertTrue(result.contains("\"action\""), "Should prefer the object with 'action' key")
        XCTAssertTrue(result.contains("\"TALK\""))
    }

    func testExtractJSONFallsBackToLargest() {
        let text = #"{"a":1} {"longer":"object","count":42}"#
        let result = router.extractJSON(from: text)
        XCTAssertTrue(result.contains("longer"), "Should return the largest candidate when no 'action' found")
    }

    func testExtractJSONSingleObjectUnchanged() {
        let text = #"{"action":"TALK","say":"hello"}"#
        let result = router.extractJSON(from: text)
        XCTAssertEqual(result, text)
    }

    // MARK: - schemaMismatch Errors

    func testParseEmptyObjectThrowsSchemaMismatch() {
        let text = "{}"
        XCTAssertThrowsError(try router.parsePlanOrAction(from: text)) { error in
            guard case OllamaRouter.OllamaError.schemaMismatch(_, let reasons) = error else {
                return XCTFail("Expected .schemaMismatch, got \(error)")
            }
            XCTAssertTrue(reasons[0].lowercased().contains("empty"),
                          "Reason should mention empty object: \(reasons)")
        }
    }

    func testParseNoStringsThrowsSchemaMismatch() {
        let text = #"{"count":42,"active":true}"#
        XCTAssertThrowsError(try router.parsePlanOrAction(from: text)) { error in
            guard case OllamaRouter.OllamaError.schemaMismatch(_, let reasons) = error else {
                return XCTFail("Expected .schemaMismatch, got \(error)")
            }
            XCTAssertTrue(reasons[0].contains("action"),
                          "Reason should mention missing action: \(reasons)")
        }
    }

    func testParseTimeNullOffsetThrowsSchemaMismatch() {
        // Real observed failure: {"time":null,"offset":"GMT"}
        let text = #"{"time":null,"offset":"GMT"}"#
        XCTAssertThrowsError(try router.parsePlanOrAction(from: text)) { error in
            guard case OllamaRouter.OllamaError.schemaMismatch = error else {
                return XCTFail("Expected .schemaMismatch, got \(error)")
            }
        }
    }

    func testParseTimeStringThrowsSchemaMismatch() {
        // Real observed failure: {"time":"00:00"}
        let text = #"{"time":"00:00"}"#
        XCTAssertThrowsError(try router.parsePlanOrAction(from: text)) { error in
            guard case OllamaRouter.OllamaError.schemaMismatch = error else {
                return XCTFail("Expected .schemaMismatch, got \(error)")
            }
        }
    }

    func testParseIncompleteTalkThrowsSchemaMismatch() {
        // {"action":"TALK"} without "say"
        let text = #"{"action":"TALK"}"#
        XCTAssertThrowsError(try router.parsePlanOrAction(from: text)) { error in
            guard case OllamaRouter.OllamaError.schemaMismatch(_, let reasons) = error else {
                return XCTFail("Expected .schemaMismatch, got \(error)")
            }
            XCTAssertTrue(reasons[0].contains("incomplete"),
                          "Reason should mention incomplete: \(reasons)")
        }
    }

    // MARK: - PLAN Steps Validation

    func testParsePlanWithStringStepsThrowsSchemaMismatch() {
        // Observed failure: PLAN with string array instead of step objects
        let text = #"{"action":"PLAN","steps":["step1","step2"]}"#
        XCTAssertThrowsError(try router.parsePlanOrAction(from: text)) { error in
            guard case OllamaRouter.OllamaError.schemaMismatch(_, let reasons) = error else {
                return XCTFail("Expected .schemaMismatch, got \(error)")
            }
            XCTAssertTrue(reasons[0].contains("step objects"),
                          "Reason should mention step objects: \(reasons)")
        }
    }

    func testParsePlanWithMixedStepsThrowsSchemaMismatch() {
        // Steps array contains a mix of strings and objects
        let text = #"{"action":"PLAN","steps":["step1",{"step":"talk","say":"hi"}]}"#
        XCTAssertThrowsError(try router.parsePlanOrAction(from: text)) { error in
            guard case OllamaRouter.OllamaError.schemaMismatch(_, let reasons) = error else {
                return XCTFail("Expected .schemaMismatch, got \(error)")
            }
            XCTAssertTrue(reasons[0].contains("step objects"),
                          "Reason should mention step objects: \(reasons)")
        }
    }

    func testParsePlanWithNamedToolStepWithoutStepKeyNormalizesToTool() {
        // PLAN steps that provide only tool "name" should normalize to step="tool".
        let text = #"{"action":"PLAN","steps":[{"name":"get_time"}]}"#
        do {
            let plan = try router.parsePlanOrAction(from: text)
            guard case .tool(let name, _, _) = plan.steps.first else {
                return XCTFail("Expected first step to normalize into tool step")
            }
            XCTAssertEqual(name, "get_time")
        } catch {
            XCTFail("Expected parser to normalize tool-only step, got: \(error)")
        }
    }

    func testParsePlanWithNamedTalkStepWithoutStepKeyThrowsSchemaMismatch() {
        let text = #"{"action":"PLAN","steps":[{"name":"talk","say":"hi"}]}"#
        XCTAssertThrowsError(try router.parsePlanOrAction(from: text)) { error in
            guard case OllamaRouter.OllamaError.schemaMismatch(_, let reasons) = error else {
                return XCTFail("Expected .schemaMismatch, got \(error)")
            }
            let joined = reasons.joined(separator: " ").lowercased()
            XCTAssertTrue(joined.contains("known tool") || joined.contains("missing step type"))
        }
    }

    func testParsePlanWithUnknownToolNameThrowsSchemaMismatch() {
        let text = #"{"action":"PLAN","steps":[{"step":"tool","name":"delete_all_files","args":{}}]}"#
        XCTAssertThrowsError(try router.parsePlanOrAction(from: text)) { error in
            guard case OllamaRouter.OllamaError.schemaMismatch(_, let reasons) = error else {
                return XCTFail("Expected .schemaMismatch, got \(error)")
            }
            XCTAssertTrue(reasons.joined(separator: " ").contains("unknown tool"))
        }
    }

    func testParseTruncatedJSONThrows() {
        // Observed failure: truncated/broken JSON like {"]
        let text = #"{"#
        XCTAssertThrowsError(try router.parsePlanOrAction(from: text)) { error in
            XCTAssert(error is OllamaRouter.OllamaError,
                      "Should throw OllamaError, got \(error)")
        }
    }

    // MARK: - rescueAsTalk

    func testJsonWithoutActionThrowsSchemaMismatch() throws {
        let text = #"{"Hello":"Hi!"}"#
        XCTAssertThrowsError(try router.parsePlanOrAction(from: text)) { error in
            guard case OllamaRouter.OllamaError.schemaMismatch(_, let reasons) = error else {
                return XCTFail("Expected .schemaMismatch, got \(error)")
            }
            XCTAssertTrue(reasons.joined(separator: " ").contains("action"),
                          "Expected missing-action diagnostic, got: \(reasons)")
        }
    }

    func testRescueAsTalkFindsLongestString() {
        let dict: [String: Any] = ["greeting": "Hi", "message": "Hello there, how are you?"]
        let result = router.rescueAsTalk(dict)
        guard case .talk(let talk) = result else {
            return XCTFail("Expected .talk, got \(String(describing: result))")
        }
        XCTAssertEqual(talk.say, "Hello there, how are you?")
    }

    func testRescueAsTalkRejectsEmptyDict() {
        XCTAssertNil(router.rescueAsTalk([:]),
                     "Should return nil for empty dict")
    }

    func testRescueAsTalkRejectsNonConversationalKeys() {
        // {"time":"00:00"} — "time" not in whitelist
        XCTAssertNil(router.rescueAsTalk(["time": "00:00"]),
                     "Should not rescue non-conversational keys")
    }

    func testRescueAsTalkRejectsOffsetGMT() {
        // {"offset":"GMT"} — "offset" not in whitelist
        XCTAssertNil(router.rescueAsTalk(["offset": "GMT"]),
                     "Should not rescue non-conversational keys")
    }

    func testRescueAsTalkRejectsTooManyKeys() {
        let dict: [String: Any] = ["say": "hi", "text": "hello", "message": "hey", "greeting": "yo"]
        XCTAssertNil(router.rescueAsTalk(dict),
                     "Should reject dicts with more than 3 keys")
    }

    func testRescueAsTalkRejectsURLValues() {
        let dict: [String: Any] = ["content": "https://example.com/page"]
        XCTAssertNil(router.rescueAsTalk(dict),
                     "Should not rescue URL strings")
    }

    func testRescueAsTalkRejectsShortValues() {
        let dict: [String: Any] = ["say": "Hi"]
        XCTAssertNil(router.rescueAsTalk(dict),
                     "Should reject strings shorter than 3 chars")
    }
}

// MARK: - FakeTransport

/// Test transport that returns queued responses without network access.
final class FakeTransport: OllamaTransport {
    private var responses: [String]
    private var callCount = 0

    /// Messages passed to each chat() call, for assertion.
    private(set) var chatCallLog: [[[String: String]]] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func chat(messages: [[String: String]], model: String?, maxOutputTokens: Int?) async throws -> String {
        _ = model
        chatCallLog.append(messages)
        guard callCount < responses.count else {
            throw OllamaRouter.OllamaError.unreachable("FakeTransport: no more responses")
        }
        let response = responses[callCount]
        callCount += 1
        return response
    }
}

// MARK: - FakeTransport Integration Tests

final class OllamaRouterTransportTests: XCTestCase {

    // MARK: - Repair on empty object

    func testRepairOnEmptyObject() async throws {
        let fake = FakeTransport(responses: [
            // First call: bad schema
            "{}",
            // Repair call: valid TALK
            #"{"action":"TALK","say":"Hello there!"}"#
        ])
        let router = OllamaRouter(transport: fake)

        let plan = try await router.routePlan("say hello")
        XCTAssertEqual(plan.steps.count, 1)
        if case .talk(let say) = plan.steps[0] {
            XCTAssertEqual(say, "Hello there!")
        } else {
            XCTFail("Expected talk step, got \(plan.steps[0])")
        }
        // Two calls: original + repair retry
        XCTAssertEqual(fake.chatCallLog.count, 2)
        // Second call should contain [REPAIR] block
        let repairMessages = fake.chatCallLog[1]
        XCTAssertTrue(repairMessages.contains { $0["content"]?.contains("[REPAIR]") == true },
                      "Repair call should include [REPAIR] block")
    }

    // MARK: - Repair on no-action JSON

    func testRepairOnJsonWithoutAction() async throws {
        let fake = FakeTransport(responses: [
            #"{"Hello":"Hi!"}"#,
            #"{"action":"TALK","say":"Hi!"}"#
        ])
        let router = OllamaRouter(transport: fake)

        let plan = try await router.routePlan("say hello")
        XCTAssertEqual(plan.steps.count, 1)
        if case .talk(let say) = plan.steps[0] {
            XCTAssertEqual(say, "Hi!")
        } else {
            XCTFail("Expected talk step")
        }
        // Should perform repair retry due to missing action field
        XCTAssertEqual(fake.chatCallLog.count, 2)
    }

    // MARK: - Repair on non-schema JSON (time/offset — not whitelisted)

    func testRepairOnTimeOffset() async throws {
        let fake = FakeTransport(responses: [
            // First call: non-schema (time/offset are NOT conversational keys)
            #"{"time":null,"offset":"GMT"}"#,
            // Repair call: valid TOOL
            #"{"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"London"},"say":"Here's the time."}]}"#
        ])
        let router = OllamaRouter(transport: fake)

        let plan = try await router.routePlan("what time is it in London")
        XCTAssertEqual(plan.steps.count, 1)
        if case .tool(let name, _, _) = plan.steps[0] {
            XCTAssertEqual(name, "get_time")
        } else {
            XCTFail("Expected tool step")
        }
        XCTAssertEqual(fake.chatCallLog.count, 2)
    }

    // MARK: - Repair on {"time":"00:00"}

    func testRepairOnTimeString() async throws {
        let fake = FakeTransport(responses: [
            #"{"time":"00:00"}"#,
            #"{"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{},"say":"Let me check."}]}"#
        ])
        let router = OllamaRouter(transport: fake)

        let plan = try await router.routePlan("what time is it")
        if case .tool(let name, _, _) = plan.steps[0] {
            XCTAssertEqual(name, "get_time")
        } else {
            XCTFail("Expected tool step, got \(plan.steps[0])")
        }
    }

    // MARK: - Garbage non-JSON triggers repair retry (jsonParseFailed)

    func testRepairOnGarbageNonJSON() async throws {
        let fake = FakeTransport(responses: [
            "I cannot help with that",
            #"{"action":"TALK","say":"Hey! How can I help?"}"#
        ])
        let router = OllamaRouter(transport: fake)

        // Non-JSON now triggers jsonParseFailed repair retry (QA-3 fix)
        let plan = try await router.routePlan("hello")
        XCTAssertEqual(plan.steps.count, 1)
        if case .talk(let say) = plan.steps[0] {
            XCTAssertEqual(say, "Hey! How can I help?")
        } else {
            XCTFail("Expected talk step, got \(plan.steps[0])")
        }
        // Two calls: original + repair retry
        XCTAssertEqual(fake.chatCallLog.count, 2)
    }

    // MARK: - Two failures in a row → propagates error (no crash)

    func testDoubleFailurePropagatesError() async throws {
        let fake = FakeTransport(responses: [
            "{}",  // First call: empty object → schemaMismatch → repair retry
            "{}"   // Repair call: empty object again → schemaMismatch (repair already set, no recursion)
        ])
        let router = OllamaRouter(transport: fake)

        do {
            _ = try await router.routePlan("hello")
            XCTFail("Should have thrown after double failure")
        } catch let error as OllamaRouter.OllamaError {
            if case .schemaMismatch = error {
                // Expected — second failure propagates
            } else {
                XCTFail("Expected schemaMismatch, got \(error)")
            }
        }
        // Should have made exactly 2 calls
        XCTAssertEqual(fake.chatCallLog.count, 2)
    }

    // MARK: - Schema reminder present in messages

    func testSchemaReminderInMessages() async throws {
        let fake = FakeTransport(responses: [
            #"{"action":"TALK","say":"hi"}"#
        ])
        let router = OllamaRouter(transport: fake)

        _ = try await router.routePlan("hello")

        let messages = fake.chatCallLog[0]
        XCTAssertTrue(messages.contains { $0["content"]?.contains("[REMINDER]") == true },
                      "Messages should include [REMINDER] block")
    }

    func testSystemPromptIncludesCoTDirective() async throws {
        let fake = FakeTransport(responses: [
            #"{"action":"TALK","say":"hi"}"#
        ])
        let router = OllamaRouter(transport: fake)

        _ = try await router.routePlan("Solve a tricky logic puzzle")

        guard let system = fake.chatCallLog.first?.first(where: { $0["role"] == "system" })?["content"] else {
            return XCTFail("Expected system prompt in first chat call")
        }
        XCTAssertTrue(system.contains("think step by step internally"),
                      "System prompt should include CoT directive")
    }

    // MARK: - Valid responses still work

    func testValidTalkPassesThrough() async throws {
        let fake = FakeTransport(responses: [
            #"{"action":"TALK","say":"Hey there!"}"#
        ])
        let router = OllamaRouter(transport: fake)

        let plan = try await router.routePlan("hello")
        XCTAssertEqual(plan.steps.count, 1)
        if case .talk(let say) = plan.steps[0] {
            XCTAssertEqual(say, "Hey there!")
        } else {
            XCTFail("Expected talk step")
        }
        XCTAssertEqual(fake.chatCallLog.count, 1)
    }

    func testValidPlanPassesThrough() async throws {
        let fake = FakeTransport(responses: [
            #"{"action":"PLAN","steps":[{"step":"talk","say":"Sure."},{"step":"tool","name":"get_time","args":{"place":"London"},"say":"Here."}]}"#
        ])
        let router = OllamaRouter(transport: fake)

        let plan = try await router.routePlan("what time is it in London")
        XCTAssertEqual(plan.steps.count, 2)
        if case .tool(let name, _, _) = plan.steps[1] {
            XCTAssertEqual(name, "get_time")
        } else {
            XCTFail("Expected tool step")
        }
        XCTAssertEqual(fake.chatCallLog.count, 1)
    }

    // MARK: - PLAN String Steps Repair

    func testRepairOnPlanWithStringSteps() async throws {
        let fake = FakeTransport(responses: [
            // First call: PLAN with string steps (observed real failure)
            #"{"action":"PLAN","steps":["step1"]}"#,
            // Repair call: valid PLAN
            #"{"action":"PLAN","steps":[{"step":"tool","name":"get_time","args":{"place":"London"},"say":"Here."}]}"#
        ])
        let router = OllamaRouter(transport: fake)

        let plan = try await router.routePlan("what time is it in london")
        if case .tool(let name, _, _) = plan.steps[0] {
            XCTAssertEqual(name, "get_time")
        } else {
            XCTFail("Expected tool step, got \(plan.steps[0])")
        }
        // Should have triggered repair retry
        XCTAssertEqual(fake.chatCallLog.count, 2)
        // Repair call should include [REPAIR] block with raw snippet
        let repairMessages = fake.chatCallLog[1]
        XCTAssertTrue(repairMessages.contains { $0["content"]?.contains("[REPAIR]") == true },
                      "Repair call should include [REPAIR] block")
    }

    // MARK: - Truncated JSON Repair (now triggers jsonParseFailed retry)

    func testTruncatedJSONTriggersRepairRetry() async throws {
        let fake = FakeTransport(responses: [
            // Observed failure: truncated JSON like {"]
            #"{"#,
            // Repair call: valid TALK
            #"{"action":"TALK","say":"Hey!"}"#
        ])
        let router = OllamaRouter(transport: fake)

        // Truncated JSON now triggers jsonParseFailed repair retry (QA-3 fix)
        let plan = try await router.routePlan("hello")
        XCTAssertEqual(plan.steps.count, 1)
        if case .talk(let say) = plan.steps[0] {
            XCTAssertEqual(say, "Hey!")
        } else {
            XCTFail("Expected talk step, got \(plan.steps[0])")
        }
        // Two calls: original + repair retry
        XCTAssertEqual(fake.chatCallLog.count, 2)
    }

    // MARK: - Empty Object Repair includes raw snippet

    func testRepairBlockIncludesRawSnippet() async throws {
        let fake = FakeTransport(responses: [
            "{}",
            #"{"action":"TALK","say":"Hi!"}"#
        ])
        let router = OllamaRouter(transport: fake)

        _ = try await router.routePlan("hello")
        XCTAssertEqual(fake.chatCallLog.count, 2)
        let repairMessages = fake.chatCallLog[1]
        let repairContent = repairMessages.first { $0["content"]?.contains("[REPAIR]") == true }?["content"] ?? ""
        XCTAssertTrue(repairContent.contains("HARD RULE"),
                      "Repair block should include HARD RULE")
        XCTAssertTrue(repairContent.contains("raw output"),
                      "Repair block should include raw snippet")
    }
}

// MARK: - MockToolsRuntime

/// Test mock that records tool calls without hitting real tool implementations.
final class MockToolsRuntime: ToolsRuntimeProtocol {
    private(set) var executedActions: [ToolAction] = []

    func execute(_ toolAction: ToolAction) -> OutputItem? {
        executedActions.append(toolAction)
        return OutputItem(kind: .markdown, payload: "{\"spoken\":\"mock result\",\"formatted\":\"mock\"}")
    }
}

final class DeterministicTimeToolsRuntime: ToolsRuntimeProtocol {
    private(set) var executedActions: [ToolAction] = []

    func toolExists(_ name: String) -> Bool {
        name == "get_time"
    }

    func execute(_ toolAction: ToolAction) -> OutputItem? {
        executedActions.append(toolAction)
        guard toolAction.name == "get_time" else { return nil }
        return OutputItem(kind: .markdown, payload: "London: 10:15 AM")
    }
}

// MARK: - PlanExecutor Forge Tool Execution Tests

@MainActor
final class PlanExecutorForgeExecutionTests: XCTestCase {

    private func makeExecutor() -> (PlanExecutor, MockToolsRuntime) {
        let mock = MockToolsRuntime()
        let executor = PlanExecutor(toolsRuntime: mock)
        return (executor, mock)
    }

    // MARK: - start_skillforge execution

    func testForgeToolExecutesWithoutLearnSlot() async {
        let (executor, mock) = makeExecutor()
        let plan = Plan(steps: [
            .tool(name: "start_skillforge", args: ["goal": .string("convert currencies")], say: "On it.")
        ])
        let result = await executor.execute(plan, originalInput: "time in london", pendingSlotName: nil)

        XCTAssertEqual(result.executedToolSteps.count, 1,
                      "start_skillforge should execute directly")
        XCTAssertEqual(result.executedToolSteps.first?.name, "start_skillforge")
        XCTAssertEqual(mock.executedActions.count, 1,
                      "MockToolsRuntime should be called once")
        XCTAssertNil(result.pendingSlotRequest)
        XCTAssertFalse(result.stoppedAtAsk)
        XCTAssertFalse(result.triggerFollowUpCapture)
    }

    func testForgeToolExecutesForLearnInputWithoutSlot() async {
        let (executor, mock) = makeExecutor()
        let plan = Plan(steps: [
            .tool(name: "start_skillforge", args: ["goal": .string("convert currencies")], say: "On it.")
        ])
        let result = await executor.execute(plan, originalInput: "learn to convert currencies", pendingSlotName: nil)

        XCTAssertEqual(result.executedToolSteps.count, 1,
                      "start_skillforge should execute without requiring a learn slot")
        XCTAssertEqual(mock.executedActions.count, 1)
        XCTAssertNil(result.pendingSlotRequest)
        XCTAssertFalse(result.stoppedAtAsk)
    }

    func testForgeClearAllowedWithoutLearnSlot() async {
        let (executor, mock) = makeExecutor()
        let plan = Plan(steps: [
            .tool(name: "forge_queue_clear", args: [:], say: "Clearing.")
        ])
        let result = await executor.execute(plan, originalInput: "hello", pendingSlotName: nil)

        XCTAssertFalse(result.executedToolSteps.isEmpty,
                      "forge_queue_clear should execute immediately without learn slot")
        XCTAssertEqual(result.executedToolSteps.first?.name, "forge_queue_clear")
        XCTAssertEqual(mock.executedActions.count, 1)
        XCTAssertEqual(mock.executedActions.first?.name, "forge_queue_clear")
        XCTAssertNil(result.pendingSlotRequest)
        XCTAssertFalse(result.stoppedAtAsk)
    }

    func testForgeToolExecutesWhenPlanRequestsIt() async {
        let (executor, _) = makeExecutor()
        let plan = Plan(steps: [
            .tool(name: "start_skillforge", args: ["goal": .string("weather")], say: "Learning.")
        ])
        let result = await executor.execute(plan, originalInput: "what is the weather today", pendingSlotName: nil)

        XCTAssertEqual(result.executedToolSteps.count, 1)
        XCTAssertNil(result.pendingSlotRequest)
        XCTAssertFalse(result.stoppedAtAsk)
    }

    // MARK: - Also works with legacy learn/batch slots

    func testForgeToolAllowedWithLearnConfirmSlot() async {
        let (executor, mock) = makeExecutor()
        let plan = Plan(steps: [
            .tool(name: "start_skillforge", args: ["goal": .string("convert currencies")], say: "On it.")
        ])
        let result = await executor.execute(plan, originalInput: "yes", pendingSlotName: "learn_confirm")

        XCTAssertFalse(result.executedToolSteps.isEmpty,
                       "start_skillforge should execute with learn_confirm slot")
        XCTAssertEqual(result.executedToolSteps[0].name, "start_skillforge")
        XCTAssertEqual(mock.executedActions.count, 1)
        XCTAssertEqual(mock.executedActions[0].name, "start_skillforge")
        XCTAssertFalse(result.stoppedAtAsk)
    }

    func testForgeToolAllowedWithBatchConfirmSlot() async {
        let (executor, mock) = makeExecutor()
        let plan = Plan(steps: [
            .tool(name: "start_skillforge", args: ["goal": .string("batch job")], say: "On it.")
        ])
        let result = await executor.execute(plan, originalInput: "yes do it", pendingSlotName: "batch_confirm")

        XCTAssertFalse(result.executedToolSteps.isEmpty,
                       "start_skillforge should execute with batch_confirm slot")
        XCTAssertEqual(mock.executedActions.count, 1)
        XCTAssertFalse(result.stoppedAtAsk)
    }

    // MARK: - Read-only forge tools (not blocked)

    func testForgeQueueStatusNotBlocked() async {
        let (executor, mock) = makeExecutor()
        let plan = Plan(steps: [
            .tool(name: "forge_queue_status", args: [:], say: "Checking.")
        ])
        let result = await executor.execute(plan, originalInput: "what's happening", pendingSlotName: nil)

        XCTAssertFalse(result.executedToolSteps.isEmpty,
                       "forge_queue_status is read-only and should execute")
        XCTAssertEqual(mock.executedActions.count, 1)
        XCTAssertEqual(mock.executedActions[0].name, "forge_queue_status")
    }

    // MARK: - Non-forge tools (never blocked)

    func testNonForgeToolNotBlocked() async {
        let (executor, mock) = makeExecutor()
        let plan = Plan(steps: [
            .tool(name: "get_time", args: ["place": .string("London")], say: "Checking.")
        ])
        let result = await executor.execute(plan, originalInput: "time in london", pendingSlotName: nil)

        XCTAssertFalse(result.executedToolSteps.isEmpty,
                       "get_time should execute normally")
        XCTAssertEqual(result.executedToolSteps[0].name, "get_time")
        XCTAssertEqual(mock.executedActions.count, 1)
    }

    // MARK: - Response shape

    func testForgeResponseHasExecutedStepWithoutPrompting() async {
        let (executor, _) = makeExecutor()
        let plan = Plan(steps: [
            .tool(name: "start_skillforge", args: ["goal": .string("x")], say: nil)
        ])
        let result = await executor.execute(plan, originalInput: "hello", pendingSlotName: nil)

        XCTAssertEqual(result.executedToolSteps.count, 1)
        XCTAssertNil(result.pendingSlotRequest)
        XCTAssertFalse(result.stoppedAtAsk)
        XCTAssertFalse(result.triggerFollowUpCapture)
    }
}

// MARK: - PlanExecutor Unknown Tool Gate Tests

final class UnknownToolGateRuntime: ToolsRuntimeProtocol {
    private let knownTools: Set<String>
    private(set) var executedActions: [ToolAction] = []

    init(knownTools: Set<String>) {
        self.knownTools = knownTools
    }

    func toolExists(_ name: String) -> Bool {
        knownTools.contains(name)
    }

    func execute(_ toolAction: ToolAction) -> OutputItem? {
        executedActions.append(toolAction)
        return OutputItem(kind: .markdown, payload: "{\"spoken\":\"result\",\"formatted\":\"result\"}")
    }
}

@MainActor
final class PlanExecutorUnknownToolGateTests: XCTestCase {

    func testUnknownToolNeverExecutes() async {
        let runtime = UnknownToolGateRuntime(knownTools: ["get_time", "show_text"])
        let executor = PlanExecutor(toolsRuntime: runtime)
        let plan = Plan(steps: [
            .tool(name: "time_in_london", args: [:], say: "Checking...")
        ])
        let result = await executor.execute(plan, originalInput: "time in london")

        // Unknown tool should NOT be in executedActions (the runtime execute should never be called)
        let executedToolNames = runtime.executedActions.map(\.name)
        XCTAssertFalse(executedToolNames.contains("time_in_london"),
                       "Unknown tool 'time_in_london' must never execute")
        // Should route to capability gap
        XCTAssertTrue(result.executedToolSteps.contains(where: { $0.name == "capability_gap" }),
                      "Unknown tool should route to capability gap")
        XCTAssertTrue(result.chatMessages.contains(where: { $0.text.contains("don't have") }),
                      "Should inform user about missing tool")
    }

    func testKnownToolExecutesNormally() async {
        let runtime = UnknownToolGateRuntime(knownTools: ["get_time", "show_text"])
        let executor = PlanExecutor(toolsRuntime: runtime)
        let plan = Plan(steps: [
            .tool(name: "get_time", args: ["place": .string("London")], say: "Checking...")
        ])
        let result = await executor.execute(plan, originalInput: "time in london")

        let executedToolNames = runtime.executedActions.map(\.name)
        XCTAssertTrue(executedToolNames.contains("get_time"),
                      "Known tool should execute normally")
        XCTAssertFalse(result.executedToolSteps.contains(where: { $0.name == "capability_gap" }),
                       "Known tool should not route to capability gap")
    }
}

// MARK: - PlanExecutor Structured Payload Speech Priority Tests

@MainActor
final class PlanExecutorSpeechPriorityTests: XCTestCase {

    private func makeExecutor() -> (PlanExecutor, MockToolsRuntime) {
        let mock = MockToolsRuntime()
        let executor = PlanExecutor(toolsRuntime: mock)
        return (executor, mock)
    }

    func testToolStepsAreSilent() async {
        let (executor, _) = makeExecutor()
        let plan = Plan(steps: [
            .tool(name: "get_time", args: ["place": .string("Sydney")], say: "Let me check the time in Sydney.")
        ])
        let result = await executor.execute(plan, originalInput: "what time is it in sydney")

        // MockToolsRuntime returns {"spoken":"mock result","formatted":"mock"}.
        // Tool-step say must stay silent; only the tool result is user-visible.
        XCTAssertEqual(result.spokenLines.count, 1, "Tool step say should be silent")
        XCTAssertEqual(result.spokenLines.first, "mock result")
        XCTAssertEqual(result.chatMessages.count, 1)
        XCTAssertEqual(result.chatMessages.first?.text, "mock result")
        XCTAssertEqual(result.outputItems.first?.kind, .markdown,
                       "Structured formatted should still go to output canvas")
    }

    func testTopLevelToolSayIsSpokenOnce() async {
        let (executor, _) = makeExecutor()
        let plan = Plan(
            steps: [.tool(name: "get_time", args: ["place": .string("Sydney")], say: nil)],
            say: "I'll check that."
        )
        let result = await executor.execute(plan, originalInput: "time in sydney")

        XCTAssertEqual(result.spokenLines, ["mock result"], "Speak-one-thing should prioritize tool output")
        XCTAssertEqual(result.chatMessages.map(\.text), ["I'll check that.", "mock result"])
        XCTAssertEqual(result.outputItems.count, 1, "Tool output should still be shown on canvas")
    }

    /// When a tool step has no `say`, Sam speaks only the tool result.
    func testStructuredSpokenUsedWhenNoStepSay() async {
        let (executor, _) = makeExecutor()
        let plan = Plan(steps: [
            .tool(name: "get_time", args: ["place": .string("London")], say: nil)
        ])
        let result = await executor.execute(plan, originalInput: "time in london")

        XCTAssertEqual(result.spokenLines.count, 1, "Should have 1 spoken line: tool result only")
        XCTAssertEqual(result.spokenLines.first, "mock result",
                       "Without step say, structured spoken should be used")
        XCTAssertEqual(result.chatMessages.first?.text, "mock result")
        XCTAssertEqual(result.outputItems.first?.kind, .markdown)
    }

    func testTimeInLondonToolIsSpoken_NoFiller() async {
        let runtime = DeterministicTimeToolsRuntime()
        let executor = PlanExecutor(toolsRuntime: runtime)
        let plan = Plan(steps: [
            .tool(name: "get_time", args: ["location": .string("London")], say: nil)
        ])

        let result = await executor.execute(plan, originalInput: "What's the time in London?")

        XCTAssertEqual(runtime.executedActions.count, 1, "Expected get_time tool to run once")
        XCTAssertEqual(runtime.executedActions.first?.name, "get_time")
        XCTAssertEqual(runtime.executedActions.first?.args["location"], "London")

        let chatJoined = result.chatMessages.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(chatJoined.contains("london"))
        XCTAssertTrue(chatJoined.contains("10:15"))

        let spokenJoined = result.spokenLines.joined(separator: " ").lowercased()
        XCTAssertTrue(spokenJoined.contains("london"))
        XCTAssertTrue(spokenJoined.contains("10:15"))
        XCTAssertFalse(spokenJoined.contains("anything else"))
        XCTAssertFalse(spokenJoined.contains("let me know if"))
        XCTAssertFalse(spokenJoined.contains("how else can i help"))
    }

    func testSpeakOneThing_ToolAndTalk() async {
        let (executor, _) = makeExecutor()
        let plan = Plan(steps: [
            .talk(say: "Let me check London time."),
            .tool(name: "get_time", args: ["place": .string("London")], say: nil)
        ])

        let result = await executor.execute(plan, originalInput: "What's the time in London?")

        XCTAssertEqual(result.spokenLines.count, 1, "Tool+talk should enqueue only one utterance")
        XCTAssertEqual(result.spokenLines.first, "mock result")
    }

    func testToolResultIsSpoken_NoAutoClose() async {
        let runtime = DeterministicTimeToolsRuntime()
        let executor = PlanExecutor(toolsRuntime: runtime)
        let plan = Plan(steps: [
            .tool(name: "get_time", args: ["location": .string("London")], say: nil)
        ])

        let result = await executor.execute(plan, originalInput: "What's the time in London?")
        let spoken = result.spokenLines.joined(separator: " ").lowercased()

        XCTAssertTrue(spoken.contains("london"))
        XCTAssertTrue(spoken.contains("10:15"))
        XCTAssertFalse(spoken.contains("anything else"))
        XCTAssertFalse(spoken.contains("let me know if"))
        XCTAssertFalse(spoken.contains("how else can i help"))
    }
}
