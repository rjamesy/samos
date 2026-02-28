import Foundation

/// Protocol for speech-to-text services.
protocol STTServiceProtocol: Sendable {
    func transcribe(audioURL: URL) async throws -> String
}
