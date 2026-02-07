import XCTest
@testable import SamOS

final class MockRouterTests: XCTestCase {

    var router: MockRouter!

    override func setUp() {
        super.setUp()
        router = MockRouter()
    }

    // MARK: - Greetings → TALK

    func testHelloReturnsTalk() {
        let action = router.route("hello")
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk for 'hello'")
        }
        XCTAssert(talk.say.lowercased().contains("hello"))
    }

    func testHiReturnsTalk() {
        let action = router.route("hi there")
        guard case .talk = action else {
            return XCTFail("Expected .talk for 'hi there'")
        }
    }

    func testHeyReturnsTalk() {
        let action = router.route("hey")
        guard case .talk = action else {
            return XCTFail("Expected .talk for 'hey'")
        }
    }

    // MARK: - Image Requests → TOOL (show_image)

    func testPictureReturnsTool() {
        let action = router.route("show me a picture of a frog")
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool for image request")
        }
        XCTAssertEqual(tool.name, "show_image")
        XCTAssertNotNil(tool.args["url"])
        XCTAssertNotNil(tool.args["alt"])
    }

    func testImageReturnsTool() {
        let action = router.route("show me an image of a cat")
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool for image request")
        }
        XCTAssertEqual(tool.name, "show_image")
        XCTAssert(tool.args["url"]?.contains("Cat") == true || tool.args["alt"]?.contains("cat") == true)
    }

    func testPhotoReturnsTool() {
        let action = router.route("photo of a dog please")
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool for photo request")
        }
        XCTAssertEqual(tool.name, "show_image")
    }

    func testShowMeReturnsTool() {
        let action = router.route("show me something cool")
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool for 'show me'")
        }
        XCTAssertEqual(tool.name, "show_image")
    }

    // MARK: - Recipe Requests → TALK (confirmation prompt)

    func testRecipeReturnsConfirmation() {
        let action = router.route("butter chicken recipe")
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk confirmation for recipe")
        }
        XCTAssert(talk.say.lowercased().contains("recipe") || talk.say.lowercased().contains("butter chicken"))
    }

    func testRecipeConfirmationYes() {
        _ = router.route("butter chicken recipe") // triggers confirmation state
        let action = router.route("yes")
        guard case .tool(let tool) = action else {
            return XCTFail("Expected .tool after confirming recipe")
        }
        XCTAssertEqual(tool.name, "show_text")
        XCTAssertNotNil(tool.args["markdown"])
    }

    func testRecipeConfirmationNo() {
        _ = router.route("give me a recipe")
        let action = router.route("no")
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk after declining")
        }
        XCTAssert(talk.say.lowercased().contains("no problem") || talk.say.lowercased().contains("let me know"))
    }

    // MARK: - Help → TALK

    func testHelpReturnsTalk() {
        let action = router.route("help me")
        guard case .talk(let talk) = action else {
            return XCTFail("Expected .talk for 'help'")
        }
        XCTAssert(talk.say.lowercased().contains("image") || talk.say.lowercased().contains("recipe"))
    }

    // MARK: - Unknown → CAPABILITY_GAP

    func testUnknownReturnsCapabilityGap() {
        let action = router.route("play some jazz music")
        guard case .capabilityGap(let gap) = action else {
            return XCTFail("Expected .capabilityGap for unknown input")
        }
        XCTAssertEqual(gap.goal, "play some jazz music")
        XCTAssertNotNil(gap.say)
    }

    func testRandomTextReturnsCapabilityGap() {
        let action = router.route("xyzzy plugh")
        guard case .capabilityGap = action else {
            return XCTFail("Expected .capabilityGap")
        }
    }

    // MARK: - Edge Cases

    func testEmptyInputTrimsAndReturnsCapabilityGap() {
        let action = router.route("   ")
        guard case .capabilityGap = action else {
            return XCTFail("Expected .capabilityGap for whitespace-only input")
        }
    }

    func testCaseInsensitivity() {
        let action = router.route("HELLO THERE")
        guard case .talk = action else {
            return XCTFail("Expected .talk for uppercase 'HELLO'")
        }
    }

    func testConfirmationStateResetsAfterResponse() {
        _ = router.route("recipe")  // enters confirmation state
        _ = router.route("yes")     // confirms and exits state
        let action = router.route("yes") // should NOT be treated as confirmation
        // Should route as unknown (no "yes" pattern match)
        guard case .capabilityGap = action else {
            return XCTFail("Expected .capabilityGap after state reset, got: \(action)")
        }
    }
}
