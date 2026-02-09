import Foundation
import CryptoKit
import Security

/// Encrypted persistence for local face profile feature-print payloads.
/// The encryption key is stored in Keychain; the ciphertext is stored in Application Support.
final class FaceProfileStore {
    struct Snapshot {
        let names: [String: String]
        let prints: [String: [Data]]
    }

    static let shared = FaceProfileStore()

    private struct StoredPayload: Codable {
        let version: Int
        let names: [String: String]
        let prints: [String: [Data]]
    }

    private static let keychainService = "com.samos.faceprofiles"
    private static let keychainAccount = "encryptionKeyV1"
    private static let payloadVersion = 1

    private let fileURL: URL
    private let keyProvider: () -> SymmetricKey?

    init(fileURL: URL? = nil, keyProvider: (() -> SymmetricKey?)? = nil) {
        self.fileURL = fileURL ?? FaceProfileStore.defaultFileURL()
        self.keyProvider = keyProvider ?? { FaceProfileStore.loadOrCreateKey() }
    }

    func load() -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Snapshot(names: [:], prints: [:])
        }
        guard let key = keyProvider(),
              let encrypted = try? Data(contentsOf: fileURL),
              let sealed = try? AES.GCM.SealedBox(combined: encrypted),
              let decrypted = try? AES.GCM.open(sealed, using: key),
              let payload = try? JSONDecoder().decode(StoredPayload.self, from: decrypted),
              payload.version == Self.payloadVersion else {
            return Snapshot(names: [:], prints: [:])
        }

        return Snapshot(names: payload.names, prints: payload.prints)
    }

    @discardableResult
    func save(_ snapshot: Snapshot) -> Bool {
        guard let key = keyProvider() else { return false }
        let payload = StoredPayload(version: Self.payloadVersion, names: snapshot.names, prints: snapshot.prints)
        guard let encoded = try? JSONEncoder().encode(payload),
              let sealed = try? AES.GCM.seal(encoded, using: key).combined else {
            return false
        }

        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try sealed.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("SamOS", isDirectory: true)
            .appendingPathComponent("face_profiles.enc", isDirectory: false)
    }

    private static func loadOrCreateKey() -> SymmetricKey? {
        if let existing = KeychainStore.get(forKey: keychainAccount, service: keychainService),
           let data = Data(base64Encoded: existing),
           data.count == 32 {
            return SymmetricKey(data: data)
        }

        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { bytes -> Int32 in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }
        guard status == errSecSuccess else { return nil }

        let b64 = data.base64EncodedString()
        guard KeychainStore.set(b64, forKey: keychainAccount, service: keychainService) else {
            return nil
        }
        return SymmetricKey(data: data)
    }
}
