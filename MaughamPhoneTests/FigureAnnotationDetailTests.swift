import XCTest
@testable import MaughamPhone
@testable import MaughamCore

/// **The phone tells the truth about a note on a table figure** (report plan
/// 9c-1 Task 7): Accept is never offered on a figure suggestion (it writes a
/// cell, so the Mac's grid accepts it) and the writer refuses one by
/// construction; Reject and Archive stay, built by Core's
/// `FigureAnnotationOps` (tripwire 19) and landing on the figure's stream as
/// a line the shared deriver reads; Accept on a paragraph's suggestion is
/// offered as before.
@MainActor
final class FigureAnnotationDetailTests: XCTestCase {

    private let figureId = "fig-k3m9q2zt"
    private let docId = "doc-0f677d7e"
    private let r1 = RowID("r1aaaaaa"), c1 = ColumnID("c1bbbbbb")
    private var identity: DeviceIdentity!

    override func setUpWithError() throws {
        identity = .softwareForTesting()
    }

    private static func posture(_ permit: Permit, _ cls: DocumentClass?) -> Posture {
        Posture(LocalWritePermit(
            permit: permit, actor: .author, documentClass: cls, writesAsItsStarter: false))
    }

    private func writer(docId: String, root: URL = TestTemp.root) -> AnnotationWriter {
        AnnotationWriter(
            projectRoot: root, docId: docId, identity: identity,
            appVersion: "0.1.0", osVersion: "iOS 17.4",
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    /// The assistant's suggestion on the figure's A1, and the note it derives to.
    private func figureSuggestion() throws -> (Op, Annotation) {
        let op = try FigureAnnotationOps.creation(
            kind: .suggestedChange, anchor: FigureCellAnchor(row: r1, column: c1),
            body: "Round it", suggestedCell: Cell(content: .value(.number(12))),
            prior: Cell(content: .value(.number(11.5))),
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: figureId, device: "assistant-x"))
        let note = try XCTUnwrap(AnnotationDeriver.derive(ops: [op], paragraphs: [:]).first)
        return (op, note)
    }

    private func paragraphSuggestion() -> Annotation {
        Annotation(
            id: "01PARASUGGESTION", kind: .suggestedChange, paragraphId: "k7m3",
            body: "tighter", suggestedText: "Dusk.", priorText: "The sun was setting.",
            createdAt: Date(timeIntervalSince1970: 1_699_000_000), createdBySession: "s",
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false)
    }

    // MARK: - What is offered

    /// Accept is absent for a figure suggestion and present for a paragraph
    /// one, under the same posture; Reject and Archive stay on both.
    func test_acceptIsAbsentOnAFigureSuggestion_andPresentOnAParagraphOne() throws {
        let author = Self.posture(.bookAuthor, nil)
        let (_, figureNote) = try figureSuggestion()
        XCTAssertEqual(PhonePosture.openNoteVerbs(for: figureNote, docId: figureId, under: author),
                       [.reject, .archive])
        XCTAssertEqual(PhonePosture.openNoteVerbs(for: paragraphSuggestion(), docId: docId, under: author),
                       [.accept, .reject, .archive])
        let reviewer = Self.posture(.reviewer, .piece("doc-a"))
        XCTAssertEqual(PhonePosture.openNoteVerbs(for: figureNote, docId: figureId, under: reviewer), [],
                       "the posture still decides the rest")
    }

    /// A figure's comment keeps its Accept (it writes no cell).
    func test_aFigureCommentKeepsItsAccept() throws {
        let op = try FigureAnnotationOps.creation(
            kind: .comment, anchor: FigureCellAnchor(row: r1, column: c1), body: "Check",
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: figureId, device: "assistant-x"))
        let note = try XCTUnwrap(AnnotationDeriver.derive(ops: [op], paragraphs: [:]).first)
        XCTAssertEqual(PhonePosture.openNoteVerbs(for: note, docId: figureId, under: Self.posture(.bookAuthor, nil)),
                       [.accept, .reject, .archive])
        let accept = try writer(docId: figureId).makeAccept(for: note)
        XCTAssertEqual(accept.kind, .claudeAccept)
        XCTAssertNil(accept.figure, "a comment's accept writes no cell")
        XCTAssertEqual(AnnotationDeriver.derive(ops: [op, accept], paragraphs: [:]).first?.status, .accepted)
    }

    /// An accepted figure suggestion offers no *Reopen & Revert* (its cell
    /// is put back in the grid); a rejected one still offers Reopen.
    func test_anAcceptedFigureSuggestionOffersNoReopenAndRevert() throws {
        let author = Self.posture(.bookAuthor, nil)
        let (op, _) = try figureSuggestion()
        let accept = FigureAnnotationOps.accept(
            annotationId: op.opId, cell: CellKey(row: r1, column: c1),
            next: Cell(content: .value(.number(12))), prior: nil,
            stamp: .init(figureId: figureId, device: "mac"))
        let accepted = try XCTUnwrap(AnnotationDeriver.derive(ops: [op, accept], paragraphs: [:]).first)
        XCTAssertEqual(accepted.status, .accepted)
        XCTAssertNil(PhonePosture.reopenVerb(for: accepted, docId: figureId, under: author))
        XCTAssertThrowsError(try writer(docId: figureId).makeAcceptRevert(
            for: accepted, acceptOp: accept, currentParagraph: nil))
        let reject = FigureAnnotationOps.reject(
            annotationId: op.opId, reason: nil, stamp: .init(figureId: figureId, device: "mac"))
        let rejected = try XCTUnwrap(AnnotationDeriver.derive(ops: [op, reject], paragraphs: [:]).first)
        XCTAssertEqual(PhonePosture.reopenVerb(for: rejected, docId: figureId, under: author), .reopen)
    }

    // MARK: - The writer

    /// The gate is structural: the writer refuses to build an accept for a
    /// figure suggestion, with no assertion, whoever asks.
    func test_theWriterRefusesToAcceptAFigureSuggestion() throws {
        let (_, note) = try figureSuggestion()
        var w = writer(docId: figureId)
        w.assertOnMalformed = true
        XCTAssertThrowsError(try w.makeAccept(for: note)) { error in
            guard case AnnotationWriter.WriteError.acceptsInTheTable(let id) = error else {
                return XCTFail("threw \(error)")
            }
            XCTAssertEqual(id, note.id)
        }
    }

    /// Reject on a figure suggestion writes a valid op on the figure's own
    /// stream: Core's figure reject, the reason kept, no cell, chained into
    /// `<figureId>.<slug>.jsonl`, and read back by the shared deriver as
    /// rejected. Archive is Core's too.
    func test_rejectWritesAValidOpOnTheFigureStream() async throws {
        let root = TestTemp.root.appendingPathComponent("fig-reject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let (creation, note) = try figureSuggestion()

        let appended = try await writer(docId: figureId, root: root).reject(note, reason: "The total is right.")

        XCTAssertEqual(appended.kind, .claudeReject)
        XCTAssertEqual(appended.docId, figureId)
        XCTAssertEqual(appended.device, identity.deviceId)
        XCTAssertEqual(appended.provenance?.sourceAnnotationId, note.id)
        XCTAssertEqual(appended.provenance?.userResponse, "The total is right.")
        XCTAssertNil(appended.figure, "no cell moves")
        let url = try OpLogStore.opLogFileURL(forDocId: figureId, deviceSlug: identity.slug, in: root)
        let loaded = try await JSONLAppendStore<Op>(fileURL: url).load()
        XCTAssertEqual(loaded, [appended])
        let derived = AnnotationDeriver.derive(ops: [creation] + loaded, paragraphs: [:])
        XCTAssertEqual(derived.first?.status, .rejected)
        XCTAssertEqual(derived.first?.userResponse, "The total is right.")

        let archive = writer(docId: figureId).makeArchive(for: note)
        XCTAssertEqual(archive.kind, .claudeArchive)
        XCTAssertEqual(archive.docId, figureId)
        XCTAssertNil(archive.figure)
        XCTAssertEqual(AnnotationDeriver.derive(ops: [creation, archive], paragraphs: [:]).first?.status, .archived)
    }

    /// A paragraph's reject is unchanged by the figure arm.
    func test_aParagraphRejectIsUnchanged() {
        let op = writer(docId: docId).makeReject(for: paragraphSuggestion(), reason: "no")
        XCTAssertEqual(op.docId, docId)
        XCTAssertEqual(op.kind, .claudeReject)
        XCTAssertNil(op.provenance?.annotationBody)
        XCTAssertEqual(op.provenance?.userResponse, "no")
    }

    // MARK: - What the detail shows

    /// The detail's figure words are Core's: the anchor line and the cells.
    func test_theDetailsFigureWordsAreCores() throws {
        var table = FigureTable(rows: 1, columns: 1)
        let key = CellKey(row: table.rows[0], column: table.columns[0])
        table.setCell(Cell(content: .value(.number(11.5))), at: key)
        let op = try FigureAnnotationOps.creation(
            kind: .suggestedChange, anchor: FigureCellAnchor(row: key.row, column: key.column),
            body: "Round it", suggestedCell: Cell(content: .value(.number(12))), prior: nil,
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: figureId, device: "assistant-x"))
        let note = try XCTUnwrap(AnnotationDeriver.derive(ops: [op], paragraphs: [:], figureTable: table).first)
        XCTAssertEqual(SuggestionDisplay.figureAnchorLine(for: note, figureTitle: "Table: cash"),
                       "A1 \u{00B7} Table: cash")
        XCTAssertEqual(SuggestionDisplay.figureCells(
            for: note, table: table, locale: TableLocale(languageTag: "en-US", fallbackRegion: nil)),
            .init(before: "11.5", after: "12"))
    }
}
