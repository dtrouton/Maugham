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

    // MARK: - Lines set aside by provenance (Task 4)

    /// (g) The same foreign bytes found again are one record, not two — the
    /// hash of the lines is in the destination name, exactly as
    /// `IntegrityQuarantine.record` dedupes a persistent tear.
    @MainActor
    func test_setAsideLines_isContentDeduped() throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.maca.jsonl")
        let lines = [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)]

        let first = try OpLogQuarantine.setAsideLines(
            lines, from: src, docId: "doc-1", reason: "written by something that is not Maugham",
            in: tmp)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.kind, .lines)
        XCTAssertEqual(first?.status, .held)

        let second = try OpLogQuarantine.setAsideLines(
            lines, from: src, docId: "doc-1", reason: "written by something that is not Maugham",
            in: tmp)
        XCTAssertNil(second, "the same bytes for the same file are already on file")

        let dir = tmp.appendingPathComponent(".maugham/conflicts/quarantined-ops")
        let archives = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lines" }
        XCTAssertEqual(archives.count, 1, "one file on disk")
        XCTAssertEqual(try Data(contentsOf: archives[0]),
                       Data("{\"a\":1}\n{\"b\":2}\n".utf8),
                       "the bytes verbatim, newline-separated")
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).count, 1)
    }

    /// Different bytes are a different event and get their own record.
    @MainActor
    func test_setAsideLines_differentBytesGetTheirOwnRecord() throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.maca.jsonl")
        XCTAssertNotNil(try OpLogQuarantine.setAsideLines(
            [Data("one".utf8)], from: src, docId: "doc-1", reason: "r", in: tmp))
        XCTAssertNotNil(try OpLogQuarantine.setAsideLines(
            [Data("two".utf8)], from: src, docId: "doc-1", reason: "r", in: tmp))
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).count, 2)
    }

    /// (g) A `.lines` record has nowhere to go back to. `attemptReturn` says so
    /// and touches nothing: the live file stays, the archive stays.
    @MainActor
    func test_attemptReturn_onALinesRecord_movesNothing() async throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.maca.jsonl")
        try writeJSONL([opFixture("aaaa")], to: src)
        let liveBytes = try Data(contentsOf: src)

        let record = try XCTUnwrap(try OpLogQuarantine.setAsideLines(
            [Data("{\"stranger\":true}".utf8)], from: src, docId: "doc-1",
            reason: "written by something that is not Maugham", in: tmp))
        let archive = OpLogQuarantine.quarantinedFileURL(for: record, in: tmp)

        let outcome = await OpLogQuarantine.attemptReturn(record: record, in: tmp, presenter: nil)
        XCTAssertEqual(outcome, .setAsideByProvenance)
        XCTAssertEqual(try Data(contentsOf: src), liveBytes, "the live file is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path),
                      "the forensics stay where they are")
        XCTAssertEqual(OpLogQuarantine.records(forDocId: "doc-1", in: tmp).first?.status, .held)
    }

    /// A record written before `kind` existed decodes as `.file`, so the whole
    /// ledger already on disk keeps its meaning without a migration.
    func test_aRecordWithNoKindDecodesAsAFile() throws {
        let json = Data("""
            {"docId":"doc-1","originalName":"doc-1.maca.jsonl",\
            "quarantinedAt":1,"reason":"torn","status":"held"}
            """.utf8)
        let record = try JSONDecoder().decode(QuarantineRecord.self, from: json)
        XCTAssertEqual(record.kind, .file)
    }

    // MARK: - The revocation partition (find 5, RULED 2026-09-18)

    private let mark = "01K5Q8ZJ3M0000000000000005"

    /// Only a revocation partitions. A broken chain has no *before*, so nothing
    /// is re-admitted and every line stays refused.
    func test_acauseThatIsNotARevocationReadmitsNothingWhateverTheMark() {
        let lines = [opLine("01K5Q8ZJ3M0000000000000001"),
                     opLine("01K5Q8ZJ3M0000000000000009")]
        let verification = quarantinedVerification(
            lines, cause: .chainBroke(.prevMismatch(lineIndex: 0)))

        XCTAssertNil(RevocationSplit.partition(
            of: verification, highestOpIdSeen: mark))
    }

    /// **The default revocation keeps what this Mac had already applied.** The
    /// mark is the highest opId it had applied from that device, so an op at or
    /// below it was in the manuscript before the writer revoked anybody, and
    /// taking it out would be the revocation reaching backwards into work the
    /// writer has read.
    func test_anOpAtOrBelowTheMarkIsReadmittedAndOneAboveItIsRefused() {
        let before = opLine("01K5Q8ZJ3M0000000000000001")
        let atTheMark = opLine(mark)
        let after = opLine("01K5Q8ZJ3M0000000000000009")

        let split = RevocationSplit.partition(
            of: quarantinedVerification(
                [before, atTheMark, after], cause: .afterRevocation(person: "aaaa")),
            highestOpIdSeen: mark)

        XCTAssertEqual(split?.readmitted, [before, atTheMark],
                       "the mark itself is an op this Mac HAD applied — the smoke's "
                           + "own case, where B's only op was the mark")
        XCTAssertEqual(split?.refused, [after])
    }

    /// **A seal travels with the op immediately before it in file order** (P2
    /// smoke, find 6's third cause). A seal carries no opId of its own, and the
    /// span it closes is the one ending at the line above it; filing `seal1`
    /// under *after revocation* while `op1` was re-admitted would accuse the
    /// signature of a position its own op does not have.
    func test_asealTravelsWithTheOpItSeals() {
        let op1 = opLine("01K5Q8ZJ3M0000000000000001")
        let seal1 = Data(#"{"seal":{"key":"aaaa"}}"#.utf8)
        let op2 = opLine("01K5Q8ZJ3M0000000000000009")
        let seal2 = Data(#"{"seal":{"key":"bbbb"}}"#.utf8)

        let split = RevocationSplit.partition(
            of: quarantinedVerification(
                [op1, seal1, op2, seal2], cause: .afterRevocation(person: "aaaa")),
            highestOpIdSeen: mark)

        XCTAssertEqual(split?.readmitted, [op1, seal1])
        XCTAssertEqual(split?.refused, [op2, seal2])
    }

    /// The same rule at the head of a span, where there is no op to travel
    /// with: a line whose position cannot be established from an op of its own
    /// stays refused, which is the strict side and the side to be wrong on.
    func test_alineWithNoOpBeforeItStaysRefused() {
        let unplaceable = Data("{not json at all".utf8)
        let late = opLine("01K5Q8ZJ3M0000000000000001")

        let split = RevocationSplit.partition(
            of: quarantinedVerification(
                [unplaceable, late], cause: .afterRevocation(person: "aaaa")),
            highestOpIdSeen: mark)

        XCTAssertEqual(split?.refused, [unplaceable])
        XCTAssertEqual(split?.readmitted, [late])
    }

    /// **The whole span is below the mark**, so the revocation set nothing
    /// aside at all — the degenerate case the old two-group return needed a
    /// clause of its own for, which now falls out of the seal rule.
    func test_aspanEntirelyBelowTheMarkIsReadmittedWhole() {
        let op1 = opLine("01K5Q8ZJ3M0000000000000001")
        let seal1 = Data(#"{"seal":{"key":"aaaa"}}"#.utf8)

        let split = RevocationSplit.partition(
            of: quarantinedVerification(
                [op1, seal1], cause: .afterRevocation(person: "aaaa")),
            highestOpIdSeen: mark)

        XCTAssertEqual(split?.readmitted, [op1, seal1])
        XCTAssertEqual(split?.refused, [])
    }

    /// **No mark is the writer's other choice** (find 5's ruling): a revocation
    /// record carrying no `highestOpIdSeen` means *nothing of theirs stands*,
    /// and nothing is re-admitted. It is also what a device this Mac had
    /// applied nothing from produces, which is the same outcome by a different
    /// road.
    func test_arevocationWithNoMarkReadmitsNothing() {
        XCTAssertNil(RevocationSplit.partition(
            of: quarantinedVerification(
                [opLine("01K5Q8ZJ3M0000000000000001")],
                cause: .afterRevocation(person: "aaaa")),
            highestOpIdSeen: nil))
    }

    /// The old two-group rule's own fixture, restated as the partition (the
    /// same answer, by one rule instead of three): an unplaceable line at the
    /// head has no op to travel with and is refused; the op below the mark is
    /// re-admitted; the one above it is refused. What changed is that the
    /// gentler half is no longer a sentence at all — it is applied.
    func test_theOldSplitsFixtureAnsweredByTheTravelRule() {
        let unplaceable = Data("{not json at all".utf8)
        let late = opLine("01K5Q8ZJ3M0000000000000001")
        let after = opLine("01K5Q8ZJ3M0000000000000009")

        let split = RevocationSplit.partition(
            of: quarantinedVerification(
                [unplaceable, late, after], cause: .afterRevocation(person: "aaaa")),
            highestOpIdSeen: mark)

        XCTAssertEqual(split?.refused, [unplaceable, after])
        XCTAssertEqual(split?.readmitted, [late])
    }

    private func opLine(_ opId: String) -> Data {
        Data(#"{"op_id":"\#(opId)","doc_id":"doc-1"}"#.utf8)
    }

    /// A verification carrying nothing but the quarantined lines and their
    /// cause — the two inputs the split reads. Built by hand rather than walked,
    /// because what is under test is the split and not the walk.
    private func quarantinedVerification(
        _ lines: [Data], cause: OpLogChain.QuarantineCause
    ) -> OpLogChain.Verification {
        OpLogChain.Verification(
            lines: lines.map { OpLogChain.Line(bytes: $0, kind: .op, state: .quarantined) },
            head: nil, legacyCount: 0, verifiedCount: 0, unsealedCount: 0,
            pendingCount: 0, foreignSealCount: 0, quarantined: lines,
            breakReason: nil, quarantineCause: cause)
    }
}

/// **What the set-aside sentence counts** (signed op log P2 smoke, finds 6 and
/// 7).
///
/// The smoke put *6 changes set aside* in front of a writer who had two. Three
/// things were wrong with the number and two of them are this file's: seal lines
/// were counted as changes, and one op that reached the archive twice — the span
/// was set aside once, then split differently on the next load — was counted
/// twice. The third (a seal filed in the wrong half of a revocation split) is
/// `RevocationSplit.groups`' and is deliberately NOT what makes the number
/// right: counting op lines alone makes the count immune to which half a seal
/// travels in.
///
/// Find 7 is the other half of the sentence's honesty: a `.lines` record is
/// permanent evidence, so it is listed forever — but once the writer admits the
/// device, the ops in it are APPLIED, and *set aside* has stopped being true of
/// them.
final class SetAsideChangeCountTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("setaside-count-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".maugham/ops"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    /// A seal is a signature over a span, not a change in it. Two ops under one
    /// seal are three lines and two changes — the rule
    /// `OpLogChain.pendingByDevice` has applied to the HELD half since P2b.
    func test_aSealIsNotAChange() throws {
        let record = try file([op("01M2RMZS8S08J1MKA7CPTFK4MS"), seal(), op("01M2RNCJ4384V357PT3EG049SW"), seal()],
                              reason: "the history's chain is broken")

        XCTAssertEqual(
            OpLogQuarantine.setAsideChanges(records: [record], in: tmp).map(\.id),
            ["01M2RMZS8S08J1MKA7CPTFK4MS", "01M2RNCJ4384V357PT3EG049SW"],
            "four lines, two changes")
        XCTAssertEqual(
            OpLogQuarantine.setAsideChangeCount(records: [record], in: tmp), 2)
    }

    /// **The smoke's own shape.** Mac B's first op was set aside once as
    /// `[op1, seal1]`, and again on the next load as `[op1]` plus
    /// `[seal1, op2, seal2]` — three records, six lines, four op lines, and two
    /// changes. The reason a change is filed under is the FIRST record's.
    func test_oneOpInTwoRecordsIsOneChange() throws {
        let first = op("01M2RMZS8S08J1MKA7CPTFK4MS")
        let second = op("01M2RNCJ4384V357PT3EG049SW")
        // Two live reasons: one archive per cause, which is what a span set
        // aside twice under different walks looks like on disk.
        let late = "written after this device was retired"
        let after = "written after this device's access was withdrawn"

        let r1 = try file([first, seal()], reason: late, at: 1)
        let r2 = try file([seal(), second, seal()], reason: after, at: 2)
        let r3 = try file([first], reason: late, at: 3)

        let changes = OpLogQuarantine.setAsideChanges(records: [r1, r2, r3], in: tmp)
        XCTAssertEqual(changes, [
            SetAsideChange(id: "01M2RMZS8S08J1MKA7CPTFK4MS", reason: late),
            SetAsideChange(id: "01M2RNCJ4384V357PT3EG049SW", reason: after),
        ], "six lines across three records are two changes")
        XCTAssertEqual(
            OpLogQuarantine.setAsideChangeCount(records: [r1, r2, r3], in: tmp), 2,
            "and the sentence says two, not six")
    }

    /// Order is by (`quarantinedAt`, archive name), so the attribution of a
    /// change held in two records does not depend on how the folder enumerated.
    func test_theReasonIsTheFirstRecordsHoweverTheFolderEnumerates() throws {
        let shared = op("01M2RMZS8S08J1MKA7CPTFK4MS")
        let late = "written after this device was retired"
        let after = "written after this device's access was withdrawn"
        let earlier = try file([shared], reason: late, at: 1)
        let later = try file([shared, op("01M2RNCJ4384V357PT3EG049SW")], reason: after, at: 2)

        for order in [[earlier, later], [later, earlier]] {
            XCTAssertEqual(
                OpLogQuarantine.setAsideChanges(records: order, in: tmp).first?.reason,
                late,
                "the earlier record named it first")
        }
    }

    /// **Find 7.** After a re-admission the ops apply, and the sentence must
    /// stop claiming them — while the records stay on disk for the disclosure
    /// to go on listing.
    func test_anAppliedChangeIsNoLongerSetAside() throws {
        let record = try file([op("01M2RMZS8S08J1MKA7CPTFK4MS"), seal(), op("01M2RNCJ4384V357PT3EG049SW")],
                              reason: "written after this device's access was withdrawn")

        XCTAssertEqual(
            OpLogQuarantine.setAsideChangeCount(records: [record], in: tmp), 2,
            "premise: held, so both are set aside")
        XCTAssertEqual(
            OpLogQuarantine.setAsideChangeCount(
                records: [record], in: tmp, applied: ["01M2RMZS8S08J1MKA7CPTFK4MS"]),
            1,
            "one of them is in the draft now")
        XCTAssertEqual(
            OpLogQuarantine.setAsideChangeCount(
                records: [record], in: tmp,
                applied: ["01M2RMZS8S08J1MKA7CPTFK4MS", "01M2RNCJ4384V357PT3EG049SW"]),
            0,
            "and with every one applied the sentence goes away entirely")
        XCTAssertEqual(
            OpLogQuarantine.records(forDocId: "doc-1", in: tmp).count, 1,
            "the evidence is untouched by any of this")
    }

    /// An inbox manifest row has no `op_id`; its own `id` is its identity, so
    /// the inbox's sentence dedupes on the same rule the op log's does.
    func test_anInboxRowIsIdentifiedByItsOwnId() throws {
        let row = Data(#"{"id":"01M2RMZS8S08J1MKA7CPTFK4MS","kind":"text"}"#.utf8)
        let a = try file([row], reason: "r", at: 1)
        let b = try file([row, Data(#"{"id":"01M2RNCJ4384V357PT3EG049SW","kind":"text"}"#.utf8)],
                         reason: "r", at: 2)

        XCTAssertEqual(
            OpLogQuarantine.setAsideChanges(records: [a, b], in: tmp).map(\.id),
            ["01M2RMZS8S08J1MKA7CPTFK4MS", "01M2RNCJ4384V357PT3EG049SW"])
    }

    /// A line naming no identity of its own is keyed on its bytes: the same
    /// bytes in two records are one change, and two different unreadable lines
    /// stay two.
    func test_aLineWithNoIdentityIsKeyedOnItsBytes() throws {
        let strange = Data("{not json at all".utf8)
        let other = Data(#"{"hello":"world"}"#.utf8)
        let a = try file([strange, other], reason: "r", at: 1)
        let b = try file([strange], reason: "r", at: 2)

        XCTAssertEqual(
            OpLogQuarantine.setAsideChangeCount(records: [a, b], in: tmp), 2,
            "three lines, two distinct ones")
    }

    /// A whole set-aside FILE is the Retry notice's subject; its line count is a
    /// different quantity and is not this sentence's.
    @MainActor
    func test_aWholeFileRecordIsNotCounted() throws {
        let src = tmp.appendingPathComponent(".maugham/ops/doc-1.maca.jsonl")
        try Data("{\"op_id\":\"01M2RMZS8S08J1MKA7CPTFK4MS\"}\n".utf8).write(to: src)
        let record = try OpLogQuarantine.quarantine(
            fileURL: src, docId: "doc-1", reason: "permission denied", in: tmp,
            isDatalessStub: { _ in false })

        XCTAssertEqual(OpLogQuarantine.setAsideChanges(records: [record], in: tmp), [])
    }

    // MARK: - Fixtures

    private func op(_ opId: String) -> Data {
        Data(#"{"prev":"abc","op_id":"\#(opId)","doc_id":"doc-1"}"#.utf8)
    }

    /// A seal line as `OpLogChain` writes one: the `{"seal":` prefix is the
    /// whole of what `isSealLine` recognises, and this file must not spell a
    /// second recogniser (tripwire 37) — it writes a line and lets the one
    /// recogniser judge it.
    private func seal() -> Data {
        Data(#"{"seal":{"at":"2026-09-17T21:39:58.365Z","head":"abc","key":"k","sig":"s"}}"#.utf8)
    }

    private func file(
        _ lines: [Data], reason: String, at second: TimeInterval = 0
    ) throws -> QuarantineRecord {
        try XCTUnwrap(OpLogQuarantine.setAsideLines(
            lines,
            from: tmp.appendingPathComponent(".maugham/ops/doc-1.macb.jsonl"),
            docId: "doc-1", reason: reason, in: tmp,
            now: Date(timeIntervalSince1970: 1_000_000 + second)))
    }
}
