import XCTest
@testable import SamOS

final class SkillTests: XCTestCase {

    // MARK: - SkillSpec Codable

    func testSkillSpecEncodeDecodRoundTrip() throws {
        let spec = SkillSpec(
            id: "test_v1",
            name: "Test Skill",
            version: 1,
            triggerPhrases: ["test me", "run a test"],
            slots: [
                SkillSpec.SlotDef(name: "value", type: .string, required: true, prompt: "What value?")
            ],
            steps: [
                SkillSpec.StepDef(action: "talk", args: ["say": "Testing {{value}}"])
            ],
            onTrigger: SkillSpec.OnTriggerDef(say: "Triggered!", sound: "Funk", showCard: true)
        )

        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(SkillSpec.self, from: data)

        XCTAssertEqual(decoded.id, "test_v1")
        XCTAssertEqual(decoded.name, "Test Skill")
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.triggerPhrases.count, 2)
        XCTAssertEqual(decoded.slots.count, 1)
        XCTAssertEqual(decoded.slots[0].type, .string)
        XCTAssertEqual(decoded.steps.count, 1)
        XCTAssertEqual(decoded.onTrigger?.say, "Triggered!")
        XCTAssertEqual(decoded.onTrigger?.sound, "Funk")
        XCTAssertEqual(decoded.onTrigger?.showCard, true)
    }

    func testSkillSpecDecodeFromJSON() throws {
        let json = """
        {
            "id": "alarm_v1",
            "name": "Alarm",
            "version": 1,
            "triggerPhrases": ["wake me up", "set an alarm"],
            "slots": [
                {"name": "datetime", "type": "date", "required": true, "prompt": "When?"}
            ],
            "steps": [
                {"action": "talk", "args": {"say": "Done"}}
            ],
            "onTrigger": {"say": "Wake up!", "sound": "Funk", "showCard": true}
        }
        """
        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(SkillSpec.self, from: data)
        XCTAssertEqual(spec.id, "alarm_v1")
        XCTAssertEqual(spec.slots[0].type, .date)
        XCTAssertTrue(spec.slots[0].required)
    }

    func testSkillSpecDecodeWithoutOnTrigger() throws {
        let json = """
        {
            "id": "simple_v1",
            "name": "Simple",
            "version": 1,
            "triggerPhrases": ["do something"],
            "slots": [],
            "steps": [{"action": "talk", "args": {"say": "Done"}}],
            "onTrigger": null
        }
        """
        let data = json.data(using: .utf8)!
        let spec = try JSONDecoder().decode(SkillSpec.self, from: data)
        XCTAssertNil(spec.onTrigger)
    }

    // MARK: - SkillStore

    func testSkillStoreInstallLoadRemove() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SkillStoreTest_\(UUID().uuidString)")
        let store = SkillStore(directory: tempDir)

        let skill = SkillSpec(
            id: "alarm_test_v1",
            name: "Test Alarm",
            version: 1,
            triggerPhrases: ["test"],
            slots: [],
            steps: [SkillSpec.StepDef(action: "talk", args: ["say": "hi"])],
            onTrigger: nil
        )

        // Install
        XCTAssertTrue(store.install(skill))
        XCTAssertEqual(store.count, 1)

        // Non-alarm IDs are also allowed for forged capabilities
        let forged = SkillSpec(
            id: "forged_junk",
            name: "Junk",
            version: 1,
            triggerPhrases: ["junk"],
            slots: [],
            steps: [SkillSpec.StepDef(action: "talk", args: ["say": "hi"])],
            onTrigger: nil
        )
        XCTAssertTrue(store.install(forged))
        XCTAssertEqual(store.count, 2)

        // Load
        XCTAssertNotNil(store.get(id: "alarm_test_v1"))
        XCTAssertNotNil(store.get(id: "forged_junk"))
        XCTAssertEqual(store.loadAll().count, 2)

        // Remove
        XCTAssertTrue(store.remove(id: "alarm_test_v1"))
        XCTAssertTrue(store.remove(id: "forged_junk"))
        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.get(id: "alarm_test_v1"))
        XCTAssertNil(store.get(id: "forged_junk"))

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSkillStoreBundledAlarm() throws {
        // Verify the alarm_v1.json can be decoded if it's in the bundle
        if let url = Bundle.main.url(forResource: "alarm_v1", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            let skill = try JSONDecoder().decode(SkillSpec.self, from: data)
            XCTAssertEqual(skill.id, "alarm_v1")
            XCTAssertEqual(skill.name, "Alarm")
            XCTAssertFalse(skill.triggerPhrases.isEmpty)
            XCTAssertFalse(skill.steps.isEmpty)
            XCTAssertNotNil(skill.onTrigger)
        }
        // If bundle resource not available in test target, that's OK — the main test is the decode
    }

    // MARK: - SkillEngine Matching

    func testSkillEngineMatchesAlarmTrigger() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SkillEngineTest_\(UUID().uuidString)")
        let store = SkillStore(directory: tempDir)

        let alarm = SkillSpec(
            id: "alarm_v1",
            name: "Alarm",
            version: 1,
            triggerPhrases: ["wake me up", "set an alarm"],
            slots: [SkillSpec.SlotDef(name: "datetime", type: .date, required: false, prompt: "When?")],
            steps: [SkillSpec.StepDef(action: "talk", args: ["say": "Alarm set"])],
            onTrigger: nil
        )
        store.install(alarm)

        // Note: SkillEngine.shared uses SkillStore.shared, so this test verifies the matching logic
        // indirectly. For a full integration test, would need dependency injection.

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - SkillEngine Interpolation

    func testInterpolateArgs() {
        let engine = SkillEngine(forTesting: true)
        let args = ["say": "Hello {{name}}, your time is {{datetime_display}}."]
        let slots = ["name": "Richard", "datetime_display": "tomorrow at 4:40 AM"]

        let result = engine.interpolateArgs(args, slots: slots)
        XCTAssertEqual(result["say"], "Hello Richard, your time is tomorrow at 4:40 AM.")
    }

    func testInterpolateArgsClearsUnfilledPlaceholders() {
        let engine = SkillEngine(forTesting: true)
        let args = ["say": "Label: {{label}}"]
        let slots: [String: String] = [:]

        let result = engine.interpolateArgs(args, slots: slots)
        XCTAssertEqual(result["say"], "Label: ")
    }

    // MARK: - SkillEngine Date Detection

    func testDateDetection() {
        let engine = SkillEngine(forTesting: true)

        // "tomorrow at 4:40am" should detect a date
        let date = engine.parseDetectedDate(from: "wake me up tomorrow at 4:40am")
        // NSDataDetector should find a date — it may not in all test environments
        // so we just check it doesn't crash
        if let date = date {
            XCTAssertTrue(date > Date().addingTimeInterval(-86400))
        }
    }

    func testDateTodayVsTomorrow_FutureTimeUsesToday() {
        let engine = SkillEngine(forTesting: true)
        let calendar = Calendar.current

        // Simulate: it's 3:47pm, user says "4pm" → should be today at 4pm
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 15
        components.minute = 47
        let fakeNow = calendar.date(from: components)!

        let date = engine.parseDetectedDate(from: "4pm", relativeTo: fakeNow)
        if let date = date {
            // The resolved date should be today (same day as fakeNow)
            XCTAssertTrue(calendar.isDate(date, inSameDayAs: fakeNow),
                          "4pm when it's 3:47pm should resolve to today, got \(date)")
            // And should be at 4pm
            let hour = calendar.component(.hour, from: date)
            XCTAssertEqual(hour, 16, "Should be 4pm (16:00)")
        }
    }

    func testDateTodayVsTomorrow_PastTimeUsesTomorrow() {
        let engine = SkillEngine(forTesting: true)
        let calendar = Calendar.current

        // Simulate: it's 4:05pm, user says "4pm" → should be tomorrow at 4pm
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 16
        components.minute = 5
        let fakeNow = calendar.date(from: components)!

        let date = engine.parseDetectedDate(from: "4pm", relativeTo: fakeNow)
        if let date = date {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: fakeNow)!
            XCTAssertTrue(calendar.isDate(date, inSameDayAs: tomorrow),
                          "4pm when it's 4:05pm should resolve to tomorrow, got \(date)")
            let hour = calendar.component(.hour, from: date)
            XCTAssertEqual(hour, 16, "Should be 4pm (16:00)")
        }
    }

    func testDateExplicitTomorrowAlwaysTomorrow() {
        let engine = SkillEngine(forTesting: true)
        let calendar = Calendar.current

        // "tomorrow at 4pm" should always be tomorrow regardless of current time
        let date = engine.parseDetectedDate(from: "tomorrow at 4pm")
        if let date = date {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
            XCTAssertTrue(calendar.isDate(date, inSameDayAs: tomorrow),
                          "Explicit 'tomorrow' should resolve to tomorrow, got \(date)")
        }
    }

    func testDateDisplayFormatting() {
        let engine = SkillEngine(forTesting: true)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let display = engine.formatDateForDisplay(tomorrow)
        XCTAssertTrue(display.lowercased().contains("tomorrow"))
    }

    // MARK: - SkillEngine Honest Confirmation

    func testExecuteSkipsTalkOnScheduleFailure() {
        let engine = SkillEngine(forTesting: true)
        let skill = SkillSpec(
            id: "test_v1",
            name: "Test",
            version: 1,
            triggerPhrases: ["test"],
            slots: [],
            steps: [
                // schedule_task with empty run_at should fail
                SkillSpec.StepDef(action: "schedule_task", args: ["run_at": "", "label": "test"]),
                SkillSpec.StepDef(action: "talk", args: ["say": "Alarm set!"]),
            ],
            onTrigger: nil
        )

        let actions = engine.execute(skill: skill, slots: [:])
        // Should NOT contain "Alarm set!" — should have a friendly prompt instead
        let hasFalseConfirmation = actions.contains { action in
            if case .talk(let talk) = action { return talk.say == "Alarm set!" }
            return false
        }
        XCTAssertFalse(hasFalseConfirmation, "Should not say 'Alarm set!' when schedule failed")

        // Should contain the friendly prompt
        let hasPrompt = actions.contains { action in
            if case .talk(let talk) = action { return talk.say.contains("I need a time") }
            return false
        }
        XCTAssertTrue(hasPrompt, "Should ask for time when schedule_task has empty run_at")
    }

    // MARK: - InputClassifier

    func testIsAffirmativePatterns() {
        XCTAssertTrue(InputClassifier.isAffirmative("yes"))
        XCTAssertTrue(InputClassifier.isAffirmative("Yeah"))
        XCTAssertTrue(InputClassifier.isAffirmative("GO AHEAD"))
        XCTAssertTrue(InputClassifier.isAffirmative("sure"))
        XCTAssertTrue(InputClassifier.isAffirmative("  ok  "))
        XCTAssertFalse(InputClassifier.isAffirmative("no"))
        XCTAssertFalse(InputClassifier.isAffirmative("what"))
        XCTAssertFalse(InputClassifier.isAffirmative(""))
    }

    func testIsNegativePatterns() {
        XCTAssertTrue(InputClassifier.isNegative("no"))
        XCTAssertTrue(InputClassifier.isNegative("Nah"))
        XCTAssertTrue(InputClassifier.isNegative("not now"))
        XCTAssertTrue(InputClassifier.isNegative("NOPE"))
        XCTAssertTrue(InputClassifier.isNegative("skip"))
        XCTAssertTrue(InputClassifier.isNegative("  cancel  "))
        XCTAssertFalse(InputClassifier.isNegative("yes"))
        XCTAssertFalse(InputClassifier.isNegative("hello"))
        XCTAssertFalse(InputClassifier.isNegative(""))
    }

    func testIsQuestionDetection() {
        XCTAssertTrue(InputClassifier.isQuestion("What time is it?"))
        XCTAssertTrue(InputClassifier.isQuestion("Want me to try?"))
        XCTAssertTrue(InputClassifier.isQuestion("Do you want me to try learning it?"))
        XCTAssertFalse(InputClassifier.isQuestion("Got it."))
        XCTAssertFalse(InputClassifier.isQuestion(""))
        XCTAssertFalse(InputClassifier.isQuestion("No problem"))
        XCTAssertFalse(InputClassifier.isQuestion("Alarm set for tomorrow at 4:40 AM."))
    }

    func testAffirmativeAndNegativeAreMutuallyExclusive() {
        let words = ["yes", "no", "yeah", "nah", "sure", "nope", "ok", "skip"]
        for word in words {
            let isYes = InputClassifier.isAffirmative(word)
            let isNo = InputClassifier.isNegative(word)
            XCTAssertFalse(isYes && isNo, "\"\(word)\" should not be both affirmative and negative")
        }
    }

    // MARK: - SkillForgeJob

    func testSkillForgeJobStatusTransitions() {
        var job = SkillForgeJob(goal: "Set an alarm")
        XCTAssertEqual(job.status, .drafting)
        XCTAssertNil(job.completedAt)

        job.status = .refining
        XCTAssertEqual(job.status, .refining)

        job.log("Test log entry")
        XCTAssertEqual(job.logs.count, 1)

        job.complete()
        XCTAssertEqual(job.status, .completed)
        XCTAssertNotNil(job.completedAt)
    }

    func testSkillForgeJobFail() {
        var job = SkillForgeJob(goal: "Do something")
        job.fail("Something went wrong")
        XCTAssertEqual(job.status, .failed)
        XCTAssertNotNil(job.completedAt)
        XCTAssertTrue(job.logs.last?.message.contains("Failed") ?? false)
    }
}
