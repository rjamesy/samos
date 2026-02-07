import XCTest
@testable import SamOS

/// Tests for KeychainStore correctness, no-prompt attributes, and test isolation.
/// These tests use the test service to avoid touching production secrets.
final class KeychainStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KeychainStore._useTestService = true
    }

    override func tearDown() {
        // Clean up test keychain items
        KeychainStore.deleteAll(service: KeychainStore.testService)
        KeychainStore._useTestService = false
        super.tearDown()
    }

    // MARK: - No-Prompt Attributes

    func testNoAccessPromptAttributes() {
        // Verify that KeychainStore does NOT use forbidden attributes that cause prompts.
        // This is a structural test — we write an item and verify we can read it back
        // without error, which would fail if ACL or DataProtectionKeychain were set
        // (those cause -34018 in XCTest runner).
        let key = "test_no_prompt_\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key) }

        let writeSuccess = KeychainStore.set("test_value", forKey: key)
        XCTAssertTrue(writeSuccess, "Write should succeed without prompt attributes")

        let readValue = KeychainStore.get(forKey: key)
        XCTAssertEqual(readValue, "test_value", "Read should succeed without prompt attributes")
    }

    // MARK: - Update-First Strategy

    func testUpdateDoesNotReAddItem() {
        let key = "test_update_\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key) }

        // Initial write (SecItemAdd path)
        let added = KeychainStore.set("first", forKey: key)
        XCTAssertTrue(added)
        XCTAssertEqual(KeychainStore.get(forKey: key), "first")

        // Second write should use SecItemUpdate, not delete+re-add
        let updated = KeychainStore.set("second", forKey: key)
        XCTAssertTrue(updated)
        XCTAssertEqual(KeychainStore.get(forKey: key), "second")

        // Third write to confirm update path is stable
        let updated2 = KeychainStore.set("third", forKey: key)
        XCTAssertTrue(updated2)
        XCTAssertEqual(KeychainStore.get(forKey: key), "third")
    }

    // MARK: - Debug/Test Service Isolation

    func testDebugServiceIsolation() {
        // With _useTestService = true (set in setUp), writes to defaultService
        // should actually go to testService
        let key = "test_isolation_\(UUID().uuidString)"

        // Write via defaultService (redirected to testService)
        KeychainStore.set("isolated_value", forKey: key)
        XCTAssertEqual(KeychainStore.get(forKey: key), "isolated_value")

        // Temporarily disable test service to verify prod service is untouched
        KeychainStore._useTestService = false
        let prodValue = KeychainStore.get(forKey: key, service: KeychainStore.defaultService)
        KeychainStore._useTestService = true

        // The value should NOT be in the production service
        // (It could be nil, or could be some unrelated value — we just check
        // it's not our test value)
        XCTAssertNotEqual(prodValue, "isolated_value",
                          "Test writes must not leak to production keychain service")

        // Clean up
        KeychainStore.delete(forKey: key)
    }

    func testExplicitServiceNotRedirected() {
        // When an explicit service is passed, it should be used as-is
        // (only defaultService is redirected)
        let customService = "com.samos.custom.\(UUID().uuidString)"
        let key = "test_explicit_\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key, service: customService) }

        KeychainStore.set("custom_value", forKey: key, service: customService)
        let value = KeychainStore.get(forKey: key, service: customService)
        XCTAssertEqual(value, "custom_value")
    }

    // MARK: - Basic Operations (using test service)

    func testSetAndGet() {
        let key = "test_basic_\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key) }

        XCTAssertNil(KeychainStore.get(forKey: key))
        XCTAssertTrue(KeychainStore.set("value", forKey: key))
        XCTAssertEqual(KeychainStore.get(forKey: key), "value")
    }

    func testDeleteIdempotent() {
        let key = "test_delete_\(UUID().uuidString)"
        // Deleting a nonexistent key should succeed
        XCTAssertTrue(KeychainStore.delete(forKey: key))
    }

    func testDeleteAllCleansService() {
        let key1 = "test_da_1_\(UUID().uuidString)"
        let key2 = "test_da_2_\(UUID().uuidString)"

        KeychainStore.set("val1", forKey: key1)
        KeychainStore.set("val2", forKey: key2)
        XCTAssertNotNil(KeychainStore.get(forKey: key1))
        XCTAssertNotNil(KeychainStore.get(forKey: key2))

        KeychainStore.deleteAll(service: KeychainStore.testService)

        XCTAssertNil(KeychainStore.get(forKey: key1))
        XCTAssertNil(KeychainStore.get(forKey: key2))
    }
}
