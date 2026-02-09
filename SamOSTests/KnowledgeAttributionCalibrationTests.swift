import XCTest
@testable import SamOS

final class KnowledgeAttributionCalibrationTests: XCTestCase {

    func testDefaultCalibrationDatasetSize() {
        let cases = KnowledgeAttributionScorer.defaultCalibrationCases()
        XCTAssertGreaterThanOrEqual(cases.count, 50)
        XCTAssertLessThanOrEqual(cases.count, 100)
    }

    func testDefaultCalibrationQuality() {
        let cases = KnowledgeAttributionScorer.defaultCalibrationCases()
        let report = KnowledgeAttributionScorer.evaluateCalibration(cases)

        XCTAssertEqual(report.caseCount, cases.count)
        XCTAssertLessThan(report.meanAbsoluteError, 26.0)
        XCTAssertGreaterThanOrEqual(report.withinToleranceRate, 0.65)
    }

    func testScorerIncludesWebsiteEvidenceForStrongMatch() {
        let snippets = [
            KnowledgeSourceSnippet(
                kind: .website,
                id: "brew-001",
                label: "Home Brew Guide",
                text: "Sanitize equipment, control fermentation temperature, and track gravity for stable beer quality.",
                url: "https://example.com/homebrew"
            )
        ]

        let attribution = KnowledgeAttributionScorer.score(
            userInput: "How do I improve home brew consistency?",
            assistantText: "Sanitize equipment and control fermentation temperature for better consistency.",
            provider: .openai,
            localSnippets: snippets
        )

        XCTAssertGreaterThanOrEqual(attribution.localKnowledgePercent, 20)
        XCTAssertFalse(attribution.evidence.isEmpty)
        XCTAssertEqual(attribution.evidence.first?.kind, .website)
        XCTAssertEqual(attribution.evidence.first?.url, "https://example.com/homebrew")
    }
}
