import XCTest
@testable import SamOS

final class ImageParsingTests: XCTestCase {

    // MARK: - JSON Payload Decoding (multi-URL format)

    func testDecodeMultiUrlPayload() {
        let json = """
        {"urls":["https://example.com/frog1.jpg","https://example.com/frog2.jpg"],"alt":"A green frog"}
        """
        let view = ImageOutputView(payload: json)
        let decoded = view.decodePayload()
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.resolvedUrls.count, 2)
        XCTAssertEqual(decoded?.resolvedUrls.first, "https://example.com/frog1.jpg")
        XCTAssertEqual(decoded?.alt, "A green frog")
    }

    func testDecodeSingleUrlPayload() {
        // Legacy single-url format still works
        let json = """
        {"url":"https://example.com/frog.jpg","alt":"A green frog"}
        """
        let view = ImageOutputView(payload: json)
        let decoded = view.decodePayload()
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.resolvedUrls.count, 1)
        XCTAssertEqual(decoded?.resolvedUrls.first, "https://example.com/frog.jpg")
        XCTAssertEqual(decoded?.alt, "A green frog")
    }

    func testDecodeImagePayloadWithParensInAlt() {
        let json = """
        {"urls":["https://example.com/frog.jpg"],"alt":"A European common frog (Rana esculenta)"}
        """
        let view = ImageOutputView(payload: json)
        let decoded = view.decodePayload()
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.alt, "A European common frog (Rana esculenta)")
    }

    func testDecodeImagePayloadNoAlt() {
        let json = """
        {"urls":["https://example.com/img.png"]}
        """
        let view = ImageOutputView(payload: json)
        let decoded = view.decodePayload()
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.resolvedUrls.first, "https://example.com/img.png")
        XCTAssertNil(decoded?.alt)
    }

    func testDecodeInvalidJSON() {
        let view = ImageOutputView(payload: "not json at all")
        XCTAssertNil(view.decodePayload())
    }

    func testDecodeEmptyPayload() {
        let view = ImageOutputView(payload: "")
        XCTAssertNil(view.decodePayload())
    }

    func testDecodeOldMarkdownPayloadFails() {
        let view = ImageOutputView(payload: "![alt](https://example.com/img.jpg)")
        XCTAssertNil(view.decodePayload())
    }

    func testResolvedUrlsPrefersUrlsOverUrl() {
        // When both fields present, urls takes priority
        let json = """
        {"url":"https://example.com/single.jpg","urls":["https://example.com/multi1.jpg","https://example.com/multi2.jpg"],"alt":"test"}
        """
        let view = ImageOutputView(payload: json)
        let decoded = view.decodePayload()
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.resolvedUrls.count, 2)
        XCTAssertEqual(decoded?.resolvedUrls.first, "https://example.com/multi1.jpg")
    }

    func testResolvedUrlsEmptyWhenNoUrls() {
        let json = """
        {"alt":"orphan alt"}
        """
        let view = ImageOutputView(payload: json)
        let decoded = view.decodePayload()
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded?.resolvedUrls.isEmpty ?? false)
    }

    // MARK: - ShowImageTool URL Validation

    func testValidDirectImageURL() {
        let tool = ShowImageTool()
        XCTAssertNil(tool.validateImageURL("https://upload.wikimedia.org/wikipedia/commons/thumb/e/ed/Frog.jpg/640px-Frog.jpg"))
    }

    func testValidPNGURL() {
        let tool = ShowImageTool()
        XCTAssertNil(tool.validateImageURL("https://example.com/image.png"))
    }

    func testValidGIFURL() {
        let tool = ShowImageTool()
        XCTAssertNil(tool.validateImageURL("https://example.com/anim.gif"))
    }

    func testValidWebPURL() {
        let tool = ShowImageTool()
        XCTAssertNil(tool.validateImageURL("https://example.com/photo.webp"))
    }

    func testRejectWikiPageURL() {
        let tool = ShowImageTool()
        let error = tool.validateImageURL("https://commons.wikimedia.org/wiki/File:European_frog.jpg")
        XCTAssertNotNil(error)
        XCTAssert(error!.contains("wiki page"))
    }

    func testRejectEmptyURL() {
        let tool = ShowImageTool()
        let error = tool.validateImageURL("")
        XCTAssertNotNil(error)
    }

    func testRejectNonImageExtension() {
        let tool = ShowImageTool()
        let error = tool.validateImageURL("https://example.com/document.pdf")
        XCTAssertNotNil(error)
        XCTAssert(error!.contains("pdf"))
    }

    func testAcceptURLWithoutExtension() {
        let tool = ShowImageTool()
        XCTAssertNil(tool.validateImageURL("https://images.unsplash.com/photo-12345"))
    }

    func testRejectFtpURL() {
        let tool = ShowImageTool()
        let error = tool.validateImageURL("ftp://example.com/image.jpg")
        XCTAssertNotNil(error)
        XCTAssert(error!.contains("http"))
    }

    // MARK: - ShowImageTool Execute (multi-URL)

    func testExecuteWithSingleUrl() {
        let tool = ShowImageTool()
        let output = tool.execute(args: ["url": "https://example.com/frog.jpg", "alt": "A frog"])
        XCTAssertEqual(output.kind, .image)
        let decoded = try? JSONDecoder().decode(ImagePayload.self, from: output.payload.data(using: .utf8)!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.resolvedUrls.first, "https://example.com/frog.jpg")
        XCTAssertEqual(decoded?.alt, "A frog")
    }

    func testExecuteWithPipeSeparatedUrls() {
        let tool = ShowImageTool()
        let output = tool.execute(args: [
            "urls": "https://example.com/frog1.jpg|https://example.com/frog2.jpg|https://example.com/frog3.jpg",
            "alt": "A frog"
        ])
        XCTAssertEqual(output.kind, .image)
        let decoded = try? JSONDecoder().decode(ImagePayload.self, from: output.payload.data(using: .utf8)!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.resolvedUrls.count, 3)
    }

    func testExecuteFiltersBadUrlsFromList() {
        let tool = ShowImageTool()
        let output = tool.execute(args: [
            "urls": "https://commons.wikimedia.org/wiki/File:Bad.jpg|https://example.com/good.jpg",
            "alt": "test"
        ])
        XCTAssertEqual(output.kind, .image)
        let decoded = try? JSONDecoder().decode(ImagePayload.self, from: output.payload.data(using: .utf8)!)
        XCTAssertNotNil(decoded)
        // Wiki URL should be filtered out, only good URL remains
        XCTAssertEqual(decoded?.resolvedUrls.count, 1)
        XCTAssertEqual(decoded?.resolvedUrls.first, "https://example.com/good.jpg")
    }

    func testExecuteAllBadUrlsReturnsError() {
        let tool = ShowImageTool()
        let output = tool.execute(args: [
            "urls": "https://commons.wikimedia.org/wiki/File:Bad.jpg|ftp://bad.com/img.jpg",
            "alt": "test"
        ])
        XCTAssertEqual(output.kind, .markdown) // Error
        XCTAssert(output.payload.contains("Image Error"))
    }

    func testExecuteWithWikiPageReturnsError() {
        let tool = ShowImageTool()
        let output = tool.execute(args: ["url": "https://commons.wikimedia.org/wiki/File:Frog.jpg", "alt": "A frog"])
        XCTAssertEqual(output.kind, .markdown)
        XCTAssert(output.payload.contains("Image Error"))
        XCTAssert(output.payload.contains("wiki page"))
    }

    func testExecuteWithEmptyURLReturnsError() {
        let tool = ShowImageTool()
        let output = tool.execute(args: ["alt": "A frog"])
        XCTAssertEqual(output.kind, .markdown)
        XCTAssert(output.payload.contains("Image Error"))
    }

    func testExecuteWithParensInAlt() {
        let tool = ShowImageTool()
        let output = tool.execute(args: [
            "url": "https://example.com/frog.jpg",
            "alt": "A frog (Rana esculenta)"
        ])
        XCTAssertEqual(output.kind, .image)
        let decoded = try? JSONDecoder().decode(ImagePayload.self, from: output.payload.data(using: .utf8)!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.alt, "A frog (Rana esculenta)")
    }

    // MARK: - ToolRegistry

    func testToolRegistryContainsShowImage() {
        let tool = ToolRegistry.shared.get("show_image")
        XCTAssertNotNil(tool, "ToolRegistry must contain show_image with exact name")
        XCTAssertEqual(tool?.name, "show_image")
    }

    func testToolRegistryContainsShowText() {
        let tool = ToolRegistry.shared.get("show_text")
        XCTAssertNotNil(tool, "ToolRegistry must contain show_text with exact name")
    }

    // MARK: - Pipeline: Tool Execution Appends OutputItem

    func testShowImageExecutionProducesImageOutput() {
        // Verifies the full tool execution path returns a usable OutputItem
        let toolAction = ToolAction(name: "show_image", args: [
            "urls": "https://example.com/frog.jpg",
            "alt": "A green frog"
        ])
        let output = ToolsRuntime.shared.execute(toolAction)
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.kind, .image)
    }

    func testShowTextExecutionProducesMarkdownOutput() {
        let toolAction = ToolAction(name: "show_text", args: [
            "markdown": "# Recipe\nStep 1: Preheat oven."
        ])
        let output = ToolsRuntime.shared.execute(toolAction)
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.kind, .markdown)
        XCTAssertEqual(output?.payload, "# Recipe\nStep 1: Preheat oven.")
    }

    func testUnknownToolReturnsErrorOutput() {
        let toolAction = ToolAction(name: "nonexistent_tool", args: [:])
        let output = ToolsRuntime.shared.execute(toolAction)
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.kind, .markdown)
        XCTAssert(output!.payload.contains("Unknown tool"))
    }

    // MARK: - ActionValidator: show_image with urls

    func testValidatorAcceptsPipeSeparatedUrls() {
        let action = Action.tool(ToolAction(
            name: "show_image",
            args: ["urls": "https://a.com/1.jpg|https://b.com/2.jpg", "alt": "test"],
            say: "Here"
        ))
        XCTAssertNil(ActionValidator.validate(action),
                     "Pipe-separated valid URLs should pass validation")
    }

    func testValidatorAcceptsSingleUrlArg() {
        let action = Action.tool(ToolAction(
            name: "show_image",
            args: ["url": "https://example.com/frog.jpg", "alt": "test"],
            say: "Here"
        ))
        XCTAssertNil(ActionValidator.validate(action),
                     "Single url arg should still pass validation")
    }

    func testValidatorRejectsNoUrls() {
        let action = Action.tool(ToolAction(name: "show_image", args: ["alt": "test"], say: nil))
        let failure = ActionValidator.validate(action)
        XCTAssertNotNil(failure, "No urls should fail validation")
    }

    func testValidatorRejectsAllInvalidUrls() {
        let action = Action.tool(ToolAction(
            name: "show_image",
            args: ["urls": "not-a-url|also-bad"],
            say: nil
        ))
        let failure = ActionValidator.validate(action)
        XCTAssertNotNil(failure, "All invalid URLs should fail validation")
    }

    // MARK: - PlanExecutor Image Probe (slot = "image_url")

    @MainActor
    func testPlanExecutorReturnsImageUrlSlotOnDeadUrls() async {
        // Use a URL that will fail the probe (non-routable address)
        let plan = Plan(steps: [
            .tool(name: "show_image", args: [
                "urls": .string("https://192.0.2.1/does-not-exist.jpg"),
                "alt": .string("test")
            ], say: "Here you go.")
        ])
        let result = await PlanExecutor.shared.execute(plan, originalInput: "show me a picture")
        // The probe should fail and return image_url slot
        XCTAssertNotNil(result.pendingSlotRequest)
        XCTAssertEqual(result.pendingSlotRequest?.slot, "image_url")
        // No image output should be appended
        XCTAssertTrue(result.outputItems.isEmpty)
    }

    @MainActor
    func testPlanExecutorPassesThroughLiveImage() async {
        // Use a real URL that should respond (Wikimedia favicon is small and fast)
        let plan = Plan(steps: [
            .tool(name: "show_image", args: [
                "urls": .string("https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/PNG_transparency_demonstration_1.png/280px-PNG_transparency_demonstration_1.png"),
                "alt": .string("test")
            ], say: "Here you go.")
        ])
        let result = await PlanExecutor.shared.execute(plan, originalInput: "show me a picture")
        // The probe should pass — image output should be appended
        XCTAssertNil(result.pendingSlotRequest)
        XCTAssertEqual(result.outputItems.count, 1)
        XCTAssertEqual(result.outputItems.first?.kind, .image)
    }

    @MainActor
    func testPlanExecutorImageProbeDoesNotAffectNonImageTools() async {
        // show_text should not be probed
        let plan = Plan(steps: [
            .tool(name: "show_text", args: [
                "markdown": .string("# Hello")
            ], say: "Here.")
        ])
        let result = await PlanExecutor.shared.execute(plan, originalInput: "hello")
        XCTAssertNil(result.pendingSlotRequest)
        XCTAssertEqual(result.outputItems.count, 1)
        XCTAssertEqual(result.outputItems.first?.kind, .markdown)
    }

    // MARK: - ImageProber Unit Tests

    func testImageProberRejectsNonRoutableAddress() async {
        // 192.0.2.1 is a TEST-NET address (RFC 5737) — should timeout or fail
        let verified = await ImageProber.probe(urls: ["https://192.0.2.1/fake.jpg"])
        XCTAssertTrue(verified.isEmpty)
    }

    func testImageProberAcceptsLiveImageUrl() async {
        // Use a well-known, stable image URL
        let verified = await ImageProber.probe(urls: [
            "https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/PNG_transparency_demonstration_1.png/280px-PNG_transparency_demonstration_1.png"
        ])
        XCTAssertFalse(verified.isEmpty, "A known-good Wikimedia image URL should pass the probe")
    }

    func testImageProberRejectsInvalidUrlString() async {
        let verified = await ImageProber.probe(urls: ["not a url at all"])
        XCTAssertTrue(verified.isEmpty)
    }

    func testImageProberFiltersDeadFromMixed() async {
        let verified = await ImageProber.probe(urls: [
            "https://192.0.2.1/fake.jpg",
            "https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/PNG_transparency_demonstration_1.png/280px-PNG_transparency_demonstration_1.png"
        ])
        XCTAssertEqual(verified.count, 1)
        XCTAssertTrue(verified.first?.contains("wikimedia") ?? false)
    }

    func testImageProberRejectsNonImageContentType() async {
        // An HTML page should fail content-type check
        let verified = await ImageProber.probe(urls: ["https://www.example.com/"])
        XCTAssertTrue(verified.isEmpty, "HTML page should be rejected by content-type check")
    }

    // MARK: - ShowImageTool Validation (additional)

    func testRejectDataSchemeUrl() {
        let tool = ShowImageTool()
        let error = tool.validateImageURL("data:image/png;base64,abc123")
        XCTAssertNotNil(error)
    }

    func testAcceptSvgExtension() {
        let tool = ShowImageTool()
        XCTAssertNil(tool.validateImageURL("https://example.com/icon.svg"))
    }

    func testRejectJavascriptScheme() {
        let tool = ShowImageTool()
        let error = tool.validateImageURL("javascript:alert(1)")
        XCTAssertNotNil(error)
    }
}
