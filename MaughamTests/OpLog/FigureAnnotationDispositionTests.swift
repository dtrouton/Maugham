import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **The author answers a figure note** (report plan 9c-1 Task 5,
/// `FigureDocument+Annotations.swift`): accepting a suggestion is ONE
/// `claudeAccept` that writes the cell and resolves the note, signed by the
/// author with the note's id recorded; its ⌘Z puts the cell back and reopens
/// the note in one step, inside a grid visit too; the refusals come in the
/// manuscript accept's order; Reject keeps its reason; a reviewer is refused.
@MainActor
final class FigureAnnotationDispositionTests: XCTestCase {

    private var projectURL: URL!
    private var identities: LocalIdentities!
    private var cacheURL: URL!

    private static let pieceA = "piece-a"
    private static let pieceB = "piece-b"

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("fignote-dispose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        cacheURL = TestTemp.root.appendingPathComponent("fignote-dispose-cache-\(UUID().uuidString).json")
        identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: cacheURL, identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
        for path in ["manuscript/a.md", "manuscript/b.md"] {
            try "Words.\n".write(to: projectURL.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [
                StructureItem(id: Self.pieceA, title: "A", type: .document, path: "manuscript/a.md"),
                StructureItem(id: Self.pieceB, title: "B", type: .document, path: "manuscript/b.md"),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Fixture

    private func text(_ s: String) -> Cell { Cell(content: .value(.text(s))) }
    private func number(_ n: Double) -> Cell { Cell(content: .value(.number(n))) }

    private var assistantDevice: String { Document.loadIdentities[.assistant].deviceId }

    private func load(_ id: String, as actor: DeviceActor = .author) async throws -> FigureDocument {
        try await FigureDocument.load(
            figureId: id, projectURL: projectURL, actor: actor, session: "s", presenter: nil,
            documentStore: nil)
    }

    /// A table figure (whole book unless `piece`) and its host, B2 holding "old".
    private func makeTable(piece: String? = nil) async throws -> (FigureRecord, FigureDocument, CellKey) {
        let store = try await ProjectStore.load(from: projectURL)
        let record = try await store.createFigure(kind: .table, name: "t", piece: piece)
        let doc = try await load(record.id)
        let b2 = CellKey(row: doc.state.table.rows[1], column: doc.state.table.columns[1])
        try await doc.setCell(text("old"), at: b2)
        return (record, doc, b2)
    }

    /// Appends `op` to the stream as another writer would (the assistant's
    /// note, a withdraw, a park), then has the host re-read it.
    private func append(_ op: Op, reloading doc: FigureDocument) async throws {
        try await Document.makeLoadOpStore(projectURL: projectURL, presenter: nil).append(op)
        try await doc.reload()
    }

    /// The assistant suggests `cell` for `key`, recording what the cell held.
    @discardableResult
    private func suggest(_ cell: Cell?, at key: CellKey, on doc: FigureDocument) async throws -> String {
        let op = try FigureAnnotationOps.creation(
            kind: .suggestedChange, anchor: FigureCellAnchor(row: key.row, column: key.column),
            body: "Should be 42", suggestedCell: cell, prior: doc.state.table[key],
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: doc.figureId, device: assistantDevice))
        try await append(op, reloading: doc)
        return op.opId
    }

    @discardableResult
    private func comment(on key: CellKey, doc: FigureDocument) async throws -> String {
        let op = try FigureAnnotationOps.creation(
            kind: .comment, anchor: FigureCellAnchor(row: key.row, column: key.column),
            body: "Check this", author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: doc.figureId, device: assistantDevice))
        try await append(op, reloading: doc)
        return op.opId
    }

    /// Every op in every file of the stream, seals excluded, in op-id order.
    private func ops(of figureId: String) throws -> [Op] {
        try unsortedOps(of: figureId).sorted { $0.opId < $1.opId }
    }

    private func unsortedOps(of figureId: String) throws -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return try OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL).flatMap { url in
            try Data(contentsOf: url)
                .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
                .compactMap { line -> Op? in
                    let data = Data(line)
                    return OpLogChain.isSealLine(data) ? nil : try? dec.decode(Op.self, from: data)
                }
        }
    }

    private func streamBytes(of figureId: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for url in OpLogStore.opLogFileURLs(forDocId: figureId, in: projectURL) {
            out[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return out
    }

    private func note(_ id: String, in doc: FigureDocument) -> Annotation? {
        doc.annotations().first { $0.id == id }
    }

    /// The figure ids `maughamAnnotationsChanged` named while `body` ran.
    private func announced(during body: () async throws -> Void) async rethrows -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamAnnotationsChanged, object: nil, queue: nil
        ) { note in
            if let id = note.userInfo?[MaughamEvent.annotationDocIdKey] as? String { seen.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    private func expect(
        _ expected: FigureNoteError, file: StaticString = #filePath, line: UInt = #line,
        _ press: () async throws -> Void
    ) async {
        do {
            try await press()
            XCTFail("not refused (expected \(expected))", file: file, line: line)
        } catch let error as FigureNoteError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("threw \(error), not \(expected)", file: file, line: line)
        }
    }

    // MARK: - Accept

    /// **Accept is one op that writes the cell and resolves the note**: a
    /// `claudeAccept` signed by the author, carrying the cell over what it
    /// replaced and the note's id; the suggester stays on the note. A fresh
    /// read shows both, and the figure's notes are announced.
    func test_acceptWritesTheCellAndResolvesTheNoteInOneAuthorSignedOp() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        let before = try ops(of: record.id).count

        let named = try await announced {
            try await doc.acceptSuggestion(id: id)
        }

        let all = try ops(of: record.id)
        XCTAssertEqual(all.count, before + 1, "one op")
        let accept = try XCTUnwrap(all.last)
        XCTAssertEqual(accept.kind, .claudeAccept)
        XCTAssertEqual(accept.provenance?.sourceAnnotationId, id, "the suggestion's attribution is recorded")
        XCTAssertEqual(accept.device, identities.author.deviceId, "signed by the author")
        XCTAssertEqual(accept.figure?.cell, b2)
        XCTAssertEqual(accept.figure?.next, number(42))
        XCTAssertEqual(accept.figure?.prior, text("old"), "it records the cell it replaced")
        XCTAssertEqual(doc.state.table[b2], number(42), "the host's fold shows the cell")
        XCTAssertEqual(note(id, in: doc)?.status, .accepted)
        XCTAssertEqual(note(id, in: doc)?.author?.sourceKind, .claude, "the suggester stays on the note")
        XCTAssertEqual(named, [record.id], "the figure's notes are announced once")

        let fresh = try await load(record.id)
        XCTAssertEqual(fresh.state.table[b2], number(42), "a fresh read folds the accept as the cell")
        XCTAssertEqual(fresh.state.diagnostics, [], "and diagnoses nothing")
        XCTAssertEqual(note(id, in: fresh)?.status, .accepted)
        XCTAssertEqual(
            try FigureCache().state(forFigureId: record.id, in: projectURL, facts: .empty).table[b2],
            number(42), "the cards' cache folds it too")
        await fresh.close()
        await doc.close()
    }

    /// **An anchor follows an insert**: a row inserted above the suggestion's
    /// cell moves it down one, and the accept writes the shifted cell.
    func test_acceptAfterAnInsertWritesTheShiftedCell() async throws {
        let (_, doc, b2) = try await makeTable()
        let id = try await suggest(number(7), at: b2, on: doc)
        XCTAssertEqual(note(id, in: doc)?.figureAddress, "B2", "precondition")
        try await doc.insertRow(after: nil)
        XCTAssertEqual(note(id, in: doc)?.figureAddress, "B3", "the anchor moved with its row")

        try await doc.acceptSuggestion(id: id)

        let b3 = CellKey(row: doc.state.table.rows[2], column: doc.state.table.columns[1])
        XCTAssertEqual(b3, b2, "the same ids, one row down")
        XCTAssertEqual(doc.state.table[b3], number(7))
        XCTAssertNil(doc.state.table[CellKey(row: doc.state.table.rows[1], column: doc.state.table.columns[1])],
                     "the cell now at B2 is untouched")
        await doc.close()
    }

    /// **A cell changed since the suggestion asks first**: the accept throws
    /// `cellChangedSinceSuggestion` and writes nothing; with `confirmChanged`
    /// it writes over the new value. A cell that already holds the
    /// suggestion is not asked about.
    func test_aCellChangedSinceTheSuggestionThrowsUntilConfirmed() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        try await doc.setCell(text("newer"), at: b2)
        let before = try streamBytes(of: record.id)

        await expect(.cellChangedSinceSuggestion) { try await doc.acceptSuggestion(id: id) }
        XCTAssertEqual(try streamBytes(of: record.id), before, "nothing written")
        XCTAssertEqual(note(id, in: doc)?.status, .open)

        try await doc.acceptSuggestion(id: id, confirmChanged: true)
        XCTAssertEqual(doc.state.table[b2], number(42))
        XCTAssertEqual(try ops(of: record.id).last?.figure?.prior, text("newer"),
                       "it records what it really replaced")

        let c3 = CellKey(row: doc.state.table.rows[2], column: doc.state.table.columns[2])
        let other = try await suggest(text("same"), at: c3, on: doc)
        try await doc.setCell(text("same"), at: c3)
        try await doc.acceptSuggestion(id: other)
        XCTAssertEqual(note(other, in: doc)?.status, .accepted, "already holding it, nothing to confirm")
        await doc.close()
    }

    /// **Refusals** — each before anything is written: the anchor's row
    /// deleted (RULING-5), a withdrawn note (RULING-22), a parked figure, a
    /// note already answered, a note that is not a cell suggestion.
    func test_orphanedWithdrawnParkedAndSettledAreRefused() async throws {
        let (record, doc, b2) = try await makeTable()

        // Orphaned: its row deleted.
        let orphan = try await suggest(number(1), at: b2, on: doc)
        try await doc.deleteRow(b2.row)
        XCTAssertEqual(note(orphan, in: doc)?.isStale, true, "precondition: orphaned")
        var before = try streamBytes(of: record.id)
        await expect(.anchorOrphaned) { try await doc.acceptSuggestion(id: orphan, confirmChanged: true) }
        XCTAssertEqual(try streamBytes(of: record.id), before)

        // Withdrawn by its writer.
        let a1 = CellKey(row: doc.state.table.rows[0], column: doc.state.table.columns[0])
        let withdrawn = try await suggest(number(2), at: a1, on: doc)
        try await append(Op(
            opId: ULID.generate(), docId: record.id, at: Date(), device: assistantDevice, session: "s",
            kind: .annotationWithdraw, changes: [],
            provenance: Op.Provenance(sessionId: "s", sourceAnnotationId: withdrawn)), reloading: doc)
        before = try streamBytes(of: record.id)
        await expect(.withdrawn) { try await doc.acceptSuggestion(id: withdrawn) }
        await expect(.withdrawn) { try await doc.rejectAnnotation(id: withdrawn) }
        XCTAssertEqual(try streamBytes(of: record.id), before)
        XCTAssertNil(doc.state.table[a1])

        // Not a suggestion; already answered.
        let note = try await comment(on: a1, doc: doc)
        await expect(.notACellSuggestion) { try await doc.acceptSuggestion(id: note) }
        let live = try await suggest(number(3), at: a1, on: doc)
        try await doc.rejectAnnotation(id: live)
        await expect(.notOpen) { try await doc.acceptSuggestion(id: live) }
        await expect(.notOpen) { try await doc.archiveAnnotation(id: live) }
        await expect(.unknownNote) { try await doc.rejectAnnotation(id: "no-such-note") }

        // Parked.
        let open = try await suggest(number(4), at: a1, on: doc)
        try await append(Op(
            opId: ULID.generate(), docId: record.id, at: Date(), device: identities.author.deviceId,
            session: "s", kind: .figureParked, changes: [],
            figure: FigureOpPayload(parkedPath: "research/t.csv", parkedHash: "h")), reloading: doc)
        XCTAssertNotNil(doc.state.parked, "precondition: parked")
        before = try streamBytes(of: record.id)
        for (name, press) in [
            ("acceptSuggestion", { try await doc.acceptSuggestion(id: open) }),
            ("rejectAnnotation", { try await doc.rejectAnnotation(id: open) }),
            ("stetAnnotation", { try await doc.stetAnnotation(id: open) }),
        ] as [(String, () async throws -> Void)] {
            do {
                try await press()
                XCTFail("\(name) was not refused on a parked figure")
            } catch let parked as FigureParkedRefused {
                XCTAssertEqual(parked.site, name)
            }
        }
        XCTAssertEqual(try streamBytes(of: record.id), before)
        await doc.close()
    }

    // MARK: - Undo

    /// **⌘Z takes the accept back in one step** — the cell as it was and the
    /// note open again, by one appended `claudeAcceptRevert` naming the note;
    /// ⇧⌘Z accepts again, and that is undoable too.
    func test_undoRestoresTheCellAndReopensTheNote_redoAcceptsAgain() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        let um = UndoManager()
        try await doc.acceptSuggestion(id: id, undoManager: um)
        let afterAccept = try ops(of: record.id).count

        let named = try await announced {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(doc.state.table[b2], text("old"), "the cell as it was")
        XCTAssertEqual(note(id, in: doc)?.status, .open, "and the note open again")
        let revert = try XCTUnwrap(try ops(of: record.id).last)
        XCTAssertEqual(try ops(of: record.id).count, afterAccept + 1, "ONE compensating op")
        XCTAssertEqual(revert.kind, .claudeAcceptRevert)
        XCTAssertEqual(revert.provenance?.sourceAnnotationId, id)
        XCTAssertEqual(revert.figure?.next, text("old"))
        XCTAssertEqual(revert.figure?.prior, number(42))
        XCTAssertEqual(named, [record.id])

        um.redo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table[b2], number(42))
        XCTAssertEqual(note(id, in: doc)?.status, .accepted)
        XCTAssertTrue(um.canUndo, "the redo is undoable again")

        let fresh = try await load(record.id)
        XCTAssertEqual(fresh.state.table[b2], number(42))
        XCTAssertEqual(note(id, in: fresh)?.status, .accepted)
        await fresh.close()
        await doc.close()
    }

    /// **The undo declines when the note moved since**: rejected elsewhere
    /// after the accept, ⌘Z neither reopens it nor puts the cell back.
    func test_undoDeclinesWhenTheNoteWasAnsweredSince() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        let um = UndoManager()
        try await doc.acceptSuggestion(id: id, undoManager: um)
        try await append(Op(
            opId: ULID.generate(), docId: record.id, at: Date(), device: identities.author.deviceId,
            session: "elsewhere", kind: .claudeReject, changes: [],
            provenance: Op.Provenance(sessionId: "elsewhere", sourceAnnotationId: id)), reloading: doc)
        XCTAssertEqual(note(id, in: doc)?.status, .rejected, "precondition")
        let before = try streamBytes(of: record.id)

        um.undo()
        await doc.awaitPendingUndoWork()

        XCTAssertEqual(try streamBytes(of: record.id), before, "nothing appended")
        XCTAssertEqual(doc.state.table[b2], number(42))
        XCTAssertEqual(note(id, in: doc)?.status, .rejected)
        await doc.close()
    }

    /// **Inside a grid visit the visit's undo compensates both**: an accept
    /// made on the visit's manager joins the visit carrying its note; the
    /// fold's one step takes back the cell AND reopens the note, and its redo
    /// accepts again — never a cell back with the note left accepted.
    func test_anAcceptInAVisitIsTakenBackWholeByTheVisitsUndo() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        let grid = UndoManager()

        XCTAssertTrue(doc.beginVisit(undoManager: grid))
        try await doc.acceptSuggestion(id: id, undoManager: grid)
        let visit = try XCTUnwrap(doc.endVisit())
        XCTAssertEqual(visit.ops.map(\.kind), [.claudeAccept])
        XCTAssertEqual(visit.ops.first?.sourceAnnotationId, id, "the visit keeps the note's id")
        XCTAssertTrue(visit.isUndoable)

        let undone = await doc.undoVisit(visit)
        XCTAssertTrue(undone)
        XCTAssertEqual(doc.state.table[b2], text("old"))
        XCTAssertEqual(note(id, in: doc)?.status, .open, "the note reopened with the cell")
        let revert = try XCTUnwrap(try ops(of: record.id).last)
        XCTAssertEqual(revert.kind, .claudeAcceptRevert)
        XCTAssertEqual(revert.provenance?.sourceAnnotationId, id)

        let redone = await doc.redoVisit(visit)
        XCTAssertTrue(redone)
        XCTAssertEqual(doc.state.table[b2], number(42))
        XCTAssertEqual(note(id, in: doc)?.status, .accepted)

        // A visit's undo that would reopen a note answered since declines whole.
        try await append(Op(
            opId: ULID.generate(), docId: record.id, at: Date(), device: identities.author.deviceId,
            session: "elsewhere", kind: .annotationStet, changes: [],
            provenance: Op.Provenance(sessionId: "elsewhere", sourceAnnotationId: id)), reloading: doc)
        let declined = await doc.undoVisit(visit)
        XCTAssertFalse(declined)
        XCTAssertEqual(doc.state.table[b2], number(42), "the cell stays with the note")
        await doc.close()
    }

    /// **The grid's own ⌘Z inside the visit, then the fold**: the accept and
    /// its revert are both in the visit, the table and the note agree after
    /// the inner undo, and the visit's undo and redo leave them agreeing.
    func test_undoInsideAVisitThenFoldLeavesTheCellAndTheNoteConsistent() async throws {
        let (_, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        let grid = UndoManager()

        XCTAssertTrue(doc.beginVisit(undoManager: grid))
        try await doc.acceptSuggestion(id: id, undoManager: grid)
        grid.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.state.table[b2], text("old"))
        XCTAssertEqual(note(id, in: doc)?.status, .open)
        let visit = try XCTUnwrap(doc.endVisit())
        XCTAssertEqual(visit.ops.map(\.kind), [.claudeAccept, .claudeAcceptRevert])
        XCTAssertEqual(visit.ops.map(\.sourceAnnotationId), [id, id])

        let undone = await doc.undoVisit(visit)
        XCTAssertTrue(undone)
        XCTAssertEqual(doc.state.table[b2], text("old"))
        XCTAssertEqual(note(id, in: doc)?.status, .open, "back where the visit began, both")
        let redone = await doc.redoVisit(visit)
        XCTAssertTrue(redone)
        XCTAssertEqual(doc.state.table[b2], text("old"))
        XCTAssertEqual(note(id, in: doc)?.status, .open)
        await doc.close()
    }

    // MARK: - Reject, stet, archive, reopen

    /// **Reject keeps its reason** (RULING-31) and moves no cell; ⌘Z reopens
    /// it, the reason kept as history; Reopen and its ⌘Z re-reject with it.
    func test_rejectKeepsItsReason_andUndoAndReopenRoundTrip() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        // Grouped by event (the default), as the window's manager is: the
        // redo re-registers its undo from a task, outside any open group.
        let um = UndoManager()
        try await doc.rejectAnnotation(id: id, reason: "The total is right.", undoManager: um)
        let written = try ops(of: record.id)
        XCTAssertEqual(written.last?.kind, .claudeReject)
        XCTAssertEqual(written.last?.device, identities.author.deviceId)
        XCTAssertEqual(written.last?.provenance?.userResponse, "The total is right.")
        XCTAssertNil(written.last?.figure, "no cell moves")
        XCTAssertEqual(note(id, in: doc)?.status, .rejected)
        XCTAssertEqual(note(id, in: doc)?.userResponse, "The total is right.")
        XCTAssertEqual(doc.state.table[b2], text("old"))

        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(note(id, in: doc)?.status, .open)
        XCTAssertEqual(note(id, in: doc)?.previousRejectionReason, "The total is right.")

        um.redo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(note(id, in: doc)?.status, .rejected)
        await doc.close()
    }

    /// **Reopen and its ⌘Z**: a rejected note reopens, and ⌘Z re-rejects it
    /// with its reason.
    func test_reopenAndItsUndoKeepTheReason() async throws {
        let (_, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        try await doc.rejectAnnotation(id: id, reason: "The total is right.")
        let reopenUndo = UndoManager()
        try await doc.reopenAnnotation(id: id, undoManager: reopenUndo)
        XCTAssertEqual(note(id, in: doc)?.status, .open)
        reopenUndo.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(note(id, in: doc)?.status, .rejected)
        XCTAssertEqual(note(id, in: doc)?.userResponse, "The total is right.", "re-rejected with its reason")
        await doc.close()
    }

    /// **Stet and archive settle a note; ⌘Z reopens it; an accepted
    /// suggestion is not reopened by Reopen** (its accept's ⌘Z puts the cell
    /// back with it).
    func test_stetAndArchiveSettle_undoReopens_andAnAcceptIsNotReopened() async throws {
        let (_, doc, b2) = try await makeTable()
        let a1 = CellKey(row: doc.state.table.rows[0], column: doc.state.table.columns[0])
        let stetted = try await comment(on: a1, doc: doc)
        let archived = try await comment(on: b2, doc: doc)
        let um = UndoManager()
        um.groupsByEvent = false

        um.beginUndoGrouping()
        try await doc.stetAnnotation(id: stetted, undoManager: um)
        um.endUndoGrouping()
        um.beginUndoGrouping()
        try await doc.archiveAnnotation(id: archived, undoManager: um)
        um.endUndoGrouping()
        XCTAssertEqual(note(stetted, in: doc)?.status, .stetted)
        XCTAssertEqual(note(archived, in: doc)?.status, .archived)

        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(note(archived, in: doc)?.status, .open)
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(note(stetted, in: doc)?.status, .open)

        let id = try await suggest(number(42), at: b2, on: doc)
        try await doc.acceptSuggestion(id: id)
        await expect(.cannotReopen) { try await doc.reopenAnnotation(id: id) }
        XCTAssertEqual(doc.state.table[b2], number(42))
        await doc.close()
    }

    // MARK: - Who may answer

    /// **A reviewer may not answer a figure's notes**: the assistant (the
    /// reviewer row on every device) and an author of another piece are
    /// refused every verb, nothing appended. Control: the figure's own
    /// piece author answers.
    func test_aReviewerAndAnAuthorOfAnotherPieceAreRefused() async throws {
        let root = try makeForeignRoot()
        let store = try await ProjectStore.load(from: projectURL)
        let theirs = try await store.createFigure(kind: .table, name: "b_table", piece: Self.pieceB)
        let hers = try await store.createFigure(kind: .table, name: "a_table", piece: Self.pieceA)
        try narrow(identities.author.fingerprint, by: root, pieces: [Self.pieceA], mark: try appliedSoFar())

        for (actor, figure) in [(DeviceActor.author, theirs), (.assistant, hers)] {
            let doc = try await load(figure.id, as: actor)
            let key = CellKey(row: doc.state.table.rows[0], column: doc.state.table.columns[0])
            let suggestion = try await suggest(number(1), at: key, on: doc)
            let before = try streamBytes(of: figure.id)
            let presses: [(String, () async throws -> Void)] = [
                ("acceptSuggestion", { try await doc.acceptSuggestion(id: suggestion, confirmChanged: true) }),
                ("rejectAnnotation", { try await doc.rejectAnnotation(id: suggestion, reason: "no") }),
                ("stetAnnotation", { try await doc.stetAnnotation(id: suggestion) }),
                ("archiveAnnotation", { try await doc.archiveAnnotation(id: suggestion) }),
            ]
            for (name, press) in presses {
                do {
                    try await press()
                    XCTFail("\(name) was not refused for \(actor) on \(figure.name)")
                } catch is FigureEditRefused {
                    XCTAssertEqual(name, "acceptSuggestion", "only the accept asks the cell's door first")
                } catch let error as FigureNoteError {
                    XCTAssertEqual(error, .notPermitted, name)
                }
            }
            XCTAssertEqual(try streamBytes(of: figure.id), before, "\(actor) on \(figure.name): nothing appended")
            XCTAssertEqual(note(suggestion, in: doc)?.status, .open)
            await doc.close()
        }

        // Control: her own piece's figure, as its author.
        let mine = try await load(hers.id)
        let key = CellKey(row: mine.state.table.rows[0], column: mine.state.table.columns[0])
        let suggestion = try await suggest(number(5), at: key, on: mine)
        try await mine.acceptSuggestion(id: suggestion)
        XCTAssertEqual(mine.state.table[key], number(5))
        await mine.close()
    }

    // MARK: - Registry fixtures (FigureDocumentTests' shapes)

    private func makeForeignRoot() throws -> DeviceIdentity {
        let root = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: root.fingerprint, name: "The other Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: root.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1_000)),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: root.fingerprint, label: "Sam", ownName: "The other Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: identities.author.fingerprint, name: "This Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, identities[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 2_000)),
            signedBy: identities.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver", ownName: "This Mac",
                role: Permit.authorRole, admittedAt: Date(timeIntervalSince1970: 2_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        return root
    }

    private func narrow(
        _ subject: String, by root: DeviceIdentity, pieces: [String],
        mark: [String: PermitMark.StreamMark] = [:]
    ) throws {
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: subject), kind: .scopeChanged,
                subject: subject, role: Permit.authorRole, scope: Permit.piecesScope,
                pieces: pieces, mark: mark,
                at: Date(timeIntervalSince1970: 3_000), by: root.fingerprint),
            signedBy: root, in: projectURL)
    }

    private func appliedSoFar() throws -> [String: PermitMark.StreamMark] {
        try OpLogStore.appliedPositions(
            ofDeviceIds: Set(identities.all.map(\.deviceId)),
            in: projectURL,
            trust: try TrustResolution.resolve(projectURL: projectURL, identities: identities)).streams
    }
}
