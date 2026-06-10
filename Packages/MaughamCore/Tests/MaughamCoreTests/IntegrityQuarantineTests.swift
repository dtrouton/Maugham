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

    private func quarantineFiles(in proj: URL) -> [URL] {
        let dir = proj.appendingPathComponent(".maugham/conflicts/quarantine")
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    // Audit N1: the same persistent torn line is recorded on every load of the doc.
    // Identical content (even at a different stamp) must collapse onto ONE file.
    func test_record_dedupsIdenticalContentAcrossLoads() throws {
        let proj = tempProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        let skipped = [ParseDiagnostics.SkippedLine(byteOffset: 11, raw: "NOT JSON")]

        let first = try IntegrityQuarantine.record(
            skipped: skipped, forDocId: "doc-0f677d7e", in: proj, stamp: "20260607-140000")
        // A later load, different stamp, identical torn content → must no-op.
        let second = try IntegrityQuarantine.record(
            skipped: skipped, forDocId: "doc-0f677d7e", in: proj, stamp: "20260608-090000")

        XCTAssertNotNil(first)
        XCTAssertNil(second, "identical content at a later stamp must not write a second file")
        XCTAssertEqual(quarantineFiles(in: proj).count, 1)
    }

    // Different torn content → distinct files (dedup is content-addressed, not per-doc).
    func test_record_distinctContentWritesSeparateFiles() throws {
        let proj = tempProject()
        defer { try? FileManager.default.removeItem(at: proj) }

        let a = try IntegrityQuarantine.record(
            skipped: [ParseDiagnostics.SkippedLine(byteOffset: 11, raw: "NOT JSON")],
            forDocId: "doc-0f677d7e", in: proj, stamp: "s1")
        let b = try IntegrityQuarantine.record(
            skipped: [ParseDiagnostics.SkippedLine(byteOffset: 25, raw: "{partial")],
            forDocId: "doc-0f677d7e", in: proj, stamp: "s2")

        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(quarantineFiles(in: proj).count, 2)
    }
}
