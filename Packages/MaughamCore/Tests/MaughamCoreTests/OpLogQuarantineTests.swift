import XCTest
@testable import MaughamCore

final class OpLogQuarantineTests: XCTestCase {
    private var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("olq-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".maugham/ops"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    /// Spec §5: the move is byte-identical — the bytes are never opened, only
    /// relocated — and the record beside it says what and why.
    @MainActor
    func test_quarantine_movesBytesIdentically_andRecordsWhy() throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        let bytes = Data("torn \u{0} garbage the reader refused".utf8)  // arbitrary bytes, not JSON
        try bytes.write(to: src)

        let record = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "permission denied",
            in: tmp, isDatalessStub: { _ in false })

        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "out of the glob")
        let dest = OpLogQuarantine.quarantinedFileURL(for: record, in: tmp)
        XCTAssertEqual(try Data(contentsOf: dest), bytes, "byte-identical")
        XCTAssertEqual(record.docId, "doc-1")
        XCTAssertEqual(record.originalName, "doc-1.phone.jsonl")
        XCTAssertEqual(record.reason, "permission denied")
        XCTAssertEqual(record.status, .held)
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).count, 1,
                       "the record round-trips through the ledger")
    }

    /// The stub belt (spec §3): a dataless iCloud stub must never be moved —
    /// moving it fights the download the wait-and-retry rung triggered.
    @MainActor
    func test_quarantine_refusesADatalessStub() throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        try Data("x".utf8).write(to: src)
        XCTAssertThrowsError(try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "r", in: tmp,
            isDatalessStub: { _ in true }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "nothing moved")
    }

    /// Two quarantines of same-named files (the writer hit this twice across
    /// weeks) must not collide: the stamp separates them, both records held.
    @MainActor
    func test_twoQuarantines_ofTheSameName_bothSurvive() throws {
        for content in ["first", "second"] {
            let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
            try Data(content.utf8).write(to: src)
            _ = try OpLogQuarantine.quarantine(
                fileURL: src, docId: "doc-1", reason: "r", in: tmp,
                isDatalessStub: { _ in false })
        }
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).count, 2)
    }
}
