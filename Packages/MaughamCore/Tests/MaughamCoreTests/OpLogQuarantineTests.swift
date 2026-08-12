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

    // MARK: - attemptReturn

    private func encode(_ op: Op) -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        return String(data: try! enc.encode(op), encoding: .utf8)!
    }

    private func opFixture(_ id: String, docId: String = "doc-1") -> Op {
        Op(opId: id, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: "phone", session: "s", kind: .typingBurst, changes: [],
           sequence: nil, provenance: nil)
    }

    private func writeJSONL(_ ops: [Op], to url: URL) throws {
        try (ops.map(encode).joined(separator: "\n") + "\n").write(
            to: url, atomically: true, encoding: .utf8)
    }

    /// Destination absent (the common case — nothing has recreated the
    /// device file since it was set aside): a verified read, a coordinated
    /// move back, and the record flips to `.returned`.
    @MainActor
    func test_return_destinationAbsent_movesBackAndReports() async throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        try writeJSONL([opFixture("aaaa"), opFixture("bbbb")], to: src)

        let record = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "torn line",
            in: tmp, isDatalessStub: { _ in false })
        let quarantinedURL = OpLogQuarantine.quarantinedFileURL(for: record, in: tmp)
        let quarantinedBytes = try Data(contentsOf: quarantinedURL)

        let outcome = await OpLogQuarantine.attemptReturn(record: record, in: tmp, presenter: nil)

        guard case .returned(let report) = outcome else {
            return XCTFail("expected .returned, got \(outcome)")
        }
        XCTAssertFalse(report.redundant, "nothing at the destination to make this redundant")
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinedURL.path),
                       "moved, not copied — gone from quarantined-ops")
        XCTAssertEqual(try Data(contentsOf: src), quarantinedBytes, "byte-identical move")
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).first?.status, .returned)
    }

    /// Destination present (sync recreated the device file while it was set
    /// aside, and the quarantined content is a strict subset of it): no
    /// move — the archive stays exactly where it is — and the record flips
    /// to `.superseded`.
    @MainActor
    func test_return_destinationPresent_neverOverwrites_archiveStays() async throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        try writeJSONL([opFixture("aaaa")], to: src)

        let record = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "torn line",
            in: tmp, isDatalessStub: { _ in false })
        let quarantinedURL = OpLogQuarantine.quarantinedFileURL(for: record, in: tmp)
        let quarantinedBytes = try Data(contentsOf: quarantinedURL)

        // Sync recreated the device file — a strict superset of what was quarantined.
        let currentBody = [opFixture("aaaa"), opFixture("bbbb")]
        try writeJSONL(currentBody, to: src)
        let currentBytes = try Data(contentsOf: src)

        let outcome = await OpLogQuarantine.attemptReturn(record: record, in: tmp, presenter: nil)

        guard case .supersededBySync(let report) = outcome else {
            return XCTFail("expected .supersededBySync, got \(outcome)")
        }
        XCTAssertTrue(report.redundant, "everything quarantined already lives in the current log")
        XCTAssertEqual(try Data(contentsOf: quarantinedURL), quarantinedBytes,
                       "archive untouched — never overwritten")
        XCTAssertEqual(try Data(contentsOf: src), currentBytes, "sync's file untouched")
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).first?.status, .superseded)
    }

    /// A torn line inside the quarantined file: readable bytes, but a line
    /// fails to decode. Salvage is the integrity path's job, not a merge
    /// input (spec §5 step 1) — this stays held, nothing moves.
    @MainActor
    func test_return_tornLine_staysHeld() async throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        let bytes = Data("torn \u{0} garbage the reader refused".utf8)  // not valid JSON
        try bytes.write(to: src)

        let record = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "torn line",
            in: tmp, isDatalessStub: { _ in false })
        let quarantinedURL = OpLogQuarantine.quarantinedFileURL(for: record, in: tmp)

        let outcome = await OpLogQuarantine.attemptReturn(record: record, in: tmp, presenter: nil)

        guard case .corrupt = outcome else {
            return XCTFail("expected .corrupt, got \(outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path), "nothing moved")
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).first?.status, .held)
    }

    /// An unreadable quarantined file (a directory squatting on the path —
    /// the coordinated read itself fails): stays held, nothing moves.
    @MainActor
    func test_return_unreadable_staysHeld() async throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        try Data("x".utf8).write(to: src)

        let record = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "permission denied",
            in: tmp, isDatalessStub: { _ in false })
        let quarantinedURL = OpLogQuarantine.quarantinedFileURL(for: record, in: tmp)

        try FileManager.default.removeItem(at: quarantinedURL)
        try FileManager.default.createDirectory(at: quarantinedURL, withIntermediateDirectories: true)

        let outcome = await OpLogQuarantine.attemptReturn(record: record, in: tmp, presenter: nil)

        guard case .stillUnreadable = outcome else {
            return XCTFail("expected .stillUnreadable, got \(outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path), "nothing moved")
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).first?.status, .held)
    }

    /// Fix round 1: a sidecar rewrite can fail AFTER `attemptReturn`'s move
    /// already succeeded — the move can't be unwound at that point, so the
    /// record is left saying `.held` for a file that, in fact, already
    /// returned. `records()` must read that situation honestly rather than
    /// reporting it as still set aside. Simulated directly (move the bytes
    /// by hand, leave the sidecar untouched) rather than by forcing the
    /// real write to fail, so this pins the READ-time correction itself.
    @MainActor
    func test_records_selfCorrectsAStaleHeldRecord_overAnAlreadyReturnedFile() throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        try writeJSONL([opFixture("aaaa")], to: src)

        let record = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "torn line",
            in: tmp, isDatalessStub: { _ in false })
        let quarantinedURL = OpLogQuarantine.quarantinedFileURL(for: record, in: tmp)
        XCTAssertEqual(record.status, .held)

        // What attemptReturn's move step does, minus the sidecar rewrite
        // that (in this scenario) failed afterward.
        try FileManager.default.moveItem(at: quarantinedURL, to: src)

        let reconciled = OpLogQuarantine.records(forDocId: "doc-1", in: tmp).first
        XCTAssertEqual(reconciled?.status, .returned,
                       "the move already happened — reporting .held would be dishonest")
    }
}
