import XCTest
@testable import SamOSv2

final class ChatMessageTests: XCTestCase {

    func testUserMessageDefaults() {
        let msg = ChatMessage(role: .user, text: "Hello")
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.text, "Hello")
        XCTAssertNil(msg.latencyMs)
        XCTAssertNil(msg.provider)
        XCTAssertFalse(msg.isEphemeral)
        XCTAssertFalse(msg.usedMemory)
    }

    func testAssistantMessageWithLatency() {
        let msg = ChatMessage(role: .assistant, text: "Hi!", latencyMs: 150, provider: "openai")
        XCTAssertEqual(msg.latencyMs, 150)
        XCTAssertEqual(msg.provider, "openai")
    }

    func testMessageCodable() throws {
        let original = ChatMessage(role: .user, text: "Test")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.text, decoded.text)
        XCTAssertEqual(original.role, decoded.role)
    }

    func testMessageEquality() {
        let id = UUID()
        let ts = Date()
        let a = ChatMessage(id: id, ts: ts, role: .user, text: "Hello")
        let b = ChatMessage(id: id, ts: ts, role: .user, text: "Hello")
        XCTAssertEqual(a, b)
    }
}
