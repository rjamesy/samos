import XCTest
@testable import SamOSv2

final class CoreToolsTests: XCTestCase {

    func testShowTextReturnsMarkdown() async {
        let tool = ShowTextTool()
        XCTAssertEqual(tool.name, "show_text")
        let result = await tool.execute(args: ["text": "Hello world"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output?.kind, .markdown)
        XCTAssertEqual(result.output?.payload, "Hello world")
    }

    func testShowTextMissingArgFails() async {
        let tool = ShowTextTool()
        let result = await tool.execute(args: [:])
        XCTAssertFalse(result.success)
    }

    func testShowImageReturnsImage() async {
        let tool = ShowImageTool()
        XCTAssertEqual(tool.name, "show_image")
        let result = await tool.execute(args: ["url": "https://example.com/img.png"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output?.kind, .image)
    }

    func testShowImageMissingUrlFails() async {
        let tool = ShowImageTool()
        let result = await tool.execute(args: [:])
        XCTAssertFalse(result.success)
    }

    func testShowAssetImage() async {
        let tool = ShowAssetImageTool()
        XCTAssertEqual(tool.name, "show_asset_image")
        let result = await tool.execute(args: ["name": "sam"])
        XCTAssertTrue(result.success)
    }

    func testListAssets() async {
        let tool = ListAssetsTool()
        XCTAssertEqual(tool.name, "list_assets")
        let result = await tool.execute(args: [:])
        XCTAssertTrue(result.success)
    }

    func testFindFiles() async {
        let tool = FindFilesTool()
        XCTAssertEqual(tool.name, "find_files")
        let result = await tool.execute(args: ["query": "test"])
        XCTAssertTrue(result.success)
    }
}
