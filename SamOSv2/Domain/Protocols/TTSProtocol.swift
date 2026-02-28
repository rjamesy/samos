import Foundation

/// Speech synthesis mode.
enum TTSMode: Sendable {
    case normal
    case interrupt
    case queue
}

/// Protocol for text-to-speech services.
protocol TTSServiceProtocol: Sendable {
    func speak(text: String, mode: TTSMode) async
    func stop()
    var isSpeaking: Bool { get }
}
