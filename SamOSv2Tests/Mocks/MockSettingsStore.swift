import Foundation
@testable import SamOSv2

/// In-memory settings store for testing.
final class MockSettingsStore: SettingsStoreProtocol, @unchecked Sendable {
    private var strings: [String: String] = [:]
    private var bools: [String: Bool] = [:]
    private var doubles: [String: Double] = [:]

    func string(forKey key: String) -> String? {
        strings[key]
    }

    func setString(_ value: String?, forKey key: String) {
        strings[key] = value
    }

    func bool(forKey key: String) -> Bool {
        bools[key] ?? false
    }

    func setBool(_ value: Bool, forKey key: String) {
        bools[key] = value
    }

    func double(forKey key: String) -> Double {
        doubles[key] ?? 0
    }

    func setDouble(_ value: Double, forKey key: String) {
        doubles[key] = value
    }

    func hasValue(forKey key: String) -> Bool {
        strings[key] != nil || bools[key] != nil || doubles[key] != nil
    }
}
