import Foundation

/// Settings backed by UserDefaults. Production implementation.
final class UserDefaultsSettingsStore: SettingsStoreProtocol, @unchecked Sendable {
    private let defaults = UserDefaults.standard

    // Defaults for bool keys that should default to true
    private let defaultTrueKeys: Set<String> = [
        SettingsKey.elevenlabsStreaming,
        SettingsKey.debugLatency,
        SettingsKey.engineCognitiveTrace,
        SettingsKey.engineWorldModel,
        SettingsKey.engineCuriosity,
        SettingsKey.engineLongitudinal,
        SettingsKey.engineBehavior,
        SettingsKey.engineTheoryOfMind,
        SettingsKey.engineMetacognition,
        SettingsKey.enginePersonality,
        SettingsKey.engineSkillEvolution,
    ]

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func setString(_ value: String?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func bool(forKey key: String) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultTrueKeys.contains(key)
        }
        return defaults.bool(forKey: key)
    }

    func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func double(forKey key: String) -> Double {
        let val = defaults.double(forKey: key)
        if val == 0 {
            switch key {
            case SettingsKey.porcupineSensitivity:
                return AppConfig.defaultWakeWordSensitivity
            case SettingsKey.followUpTimeoutS:
                return AppConfig.defaultFollowUpTimeout
            default:
                return 0
            }
        }
        return val
    }

    func setDouble(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func hasValue(forKey key: String) -> Bool {
        defaults.object(forKey: key) != nil
    }
}
