import Foundation
import Security

/// Lightweight Keychain wrapper for storing small secrets (API keys).
///
/// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` to avoid macOS login-keychain
/// password prompts. Items are only accessible after the first unlock, are device-local
/// (no iCloud sync), and have no user-presence or biometric requirement.
///
/// **Forbidden attributes** (cause password prompts on every launch or code-sign change):
/// - `kSecUseDataProtectionKeychain`
/// - `kSecAccessControl` (ACL)
/// - `kSecAttrAccessGroup`
///
/// DEV NOTE: If upgrading from a build that used any of the above,
/// delete old Keychain items once via Keychain Access.app or by calling
/// `KeychainStore.deleteAll(service:)` for each affected service.
///
/// In Debug builds, logs each access to verify caching is working.
enum KeychainStore {

    /// Default service identifier for SamOS keychain items.
    static let defaultService = "com.samos.app"

    /// Isolated service identifier for tests. Used automatically in DEBUG when
    /// `_useTestService` is true — ensures the XCTest runner never touches prod secrets.
    static let testService = "com.samos.test"

    /// When true (set by tests), all operations that use `defaultService` are
    /// redirected to `testService`. Does NOT affect explicit service parameters.
    static var _useTestService = false

    /// Resolves the effective service: redirects `defaultService` → `testService` when
    /// `_useTestService` is enabled.
    static func effectiveService(_ service: String) -> String {
        if _useTestService && service == defaultService {
            return testService
        }
        return service
    }

    /// When false, API keys are kept in memory only (no Keychain access at all).
    /// Default is true (recommended). Toggle in Settings if Keychain prompts persist.
    static var useKeychain: Bool {
        get {
            if UserDefaults.standard.object(forKey: "samos_useKeychain") == nil {
                #if DEBUG
                // In development, default to app-local secret storage to avoid Keychain prompts.
                return false
                #else
                return true
                #endif
            }
            return UserDefaults.standard.bool(forKey: "samos_useKeychain")
        }
        set { UserDefaults.standard.set(newValue, forKey: "samos_useKeychain") }
    }

    #if DEBUG
    /// Tracks how many times each key has been read from Keychain (Debug only).
    private(set) static var readCounts: [String: Int] = [:]
    #endif

    // MARK: - Core Attributes

    /// In-memory cache — avoids hitting Keychain more than once per key per launch.
    private static var cache: [String: String] = [:]

    private static func cacheKey(_ key: String, _ service: String) -> String {
        "\(effectiveService(service))/\(key)"
    }

    /// Base query attributes for a keychain item.
    /// Uses ONLY kSecClass, kSecAttrAccount, kSecAttrService, kSecAttrSynchronizable — no ACL,
    /// no access group, no data protection keychain flag.
    private static func baseQuery(key: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: effectiveService(service),
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }

    /// The accessibility level for all SamOS keychain items.
    /// `AfterFirstUnlockThisDeviceOnly`:
    ///  - Available after first unlock (no prompt on every read)
    ///  - Device-local (not synced via iCloud Keychain)
    ///  - No user-presence or biometric requirement
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    // MARK: - Write

    /// Saves a string value to the Keychain under the given key.
    /// Uses SecItemUpdate first; falls back to SecItemAdd if the item doesn't exist.
    @discardableResult
    static func set(_ value: String, forKey key: String, service: String = defaultService) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query = baseQuery(key: key, service: service)

        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]

        // Try update first (preserves ACL / "Always Allow" trust)
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            cache[cacheKey(key, service)] = value
            return true
        }

        // Item doesn't exist yet — add it
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessibility
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                cache[cacheKey(key, service)] = value
                return true
            }
            // If add fails due to duplicate (stale item with different attrs), delete and retry
            if addStatus == errSecDuplicateItem {
                SecItemDelete(query as CFDictionary)
                let retryStatus = SecItemAdd(addQuery as CFDictionary, nil)
                if retryStatus == errSecSuccess {
                    cache[cacheKey(key, service)] = value
                }
                return retryStatus == errSecSuccess
            }
            #if DEBUG
            print("[KeychainStore] add failed: \(addStatus)")
            #endif
            return false
        }

        #if DEBUG
        print("[KeychainStore] set failed: \(updateStatus)")
        #endif
        return false
    }

    // MARK: - Read

    /// Retrieves a string value from the Keychain for the given key.
    /// Serves from in-memory cache after the first read. Uses `kSecUseAuthenticationUIFail`
    /// to prevent macOS from ever showing a password prompt on the initial read.
    static func get(forKey key: String, service: String = defaultService) -> String? {
        let ck = cacheKey(key, service)

        // Serve from cache if already loaded
        if let cached = cache[ck] {
            #if DEBUG
            readCounts[ck, default: 0] += 1
            print("[KeychainStore] GET \(ck) (cached, read #\(readCounts[ck]!))")
            #endif
            return cached.isEmpty ? nil : cached
        }

        #if DEBUG
        readCounts[ck, default: 0] += 1
        print("[KeychainStore] GET \(ck) (keychain, read #\(readCounts[ck]!))")
        #endif

        var query = baseQuery(key: key, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            cache[ck] = value
            return value
        }

        #if DEBUG
        if status == errSecInteractionNotAllowed {
            print("[KeychainStore] WARNING: \(ck) requires UI auth — stale item? Delete and re-save.")
        }
        #endif

        // Cache the miss so we don't keep hitting Keychain
        cache[ck] = ""
        return nil
    }

    // MARK: - Delete

    /// Deletes a value from the Keychain for the given key.
    @discardableResult
    static func delete(forKey key: String, service: String = defaultService) -> Bool {
        cache.removeValue(forKey: cacheKey(key, service))
        let query = baseQuery(key: key, service: service)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Deletes ALL items for a given service. Useful for one-time migration cleanup.
    /// Loops until Keychain reports no more items (macOS SecItemDelete can be single-shot).
    @discardableResult
    static func deleteAll(service: String) -> Bool {
        // Clear cache entries for this service
        let prefix = effectiveService(service) + "/"
        cache = cache.filter { !$0.key.hasPrefix(prefix) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: effectiveService(service),
        ]
        var status = SecItemDelete(query as CFDictionary)
        // macOS may only delete one item per call — loop until empty
        while status == errSecSuccess {
            status = SecItemDelete(query as CFDictionary)
        }
        return status == errSecItemNotFound
    }
}
