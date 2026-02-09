import AVFoundation
import AppKit

/// Helper for microphone permission status and requests.
enum MicrophonePermission {

    enum Status {
        case granted
        case denied
        case undetermined
    }

    static var currentStatus: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    /// Requests microphone permission only when status is `.notDetermined`.
    /// Returns `true` if access is (or was already) granted, `false` otherwise.
    /// Never re-prompts if already authorized or denied.
    static func request() async -> Bool {
        switch currentStatus {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    /// Opens System Settings to the Privacy & Security > Microphone pane.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Helper for camera permission status and requests.
enum CameraPermission {

    enum Status {
        case granted
        case denied
        case undetermined
    }

    static var currentStatus: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    /// Requests camera permission only when status is `.notDetermined`.
    /// Returns `true` if access is (or was already) granted.
    static func request() async -> Bool {
        switch currentStatus {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        }
    }

    /// Opens System Settings to the Privacy & Security > Camera pane.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}
