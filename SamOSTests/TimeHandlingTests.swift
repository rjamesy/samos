import XCTest
@testable import SamOS

final class TimeHandlingTests: XCTestCase {

    // MARK: - Structured Payload

    func testGetTimeToolReturnsAllFields() {
        let tool = GetTimeTool()
        let result = tool.execute(args: [:])
        let parsed = GetTimeTool.parsePayload(result.payload)

        XCTAssertNotNil(parsed, "Payload must be parseable JSON")
        guard let p = parsed else { return }

        XCTAssertTrue(p.spoken.hasPrefix("It's "), "spoken should start with 'It's ', got: \(p.spoken)")
        XCTAssertTrue(p.spoken.hasSuffix("."), "spoken should end with period")
        XCTAssertFalse(p.formatted.isEmpty, "formatted should not be empty")
        XCTAssertTrue(p.timestamp > 0, "timestamp should be positive")
    }

    func testSpokenContainsTimeComponents() {
        let tool = GetTimeTool()
        let result = tool.execute(args: [:])
        let parsed = GetTimeTool.parsePayload(result.payload)!

        // spoken should contain AM or PM
        let upper = parsed.spoken.uppercased()
        XCTAssertTrue(upper.contains("AM") || upper.contains("PM"),
                       "spoken should contain AM or PM, got: \(parsed.spoken)")
    }

    func testFormattedContainsCurrentYear() {
        let tool = GetTimeTool()
        let result = tool.execute(args: [:])
        let parsed = GetTimeTool.parsePayload(result.payload)!

        let year = Calendar.current.component(.year, from: Date())
        XCTAssertTrue(parsed.formatted.contains(String(year)),
                       "formatted should contain current year, got: \(parsed.formatted)")
    }

    // MARK: - Injectable Date

    func testInjectableDateProvider() {
        var tool = GetTimeTool()
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 15
        comps.hour = 14; comps.minute = 30; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let fixedDate = Calendar.current.date(from: comps)!
        let expectedTimestamp = Int(fixedDate.timeIntervalSince1970)
        tool.dateProvider = { fixedDate }

        let result = tool.execute(args: ["timezone": "UTC"])
        let parsed = GetTimeTool.parsePayload(result.payload)

        XCTAssertNotNil(parsed)
        guard let p = parsed else { return }

        XCTAssertEqual(p.timestamp, expectedTimestamp, "timestamp should match injected date")
        XCTAssertTrue(p.spoken.contains("2:30"), "spoken should show 2:30 for UTC, got: \(p.spoken)")
    }

    func testInjectableDateMatchesSystemDate() {
        let beforeDate = Date()
        let tool = GetTimeTool()
        let result = tool.execute(args: [:])
        let afterDate = Date()

        let parsed = GetTimeTool.parsePayload(result.payload)!
        let toolDate = Date(timeIntervalSince1970: Double(parsed.timestamp))

        XCTAssertTrue(toolDate >= beforeDate.addingTimeInterval(-1),
                       "Tool date should not be before test start")
        XCTAssertTrue(toolDate <= afterDate.addingTimeInterval(1),
                       "Tool date should not be after test end")
    }

    // MARK: - Timezone

    func testLocalTimezoneIsNotUTC() {
        let localTz = TimeZone.current
        guard localTz.identifier != "UTC" && localTz.abbreviation() != "UTC" else { return }

        var toolLocal = GetTimeTool()
        var toolUTC = GetTimeTool()

        let fixed = Date()
        toolLocal.dateProvider = { fixed }
        toolUTC.dateProvider = { fixed }

        let localResult = toolLocal.execute(args: [:])
        let utcResult = toolUTC.execute(args: ["timezone": "UTC"])

        let localParsed = GetTimeTool.parsePayload(localResult.payload)!
        let utcParsed = GetTimeTool.parsePayload(utcResult.payload)!

        XCTAssertEqual(localParsed.timestamp, utcParsed.timestamp)
        if localTz.secondsFromGMT() != 0 {
            XCTAssertNotEqual(localParsed.formatted, utcParsed.formatted,
                              "Local and UTC formatted times should differ")
        }
    }

    func testTimezoneArgApplied() {
        var tool = GetTimeTool()
        var tzComps = DateComponents()
        tzComps.year = 2026; tzComps.month = 1; tzComps.day = 15
        tzComps.hour = 14; tzComps.minute = 30; tzComps.second = 0
        tzComps.timeZone = TimeZone(identifier: "UTC")
        let fixed = Calendar.current.date(from: tzComps)!
        tool.dateProvider = { fixed }

        let nyResult = tool.execute(args: ["timezone": "America/New_York"])
        let laResult = tool.execute(args: ["timezone": "America/Los_Angeles"])

        let nyParsed = GetTimeTool.parsePayload(nyResult.payload)!
        let laParsed = GetTimeTool.parsePayload(laResult.payload)!

        XCTAssertNotEqual(nyParsed.spoken, laParsed.spoken,
                          "NY and LA should show different times")
        XCTAssertEqual(nyParsed.timestamp, laParsed.timestamp)
    }

    // MARK: - Consecutive Calls Same Minute

    func testConsecutiveCallsReturnSameMinute() {
        var tool = GetTimeTool()
        let fixed = Date()
        tool.dateProvider = { fixed }

        let result1 = tool.execute(args: [:])
        let result2 = tool.execute(args: [:])

        let parsed1 = GetTimeTool.parsePayload(result1.payload)!
        let parsed2 = GetTimeTool.parsePayload(result2.payload)!

        XCTAssertEqual(parsed1.spoken, parsed2.spoken)
        XCTAssertEqual(parsed1.formatted, parsed2.formatted)
        XCTAssertEqual(parsed1.timestamp, parsed2.timestamp)
    }

    // MARK: - Structural Validation: TALK (no intent routing)

    func testNormalTalkPassesValidation() {
        let action = Action.talk(Talk(say: "Hey! What's up?"))
        XCTAssertNil(ActionValidator.validate(action),
                     "Normal TALK should pass validation")
    }

    func testShortHelpTalkPassesValidation() {
        let action = Action.talk(Talk(say: "Sure, I can help with that."))
        XCTAssertNil(ActionValidator.validate(action),
                     "Short help TALK should pass validation")
    }

    // MARK: - No Intent Routing (LLM drives tool choice)

    func testTimeClaimInTalkPassesValidation() {
        // TALK is always accepted — the LLM is a conversational assistant first.
        let action = Action.talk(Talk(say: "It's 10:30 AM right now."))
        XCTAssertNil(ActionValidator.validate(action),
                     "TALK with time claim should pass — TALK is always accepted")
    }

    func testSchedulerClaimInTalkIsNotIntercepted() {
        // The app does NOT intercept scheduler claims — the LLM uses schedule_task.
        let action = Action.talk(Talk(say: "Done! I've set a reminder for you."))
        XCTAssertNil(ActionValidator.validate(action),
                     "Scheduler claim in TALK must NOT be intercepted — LLM drives tool choice")
    }

    func testCancelClaimInTalkIsNotIntercepted() {
        let action = Action.talk(Talk(say: "I've cancelled the alarm."))
        XCTAssertNil(ActionValidator.validate(action),
                     "Cancel claim in TALK must NOT be intercepted — LLM drives tool choice")
    }

    func testLongTalkIsNotAutoConverted() {
        // Long TALK should NOT be auto-converted to show_text — that's the app deciding tool choice.
        let longSay = String(repeating: "Cook the chicken in a large pot with spices. ", count: 12)
        let action = Action.talk(Talk(say: longSay))
        XCTAssertNil(ActionValidator.validate(action),
                     "Long TALK must NOT be auto-converted to show_text — LLM drives tool choice")
    }

    // MARK: - Truth Guardrail: False Canvas Confirmation

    func testCanvasClaimInTalkPassesValidation() {
        // TALK is always accepted — no false-confirmation guardrail.
        let action = Action.talk(Talk(say: "Here's a recipe for butter chicken!"))
        XCTAssertNil(ActionValidator.validate(action),
                     "TALK is always accepted")
    }

    func testImageClaimInTalkPassesValidation() {
        let action = Action.talk(Talk(say: "Here's a picture of a frog."))
        XCTAssertNil(ActionValidator.validate(action),
                     "TALK is always accepted")
    }

    func testShowYouClaimInTalkPassesValidation() {
        let action = Action.talk(Talk(say: "Let me show you what I found."))
        XCTAssertNil(ActionValidator.validate(action),
                     "TALK is always accepted")
    }

    func testAnyTalkPassesValidation() {
        let action = Action.talk(Talk(say: "Here's a recipe for you!"))
        XCTAssertNil(ActionValidator.validate(action),
                     "TALK is always accepted")
    }

    // MARK: - Structural Validation: TOOL args

    func testMissingScheduleArgsFailsValidation() {
        let action = Action.tool(ToolAction(name: "schedule_task", args: [:], say: "Setting alarm"))
        let failure = ActionValidator.validate(action)
        XCTAssertNotNil(failure, "Missing run_at should fail validation")
        XCTAssertTrue(failure!.reasons[0].contains("run_at"),
                      "Reason should mention missing run_at")
    }

    func testValidScheduleArgsPassValidation() {
        let action = Action.tool(ToolAction(
            name: "schedule_task",
            args: ["run_at": "1738825380", "label": "test"],
            say: "Setting alarm"
        ))
        XCTAssertNil(ActionValidator.validate(action),
                     "Valid schedule_task should pass validation")
    }

    func testCancelWithoutIdPassesValidation() {
        let action = Action.tool(ToolAction(name: "cancel_task", args: [:], say: "Cancelling"))
        XCTAssertNil(ActionValidator.validate(action),
                     "cancel_task without id should pass — tool lists pending tasks")
    }

    func testMissingImageUrlFailsValidation() {
        let action = Action.tool(ToolAction(name: "show_image", args: [:], say: "Here"))
        let failure = ActionValidator.validate(action)
        XCTAssertNotNil(failure, "Missing url should fail validation")
        XCTAssertTrue(failure!.reasons[0].contains("url"),
                      "Reason should mention missing url")
    }

    func testInvalidImageUrlFailsValidation() {
        let action = Action.tool(ToolAction(name: "show_image", args: ["url": "not-a-url"], say: "Here"))
        let failure = ActionValidator.validate(action)
        XCTAssertNotNil(failure, "Invalid URL should fail validation")
    }

    func testNonHttpImageUrlFailsValidation() {
        let action = Action.tool(ToolAction(name: "show_image", args: ["url": "ftp://example.com/img.jpg"], say: nil))
        let failure = ActionValidator.validate(action)
        XCTAssertNotNil(failure, "Non-http URL should fail validation")
    }

    func testValidShowImagePassesValidation() {
        let action = Action.tool(ToolAction(
            name: "show_image",
            args: ["url": "https://example.com/image.jpg", "alt": "A frog"],
            say: "Here you go"
        ))
        XCTAssertNil(ActionValidator.validate(action),
                     "Valid show_image should pass validation")
    }

    func testEmptyShowTextFailsValidation() {
        let action = Action.tool(ToolAction(name: "show_text", args: ["markdown": ""], say: nil))
        let failure = ActionValidator.validate(action)
        XCTAssertNotNil(failure, "Empty markdown should fail validation")
    }

    func testValidShowTextPassesValidation() {
        let action = Action.tool(ToolAction(
            name: "show_text",
            args: ["markdown": "# Recipe\nStep 1: Preheat oven."],
            say: "Here you go"
        ))
        XCTAssertNil(ActionValidator.validate(action),
                     "Valid show_text should pass validation")
    }

    func testEmptySaveMemoryFailsValidation() {
        let action = Action.tool(ToolAction(name: "save_memory", args: ["content": "  "], say: nil))
        let failure = ActionValidator.validate(action)
        XCTAssertNotNil(failure, "Empty save_memory content should fail validation")
    }

    func testGetTimePassesValidation() {
        let action = Action.tool(ToolAction(name: "get_time", args: [:], say: nil))
        XCTAssertNil(ActionValidator.validate(action),
                     "get_time should pass validation")
    }

    func testDelegateOpenAIPassesValidation() {
        let action = Action.delegateOpenAI(DelegateOpenAI(task: "test", say: nil))
        XCTAssertNil(ActionValidator.validate(action),
                     "DELEGATE_OPENAI should pass validation")
    }

    func testCapabilityGapPassesValidation() {
        let action = Action.capabilityGap(CapabilityGap(goal: "test", missing: "test", say: nil))
        XCTAssertNil(ActionValidator.validate(action),
                     "CAPABILITY_GAP should pass validation")
    }

    // MARK: - Pending Clarification Injection

    func testBuildMessagesIncludesPendingSlot() {
        let router = OllamaRouter()
        let slot = PendingSlot(
            slotName: "timezone",
            prompt: "Which state?",
            originalUserText: "What time is it in America?"
        )
        let messages = router.buildMessages(
            input: "Alabama",
            history: [],
            systemPrompt: "test prompt",
            pendingSlot: slot
        )

        // Should have: system prompt + pending slot system block + [REMINDER] + user message
        XCTAssertEqual(messages.count, 4)

        let slotMsg = messages[1]
        XCTAssertEqual(slotMsg["role"], "system")
        XCTAssertTrue(slotMsg["content"]!.contains("PENDING_SLOT"),
                       "Should contain pending slot block")
        XCTAssertTrue(slotMsg["content"]!.contains("What time is it in America?"),
                       "Should contain original user text")
        XCTAssertTrue(slotMsg["content"]!.contains("Which state?"),
                       "Should contain Sam's prompt")
        XCTAssertTrue(slotMsg["content"]!.contains("Alabama"),
                       "Should contain user's reply")
    }

    func testBuildMessagesWithoutPendingSlot() {
        let router = OllamaRouter()
        let messages = router.buildMessages(
            input: "Hello",
            history: [],
            systemPrompt: "test prompt",
            pendingSlot: nil
        )

        // Should have: system prompt + [REMINDER] + user message
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[2]["role"], "user")
    }

    // MARK: - parsePayload

    func testParsePayloadValid() {
        let json = """
        {"spoken":"It's 5:03 PM.","formatted":"Friday, 6 February 2026 at 5:03 pm","timestamp":1738825380}
        """
        let parsed = GetTimeTool.parsePayload(json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.spoken, "It's 5:03 PM.")
        XCTAssertEqual(parsed?.timestamp, 1738825380)
    }

    func testParsePayloadInvalidJSON() {
        XCTAssertNil(GetTimeTool.parsePayload("not json"))
    }

    func testParsePayloadMissingField() {
        let json = """
        {"spoken":"It's 5:03 PM.","formatted":"Friday"}
        """
        XCTAssertNil(GetTimeTool.parsePayload(json), "Missing timestamp should return nil")
    }

    // MARK: - Place-Based Resolution

    func testGetTimeWithPlaceAlabama() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "Alabama"])
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed, "Alabama should resolve to a time payload")
        XCTAssertTrue(parsed!.spoken.hasPrefix("It's "))
    }

    func testGetTimeWithPlaceNewYork() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "New York"])
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed, "New York should resolve to a time payload")
    }

    func testGetTimeWithPlaceCaseInsensitive() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "CALIFORNIA"])
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed, "CALIFORNIA should resolve to a time payload")
    }

    // MARK: - Ambiguous Region → Prompt Payload

    func testGetTimeWithAmbiguousAmerica() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "America"])
        let prompt = GetTimeTool.parsePromptPayload(result.payload)
        XCTAssertNotNil(prompt, "America should return a prompt payload")
        XCTAssertEqual(prompt?.slot, "timezone")
        XCTAssertTrue(prompt!.spoken.contains("state") || prompt!.spoken.contains("city"),
                      "Prompt should ask for state or city, got: \(prompt!.spoken)")
    }

    func testGetTimeWithAmbiguousUSA() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "USA"])
        let prompt = GetTimeTool.parsePromptPayload(result.payload)
        XCTAssertNotNil(prompt, "USA should return a prompt payload")
        XCTAssertEqual(prompt?.slot, "timezone")
    }

    func testGetTimeWithAmbiguousUnitedStates() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "United States"])
        let prompt = GetTimeTool.parsePromptPayload(result.payload)
        XCTAssertNotNil(prompt, "United States should return a prompt payload")
    }

    func testGetTimeWithAmbiguousUS() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "US"])
        let prompt = GetTimeTool.parsePromptPayload(result.payload)
        XCTAssertNotNil(prompt, "US should return a prompt payload")
    }

    func testGetTimeWithUnknownPlace() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "Narnia"])
        let prompt = GetTimeTool.parsePromptPayload(result.payload)
        XCTAssertNotNil(prompt, "Unknown place should return a prompt payload")
        XCTAssertTrue(prompt!.spoken.contains("Narnia"),
                      "Prompt should mention the unknown place")
    }

    func testGetTimeTimezoneArgTakesPriority() {
        // timezone arg takes priority over place
        var tool = GetTimeTool()
        let fixed = Date()
        tool.dateProvider = { fixed }

        let result = tool.execute(args: ["timezone": "America/New_York", "place": "California"])
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed, "timezone arg should take priority and return time payload")
    }

    func testGetTimePromptPayloadIsNotTimeParseable() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "America"])
        // Prompt payload should NOT parse as time payload
        XCTAssertNil(GetTimeTool.parsePayload(result.payload),
                     "Prompt payload must not parse as time payload")
    }

    // MARK: - Time Claim Guardrail

    func testTimeClaimWithPMFails() {
        XCTAssertTrue(ActionValidator.containsTimeClaim("It's 9:06 pm."))
    }

    func testTimeClaimWithAMFails() {
        XCTAssertTrue(ActionValidator.containsTimeClaim("The time is 10:30 AM right now."))
    }

    func testTimeClaimWithoutSpaceFails() {
        XCTAssertTrue(ActionValidator.containsTimeClaim("It's 9:06pm."))
    }

    func testNoTimeClaimInNormalText() {
        XCTAssertFalse(ActionValidator.containsTimeClaim("Sure, I can help with that!"))
    }

    func testNoTimeClaimInGreeting() {
        XCTAssertFalse(ActionValidator.containsTimeClaim("Hey there, what's up?"))
    }

    func testTimePlanStepTalkPasses() {
        // TALK plan steps are always accepted.
        let step = PlanStep.talk(say: "It's 3:45 PM right now.")
        XCTAssertNil(ActionValidator.validatePlanStep(step),
                     "TALK plan step is always accepted")
    }
}
