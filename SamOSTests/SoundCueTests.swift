import XCTest
@testable import SamOS

final class SoundCueTests: XCTestCase {

    // MARK: - Settings

    func testCaptureBeepDefaultsToTrue() {
        // Remove any stored value to test the default
        let key = "m2_captureBeepEnabled"
        let hadValue = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            // Restore original value
            if let had = hadValue {
                UserDefaults.standard.set(had, forKey: key)
            }
        }

        XCTAssertTrue(M2Settings.captureBeepEnabled)
    }

    func testCaptureBeepPersistence() {
        let original = M2Settings.captureBeepEnabled

        M2Settings.captureBeepEnabled = false
        XCTAssertFalse(M2Settings.captureBeepEnabled)

        M2Settings.captureBeepEnabled = true
        XCTAssertTrue(M2Settings.captureBeepEnabled)

        // Restore
        M2Settings.captureBeepEnabled = original
    }

    // MARK: - SoundCuePlayer Safety

    @MainActor
    func testPlayCaptureBeepWithMissingAssetDoesNotCrash() {
        // This tests that calling playCaptureBeep() is safe even if the asset
        // is missing or we're in a test environment. It should simply no-op.
        // The fact that this test completes without crashing is the assertion.
        SoundCuePlayer.shared.playCaptureBeep()
    }

    @MainActor
    func testPlayCaptureBeepRespectsDisabledSetting() {
        let original = M2Settings.captureBeepEnabled
        defer { M2Settings.captureBeepEnabled = original }

        M2Settings.captureBeepEnabled = false
        // Should be a no-op when disabled — no crash
        SoundCuePlayer.shared.playCaptureBeep()
    }
}
