import Foundation

/// DEBUG-only secret storage using UserDefaults.
/// Avoids all Keychain access (and password prompts) during development.
/// In RELEASE builds this class exists but is never called.
final class DevSecretsStore {
    static let shared = DevSecretsStore()
    private let defaults = UserDefaults.standard

    func get(_ key: String) -> String? {
        let v = defaults.string(forKey: key)
        return (v?.isEmpty == false) ? v : nil
    }

    func set(_ key: String, _ value: String) {
        defaults.set(value, forKey: key)
    }

    func delete(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}
