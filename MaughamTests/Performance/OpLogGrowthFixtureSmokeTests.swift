import XCTest
@testable import Maugham
@testable import MaughamCore

/// Always-on tiny-scale check that the fixture generator produces genuine
/// op logs through the production Document API (growth spec §3). The full
/// baseline runs are env-gated in OpLogGrowthBaselineTests.
@MainActor
final class OpLogGrowthFixtureSmokeTests: XCTestCase {

    func test_smokeFixture_producesOpsAndSurvivesReload() async throws {
        let result = try await OpLogGrowthFixture.generate(spec: .smoke)
        defer { try? FileManager.default.removeItem(at: result.projectURL) }

        XCTAssertEqual(result.docIds.count, 2)
        XCTAssertGreaterThan(result.burstCount, 0)
        XCTAssertGreaterThan(result.tailBytesRewritten, 0)

        for (docId, url) in zip(result.docIds, result.docURLs) {
            let ops = try await OpLogStore(projectURL: result.projectURL)
                .load(docId: docId)
            XCTAssertGreaterThan(ops.count, 1, "bootstrap + bursts expected")
            XCTAssertTrue(ops.contains { $0.kind == .bootstrap })
            XCTAssertTrue(ops.contains { $0.kind == .typingBurst })

            // Reload through production load: derived text must be non-empty
            // and contain a fixture edit marker (history genuinely applied).
            let doc = try await Document.load(
                url: url, device: OpLogGrowthFixture.deviceName,
                session: "verify", presenter: nil)
            XCTAssertFalse(doc.displayText.isEmpty)
            XCTAssertTrue(doc.displayText.contains("edit"),
                          "session edits must survive reload")
            await doc.close()
        }
    }

    func test_seededRandom_isDeterministic() {
        var a = SeededRandom(seed: 7), b = SeededRandom(seed: 7)
        for _ in 0..<100 { XCTAssertEqual(a.next(), b.next()) }
    }
}
