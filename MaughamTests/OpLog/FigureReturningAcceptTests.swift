import XCTest
@testable import Maugham
@testable import MaughamCore

/// **A checkpoint revert's figure note classes** (hardening 11-11 Task 2,
/// #136 W1 and W4, ruling R-A): a figure suggestion follows the manuscript's
/// rule — a restore changes a suggestion only where it rewrites that
/// suggestion's cell. A suggestion accepted at the checkpoint and reverted
/// since returns to accepted when the restore writes its value back
/// (RULING-57's figure twin: `RewindReturningAcceptTests`); one accepted at
/// the checkpoint and now is never stranded (the manuscript's
/// `acceptedAtTarget`); one on a cell the restore does not write keeps its
/// status (`PartialRestoreStrandedAcceptTests`). The walk is Core's
/// `FigureRestoreNotePlan`, pinned by `FigureRestoreNotePlanTests`.
@MainActor
final class FigureReturningAcceptTests: XCTestCase {

    private var projectURL: URL!
    private var identities: LocalIdentities!
    private var cacheURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("fignote-return-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        cacheURL = TestTemp.root.appendingPathComponent("fignote-return-cache-\(UUID().uuidString).json")
        identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: cacheURL, identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
        try "Words.\n".write(
            to: projectURL.appendingPathComponent("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "piece-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
    }

    override func tearDown() async throws {
        FigureDocument.betweenRestoreOpsForTesting = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Fixture

    private static let checkpoint = "cp-1"

    private func text(_ s: String) -> Cell { Cell(content: .value(.text(s))) }
    private func number(_ n: Double) -> Cell { Cell(content: .value(.number(n))) }

    private func load(_ id: String) async throws -> FigureDocument {
        try await FigureDocument.load(
            figureId: id, projectURL: projectURL, actor: .author, session: "s", presenter: nil,
            documentStore: nil)
    }

    /// A whole-book table figure and its host, B2 holding "old".
    private func makeTable() async throws -> (FigureRecord, FigureDocument, CellKey) {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: nil)
        let doc = try await load(record.id)
        let b2 = CellKey(row: doc.state.table.rows[1], column: doc.state.table.columns[1])
        try await doc.setCell(text("old"), at: b2)
        return (record, doc, b2)
    }

    /// The assistant suggests `cell` for `key`, recording what the cell held.
    private func suggest(_ cell: Cell?, at key: CellKey, on doc: FigureDocument) async throws -> String {
        let op = try FigureAnnotationOps.creation(
            kind: .suggestedChange, anchor: FigureCellAnchor(row: key.row, column: key.column),
            body: "Should be this", suggestedCell: cell, prior: doc.state.table[key],
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: doc.figureId, device: Document.loadIdentities[.assistant].deviceId))
        try await Document.makeLoadOpStore(projectURL: projectURL, presenter: nil).append(op)
        try await doc.reload()
        return op.opId
    }

    /// Every op in the stream, seals excluded, in op-id order.
    private func ops(of figureId: String) throws -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return try OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL).flatMap { url in
            try Data(contentsOf: url)
                .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
                .compactMap { line -> Op? in
                    let data = Data(line)
                    return OpLogChain.isSealLine(data) ? nil : try? dec.decode(Op.self, from: data)
                }
        }.sorted { $0.opId < $1.opId }
    }

    private func status(_ id: String, in doc: FigureDocument) -> AnnotationStatus? {
        doc.annotations().first { $0.id == id }?.status
    }

    /// ⌘Z or ⇧⌘Z, its work landed.
    private func press(_ undo: Bool, _ um: UndoManager, _ doc: FigureDocument) async {
        if undo { um.undo() } else { um.redo() }
        await doc.awaitPendingUndoWork()
    }

    // MARK: - Returning

    /// **A reverted accept returns to accepted when the restore writes its
    /// value back** (W1; RULING-57's figure twin): suggest old→42, accept,
    /// checkpoint, ⌘Z, restore — the cell is 42 again by ONE `claudeAccept`
    /// carrying the cell and the note's id, stamped with the checkpoint, and
    /// the note is accepted. Reject is never offered over the returned value:
    /// it refuses `notOpen`.
    func test_aRevertedAcceptReturnsToAccepted_whenTheRestoreWritesItsValueBack() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        let um = UndoManager()
        try await doc.acceptSuggestion(id: id, undoManager: um)
        let pointer = try XCTUnwrap(try ops(of: record.id).last?.opId)
        await press(true, um, doc)
        XCTAssertEqual(status(id, in: doc), .open, "premise: the ⌘Z reopened it")
        XCTAssertEqual(doc.state.table[b2], text("old"), "premise: and put the cell back")
        let before = try ops(of: record.id).count

        let outcome = try await doc.restoreToCheckpoint(Self.checkpoint, through: pointer)

        XCTAssertEqual(outcome, .restored(opCount: 1))
        XCTAssertEqual(doc.state.table[b2], number(42))
        XCTAssertEqual(status(id, in: doc), .accepted)
        let written = Array(try ops(of: record.id).dropFirst(before))
        XCTAssertEqual(written.map(\.kind), [.claudeAccept], "exactly one op: cell and note together")
        XCTAssertEqual(written.first?.provenance?.sourceAnnotationId, id)
        XCTAssertEqual(written.first?.provenance?.sourceCheckpoint, Self.checkpoint)
        XCTAssertEqual(written.first?.figure?.cell, b2)
        XCTAssertEqual(written.first?.figure?.next, number(42))
        XCTAssertEqual(written.first?.figure?.prior, text("old"))
        XCTAssertEqual(doc.lastRestoreNotes, FigureRestoreNotes(reaccepted: [id]))
        do {
            try await doc.rejectAnnotation(id: id)
            XCTFail("Reject was offered over the returned value")
        } catch let error as FigureNoteError {
            XCTAssertEqual(error, .notOpen)
        }

        let fresh = try await load(record.id)
        XCTAssertEqual(fresh.state.table[b2], number(42))
        XCTAssertEqual(status(id, in: fresh), .accepted)
        await fresh.close()
        await doc.close()
    }

    /// **Accepted at the checkpoint and now is never stranded** (the
    /// manuscript's `acceptedAtTarget`; #136 verification cases 1 and 2):
    /// accept, checkpoint, ⌘Z, ⇧⌘Z, restore — nothing written, the note
    /// accepted over 42. Then a hand edit to "hand" and restore again: 42
    /// comes back as a plain `figureCellSet`, and the note stays accepted.
    func test_acceptedAtTheCheckpointAndNow_isNotStranded() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        let um = UndoManager()
        try await doc.acceptSuggestion(id: id, undoManager: um)
        let pointer = try XCTUnwrap(try ops(of: record.id).last?.opId)
        await press(true, um, doc)
        await press(false, um, doc)
        XCTAssertEqual(status(id, in: doc), .accepted, "premise: ⇧⌘Z accepted it again")
        var before = try ops(of: record.id).count

        let unchanged = try await doc.restoreToCheckpoint(Self.checkpoint, through: pointer)

        XCTAssertEqual(unchanged, .unchanged)
        XCTAssertEqual(try ops(of: record.id).count, before, "no note line")
        XCTAssertEqual(status(id, in: doc), .accepted)
        XCTAssertEqual(doc.state.table[b2], number(42))

        try await doc.setCell(text("hand"), at: b2)
        before = try ops(of: record.id).count

        let restored = try await doc.restoreToCheckpoint(Self.checkpoint, through: pointer)

        XCTAssertEqual(restored, .restored(opCount: 1))
        let written = Array(try ops(of: record.id).dropFirst(before))
        XCTAssertEqual(written.map(\.kind), [.figureCellSet], "a plain cell set")
        XCTAssertNil(written.first?.provenance?.sourceAnnotationId, "carrying no note")
        XCTAssertEqual(written.first?.figure?.next, number(42))
        XCTAssertEqual(doc.state.table[b2], number(42))
        XCTAssertEqual(status(id, in: doc), .accepted)
        XCTAssertEqual(doc.lastRestoreNotes, FigureRestoreNotes())
        await doc.close()
    }

    /// **A cell the restore does not write keeps its note** (W4, ruling R-A's
    /// example): 42 typed by hand, checkpoint, then the old→42 suggestion
    /// accepted — the restore finds the cell as it was then, writes nothing,
    /// and the note stays accepted.
    func test_aCellTheRestoreDoesNotWrite_keepsItsNote() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        try await doc.setCell(number(42), at: b2)
        let pointer = try XCTUnwrap(try ops(of: record.id).last?.opId)
        try await doc.acceptSuggestion(id: id)
        XCTAssertEqual(status(id, in: doc), .accepted, "premise: accepted after the checkpoint")
        let before = try ops(of: record.id).count

        let outcome = try await doc.restoreToCheckpoint(Self.checkpoint, through: pointer)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(try ops(of: record.id).count, before, "zero ops")
        XCTAssertEqual(status(id, in: doc), .accepted)
        XCTAssertEqual(doc.state.table[b2], number(42))
        XCTAssertEqual(doc.lastRestoreNotes, FigureRestoreNotes())
        await doc.close()
    }

    // MARK: - Review focus

    /// **A part-way stop after the returning accept, then a retry** (Review
    /// Focus 1): a reload after the `claudeAccept` lands stops the restore
    /// (`.partlyRestored`); restoring again finishes the rest, and the log
    /// holds ONE checkpoint-stamped `claudeAccept` for the note — the note,
    /// accepted again, is no longer open, so it is not returning twice.
    func test_aStopAfterTheReturningAccept_andARetry_writeOneAccept() async throws {
        let (record, doc, _) = try await makeTable()
        // The restore writes cells in (row id, column id) order: the
        // suggestion's cell first, a hand-edited one after it.
        let keys = doc.state.table.rows.flatMap { row in
            doc.state.table.columns.map { CellKey(row: row, column: $0) }
        }.sorted { ($0.row.raw, $0.column.raw) < ($1.row.raw, $1.column.raw) }
        let (first, last) = (try XCTUnwrap(keys.first), try XCTUnwrap(keys.last))
        XCTAssertNotEqual(first, last, "premise: two cells")
        try await doc.setCell(text("old"), at: first)
        let id = try await suggest(number(42), at: first, on: doc)
        let um = UndoManager()
        try await doc.acceptSuggestion(id: id, undoManager: um)
        let pointer = try XCTUnwrap(try ops(of: record.id).last?.opId)
        await press(true, um, doc)
        let lastThen = doc.state.table[last]
        try await doc.setCell(text("hand"), at: last)
        let before = try ops(of: record.id).count
        final class Seen { var landed: [OpKind] = [] }
        let seen = Seen()
        FigureDocument.betweenRestoreOpsForTesting = { doc in
            FigureDocument.betweenRestoreOpsForTesting = nil
            seen.landed = doc._ops.suffix(1).map(\.kind)
            try? await doc.reload()
        }

        let outcome = try await doc.restoreToCheckpoint(Self.checkpoint, through: pointer)

        XCTAssertEqual(seen.landed, [.claudeAccept], "premise: the returning accept landed first")
        XCTAssertEqual(outcome, .partlyRestored(opCount: 1, why: .changedElsewhere))
        XCTAssertEqual(status(id, in: doc), .accepted)
        XCTAssertEqual(doc.lastRestoreNotes, FigureRestoreNotes(reaccepted: [id]), "what landed")

        let retry = try await doc.restoreToCheckpoint(Self.checkpoint, through: pointer)

        XCTAssertEqual(retry, .restored(opCount: 1), "only the hand-edited cell is left")
        let written = Array(try ops(of: record.id).dropFirst(before))
        XCTAssertEqual(written.map(\.kind), [.claudeAccept, .figureCellSet])
        let accepts = try ops(of: record.id).filter {
            $0.kind == .claudeAccept && $0.provenance?.sourceAnnotationId == id
                && $0.provenance?.sourceCheckpoint == Self.checkpoint
        }
        XCTAssertEqual(accepts.count, 1, "one checkpoint-stamped accept, not two")
        XCTAssertEqual(doc.lastRestoreNotes, FigureRestoreNotes())
        XCTAssertEqual(doc.state.table[first], number(42))
        XCTAssertEqual(doc.state.table[last], lastThen)
        XCTAssertEqual(status(id, in: doc), .accepted)
        await doc.close()
    }

    /// **Two suggestions on one cell, both accepted after the checkpoint**
    /// (Review Focus 3, the coordinator's ruling): the restore's one change
    /// to the cell carries the note whose cell-carrying accept is NEWEST —
    /// the second, accepted over the first — as its `claudeAcceptRevert`;
    /// the first gets a status-only revert, only because its cell was
    /// written. Neither ends accepted over a value it did not suggest, and
    /// neither is left open over its own value.
    func test_twoSuggestionsOnOneCell_theNewestAcceptCarriesTheChange() async throws {
        let (record, doc, b2) = try await makeTable()
        let older = try await suggest(number(42), at: b2, on: doc)
        let newer = try await suggest(number(7), at: b2, on: doc)
        let pointer = try XCTUnwrap(try ops(of: record.id).last?.opId)
        try await doc.acceptSuggestion(id: older)
        try await doc.acceptSuggestion(id: newer, confirmChanged: true)
        XCTAssertEqual([status(older, in: doc), status(newer, in: doc)], [.accepted, .accepted], "premise")
        XCTAssertEqual(doc.state.table[b2], number(7), "premise: the newer accept wrote last")
        let before = try ops(of: record.id).count

        _ = try await doc.restoreToCheckpoint(Self.checkpoint, through: pointer)

        let written = Array(try ops(of: record.id).dropFirst(before))
        XCTAssertEqual(written.map(\.kind), [.claudeAcceptRevert, .claudeAcceptRevert])
        XCTAssertEqual(written[0].provenance?.sourceAnnotationId, newer, "the change carries the newest accept")
        XCTAssertEqual(written[0].figure?.cell, b2)
        XCTAssertEqual(written[0].figure?.next, text("old"))
        XCTAssertEqual(written[1].provenance?.sourceAnnotationId, older)
        XCTAssertNil(written[1].figure, "status only: its cell was written by the other's change")
        XCTAssertEqual(written.map(\.provenance?.sourceCheckpoint), [Self.checkpoint, Self.checkpoint])
        XCTAssertEqual(doc.state.table[b2], text("old"))
        XCTAssertEqual([status(older, in: doc), status(newer, in: doc)], [.open, .open],
                       "neither accepted over a value it did not suggest; neither open over its own")
        XCTAssertEqual(doc.lastRestoreNotes, FigureRestoreNotes(reopened: [newer, older]))
        await doc.close()
    }
}
