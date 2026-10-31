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
        try await doc.acceptSuggestion(id: live)
        before = try streamBytes(of: record.id)
        await expect(.notOpen) { try await doc.acceptSuggestion(id: live) }
        await expect(.notOpen) { try await doc.rejectAnnotation(id: live) }
        XCTAssertEqual(try streamBytes(of: record.id), before, "an accepted suggestion takes no second answer")
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

    // MARK: - A note that writes no cell (Task 7)

    /// **Got it / a query's Reply** (`acceptNote`): one status-only
    /// `claudeAccept`, the author's, carrying the reply and no cell; ⌘Z is a
    /// status-only revert that reopens it; ⇧⌘Z accepts again with the reply.
    func test_acceptNoteIsAStatusOnlyAccept_carryingTheReply_andUndoReopens() async throws {
        let (record, doc, b2) = try await makeTable()
        let query = try FigureAnnotationOps.creation(
            kind: .query, anchor: FigureCellAnchor(row: b2.row, column: b2.column), body: "Source?",
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: doc.figureId, device: assistantDevice))
        try await append(query, reloading: doc)
        let um = UndoManager()
        try await doc.acceptNote(id: query.opId, userResponse: "The 2023 census", undoManager: um)
        var written = try ops(of: record.id)
        XCTAssertEqual(written.last?.kind, .claudeAccept)
        XCTAssertEqual(written.last?.device, identities.author.deviceId)
        XCTAssertEqual(written.last?.provenance?.userResponse, "The 2023 census")
        XCTAssertNil(written.last?.figure, "no cell moves")
        XCTAssertEqual(note(query.opId, in: doc)?.status, .accepted)
        XCTAssertEqual(doc.state.table[b2], text("old"))

        um.undo()
        await doc.awaitPendingUndoWork()
        written = try ops(of: record.id)
        XCTAssertEqual(written.last?.kind, .claudeAcceptRevert)
        XCTAssertNil(written.last?.figure)
        XCTAssertEqual(note(query.opId, in: doc)?.status, .open)

        um.redo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(note(query.opId, in: doc)?.status, .accepted)
        XCTAssertEqual(note(query.opId, in: doc)?.userResponse, "The 2023 census")
        XCTAssertEqual(doc.state.table[b2], text("old"))
        await doc.close()
    }

    /// **Reopen takes back an accepted note that wrote no cell** (fix round 1,
    /// I2): a status-only `claudeAcceptRevert`, no cell; its ⌘Z re-accepts
    /// with the reply. An accepted suggestion still refuses Reopen.
    func test_reopenTakesBackACelllessAccept_andItsUndoKeepsTheReply() async throws {
        let (record, doc, b2) = try await makeTable()
        let c = try await comment(on: b2, doc: doc)
        try await doc.acceptNote(id: c, userResponse: "Noted")
        let um = UndoManager()
        try await doc.reopenAnnotation(id: c, undoManager: um)
        let written = try ops(of: record.id)
        XCTAssertEqual(written.last?.kind, .claudeAcceptRevert)
        XCTAssertNil(written.last?.figure)
        XCTAssertEqual(note(c, in: doc)?.status, .open)
        XCTAssertEqual(doc.state.table[b2], text("old"))
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(note(c, in: doc)?.status, .accepted)
        XCTAssertEqual(note(c, in: doc)?.userResponse, "Noted", "re-accepted with its reply")
        await doc.close()
    }

    /// **Undoing a reply that replaced a reply puts the first back** (fix
    /// round 1, M5).
    func test_undoingAReplyOverAReplyRestoresTheFirst() async throws {
        let (_, doc, b2) = try await makeTable()
        let c = try await comment(on: b2, doc: doc)
        try await doc.acceptNote(id: c, userResponse: "First")
        let um = UndoManager()
        try await doc.acceptNote(id: c, userResponse: "Second", undoManager: um)
        XCTAssertEqual(note(c, in: doc)?.userResponse, "Second")
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(note(c, in: doc)?.status, .accepted)
        XCTAssertEqual(note(c, in: doc)?.userResponse, "First")
        await doc.close()
    }

    /// `acceptNote` refuses a suggestion (it is the table's), with nothing
    /// written. (A reviewer's refusal is in the who-may-answer test below.)
    func test_acceptNoteRefusesASuggestion() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        let before = try ops(of: record.id).count
        await expect(.acceptInTheTable) { try await doc.acceptNote(id: id) }
        XCTAssertEqual(try ops(of: record.id).count, before)
        XCTAssertEqual(note(id, in: doc)?.status, .open)
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
                ("acceptNote", { try await doc.acceptNote(id: suggestion) }),
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

    // MARK: - Fix round 1

    /// **The manuscript's lifecycle rules** (M3): an answer may follow an
    /// answer — archive a rejected note, stet it, accept a rejected
    /// suggestion — the latest wins; and ⌘Z undoes ONE decision, putting the
    /// displaced resolution back (a rejection with its reason, an accept as
    /// status only). Only an accepted suggestion refuses Reject.
    func test_answersFollowAnswers_andUndoPutsTheDisplacedOneBack() async throws {
        let (_, doc, b2) = try await makeTable()
        let a1 = CellKey(row: doc.state.table.rows[0], column: doc.state.table.columns[0])
        let note = try await comment(on: a1, doc: doc)
        try await doc.rejectAnnotation(id: note, reason: "No.")
        let um = UndoManager()
        try await doc.archiveAnnotation(id: note, undoManager: um)
        XCTAssertEqual(self.note(note, in: doc)?.status, .archived, "archive over a rejection")
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(self.note(note, in: doc)?.status, .rejected, "⌘Z puts the rejection back")
        XCTAssertEqual(self.note(note, in: doc)?.userResponse, "No.", "with its reason")

        let s = try await suggest(number(42), at: b2, on: doc)
        try await doc.rejectAnnotation(id: s)
        try await doc.acceptSuggestion(id: s)
        XCTAssertEqual(self.note(s, in: doc)?.status, .accepted, "a rejected suggestion may still be accepted")
        XCTAssertEqual(doc.state.table[b2], number(42))
        let stetUndo = UndoManager()
        try await doc.stetAnnotation(id: s, undoManager: stetUndo)
        XCTAssertEqual(self.note(s, in: doc)?.status, .stetted)
        stetUndo.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(self.note(s, in: doc)?.status, .accepted, "⌘Z re-accepts, status only")
        XCTAssertEqual(doc.state.table[b2], number(42), "the cell was never taken back")
        await doc.close()
    }

    /// **Changed-since is about content** (M4): a format the author set since
    /// is no change, and the accept writes the suggested content over the
    /// cell's current format.
    func test_aFormatChangeIsNotAChange_andTheAcceptKeepsTheCellsFormat() async throws {
        let (_, doc, b2) = try await makeTable()
        try await doc.setCell(number(5), at: b2)
        let id = try await suggest(number(42), at: b2, on: doc)
        let percent = Cell(content: .value(.number(5)), format: CellFormat(zeroAsDash: true), alignment: .right)
        try await doc.setCell(percent, at: b2)

        try await doc.acceptSuggestion(id: id)

        XCTAssertEqual(doc.state.table[b2]?.content, .value(.number(42)))
        XCTAssertEqual(doc.state.table[b2]?.format, CellFormat(zeroAsDash: true), "the format set since is kept")
        XCTAssertEqual(doc.state.table[b2]?.alignment, .right)
        await doc.close()
    }

    /// **A checkpoint restore to before an accept reopens the note** (I2,
    /// RULING-28 as the manuscript's restore): the cell goes back by ONE
    /// `claudeAcceptRevert` naming the note and the checkpoint, so the note
    /// is open over the restored cell — never accepted over the old value.
    func test_aRestoreToBeforeAnAcceptReopensTheNoteInTheSameOp() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        let pointer = try XCTUnwrap(try ops(of: record.id).last?.opId)
        try await doc.acceptSuggestion(id: id)
        let before = try ops(of: record.id).count

        let outcome = try await doc.restoreToCheckpoint("cp-1", through: pointer)

        XCTAssertEqual(outcome, .restored(opCount: 1))
        XCTAssertEqual(doc.state.table[b2], text("old"))
        XCTAssertEqual(note(id, in: doc)?.status, .open, "the stranded accept is reopened")
        let written = try ops(of: record.id).dropFirst(before)
        XCTAssertEqual(written.map(\.kind), [.claudeAcceptRevert], "one op: cell and note together")
        XCTAssertEqual(written.first?.provenance?.sourceAnnotationId, id)
        XCTAssertEqual(written.first?.provenance?.sourceCheckpoint, "cp-1")
        let fresh = try await load(record.id)
        XCTAssertEqual(note(id, in: fresh)?.status, .open)
        XCTAssertEqual(fresh.state.table[b2], text("old"))
        await fresh.close()
        await doc.close()
    }

    /// **A status-only re-accept does not hide the accept from a restore**
    /// (N1): accept, stet, ⌘Z (which puts the accept back status only), then
    /// restore to before the accept — the cell goes back AND the note opens.
    func test_aRestoreAfterAStetsUndoStillReopensTheAccept() async throws {
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        let pointer = try XCTUnwrap(try ops(of: record.id).last?.opId)
        try await doc.acceptSuggestion(id: id)
        let um = UndoManager()
        try await doc.stetAnnotation(id: id, undoManager: um)
        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(note(id, in: doc)?.status, .accepted, "premise: re-accepted, status only")
        XCTAssertEqual(try ops(of: record.id).last?.figure, nil, "premise: the latest accept carries no cell")

        _ = try await doc.restoreToCheckpoint("cp-1", through: pointer)

        XCTAssertEqual(doc.state.table[b2], text("old"))
        XCTAssertEqual(note(id, in: doc)?.status, .open)
        XCTAssertEqual(try ops(of: record.id).last?.provenance?.sourceAnnotationId, id)
        XCTAssertEqual(doc.lastRestoreNotes, FigureRestoreNotes(reopened: [id]))
        await doc.close()
    }

    /// **The restore's two status-only branches** (N3): a cell already back
    /// to its old value reopens the note by a status-only revert; a cell in
    /// a row added after the checkpoint (gone then) archives it. Both named.
    func test_aRestoreReopensWhereTheCellStands_andArchivesWhereItIsGone() async throws {
        let (record, doc, b2) = try await makeTable()
        let standing = try await suggest(number(42), at: b2, on: doc)
        let pointer = try XCTUnwrap(try ops(of: record.id).last?.opId)
        try await doc.acceptSuggestion(id: standing)
        try await doc.setCell(text("old"), at: b2)
        let row = try await doc.insertRow(after: nil)
        let added = CellKey(row: row, column: doc.state.table.columns[0])
        let gone = try await suggest(number(7), at: added, on: doc)
        try await doc.acceptSuggestion(id: gone)
        let before = try ops(of: record.id).count

        _ = try await doc.restoreToCheckpoint("cp-1", through: pointer)

        let written = try ops(of: record.id).dropFirst(before)
        let reopen = try XCTUnwrap(written.first { $0.provenance?.sourceAnnotationId == standing })
        XCTAssertEqual(reopen.kind, .claudeAcceptRevert)
        XCTAssertNil(reopen.figure, "status only: the cell already stood as it did then")
        XCTAssertEqual(note(standing, in: doc)?.status, .open)
        let archive = try XCTUnwrap(written.first { $0.provenance?.sourceAnnotationId == gone })
        XCTAssertEqual(archive.kind, .claudeArchive)
        XCTAssertEqual(archive.provenance?.sourceCheckpoint, "cp-1")
        XCTAssertEqual(note(gone, in: doc)?.status, .archived, "its cell is gone then")
        XCTAssertEqual(doc.lastRestoreNotes, FigureRestoreNotes(reopened: [standing], archived: [gone]))
        await doc.close()
    }

    /// **A restore asks `.dispose` before it archives** (final review M2): in
    /// a piece she started that nobody has claimed she may edit the figure
    /// but not dispose of its notes, so a stranded accept whose cell is gone
    /// is reopened status only — never archived behind `.editFigure` alone.
    func test_aRestoreThatMayNotDisposeReopensInsteadOfArchiving() async throws {
        // Narrowed to piece A, she starts piece B and makes its figure: every
        // line of it hers as the unclaimed piece's starter.
        let root = try makeForeignRoot()
        try narrow(identities.author.fingerprint, by: root, pieces: [Self.pieceA])
        try recordStarter(identities.author.deviceId, of: Self.pieceB)
        let (record, doc, _) = try await makeTable(piece: Self.pieceB)
        let pointer = try XCTUnwrap(try ops(of: record.id).last?.opId)
        let row = try await doc.insertRow(after: nil)
        let added = CellKey(row: row, column: doc.state.table.columns[0])
        let gone = try await suggest(number(7), at: added, on: doc)
        try await doc.acceptSuggestion(id: gone)
        XCTAssertEqual(note(gone, in: doc)?.status, .accepted, "premise: accepted")
        let mayEdit = await doc.mayHere(.editFigure)
        let mayDispose = await doc.mayHere(.dispose)
        XCTAssertTrue(mayEdit, "premise: her own started piece's figure is hers to edit")
        XCTAssertFalse(mayDispose, "premise: disposing waits for the root to claim the piece")
        let before = try ops(of: record.id).count

        _ = try await doc.restoreToCheckpoint("cp-1", through: pointer)

        let written = try ops(of: record.id).dropFirst(before)
        XCTAssertFalse(written.contains { $0.kind == .claudeArchive }, "no archive behind a refused .dispose")
        let line = try XCTUnwrap(written.first { $0.provenance?.sourceAnnotationId == gone })
        XCTAssertEqual(line.kind, .claudeAcceptRevert)
        XCTAssertNil(line.figure, "status only: its cell is gone then")
        XCTAssertEqual(note(gone, in: doc)?.status, .open)
        XCTAssertEqual(doc.lastRestoreNotes, FigureRestoreNotes(reopened: [gone]))
        await doc.close()
    }

    /// **A reopen the fold does not honour cannot hide an accept from a
    /// restore** (final review M3): newest on an accepted note, a dishonoured
    /// reopen leaves it accepted, so the restore still puts the cell back
    /// with the note in one `claudeAcceptRevert` — never the cell alone.
    func test_aDishonouredReopenDoesNotHideTheAcceptFromARestore() async throws {
        FigureDocument.amendmentsForTesting = AnnotationAmendments(honours: { _, _ in true }, disposing: { _ in false })
        defer { FigureDocument.amendmentsForTesting = nil }
        let (record, doc, b2) = try await makeTable()
        let id = try await suggest(number(42), at: b2, on: doc)
        let pointer = try XCTUnwrap(try ops(of: record.id).last?.opId)
        try await doc.acceptSuggestion(id: id)
        try await append(FigureAnnotationOps.reopen(annotationId: id, stamp: doc.noteStamp), reloading: doc)
        XCTAssertEqual(note(id, in: doc)?.status, .accepted, "premise: the reopen is not honoured")
        XCTAssertEqual(try ops(of: record.id).last?.kind, .annotationReopen, "premise: it is the newest line")

        _ = try await doc.restoreToCheckpoint("cp-1", through: pointer)

        XCTAssertEqual(doc.state.table[b2], text("old"))
        XCTAssertEqual(note(id, in: doc)?.status, .open, "not stranded: accepted over the old value")
        XCTAssertEqual(try ops(of: record.id).last?.kind, .claudeAcceptRevert)
        await doc.close()
    }

    /// **A settling ⌘Z that reopens but cannot put the earlier answer back
    /// says so** (N2): the note is back but open, in those words.
    func test_aSettlingUndoWhosePutBackFailsSaysTheNoteIsBackButOpen() async throws {
        let (_, doc, b2) = try await makeTable()
        let note = try await comment(on: b2, doc: doc)
        try await doc.archiveAnnotation(id: note)
        let um = UndoManager()
        try await doc.rejectAnnotation(id: note, reason: "No.", undoManager: um)
        FigureDocument.beforeCommitAppendForTesting = { op in
            if op.kind == .claudeArchive { throw FigureEditInvalid(reason: "disk full") }
        }
        defer { FigureDocument.beforeCommitAppendForTesting = nil }
        var said: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { n in if let m = n.userInfo?[MaughamEvent.noticeMessageKey] as? String { said.append(m) } }
        um.undo()
        await doc.awaitPendingUndoWork()
        NotificationCenter.default.removeObserver(token)
        XCTAssertEqual(said, ["Couldn't put the note's earlier answer back — the note is back but open."])
        XCTAssertEqual(self.note(note, in: doc)?.status, .open)
        await doc.close()
    }

    /// **The restore sheet names the notes** (N4, RULING-28's AFTER half).
    func test_theRestoreSentenceNamesTheReopenedAndArchivedSuggestions() {
        func r(_ name: String) -> FigureRecord {
            FigureRecord(id: "fig-\(name)", name: name, kind: .table, piece: nil, path: "figures/\(name).csv")
        }
        XCTAssertEqual(PartialRestorePicker.figureSentence(for: [
            (r("cash"), .outcome(.restored(opCount: 2), notes: FigureRestoreNotes(reopened: ["n1"]))),
        ]), "Reopened 1 accepted suggestion on cash.")
        XCTAssertEqual(PartialRestorePicker.figureSentence(for: [
            (r("cash"), .outcome(.restored(opCount: 3), notes: FigureRestoreNotes(reopened: ["n1", "n2"], archived: ["n3"]))),
            (r("plan"), .outcome(.unchanged)),
        ]), "Reopened 2 accepted suggestions and archived 1 accepted suggestion whose cells are gone on cash.")
        XCTAssertNil(PartialRestorePicker.figureSentence(for: [(r("cash"), .outcome(.restored(opCount: 1)))]))
    }

    /// **An accepted formula reading Research takes its pins** (I1), as the
    /// same formula typed in the grid does: the render computes, never
    /// `#REF!`; ⌘Z takes back the cell and the pins and reopens the note.
    func test_anAcceptedResearchFormulaTakesItsPins_andUndoTakesThemBack() async throws {
        try "Words.\n".write(to: projectURL.appendingPathComponent("manuscript/a.md"), atomically: true, encoding: .utf8)
        let store = try await DocumentStore.open(url: projectURL)
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        let folder = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let csv = folder.appendingPathComponent("model.csv")
        try Data("Year,Revenue\n2025,10\n2026,20\n".utf8).write(to: csv)
        let item = try await projectStore.addResearchAsset(parentId: nil, fromURL: csv)
        let summary = try await projectStore.createFigure(kind: .table, name: "summary", piece: nil)
        let host = try await store.openFigure(figureId: summary.id)
        let a1 = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
        let names = FormulaNames(research: [(item.id, item.title)])
        guard case .success(let formula) = FormulaParser.parse(
            "SUM(research:model!B2:B3)", in: host.state.table, names: names)
        else { return XCTFail("the formula did not parse") }
        let suggestion = try FigureAnnotationOps.creation(
            kind: .suggestedChange, anchor: FigureCellAnchor(row: a1.row, column: a1.column),
            body: "Total it", suggestedCell: Cell(content: .formula(formula)), prior: nil,
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: summary.id, device: assistantDevice))
        try await store.addFigureAnnotation(suggestion)

        let um = UndoManager()
        try await host.acceptSuggestion(id: suggestion.opId, undoManager: um)
        await store.awaitOpenFigureRenderForTesting()

        XCTAssertEqual(host.state.pins[a1]?.map(\.research), [item.id, item.id], "both cells it read are pinned")
        let rendered = try String(contentsOf: projectURL.appendingPathComponent(summary.path), encoding: .utf8)  // adr-0018-ok: test reads the derived render to assert what was written
        XCTAssertEqual(TableCSV.rows(rendered).rows.first?.first, "30", "computed, not #REF!")

        um.undo()
        await host.awaitPendingUndoWork()
        XCTAssertNil(host.state.table[a1], "the cell went back")
        XCTAssertNil(host.state.pins[a1], "and its pins with it")
        XCTAssertEqual(host.annotations().first { $0.id == suggestion.opId }?.status, .open)
        await store.closeFigure(figureId: summary.id)
        await store.close()
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

    /// Record who started `docId` in the manifest on disk — what a creation
    /// writes (`DocumentWaitingTests`' shape).
    private func recordStarter(_ deviceId: String, of docId: String) throws {
        let url = projectURL.appendingPathComponent(ProjectManifest.fileName)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var manifest = try dec.decode(ProjectManifest.self, from: Data(contentsOf: url))
        manifest.structure = TreeWalk.mutate(id: docId, in: manifest.structure) {
            var item = $0
            item.startedBy = deviceId
            return item
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: url)
    }

    private func appliedSoFar() throws -> [String: PermitMark.StreamMark] {
        try OpLogStore.appliedPositions(
            ofDeviceIds: Set(identities.all.map(\.deviceId)),
            in: projectURL,
            trust: try TrustResolution.resolve(projectURL: projectURL, identities: identities)).streams
    }
}
