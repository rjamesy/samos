import Foundation
import AppKit

@MainActor
final class CameraHealthMonitor {
    static let shared = CameraHealthMonitor()

    private let camera: CameraVisionProviding
    private var timer: Timer?
    private var recoveryAttempts: Int = 0
    private let maxRetries = 3
    private let staleFrameThresholdSeconds: TimeInterval = 1.5

    var onCameraLost: (() -> Void)?
    var onCameraRecovered: (() -> Void)?
    var onCameraDisabled: (() -> Void)?

    init(camera: CameraVisionProviding = CameraVisionService.shared) {
        self.camera = camera
    }

    func startMonitoring() {
        stopMonitoring()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHealth()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func resetRetryCount() {
        recoveryAttempts = 0
    }

    private func checkHealth() {
        guard camera.isRunning else { return }

        let isStale: Bool
        if let lastFrame = camera.latestFrameAt {
            isStale = Date().timeIntervalSince(lastFrame) > staleFrameThresholdSeconds
        } else {
            isStale = true
        }

        if isStale || !camera.health.isHealthy {
            let reason = isStale ? "stale_frame" : "unhealthy"
            attemptRecovery(reason: reason)
        }
    }

    private func attemptRecovery(reason: String) {
        recoveryAttempts += 1

        if recoveryAttempts > maxRetries {
            camera.stop()
            onCameraDisabled?()
            #if DEBUG
            print("[MEDIA_RECOVERY] kind=camera status=disabled_after_3_retries")
            #endif
            return
        }

        #if DEBUG
        print("[MEDIA_RECOVERY] kind=camera reason=\(reason) attempt=\(recoveryAttempts)")
        #endif

        onCameraLost?()
        camera.stop()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                try camera.start()
                recoveryAttempts = 0
                onCameraRecovered?()
            } catch {
                #if DEBUG
                print("[MEDIA_RECOVERY] kind=camera recovery_failed error=\(error.localizedDescription)")
                #endif
            }
        }
    }
}
