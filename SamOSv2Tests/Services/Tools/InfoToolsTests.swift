import XCTest
@testable import SamOSv2

final class InfoToolsTests: XCTestCase {

    func testGetTimeReturnsTime() async {
        let tool = GetTimeTool()
        XCTAssertEqual(tool.name, "get_time")
        let result = await tool.execute(args: [:])
        XCTAssertTrue(result.success)
        XCTAssertNotNil(result.spokenText)
    }

    func testGetTimeWithCity() async {
        let tool = GetTimeTool()
        let result = await tool.execute(args: ["city": "London"])
        XCTAssertTrue(result.success)
    }

    func testGetTimeWithTimezone() async {
        let tool = GetTimeTool()
        let result = await tool.execute(args: ["timezone": "America/New_York"])
        XCTAssertTrue(result.success)
    }

    func testGetWeatherName() {
        let tool = GetWeatherTool()
        XCTAssertEqual(tool.name, "get_weather")
    }

    func testGetWeatherMissingLocationFails() async {
        let tool = GetWeatherTool()
        let result = await tool.execute(args: [:])
        XCTAssertFalse(result.success)
    }

    func testNewsFetchName() {
        let tool = NewsFetchTool()
        XCTAssertEqual(tool.name, "news.fetch")
    }

    func testMovieShowtimesName() {
        let tool = MovieShowtimesTool()
        XCTAssertEqual(tool.name, "movies.showtimes")
    }

    func testFishingReportName() {
        let tool = FishingReportTool()
        XCTAssertEqual(tool.name, "fishing.report")
    }

    func testPriceLookupName() {
        let tool = PriceLookupTool()
        XCTAssertEqual(tool.name, "price.lookup")
    }

    func testPriceLookupMissingItemFails() async {
        let tool = PriceLookupTool()
        let result = await tool.execute(args: [:])
        XCTAssertFalse(result.success)
    }
}
