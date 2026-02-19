import XCTest

final class DomainLayerDependencyTests: XCTestCase {
    func testDomainLayerDoesNotImportSwiftUI() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = fileURL
            .deletingLastPathComponent()   // Architecture
            .deletingLastPathComponent()   // SamOSTests
            .deletingLastPathComponent()   // repo root

        let domainRoot = repoRoot.appendingPathComponent("SamOS/Domain", isDirectory: true)
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: domainRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var offenders: [String] = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file)
            if text.contains("import SwiftUI") || text.contains("import AppKit") {
                offenders.append(file.path)
            }
        }

        XCTAssertTrue(offenders.isEmpty, "Domain layer imported UI modules: \(offenders)")
    }
}
