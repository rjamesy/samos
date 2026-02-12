import XCTest
@testable import SamOS

@MainActor
final class SpeechCoordinatorTests: XCTestCase {

    func testSelectSpokenLinesPrefersToolWhenToolOutputPresent() {
        let coordinator = SpeechCoordinator()
        let entries = [
            SpeechLineEntry(text: "Talk fallback", source: .talk),
            SpeechLineEntry(text: "Tool answer", source: .tool)
        ]

        let selected = coordinator.selectSpokenLines(
            entries: entries,
            toolProducedUserFacingOutput: true,
            maxSpeakChars: 500
        )

        XCTAssertEqual(selected, ["Tool answer"])
    }

    func testSelectSpokenLinesSkipsTemplateTalkTokens() {
        let coordinator = SpeechCoordinator()
        let entries = [
            SpeechLineEntry(text: "Normal answer", source: .talk),
            SpeechLineEntry(text: "I need {slot_name}", source: .talk)
        ]

        let selected = coordinator.selectSpokenLines(
            entries: entries,
            toolProducedUserFacingOutput: false,
            maxSpeakChars: 500
        )

        XCTAssertEqual(selected, ["Normal answer"])
    }

    func testSelectSpokenLinesAppliesLengthCapWithSummarySuffix() {
        let coordinator = SpeechCoordinator()
        let longText = String(repeating: "a", count: 180)

        let selected = coordinator.selectSpokenLines(
            entries: [SpeechLineEntry(text: longText, source: .talk)],
            toolProducedUserFacingOutput: false,
            maxSpeakChars: 10
        )

        let line = selected.first ?? ""
        XCTAssertTrue(line.contains("I've shown the full details on screen."))
        XCTAssertLessThan(line.count, longText.count)
    }

    func testThinkingFillerEmitsOncePerTurnAndResetsOnBeginTurn() {
        let coordinator = SpeechCoordinator()

        coordinator.beginTurn()
        let first = coordinator.consumeThinkingFillerIfAllowed(
            isTTSSpeaking: false,
            isCapturing: false,
            enforceStrictPhases: false,
            isRoutingPhase: false
        )
        let second = coordinator.consumeThinkingFillerIfAllowed(
            isTTSSpeaking: false,
            isCapturing: false,
            enforceStrictPhases: false,
            isRoutingPhase: false
        )

        coordinator.beginTurn()
        let third = coordinator.consumeThinkingFillerIfAllowed(
            isTTSSpeaking: false,
            isCapturing: false,
            enforceStrictPhases: false,
            isRoutingPhase: false
        )

        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertNotNil(third)
    }

    func testThinkingFillerSuppressedDuringStrictRoutingPhase() {
        let coordinator = SpeechCoordinator()
        coordinator.beginTurn()

        let filler = coordinator.consumeThinkingFillerIfAllowed(
            isTTSSpeaking: false,
            isCapturing: false,
            enforceStrictPhases: true,
            isRoutingPhase: true
        )

        XCTAssertNil(filler)
    }

    func testSlowStartTrackingRecordAndClear() {
        let coordinator = SpeechCoordinator()

        coordinator.recordSlowStart(correlationID: "turn_42")
        XCTAssertEqual(coordinator.lastSlowStartCorrelationID, "turn_42")

        coordinator.clearSlowStartTracking()
        XCTAssertNil(coordinator.lastSlowStartCorrelationID)
    }
}
