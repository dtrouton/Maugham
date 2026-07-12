import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class DocumentOpLogAccessorTests: XCTestCase {

    func test_opLog_returnsLogIncludingBootstrap() async throws {
        let (_, docURL) = try makeTestProject(
            prefix: "OPLOG",
            initialMd: "First paragraph.\n\nSecond paragraph.")
        let doc = try await Document.load(
            url: docURL,
            device: "m", session: "s", presenter: nil)
        let ops = try await doc.opLog()
        XCTAssertFalse(ops.isEmpty)
        XCTAssertTrue(ops.contains(where: { $0.kind == .bootstrap }))
    }

    func test_opLog_reflectsAppendedBurst() async throws {
        let (_, docURL) = try makeTestProject(prefix: "OPLOG", initialMd: "Hello.")
        let doc = try await Document.load(
            url: docURL,
            device: "m", session: "s", presenter: nil)
        let countBefore = (try await doc.opLog()).count
        doc.setFullText("Hello world.")
        try await doc.flushBurstNow()
        let countAfter = (try await doc.opLog()).count
        XCTAssertEqual(countAfter, countBefore + 1)
        let opsAfter = try await doc.opLog()
        XCTAssertEqual(opsAfter.last?.kind, .typingBurst)
    }
}
