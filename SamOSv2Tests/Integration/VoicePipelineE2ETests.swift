import XCTest
@testable import SamOSv2

final class VoicePipelineE2ETests: XCTestCase {

    @MainActor
    func testFullStateTransitionCycle() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        XCTAssertEqual(pipeline.state, .idle)

        // Idle → wakeWordDetected → capturing (auto-transition)
        pipeline.onWakeWordDetected()
        XCTAssertEqual(pipeline.state, .capturing)

        // capturing → processing
        pipeline.onCaptureComplete(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        XCTAssertEqual(pipeline.state, .processing)

        // processing → routing
        pipeline.onTranscriptionComplete(text: "Hello Sam")
        XCTAssertEqual(pipeline.state, .routing)

        // routing → speaking
        pipeline.onRoutingComplete()
        XCTAssertEqual(pipeline.state, .speaking)

        // speaking → followUp
        pipeline.onSpeechComplete()
        XCTAssertEqual(pipeline.state, .followUp)
    }

    @MainActor
    func testBargeInFromSpeaking() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        pipeline.onWakeWordDetected()
        pipeline.onCaptureComplete(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        pipeline.onTranscriptionComplete(text: "Hello")
        pipeline.onRoutingComplete()

        XCTAssertEqual(pipeline.state, .speaking)

        // Barge-in should reset to idle
        pipeline.onBargeIn()
        XCTAssertEqual(pipeline.state, .idle)
    }

    @MainActor
    func testBargeInFromFollowUp() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        pipeline.onWakeWordDetected()
        pipeline.onCaptureComplete(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        pipeline.onTranscriptionComplete(text: "Hello")
        pipeline.onRoutingComplete()
        pipeline.onSpeechComplete()

        XCTAssertEqual(pipeline.state, .followUp)

        pipeline.onBargeIn()
        XCTAssertEqual(pipeline.state, .idle)
    }

    @MainActor
    func testResetFromAnyState() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        pipeline.onWakeWordDetected()
        pipeline.onCaptureComplete(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        pipeline.onTranscriptionComplete(text: "Hello")

        XCTAssertEqual(pipeline.state, .routing)

        pipeline.reset()
        XCTAssertEqual(pipeline.state, .idle)
    }

    @MainActor
    func testFollowUpCanDetectWakeWord() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        pipeline.onWakeWordDetected()
        pipeline.onCaptureComplete(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        pipeline.onTranscriptionComplete(text: "Hello")
        pipeline.onRoutingComplete()
        pipeline.onSpeechComplete()

        XCTAssertEqual(pipeline.state, .followUp)

        // Follow-up state allows wake word detection (restarts cycle)
        pipeline.onWakeWordDetected()
        XCTAssertEqual(pipeline.state, .capturing)
    }
}
