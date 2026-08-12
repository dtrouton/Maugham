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

    private func opFixture(
        _ id: String, docId: String = "doc-1",
        changes: [Op.ParagraphChange] = [], sequence: [String]? = nil
    ) -> Op {
        Op(opId: id, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: "phone", session: "s", kind: .typingBurst, changes: changes,
           sequence: sequence, provenance: nil)
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

    // MARK: - The superseded branch's report (whole-branch review C1)

    /// **The reproduction.** Sync recreated the device file from a DIVERGENT,
    /// older generation while the archive was set aside, and the archive holds
    /// the keyframe that would have won a merge. Nothing moves on this branch,
    /// so the archive's paragraphs are in no readable log — and they must be
    /// reported as orphans. Before the fix the report was computed against the
    /// hypothetical merge, so it read empty, the record flipped `.superseded`,
    /// the standing notice disappeared and the toast said "nothing was
    /// missing".
    @MainActor
    func test_return_destinationPresentWithDivergentContent_reportsTheArchivesOwnParagraphs() async throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        try writeJSONL([
            opFixture("aaaa", changes: [.init(paragraphId: "abcd", prior: nil, next: "archive-1")],
                      sequence: ["abcd", "efgh"]),
            opFixture("bbbb", changes: [.init(paragraphId: "efgh", prior: nil, next: "archive-2")],
                      sequence: ["abcd", "efgh"]),
        ], to: src)

        let record = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "torn line",
            in: tmp, isDatalessStub: { _ in false })
        let quarantinedURL = OpLogQuarantine.quarantinedFileURL(for: record, in: tmp)

        // Sync recreates the device file — an older generation with its own
        // keyframe, sharing not one opId with the archive.
        try writeJSONL([
            opFixture("0001", changes: [.init(paragraphId: "jkmn", prior: nil, next: "recreated")],
                      sequence: ["jkmn"]),
        ], to: src)

        let outcome = await OpLogQuarantine.attemptReturn(record: record, in: tmp, presenter: nil)

        guard case .supersededBySync(let report) = outcome else {
            return XCTFail("expected .supersededBySync, got \(outcome)")
        }
        XCTAssertEqual(report.orphans.map(\.paragraphId), ["abcd", "efgh"],
                       "the archive did not move — its paragraphs are in no readable log")
        XCTAssertFalse(report.redundant,
                       "the live log holds neither archive op — this is the lossy case")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path),
                      "archive untouched — never overwritten")
    }

    // MARK: - The sidecar is written first (review M1)

    /// A failed sidecar write must strand NOTHING: the bytes stay in
    /// `.maugham/ops/` and no record is filed. With the sidecar written after
    /// the move (the shipped order) this test fails exactly the way the review
    /// described — the file is gone from `.maugham/ops/` and nothing records
    /// where it went.
    ///
    /// **The plant is a filename length.** A name of 220 characters makes the
    /// stamped DESTINATION name legal (220 + 1 + the 24-character stamp = 245,
    /// under the 255-byte `NAME_MAX`) while its `.quarantine.json` sidecar is
    /// not (261) — so the move can succeed and only the record write can fail,
    /// which is the one interleaving that separates the two orders. Planting a
    /// directory at the sidecar path does NOT work for this: the collision
    /// loop (M3) sees it as an existing sidecar and steps politely around it.
    @MainActor
    func test_quarantine_sidecarWriteFailure_movesNothing() throws {
        let longName = String(repeating: "a", count: 214) + ".jsonl"
        let src = tmp.appendingPathComponent(".maugham/ops").appendingPathComponent(longName)
        try Data("x".utf8).write(to: src)

        let now = Date(timeIntervalSince1970: 1_700_000_000.5)
        let stamped = "\(longName).\(OpLogQuarantine.stamp(from: now))"
        XCTAssertLessThanOrEqual(stamped.count, 255, "self-check: the data name must be legal")
        XCTAssertGreaterThan("\(stamped).quarantine.json".count, 255,
                             "self-check: and its sidecar's must not be")

        XCTAssertThrowsError(try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "r", in: tmp, now: now,
            isDatalessStub: { _ in false }))

        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path),
                      "the bytes never left .maugham/ops/ — a record must exist before they do")
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp), [],
                       "and no record was filed")
        let dir = tmp.appendingPathComponent(".maugham/conflicts/quarantined-ops", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(entries, [], "and nothing at all landed in quarantined-ops/")
    }

    /// The other half of the reorder: the move can fail with the record
    /// already written, and that record describes nothing. It must be deleted
    /// rather than left behind as a `.held` row offering a Retry for history
    /// the writer never lost. Planted with a source that does not exist, so
    /// the sidecar write succeeds and only the move fails.
    @MainActor
    func test_quarantine_moveFailure_leavesNoRecordOfNothing() throws {
        let missing = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")

        XCTAssertThrowsError(try OpLogQuarantine.quarantine(
            fileURL: missing, docId: "doc-1", reason: "r", in: tmp,
            isDatalessStub: { _ in false }))

        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp), [],
                       "the record-of-nothing is deleted, not left for the pane to offer")
        let dir = tmp.appendingPathComponent(".maugham/conflicts/quarantined-ops", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(entries.filter { $0.lastPathComponent.hasSuffix(".quarantine.json") }, [],
                       "and no sidecar survives on disk")
    }

    // MARK: - A returned record's sidecar is never overwritten (review M3)

    /// A record that has RETURNED leaves its forensic sidecar behind with the
    /// data file gone. A re-quarantine of the same original name in the same
    /// stamp millisecond must disambiguate around it — the collision loop
    /// probes the sidecar, not only the data path — or the one durable account
    /// of what was set aside and why is overwritten. The same `now` for both
    /// calls is what makes the millisecond collision deterministic.
    @MainActor
    func test_quarantine_sameMillisecond_neverOverwritesAReturnedRecordsSidecar() throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        try writeJSONL([opFixture("aaaa")], to: src)
        let now = Date(timeIntervalSince1970: 1_700_000_000.25)

        let first = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "the first refusal", in: tmp,
            now: now, isDatalessStub: { _ in false })
        // The return: the bytes go back, the sidecar stays behind.
        try FileManager.default.moveItem(
            at: OpLogQuarantine.quarantinedFileURL(for: first, in: tmp), to: src)

        let second = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "the second refusal", in: tmp,
            now: now, isDatalessStub: { _ in false })

        let reasons = OpLogQuarantine.records(forDocId: "doc-1", in: tmp).map(\.reason).sorted()
        XCTAssertEqual(reasons, ["the first refusal", "the second refusal"],
                       "both accounts survive — the second quarantine stepped around the "
                       + "first's sidecar instead of writing over it")
        // Read off the directory rather than through `quarantinedFileURL`: the
        // two records share a `quarantinedAt` to the bit here (the injected
        // `now` is what makes the collision deterministic), which is the one
        // case that function documents as ambiguous.
        let dir = tmp.appendingPathComponent(".maugham/conflicts/quarantined-ops", isDirectory: true)
        let sidecars = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".quarantine.json") }
            .sorted()
        let base = "doc-1.phone.jsonl.\(OpLogQuarantine.stamp(from: now))"
        XCTAssertEqual(sidecars, ["\(base)-2.quarantine.json", "\(base).quarantine.json"].sorted(),
                       "the second landed on a disambiguated name beside the first")
        XCTAssertEqual(second.reason, "the second refusal", "self-check: the second is the returned record")
    }

    // MARK: - `.returned` is sticky (review M2)

    /// The concurrency shape: the auto-return sweep and the History pane's
    /// Retry both run over the same record, one wins the move and writes
    /// `.returned`, and the loser reaches its own rewrite afterwards. Its
    /// `.superseded` must not land — it would send the pane looking in
    /// `quarantined-ops/` for bytes that are back in `.maugham/ops/`. Planted
    /// by hand-writing the winner's verdict, then driving the loser's whole
    /// path through `attemptReturn` with the destination present.
    @MainActor
    func test_rewrite_neverDowngradesAnAlreadyReturnedRecord() async throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.phone.jsonl")
        try writeJSONL([opFixture("aaaa")], to: src)

        let record = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "torn line",
            in: tmp, isDatalessStub: { _ in false })
        let quarantinedURL = OpLogQuarantine.quarantinedFileURL(for: record, in: tmp)

        // The winner: it moved the file back and stamped `.returned`. (The
        // archive is left in place here so the loser's own read still
        // succeeds — that is exactly the interleaving being pinned.)
        try writeJSONL([opFixture("aaaa")], to: src)
        var won = record
        won.status = .returned
        let sidecar = OpLogQuarantine.sidecarURL(
            forQuarantinedName: quarantinedURL.lastPathComponent,
            in: tmp.appendingPathComponent(".maugham/conflicts/quarantined-ops", isDirectory: true))
        try JSONEncoder().encode(won).write(to: sidecar, options: .atomic)

        // The loser, arriving with its stale `.held` snapshot.
        let outcome = await OpLogQuarantine.attemptReturn(record: record, in: tmp, presenter: nil)

        guard case .supersededBySync = outcome else {
            return XCTFail("expected .supersededBySync, got \(outcome)")
        }
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).first?.status, .returned,
                       "`.returned` is terminal — the loser's verdict must not overwrite it")
    }
}
