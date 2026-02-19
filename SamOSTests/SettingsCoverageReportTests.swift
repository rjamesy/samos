import XCTest
@testable import SamOS

final class SettingsCoverageReportTests: XCTestCase {
    func testSettingsAuditMatrixContainsAllCanonicalKeysWithConsumerAndTest() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = fileURL
            .deletingLastPathComponent()   // SamOSTests
            .deletingLastPathComponent()   // repo root
        let matrixURL = repoRoot.appendingPathComponent("docs/settings_audit_matrix.md")
        let matrix = try String(contentsOf: matrixURL)
        let rows = matrix
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("|") && $0.contains("`") }

        for key in SettingsKey.allCases {
            guard let row = rows.first(where: { $0.contains("`\(key.rawValue)`") }) else {
                XCTFail("Missing matrix row for setting key: \(key.rawValue)")
                continue
            }
            let columns = row
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

            // | tab | label | key | default | storage | consumer | apply | effect | test |
            XCTAssertGreaterThanOrEqual(columns.count, 10, "Malformed matrix row: \(row)")

            let consumer = columns[6]
            let testName = columns[9]
            XCTAssertFalse(consumer.isEmpty || consumer == "-", "Missing consumer mapping for \(key.rawValue)")
            XCTAssertFalse(testName.isEmpty || testName == "-", "Missing test mapping for \(key.rawValue)")
        }
    }
}

