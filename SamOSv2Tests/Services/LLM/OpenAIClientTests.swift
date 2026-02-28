import XCTest
@testable import SamOSv2

final class OpenAIClientTests: XCTestCase {

    func testMissingAPIKeyThrows() async {
        let settings = MockSettingsStore()
        // No API key set
        let client = OpenAIClient(settings: settings)
        let request = LLMRequest(messages: [LLMMessage(role: "user", content: "Hello")])

        do {
            _ = try await client.complete(request)
            XCTFail("Should throw apiKeyMissing")
        } catch let error as LLMError {
            if case .apiKeyMissing = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyAPIKeyThrows() async {
        let settings = MockSettingsStore()
        settings.setString("", forKey: SettingsKey.openaiAPIKey)
        let client = OpenAIClient(settings: settings)
        let request = LLMRequest(messages: [LLMMessage(role: "user", content: "Hello")])

        do {
            _ = try await client.complete(request)
            XCTFail("Should throw apiKeyMissing")
        } catch let error as LLMError {
            if case .apiKeyMissing = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
