import Foundation

/// Voice pipeline states.
enum VoicePipelineState: String, Sendable {
    case idle
    case wakeWordDetected
    case capturing
    case processing
    case routing
    case speaking
    case followUp
}

/// State machine for the voice pipeline:
/// Idle -> WakeWordDetected -> Capturing -> Processing -> Routing -> Speaking -> FollowUp -> Idle
@MainActor
@Observable
final class VoicePipeline {
    private(set) var state: VoicePipelineState = .idle
    private let settings: any SettingsStoreProtocol

    private var followUpTimer: Task<Void, Never>?

    init(settings: any SettingsStoreProtocol) {
        self.settings = settings
    }

    // MARK: - State Transitions

    func onWakeWordDetected() {
        guard state == .idle || state == .followUp else { return }
        state = .wakeWordDetected
        transitionTo(.capturing)
    }

    func onCaptureComplete(audioURL: URL) {
        guard state == .capturing else { return }
        transitionTo(.processing)
    }

    func onTranscriptionComplete(text: String) {
        guard state == .processing else { return }
        transitionTo(.routing)
    }

    func onRoutingComplete() {
        guard state == .routing else { return }
        transitionTo(.speaking)
    }

    func onSpeechComplete() {
        guard state == .speaking else { return }
        startFollowUpTimer()
    }

    func onBargeIn() {
        // Any state -> interrupt -> reset
        followUpTimer?.cancel()
        state = .idle
    }

    func reset() {
        followUpTimer?.cancel()
        state = .idle
    }

    // MARK: - Private

    private func transitionTo(_ newState: VoicePipelineState) {
        state = newState
    }

    private func startFollowUpTimer() {
        state = .followUp
        followUpTimer?.cancel()

        let timeout = settings.double(forKey: SettingsKey.followUpTimeoutS)
        let effectiveTimeout = timeout > 0 ? timeout : AppConfig.defaultFollowUpTimeout

        followUpTimer = Task {
            try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
            if !Task.isCancelled {
                await MainActor.run {
                    if self.state == .followUp {
                        self.state = .idle
                    }
                }
            }
        }
    }
}
