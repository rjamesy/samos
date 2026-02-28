import XCTest
@testable import SamOSv2

final class EngineIntegrationTests: XCTestCase {

    private func makeContext(_ message: String) -> EngineTurnContext {
        EngineTurnContext(
            userText: message,
            assistantText: "",
            sessionId: "test"
        )
    }

    // MARK: - CognitiveTrace

    func testCognitiveTraceDetectsMultiPart() async throws {
        let engine = CognitiveTraceEngine()
        let result = try await engine.run(context: makeContext("What is A? And what about B?"))
        XCTAssertTrue(result.contains("Multi-part"))
    }

    func testCognitiveTraceDetectsComparative() async throws {
        let engine = CognitiveTraceEngine()
        let result = try await engine.run(context: makeContext("Is Python better than JavaScript?"))
        XCTAssertTrue(result.contains("Comparative"))
    }

    func testCognitiveTraceEmptyForSimple() async throws {
        let engine = CognitiveTraceEngine()
        let result = try await engine.run(context: makeContext("Hello"))
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - MetaCognition

    func testMetaCognitionDetectsDoubt() async throws {
        let engine = MetaCognitionEngine()
        let result = try await engine.run(context: makeContext("Are you sure about that?"))
        XCTAssertTrue(result.contains("questioning accuracy"))
    }

    func testMetaCognitionDetectsRealtimeQuery() async throws {
        let engine = MetaCognitionEngine()
        let result = try await engine.run(context: makeContext("What is the latest news?"))
        XCTAssertTrue(result.contains("recent/real-time"))
    }

    // MARK: - TheoryOfMind

    func testTheoryOfMindDetectsFrustration() async throws {
        let engine = TheoryOfMindEngine()
        let result = try await engine.run(context: makeContext("This doesn't work and I tried everything"))
        XCTAssertTrue(result.contains("frustrated"))
    }

    func testTheoryOfMindDetectsUrgency() async throws {
        let engine = TheoryOfMindEngine()
        let result = try await engine.run(context: makeContext("I need this right now please"))
        XCTAssertTrue(result.contains("Urgency"))
    }

    // MARK: - Counterfactual

    func testCounterfactualDetectsDecision() async throws {
        let engine = CounterfactualEngine()
        let result = try await engine.run(context: makeContext("Should I switch to Swift or stay with Python?"))
        XCTAssertTrue(result.contains("Decision"))
    }

    func testCounterfactualDetectsHypothetical() async throws {
        let engine = CounterfactualEngine()
        let result = try await engine.run(context: makeContext("What if I moved to Japan?"))
        XCTAssertTrue(result.contains("hypothetical"))
    }

    // MARK: - ActiveCuriosity

    func testCuriosityDetectsUncertainty() async throws {
        let engine = ActiveCuriosityEngine()
        let result = try await engine.run(context: makeContext("I think maybe this is wrong, not sure"))
        XCTAssertTrue(result.contains("uncertainty"))
    }
}
