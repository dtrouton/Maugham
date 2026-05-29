import XCTest
@testable import Maugham

final class EmissionContractTests: XCTestCase {
    /// Path to the committed starter copy. This test file lives at
    /// `<repo>/MaughamTests/Publish/EmissionContractTests.swift` — three
    /// `deletingLastPathComponent()` hops from `#filePath` reach the repo root
    /// (file → Publish → MaughamTests → repo).
    private var docURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Publish/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham/Resources/PublishStarter/EMISSION.md")
    }

    func test_committedEmissionDoc_matchesGeneratedContract() throws {
        let generated = EmissionContract.renderMarkdown()
        if !FileManager.default.fileExists(atPath: docURL.path) {
            try generated.write(to: docURL, atomically: true, encoding: .utf8)
            XCTFail("EMISSION.md did not exist — wrote it. Re-run this test; commit the file.")
            return
        }
        let committed = try String(contentsOf: docURL, encoding: .utf8)
        XCTAssertEqual(committed, generated,
            "EMISSION.md is stale: the emitter or contract changed but the doc didn't. "
          + "Regenerate by deleting Maugham/Resources/PublishStarter/EMISSION.md and "
          + "re-running this test, then commit the regenerated file.")
    }
}
