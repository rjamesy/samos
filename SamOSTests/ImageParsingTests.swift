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

    func testExecuteWithImageUrlAlias() {
        let tool = ShowImageTool()
        let output = tool.execute(args: ["imageUrl": "https://example.com/frog.jpg", "alt": "A frog"])
        XCTAssertEqual(output.kind, .image)
        let decoded = try? JSONDecoder().decode(ImagePayload.self, from: output.payload.data(using: .utf8)!)
        XCTAssertEqual(decoded?.resolvedUrls.first, "https://example.com/frog.jpg")
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

    // MARK: - FindImageTool Google URL Extraction

    func testFindImageExtractGoogleURLsFromHTML() {
        let html = """
        <html><body>
        "ou":"https:\\/\\/images.example.com\\/frog.jpg"
        "imgurl":"https:\\/\\/cdn.example.org\\/green-frog.png"
        https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQfrog123
        </body></html>
        """

        let urls = FindImageTool.extractGoogleImageURLs(fromHTML: html, limit: 6)
        XCTAssertTrue(urls.contains("https://images.example.com/frog.jpg"))
        XCTAssertTrue(urls.contains("https://cdn.example.org/green-frog.png"))
        XCTAssertTrue(urls.contains("https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQfrog123"))
    }

    func testFindImageExtractGoogleURLsSkipsSearchPages() {
        let html = """
        <html><body>
        "imgurl":"https:\\/\\/www.google.com\\/search?tbm=isch&q=frog"
        "ou":"https:\\/\\/example.com\\/frog.webp"
        </body></html>
        """

        let urls = FindImageTool.extractGoogleImageURLs(fromHTML: html, limit: 6)
        XCTAssertFalse(urls.contains(where: { $0.contains("/search?tbm=isch") }))
        XCTAssertTrue(urls.contains("https://example.com/frog.webp"))
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

    func testToolRegistryContainsFindImage() {
        let tool = ToolRegistry.shared.get("find_image")
        XCTAssertNotNil(tool, "ToolRegistry must contain find_image with exact name")
    }

    func testToolRegistryContainsFindVideo() {
        let tool = ToolRegistry.shared.get("find_video")
        XCTAssertNotNil(tool, "ToolRegistry must contain find_video with exact name")
    }

    func testToolRegistryContainsFindFiles() {
        let tool = ToolRegistry.shared.get("find_files")
        XCTAssertNotNil(tool, "ToolRegistry must contain find_files with exact name")
    }

    func testFindRecipeNormalizesDuckDuckGoSchemeRelativeRedirect() {
        let tool = FindRecipeTool()
        let href = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.recipetineats.com%2Fbutter-chicken%2F"
        let resolved = tool.normalizeSearchHref(href, baseURL: URL(string: "https://duckduckgo.com/html/?q=butter+chicken"))
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.host, "www.recipetineats.com")
        XCTAssertTrue(resolved?.absoluteString.contains("/butter-chicken/") == true)
    }

    func testFindRecipeNormalizesDuckDuckGoAbsoluteRedirect() {
        let tool = FindRecipeTool()
        let href = "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.bbcgoodfood.com%2Frecipes%2Feasy-butter-chicken"
        let resolved = tool.normalizeSearchHref(href)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.host, "www.bbcgoodfood.com")
        XCTAssertTrue(resolved?.absoluteString.contains("/recipes/") == true)
    }

    func testShowTextAcceptsTextAlias() {
        guard let tool = ToolRegistry.shared.get("show_text") else {
            return XCTFail("show_text tool missing")
        }
        let output = tool.execute(args: ["text": "# Alias Works"])
        XCTAssertEqual(output.kind, .markdown)
        XCTAssertEqual(output.payload, "# Alias Works")
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

    func testFindImageExecutionProducesImageOutput() {
        let toolAction = ToolAction(name: "find_image", args: [
            "query": "frog"
        ])
        let output = ToolsRuntime.shared.execute(toolAction)
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.kind, .image)

        guard let data = output?.payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ImagePayload.self, from: data) else {
            return XCTFail("Expected image payload JSON from find_image")
        }
        XCTAssertGreaterThanOrEqual(decoded.resolvedUrls.count, 1)
        XCTAssertEqual(decoded.alt, "frog")
    }

    func testFindImageMissingQueryReturnsPromptPayload() {
        let toolAction = ToolAction(name: "find_image", args: [:])
        let output = ToolsRuntime.shared.execute(toolAction)
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.kind, .markdown)

        guard let payload = output?.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return XCTFail("Expected structured prompt payload JSON from find_image")
        }
        XCTAssertEqual(dict["kind"] as? String, "prompt")
        XCTAssertEqual(dict["slot"] as? String, "query")
    }

    func testFindVideoMissingQueryReturnsPromptPayload() {
        let toolAction = ToolAction(name: "find_video", args: [:])
        let output = ToolsRuntime.shared.execute(toolAction)
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.kind, .markdown)

        guard let payload = output?.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return XCTFail("Expected structured prompt payload JSON from find_video")
        }
        XCTAssertEqual(dict["kind"] as? String, "prompt")
        XCTAssertEqual(dict["slot"] as? String, "query")
    }

    func testFindFilesMatchesPartialNameAndType() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("FindFilesTool_\(UUID().uuidString)", isDirectory: true)
        let downloads = base.appendingPathComponent("Downloads", isDirectory: true)
        let documents = base.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let wanted = downloads.appendingPathComponent("BestReport-final.pdf")
        let other = documents.appendingPathComponent("BestReport-notes.docx")
        let noise = documents.appendingPathComponent("shopping-list.txt")
        try Data("pdf".utf8).write(to: wanted)
        try Data("docx".utf8).write(to: other)
        try Data("txt".utf8).write(to: noise)

        let tool = FindFilesTool(
            fileManager: .default,
            directoryProvider: { [downloads, documents] }
        )
        let output = tool.execute(args: ["name": "bestreport", "type": "pdf"])
        XCTAssertEqual(output.kind, .markdown)

        guard let data = output.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formatted = dict["formatted"] as? String else {
            return XCTFail("Expected structured markdown payload from find_files")
        }

        XCTAssertTrue(formatted.contains("BestReport-final.pdf"))
        XCTAssertFalse(formatted.contains("BestReport-notes.docx"))
        XCTAssertFalse(formatted.contains("shopping-list.txt"))
    }

    func testFindFilesReportsWhenNoMatches() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("FindFilesToolEmpty_\(UUID().uuidString)", isDirectory: true)
        let downloads = base.appendingPathComponent("Downloads", isDirectory: true)
        let documents = base.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try Data("hello".utf8).write(to: downloads.appendingPathComponent("notes.txt"))

        let tool = FindFilesTool(
            fileManager: .default,
            directoryProvider: { [downloads, documents] }
        )
        let output = tool.execute(args: ["query": "find all pdfs"])
        XCTAssertEqual(output.kind, .markdown)

        guard let data = output.payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spoken = dict["spoken"] as? String,
              let formatted = dict["formatted"] as? String else {
            return XCTFail("Expected structured markdown payload from find_files")
        }

        XCTAssertTrue(spoken.contains("couldn't find"))
        XCTAssertTrue(formatted.contains("No matching files found."))
    }

    func testFindFilesPreferredHomeDirectoryStripsContainerPath() {
        let containerHome = URL(fileURLWithPath: "/Users/rjamesy/Library/Containers/com.samos.SamOS/Data", isDirectory: true)
        let resolved = FindFilesTool.preferredHomeDirectory(for: containerHome)
        XCTAssertEqual(resolved.path, "/Users/rjamesy")

        let downloads = resolved.appendingPathComponent("Downloads", isDirectory: true)
        let documents = resolved.appendingPathComponent("Documents", isDirectory: true)
        XCTAssertEqual(downloads.path, "/Users/rjamesy/Downloads")
        XCTAssertEqual(documents.path, "/Users/rjamesy/Documents")
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
