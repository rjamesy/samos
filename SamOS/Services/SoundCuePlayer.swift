import AVFoundation

/// Plays short sound cues for UX feedback (e.g., capture start beep).
/// Non-blocking, safe on @MainActor, handles missing assets gracefully.
@MainActor
final class SoundCuePlayer {

    static let shared = SoundCuePlayer()

    private var player: AVAudioPlayer?

    private init() {}

    /// Plays the capture-start beep if the setting is enabled and the asset exists.
    func playCaptureBeep() {
        guard M2Settings.captureBeepEnabled else { return }

        guard let url = Bundle.main.url(forResource: "capture_beep", withExtension: "wav") else {
            print("[SoundCuePlayer] capture_beep.wav not found in bundle")
            return
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.volume = 0.6
            newPlayer.prepareToPlay()
            newPlayer.play()
            // Hold a strong reference until playback finishes
            player = newPlayer
        } catch {
            print("[SoundCuePlayer] Failed to play capture beep: \(error.localizedDescription)")
        }
    }
}
