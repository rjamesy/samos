import XCTest
@testable import SamOS

final class TimezoneTests: XCTestCase {

    // MARK: - Timezone Mapping

    func testTimezoneMappingAlabama() {
        XCTAssertEqual(TimezoneMapping.lookup("Alabama"), "America/Chicago")
    }

    func testTimezoneMappingCalifornia() {
        XCTAssertEqual(TimezoneMapping.lookup("California"), "America/Los_Angeles")
    }

    func testTimezoneMappingHawaii() {
        XCTAssertEqual(TimezoneMapping.lookup("Hawaii"), "Pacific/Honolulu")
    }

    func testTimezoneMappingAbbreviation() {
        XCTAssertEqual(TimezoneMapping.lookup("tx"), "America/Chicago")
    }

    func testTimezoneMappingCaseInsensitive() {
        XCTAssertEqual(TimezoneMapping.lookup("NEW YORK"), "America/New_York")
    }

    func testTimezoneMappingUnknown() {
        XCTAssertNil(TimezoneMapping.lookup("Atlantis"))
    }

    func testContainsStateName() {
        XCTAssertTrue(TimezoneMapping.containsStateName("what time is it in california"))
        XCTAssertFalse(TimezoneMapping.containsStateName("what time is it in london"))
    }

    // MARK: - GetTimeTool Timezone

    func testGetTimeToolWithTimezone() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["timezone": "America/Chicago"])
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed!.spoken.hasPrefix("It's "))
    }

    func testGetTimeToolWithInvalidTimezone() {
        let tool = GetTimeTool()
        let result = tool.execute(args: ["timezone": "Invalid/Zone"])
        // Should fall back to local time
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed, "Invalid timezone should still produce structured payload")
    }

    func testGetTimeToolWithoutTimezone() {
        let tool = GetTimeTool()
        let result = tool.execute(args: [:])
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed)
    }

    // MARK: - International City Resolution

    func testGetTimeLondonResolvesToEuropeLondon() {
        XCTAssertEqual(TimezoneMapping.lookup("London"), "Europe/London")
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "London"])
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed, "London should resolve to a time, not a clarification prompt")
        XCTAssertTrue(parsed!.spoken.hasPrefix("It's "))
        XCTAssertTrue(parsed!.spoken.lowercased().contains("london"),
                      "Spoken time should preserve place context for downstream reasoning")
    }

    func testGetTimeTokyoResolvesToAsiaTokyo() {
        XCTAssertEqual(TimezoneMapping.lookup("Tokyo"), "Asia/Tokyo")
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "Tokyo"])
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed, "Tokyo should resolve to a time, not a clarification prompt")
    }

    func testGetTimeParisResolvesToEuropeParis() {
        XCTAssertEqual(TimezoneMapping.lookup("Paris"), "Europe/Paris")
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "Paris"])
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed, "Paris should resolve to a time, not a clarification prompt")
    }

    func testGetTimeSydneyResolvesToAustraliaSydney() {
        XCTAssertEqual(TimezoneMapping.lookup("Sydney"), "Australia/Sydney")
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "Sydney"])
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed, "Sydney should resolve to a time, not a clarification prompt")
    }

    func testTimeQuestionNeverAsksForUSStateForNonUSCities() {
        let tool = GetTimeTool()
        let cities = ["London", "Tokyo", "Paris", "Sydney", "Berlin", "Dubai", "Singapore"]
        for city in cities {
            let result = tool.execute(args: ["place": city])
            let prompt = GetTimeTool.parsePromptPayload(result.payload)
            XCTAssertNil(prompt, "\(city) should NOT trigger a clarification prompt")
        }
    }

    func testGetTimeInternationalCityCaseInsensitive() {
        XCTAssertEqual(TimezoneMapping.lookup("LONDON"), "Europe/London")
        XCTAssertEqual(TimezoneMapping.lookup("tokyo"), "Asia/Tokyo")
        XCTAssertEqual(TimezoneMapping.lookup("Hong Kong"), "Asia/Hong_Kong")
    }

    func testUSStatesStillWork() {
        // Verify adding international cities didn't break US states
        let tool = GetTimeTool()
        let result = tool.execute(args: ["place": "Alabama"])
        let parsed = GetTimeTool.parsePayload(result.payload)
        XCTAssertNotNil(parsed, "US states should still resolve")
    }
}
