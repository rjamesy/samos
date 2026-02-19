import Foundation

actor AudioLoadGovernor {
    static let shared = AudioLoadGovernor()

    private(set) var activeCapture = false
    private(set) var activeSTT = false
    private(set) var activeTTS = false

    var isOverloaded: Bool { activeCapture && activeSTT && activeTTS }

    /// Request activation for a work kind. Returns true after activation.
    /// If all 3 would be active, pauses the lowest-priority active kind first.
    /// Priority: STT > TTS > Capture (capture paused first, then TTS).
    @discardableResult
    func requestActivation(_ kind: AudioCoordinator.WorkKind) -> Bool {
        // Count how many would be active including the new one
        var wouldBeActive = [activeCapture, activeSTT, activeTTS].filter { $0 }.count
        if !isActive(kind) { wouldBeActive += 1 }

        if wouldBeActive >= 3 {
            // Pause lowest priority that isn't the one being activated
            let pauseTarget = lowestPriorityActive(excluding: kind)
            if let target = pauseTarget {
                setActive(target, value: false)
                #if DEBUG
                print("[AUDIO_GOVERNOR] paused=\(target.rawValue) reason=overload activating=\(kind.rawValue)")
                #endif
            }
        }

        setActive(kind, value: true)
        return true
    }

    func markDeactivated(_ kind: AudioCoordinator.WorkKind) {
        setActive(kind, value: false)
    }

    func _resetForTesting() {
        activeCapture = false
        activeSTT = false
        activeTTS = false
    }

    // MARK: - Private

    private func isActive(_ kind: AudioCoordinator.WorkKind) -> Bool {
        switch kind {
        case .capture: return activeCapture
        case .stt: return activeSTT
        case .tts: return activeTTS
        }
    }

    private func setActive(_ kind: AudioCoordinator.WorkKind, value: Bool) {
        switch kind {
        case .capture: activeCapture = value
        case .stt: activeSTT = value
        case .tts: activeTTS = value
        }
    }

    /// Returns the lowest-priority currently-active kind, excluding the specified kind.
    /// Priority order: capture (1) < tts (3) < stt (2)... wait, actual priorities:
    /// capture=1, stt=2, tts=3. Lowest priority = capture first, then stt.
    private func lowestPriorityActive(excluding kind: AudioCoordinator.WorkKind) -> AudioCoordinator.WorkKind? {
        let candidates: [AudioCoordinator.WorkKind] = [.capture, .stt, .tts]
        return candidates
            .filter { $0 != kind && isActive($0) }
            .sorted { $0.priority < $1.priority }
            .first
    }
}
