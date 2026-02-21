import XCTest
@testable import SamOS

final class OpenAIRouterTransportTests: XCTestCase {
    func testCompletionTokenParameterUsesMaxCompletionTokensForGPT5() {
        XCTAssertEqual(RealOpenAITransport.completionTokenParameter(for: "gpt-5.2"), "max_completion_tokens")
        XCTAssertEqual(RealOpenAITransport.completionTokenParameter(for: "GPT-5"), "max_completion_tokens")
    }

    func testCompletionTokenParameterUsesMaxTokensForLegacyModels() {
        XCTAssertEqual(RealOpenAITransport.completionTokenParameter(for: "gpt-4o-mini"), "max_tokens")
        XCTAssertEqual(RealOpenAITransport.completionTokenParameter(for: "gpt-4.1"), "max_tokens")
    }
}
