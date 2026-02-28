import XCTest
@testable import SamOSv2

@MainActor
final class VoicePipelineTests: XCTestCase {

    func testInitialStateIsIdle() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        XCTAssertEqual(pipeline.state, .idle)
    }

    func testWakeWordTransitionToCapturing() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        pipeline.onWakeWordDetected()
        XCTAssertEqual(pipeline.state, .capturing)
    }

    func testCaptureCompleteTransitionsToProcessing() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        pipeline.onWakeWordDetected()
        pipeline.onCaptureComplete(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        XCTAssertEqual(pipeline.state, .processing)
    }

    func testTranscriptionTransitionsToRouting() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        pipeline.onWakeWordDetected()
        pipeline.onCaptureComplete(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        pipeline.onTranscriptionComplete(text: "Hello Sam")
        XCTAssertEqual(pipeline.state, .routing)
    }

    func testBargeInResetsToIdle() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        pipeline.onWakeWordDetected()
        pipeline.onBargeIn()
        XCTAssertEqual(pipeline.state, .idle)
    }

    func testResetFromAnyState() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        pipeline.onWakeWordDetected()
        pipeline.onCaptureComplete(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        pipeline.reset()
        XCTAssertEqual(pipeline.state, .idle)
    }

    func testInvalidTransitionIgnored() {
        let settings = MockSettingsStore()
        let pipeline = VoicePipeline(settings: settings)
        // Should not transition from idle to processing directly
        pipeline.onCaptureComplete(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        XCTAssertEqual(pipeline.state, .idle)
    }
}
