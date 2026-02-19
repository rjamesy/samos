import XCTest
@testable import SamOS

final class SamResponseParserTests: XCTestCase {

    // MARK: - Plain Text

    func testPlainTextShortReply() {
        let result = SamResponseParser.parse("Hello! How can I help you today?")
        XCTAssertTrue(result.canvasItems.isEmpty, "Short plain text should produce no canvas items")
        XCTAssertEqual(result.spokenText, "Hello! How can I help you today?")
    }

    func testEmptyInput() {
        let result = SamResponseParser.parse("")
        XCTAssertTrue(result.canvasItems.isEmpty)
        XCTAssertTrue(result.spokenText.isEmpty)
    }

    func testWhitespaceOnly() {
        let result = SamResponseParser.parse("   \n  \n  ")
        XCTAssertTrue(result.canvasItems.isEmpty)
        XCTAssertTrue(result.spokenText.isEmpty)
    }

    // MARK: - Image Extraction

    func testMarkdownImageExtraction() {
        let text = "Here's a sunset for you!\n\n![A beautiful sunset](https://example.com/sunset.jpg)"
        let result = SamResponseParser.parse(text)

        let imageItems = result.canvasItems.filter { $0.kind == .image }
        XCTAssertEqual(imageItems.count, 1, "Should extract one image")

        // Verify payload is valid JSON with URL and alt text
        let payload = imageItems[0].payload
        let data = payload.data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let urls = json["urls"] as! [String]
        XCTAssertEqual(urls.first, "https://example.com/sunset.jpg")
        XCTAssertEqual(json["alt"] as? String, "A beautiful sunset")

        // Spoken text should not contain the markdown image syntax
        XCTAssertFalse(result.spokenText.contains("!["))
        XCTAssertTrue(result.spokenText.contains("sunset for you"))
    }

    func testMultipleImages() {
        let text = """
        Here are two images:
        ![Cat](https://example.com/cat.jpg)
        ![Dog](https://example.com/dog.jpg)
        """
        let result = SamResponseParser.parse(text)

        let imageItems = result.canvasItems.filter { $0.kind == .image }
        XCTAssertEqual(imageItems.count, 2, "Should extract two images")
    }

    func testInvalidImageURLSkipped() {
        let text = "![local](file:///tmp/secret.jpg)"
        let result = SamResponseParser.parse(text)

        let imageItems = result.canvasItems.filter { $0.kind == .image }
        XCTAssertEqual(imageItems.count, 0, "Non-http(s) URLs should be skipped")
    }

    // MARK: - Rich Content Detection

    func testHeadingsCreateMarkdownItem() {
        let text = "# Pasta Recipe\n\nBoil water and cook pasta for 10 minutes."
        let result = SamResponseParser.parse(text)

        let mdItems = result.canvasItems.filter { $0.kind == .markdown }
        XCTAssertEqual(mdItems.count, 1, "Headings should trigger markdown canvas item")
        XCTAssertTrue(mdItems[0].payload.contains("Pasta Recipe"))
    }

    func testBulletListsCreateMarkdownItem() {
        let text = "Shopping list:\n- Eggs\n- Milk\n- Bread"
        let result = SamResponseParser.parse(text)

        let mdItems = result.canvasItems.filter { $0.kind == .markdown }
        XCTAssertEqual(mdItems.count, 1, "Bullet lists should trigger markdown canvas item")
    }

    func testNumberedListsCreateMarkdownItem() {
        let text = "Steps:\n1. Preheat oven\n2. Mix ingredients\n3. Bake for 20 minutes"
        let result = SamResponseParser.parse(text)

        let mdItems = result.canvasItems.filter { $0.kind == .markdown }
        XCTAssertEqual(mdItems.count, 1, "Numbered lists should trigger markdown canvas item")
    }

    func testCodeFencesCreateMarkdownItem() {
        let text = "Here's the code:\n```swift\nprint(\"hello\")\n```"
        let result = SamResponseParser.parse(text)

        let mdItems = result.canvasItems.filter { $0.kind == .markdown }
        XCTAssertEqual(mdItems.count, 1, "Code fences should trigger markdown canvas item")
    }

    // MARK: - Mixed Content

    func testImagePlusRichText() {
        let text = """
        # Sunset Guide

        ![Sunset](https://example.com/sunset.jpg)

        - Best time: golden hour
        - Location: west-facing beach
        - Camera: wide angle lens
        """
        let result = SamResponseParser.parse(text)

        let imageItems = result.canvasItems.filter { $0.kind == .image }
        let mdItems = result.canvasItems.filter { $0.kind == .markdown }

        XCTAssertEqual(imageItems.count, 1, "Should extract the image")
        XCTAssertEqual(mdItems.count, 1, "Should create markdown canvas for rich text")

        // Markdown item should not contain the image line
        XCTAssertFalse(mdItems[0].payload.contains("![Sunset]"))
    }

    // MARK: - Spoken Text

    func testSpokenTextStripsMarkdownFormatting() {
        let text = "## Important\n\n**Bold text** and *italic text*"
        let result = SamResponseParser.parse(text)

        XCTAssertFalse(result.spokenText.contains("##"))
        XCTAssertFalse(result.spokenText.contains("**"))
        XCTAssertTrue(result.spokenText.contains("Important"))
        XCTAssertTrue(result.spokenText.contains("Bold text"))
    }

    func testSpokenTextStripsCodeFences() {
        let text = "Run this:\n```\necho hello\n```"
        let result = SamResponseParser.parse(text)

        XCTAssertFalse(result.spokenText.contains("```"))
        XCTAssertTrue(result.spokenText.contains("echo hello"))
    }

    func testSpokenTextReplacesImageWithAlt() {
        let text = "Look at this ![cute cat](https://example.com/cat.jpg) photo"
        let result = SamResponseParser.parse(text)

        XCTAssertTrue(result.spokenText.contains("cute cat"))
        XCTAssertFalse(result.spokenText.contains("https://"))
    }

    func testSpokenTextStripsDomainAttributionLinks() {
        // Sam-style response with image + source attribution link
        let text = "Here's a Ferrari for you:\n\n![Ferrari 488 GTB](https://commons.wikimedia.org/wiki/Special:FilePath/Ferrari.jpg)\n\n([commons.wikimedia.org](https://commons.wikimedia.org/wiki/File:Ferrari.jpg))"
        let result = SamResponseParser.parse(text)

        XCTAssertFalse(result.spokenText.contains("commons"), "Domain attribution should be stripped from spoken text")
        XCTAssertFalse(result.spokenText.contains("wikimedia"), "Domain attribution should be stripped from spoken text")
        XCTAssertTrue(result.spokenText.contains("Ferrari"))
    }

    func testSpokenTextKeepsNormalLinkText() {
        let text = "Check out [this article](https://example.com/article) about cooking"
        let result = SamResponseParser.parse(text)

        XCTAssertTrue(result.spokenText.contains("this article"), "Normal link text should be kept")
        XCTAssertFalse(result.spokenText.contains("https://"))
    }

    // MARK: - Short vs Long

    func testShortPlainTextNoCanvas() {
        let result = SamResponseParser.parse("Sure, I can help with that.")
        XCTAssertTrue(result.canvasItems.isEmpty)
    }

    func testLongStructuredTextCreatesCanvas() {
        // >400 chars with multiple paragraphs
        let para1 = String(repeating: "This is a detailed explanation. ", count: 8)
        let para2 = String(repeating: "More details about the topic. ", count: 8)
        let text = para1 + "\n\n" + para2
        XCTAssertGreaterThan(text.count, 400)

        let result = SamResponseParser.parse(text)
        let mdItems = result.canvasItems.filter { $0.kind == .markdown }
        XCTAssertEqual(mdItems.count, 1, "Long multi-paragraph text should create canvas item")
    }
}
