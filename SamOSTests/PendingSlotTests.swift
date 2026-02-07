import XCTest
@testable import SamOS

final class PendingSlotTests: XCTestCase {

    func testExpiresAfter10Minutes() {
        let past = Date().addingTimeInterval(-601)
        let slot = PendingSlot(
            createdAt: past,
            slotName: "time",
            prompt: "What time?",
            originalUserText: "Set an alarm"
        )
        XCTAssertTrue(slot.isExpired)
    }

    func testNotExpiredWhenFresh() {
        let slot = PendingSlot(
            slotName: "time",
            prompt: "What time?",
            originalUserText: "Set an alarm"
        )
        XCTAssertFalse(slot.isExpired)
    }

    func testExpiresAtIs10MinutesFromCreation() {
        let now = Date()
        let slot = PendingSlot(
            createdAt: now,
            slotName: "timezone",
            prompt: "Which state?",
            originalUserText: "What time is it in America?"
        )
        XCTAssertEqual(slot.expiresAt.timeIntervalSince(now), 600, accuracy: 1)
    }

    func testAttemptsStartAtZero() {
        let slot = PendingSlot(
            slotName: "task_id",
            prompt: "Which alarm?",
            originalUserText: "Cancel alarm"
        )
        XCTAssertEqual(slot.attempts, 0)
    }

    func testCustomTTL() {
        let now = Date()
        let slot = PendingSlot(
            createdAt: now,
            slotName: "learn_confirm",
            prompt: "Want me to learn?",
            originalUserText: "play music",
            ttl: 20
        )
        XCTAssertEqual(slot.expiresAt.timeIntervalSince(now), 20, accuracy: 1)
    }

    func testEquality() {
        let id = UUID()
        let date = Date()
        let a = PendingSlot(id: id, createdAt: date, slotName: "time", prompt: "When?", originalUserText: "alarm")
        let b = PendingSlot(id: id, createdAt: date, slotName: "time", prompt: "When?", originalUserText: "alarm")
        XCTAssertEqual(a, b)
    }

    func testInequalityDifferentId() {
        let date = Date()
        let a = PendingSlot(createdAt: date, slotName: "time", prompt: "When?", originalUserText: "alarm")
        let b = PendingSlot(createdAt: date, slotName: "time", prompt: "When?", originalUserText: "alarm")
        XCTAssertNotEqual(a, b) // different UUIDs
    }

    func testMutateAttempts() {
        var slot = PendingSlot(slotName: "time", prompt: "When?", originalUserText: "alarm")
        XCTAssertEqual(slot.attempts, 0)
        slot.attempts += 1
        XCTAssertEqual(slot.attempts, 1)
    }
}
