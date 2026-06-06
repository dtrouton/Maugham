import XCTest
@testable import MaughamCore

final class IntegrityQuarantineTests: XCTestCase {
    private func tempProject() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proj-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_record_writesRawLinesUnderConflictsQuarantine() throws {
        let proj = tempProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        let skipped = [
            ParseDiagnostics.SkippedLine(byteOffset: 11, raw: "NOT JSON"),
            ParseDiagnostics.SkippedLine(byteOffset: 25, raw: "{partial"),
        ]

        let written = try IntegrityQuarantine.record(
            skipped: skipped, forDocId: "doc-0f677d7e", in: proj, stamp: "20260607-140000")

        let dir = proj.appendingPathComponent(".maugham/conflicts/quarantine")
        XCTAssertEqual(written?.deletingLastPathComponent(), dir)
        let contents = try String(contentsOf: XCTUnwrap(written), encoding: .utf8)
        XCTAssertTrue(contents.contains("NOT JSON"))
        XCTAssertTrue(contents.contains("{partial"))
        XCTAssertTrue(contents.contains("doc-0f677d7e"))
    }

    func test_record_emptySkippedWritesNothing() throws {
        let proj = tempProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        let written = try IntegrityQuarantine.record(
            skipped: [], forDocId: "doc-0f677d7e", in: proj, stamp: "x")
        XCTAssertNil(written)
    }
}
