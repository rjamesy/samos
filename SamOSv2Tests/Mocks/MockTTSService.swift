import Foundation
@testable import SamOSv2

/// Mock TTS that tracks calls without producing audio.
final class MockTTSService: TTSServiceProtocol, @unchecked Sendable {
    var spokenTexts: [String] = []
    var stopCount = 0
    var isSpeaking = false

    func speak(text: String, mode: TTSMode) async {
        spokenTexts.append(text)
        isSpeaking = true
    }

    func stop() {
        stopCount += 1
        isSpeaking = false
    }
}
