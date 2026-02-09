import XCTest
import CryptoKit
@testable import SamOS

final class FaceProfileStoreTests: XCTestCase {

    private func makeTempURL(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceProfiles_\(UUID().uuidString)_\(suffix).enc")
    }

    private func makeKey(_ byte: UInt8) -> SymmetricKey {
        SymmetricKey(data: Data(repeating: byte, count: 32))
    }

    func testRoundTripSaveLoadEncryptedSnapshot() throws {
        let url = makeTempURL("roundtrip")
        let store = FaceProfileStore(fileURL: url, keyProvider: { self.makeKey(7) })

        let snapshot = FaceProfileStore.Snapshot(
            names: ["ryan": "Ryan"],
            prints: ["ryan": [Data([1, 2, 3, 4]), Data([5, 6, 7])]]
        )

        XCTAssertTrue(store.save(snapshot))

        let loaded = store.load()
        XCTAssertEqual(loaded.names["ryan"], "Ryan")
        XCTAssertEqual(loaded.prints["ryan"]?.count, 2)
        XCTAssertEqual(loaded.prints["ryan"]?.first, Data([1, 2, 3, 4]))

        let fileData = try Data(contentsOf: url)
        let fileText = String(data: fileData, encoding: .utf8) ?? ""
        XCTAssertFalse(fileText.contains("Ryan"), "Ciphertext file must not contain plaintext names")
    }

    func testLoadWithWrongKeyReturnsEmptySnapshot() {
        let url = makeTempURL("wrongkey")
        let writer = FaceProfileStore(fileURL: url, keyProvider: { self.makeKey(9) })
        let reader = FaceProfileStore(fileURL: url, keyProvider: { self.makeKey(10) })

        let snapshot = FaceProfileStore.Snapshot(
            names: ["ricky": "Ricky"],
            prints: ["ricky": [Data([9, 9, 9])]]
        )
        XCTAssertTrue(writer.save(snapshot))

        let loaded = reader.load()
        XCTAssertTrue(loaded.names.isEmpty)
        XCTAssertTrue(loaded.prints.isEmpty)
    }

    func testLoadMissingFileReturnsEmptySnapshot() {
        let url = makeTempURL("missing")
        let store = FaceProfileStore(fileURL: url, keyProvider: { self.makeKey(11) })

        let loaded = store.load()
        XCTAssertTrue(loaded.names.isEmpty)
        XCTAssertTrue(loaded.prints.isEmpty)
    }
}
