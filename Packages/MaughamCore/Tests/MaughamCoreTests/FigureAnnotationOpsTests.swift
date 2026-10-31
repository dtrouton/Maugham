import XCTest
@testable import MaughamCore

/// Report plan 9c-1 Task 2: the anchor text, the machine-form suggested value,
/// and every figure-note op builder, each proved through `AnnotationDeriver`.
final class FigureAnnotationOpsTests: XCTestCase {

    private let figureId = "fig-k3m9q2zt"
    private let r1 = RowID("r1aaaaaa"), r2 = RowID("r2bbbbbb"), r3 = RowID("r3cccccc")
    private let c1 = ColumnID("c1dddddd"), c2 = ColumnID("c2eeeeee"), c3 = ColumnID("c3ffffff")
    private let claude = AnnotationAuthor(sourceKind: .claude, displayName: "Claude")
    private var counter = 0

    private func stamp() -> FigureAnnotationOps.Stamp {
        counter += 1
        return .init(figureId: figureId, device: "macA", session: "s",
                     at: Date(timeIntervalSince1970: TimeInterval(1_000 + counter)),
                     appVersion: "1", osVersion: "2")
    }

    private func figureOp(_ kind: OpKind, _ payload: FigureOpPayload) -> Op {
        counter += 1
        return Op(opId: String(format: "base%03d", counter), docId: figureId,
                  at: Date(timeIntervalSince1970: TimeInterval(counter)),
                  device: "macA", session: "s", kind: kind, changes: [], figure: payload)
    }

    /// A 3x3 table, so (r3, c3) is "C3".
    private func base() -> [Op] {
        [figureOp(.figureCreate, .init(kind: .table))]
        + [(r1, nil), (r2, r1), (r3, r2)].map { figureOp(.figureStructure, .init(structure: .insertRow($0.0, after: $0.1))) }
        + [(c1, nil), (c2, c1), (c3, c2)].map { figureOp(.figureStructure, .init(structure: .insertColumn($0.0, after: $0.1))) }
    }

    private var table: FigureTable { FigureDeriver.derive(base()).table }
    private func num(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }
    private let c3Key = CellKey(row: RowID("r3cccccc"), column: ColumnID("c3ffffff"))

    private func derive(_ ops: [Op]) -> [Annotation] {
        AnnotationAggregation.allAnnotations(
            ops: ops, paragraphs: [:], figureTable: AnnotationAggregation.figureTable(in: ops))
    }

    private func suggestion() throws -> Op {
        try FigureAnnotationOps.creation(
            kind: .suggestedChange, anchor: FigureCellAnchor(row: r3, column: c3), body: "Round it",
            suggestedCell: num(12), prior: num(11.5), author: claude, stamp: stamp())
    }

    // MARK: - Address text

    func test_parse_forms() {
        XCTAssertTrue(FigureAnchorAddress.parse("tbl:x")! == ("tbl:x", nil))
        XCTAssertTrue(FigureAnchorAddress.parse("tbl:x!C3")! == ("tbl:x", "C3"))
        XCTAssertTrue(FigureAnchorAddress.parse("tbl:x!c3:e3")! == ("tbl:x", "c3:e3"))
        XCTAssertTrue(FigureAnchorAddress.parse("tbl:cash flow!C3:E3")! == ("tbl:cash flow", "C3:E3"))
        for junk in ["", "x", "tbl:", "tbl:!C3", "tbl:x!", "!C3", "doc:x!C3"] {
            XCTAssertNil(FigureAnchorAddress.parse(junk), junk)
        }
    }

    func test_anchor_turnsPositionsIntoIds() throws {
        let one = try FigureAnchorAddress.anchor("C3", in: table).get()
        XCTAssertEqual(one, FigureCellAnchor(row: r3, column: c3))
        let range = try FigureAnchorAddress.anchor("a1:c2", in: table).get()
        XCTAssertEqual(range, FigureCellAnchor(row: r1, rowEnd: r2, column: c1, columnEnd: c3))
        let rowOnly = try FigureAnchorAddress.anchor("A2:C2", in: table).get()
        XCTAssertEqual(rowOnly, FigureCellAnchor(row: r2, column: c1, columnEnd: c3))
    }

    func test_anchor_ofAnOutOfRangeCell_isAnError() {
        for bad in ["D1", "A4", "A1:D9", "nope", ""] {
            XCTAssertThrowsError(try FigureAnchorAddress.anchor(bad, in: table).get(), bad)
        }
    }

    // MARK: - Machine-form value

    func test_suggestedCell_numberAndText() throws {
        let key = c3Key
        XCTAssertEqual(try FigureAnnotationOps.suggestedCell(from: "1234.5", at: key, table: table, names: .empty).get(),
                       num(1234.5))
        XCTAssertNil(try FigureAnnotationOps.suggestedCell(from: "", at: key, table: table, names: .empty).get())
    }

    func test_suggestedCell_formulaIsStoredByIds() throws {
        let cell = try XCTUnwrap(FigureAnnotationOps.suggestedCell(
            from: "=SUM(B2:B3)", at: c3Key, table: table, names: .empty).get())
        guard case .formula(let formula) = cell.content else { return XCTFail("not a formula") }
        // Moving the referenced rows' neighbours must not change what it reads: ids, not positions.
        var grown = table
        _ = grown.insertRow(after: nil)
        let shown = FigureCellEntry.formulaBarText(
            for: Cell(content: .formula(formula)), table: grown, names: .empty,
            locale: TableLocale(languageTag: "en-US", fallbackRegion: nil))
        XCTAssertEqual(shown, "=SUM(B3:B4)")
    }

    func test_suggestedCell_badFormulaFailsWithAnOffset() {
        let result = FigureAnnotationOps.suggestedCell(from: "=SUM(", at: c3Key, table: table, names: .empty)
        guard case .failure = result else { return XCTFail("expected a parse error") }
    }

    // MARK: - Creation

    func test_creation_comment_onACellAndOnTheWholeFigure() throws {
        let cell = try FigureAnnotationOps.creation(
            kind: .comment, anchor: FigureCellAnchor(row: r1, rowEnd: r2, column: c2),
            body: "Look", author: claude, stamp: stamp())
        let whole = try FigureAnnotationOps.creation(
            kind: .query, anchor: nil, body: "Why?", author: claude, language: "es", stamp: stamp())
        let notes = derive(base() + [cell, whole])
        let a = try XCTUnwrap(notes.first { $0.id == cell.opId })
        XCTAssertEqual(a.kind, .comment)
        XCTAssertEqual(a.figureAddress, "B1:B2")
        XCTAssertEqual(a.author?.sourceKind, .claude)
        XCTAssertEqual(a.status, .open)
        let w = try XCTUnwrap(notes.first { $0.id == whole.opId })
        XCTAssertNil(w.figureAnchor)
        XCTAssertEqual(w.language, "es")
    }

    func test_creation_suggestion_carriesTheCell() throws {
        let op = try suggestion()
        XCTAssertEqual(op.kind, .claudeSuggestion)
        XCTAssertEqual(op.figure?.cell, c3Key)
        let note = try XCTUnwrap(derive(base() + [op]).first)
        XCTAssertEqual(note.suggestedCell, num(12))
        XCTAssertEqual(note.figureAddress, "C3")
        // Still a suggestion: the table is untouched.
        XCTAssertNil(FigureDeriver.derive(base() + [op]).table[c3Key])
    }

    func test_creation_refusals() {
        XCTAssertThrowsError(try FigureAnnotationOps.creation(
            kind: .suggestedChange, anchor: nil, body: "", suggestedCell: num(1), author: claude, stamp: stamp()))
        XCTAssertThrowsError(try FigureAnnotationOps.creation(
            kind: .suggestedChange, anchor: FigureCellAnchor(row: r1, rowEnd: r2, column: c1),
            body: "", suggestedCell: num(1), author: claude, stamp: stamp()))
        XCTAssertThrowsError(try FigureAnnotationOps.creation(
            kind: .craftNote, anchor: FigureCellAnchor(row: r1, column: c1), body: "", author: claude, stamp: stamp()))
    }

    // MARK: - Lifecycle

    private func status(of id: String, after ops: [Op]) throws -> AnnotationStatus {
        try XCTUnwrap(derive(base() + ops).first { $0.id == id }).status
    }

    /// An accept's revert as a host mints it: `FigureInverse` of its payload,
    /// stamped with `lifecycleProvenance` (no builder spells it twice).
    private func revert(of accept: Op) throws -> Op {
        let inv = try XCTUnwrap(FigureInverse.inverse(of: try XCTUnwrap(accept.figure), kind: accept.kind))
        let st = stamp()
        return Op(opId: ULID.generate(), docId: figureId, at: st.at, device: st.device, session: st.session,
                  kind: inv.0, changes: [],
                  provenance: FigureAnnotationOps.lifecycleProvenance(
                      annotationId: try XCTUnwrap(accept.provenance?.sourceAnnotationId), stamp: st),
                  figure: inv.1)
    }

    func test_accept_thenRevert() throws {
        let s = try suggestion()
        let accept = FigureAnnotationOps.accept(
            annotationId: s.opId, cell: c3Key, next: num(12), prior: num(11.5), stamp: stamp())
        XCTAssertEqual(accept.kind, .claudeAccept)
        XCTAssertEqual(accept.provenance?.sourceAnnotationId, s.opId)
        XCTAssertEqual(accept.figure, FigureOpPayload(cell: c3Key, next: num(12), prior: num(11.5)))
        XCTAssertEqual(try status(of: s.opId, after: [s, accept]), .accepted)

        let revert = try revert(of: accept)
        XCTAssertEqual(revert.kind, .claudeAcceptRevert)
        XCTAssertEqual(revert.figure, FigureOpPayload(cell: c3Key, next: num(11.5), prior: num(12)))
        XCTAssertEqual(try status(of: s.opId, after: [s, accept, revert]), .open)
    }

    func test_rejectKeepsItsReason_thenReopen() throws {
        let s = try suggestion()
        let reject = FigureAnnotationOps.reject(annotationId: s.opId, reason: "Wrong year", stamp: stamp())
        XCTAssertEqual(try status(of: s.opId, after: [s, reject]), .rejected)
        XCTAssertEqual(derive(base() + [s, reject]).first?.userResponse, "Wrong year")
        let reopen = FigureAnnotationOps.reopen(annotationId: s.opId, stamp: stamp())
        XCTAssertEqual(try status(of: s.opId, after: [s, reject, reopen]), .open)
        XCTAssertEqual(derive(base() + [s, reject, reopen]).first?.previousRejectionReason, "Wrong year")
    }

    func test_aStatusOnlyAcceptResolvesAndWritesNoCell() throws {
        let s = try suggestion()
        let again = FigureAnnotationOps.statusOnlyAccept(annotationId: s.opId, stamp: stamp())
        XCTAssertEqual(again.kind, .claudeAccept)
        XCTAssertNil(again.figure)
        XCTAssertFalse(FigureOpPayload.folds(again))
        XCTAssertEqual(try status(of: s.opId, after: [s, again]), .accepted)
    }

    func test_stetAndArchive_thenReopen() throws {
        let s = try suggestion()
        let stet = FigureAnnotationOps.stet(annotationId: s.opId, stamp: stamp())
        XCTAssertEqual(try status(of: s.opId, after: [s, stet]), .stetted)
        let archive = FigureAnnotationOps.archive(annotationId: s.opId, stamp: stamp())
        XCTAssertEqual(try status(of: s.opId, after: [s, stet, archive]), .archived)
        let reopen = FigureAnnotationOps.reopen(annotationId: s.opId, stamp: stamp())
        XCTAssertEqual(try status(of: s.opId, after: [s, stet, archive, reopen]), .open)
    }

    func test_everyOpIsOnTheFiguresStreamAndStamped() throws {
        let s = try suggestion()
        for op in [s, FigureAnnotationOps.stet(annotationId: s.opId, stamp: stamp())] {
            XCTAssertEqual(op.docId, figureId)
            XCTAssertEqual(op.device, "macA")
            XCTAssertEqual(op.provenance?.sessionId, "s")
            XCTAssertEqual(op.provenance?.appVersion, "1")
        }
    }

    // MARK: - The accept's cell, folded (Task 5)

    /// **An accept writes its cell; its revert puts it back** — folded as the
    /// cell set each payload is, by the deriver, the annotation table and the
    /// return base alike, with no diagnostic. The suggestion's own payload
    /// still folds as nothing.
    func test_anAcceptAndItsRevertFoldAsCellSets() throws {
        let s = try suggestion()
        let accept = FigureAnnotationOps.accept(
            annotationId: s.opId, cell: c3Key, next: num(12), prior: nil, stamp: stamp())
        let revert = try revert(of: accept)

        let accepted = FigureDeriver.derive(base() + [s, accept])
        XCTAssertEqual(accepted.table[c3Key], num(12))
        XCTAssertEqual(accepted.diagnostics.filter { !$0.contains(s.opId) }, [],
                       "the accept folds cleanly (only the note's creation is not a figure op)")
        XCTAssertEqual(AnnotationAggregation.figureTable(in: base() + [s, accept])?[c3Key], num(12))
        XCTAssertNil(FigureDeriver.derive(base() + [s, accept, revert]).table[c3Key], "the revert puts it back")
        XCTAssertNil(AnnotationAggregation.figureTable(in: base() + [s])?[c3Key], "a suggestion writes nothing")

        let stream = base() + [s, accept]
        let returned = FigureReturnDiff.base(
            of: stream, streams: ["macA": stream.map(\.opId)], frontier: ["macA": accept.opId])
        XCTAssertEqual(returned.table[c3Key], num(12), "a return's base counts the accept it had read")
    }

    /// **Which ops fold**: the nine figure kinds as themselves; an accept or
    /// revert carrying a cell as a cell set; a manuscript's accept (no
    /// payload), and every note's other line, as nothing — so `kinds`, which
    /// the permit census reads, stays the nine.
    func test_foldKindIsDecidedByThePayload() {
        XCTAssertEqual(FigureOpPayload.foldKind(.figureCellSet, payload: nil), .figureCellSet)
        XCTAssertEqual(FigureOpPayload.foldKind(.claudeAccept, payload: .init(cell: c3Key)), .figureCellSet)
        XCTAssertEqual(FigureOpPayload.foldKind(.claudeAcceptRevert, payload: .init(cell: c3Key)), .figureCellSet)
        XCTAssertNil(FigureOpPayload.foldKind(.claudeAccept, payload: nil), "a manuscript accept")
        XCTAssertNil(FigureOpPayload.foldKind(.claudeAccept, payload: .init()), "no cell")
        XCTAssertNil(FigureOpPayload.foldKind(.claudeSuggestion, payload: .init(cell: c3Key)), "a suggestion")
        XCTAssertNil(FigureOpPayload.foldKind(.claudeReject, payload: .init(cell: c3Key)))
        XCTAssertFalse(FigureOpPayload.kinds.contains(.claudeAccept))
        let manuscriptAccept = Op(opId: "m1", docId: "doc", at: Date(), device: "macA", session: "s",
                                  kind: .claudeAccept, changes: [])
        XCTAssertFalse(FigureOpPayload.folds(manuscriptAccept))
        var state = FigureDeriver.derive(base())
        FigureDeriver.fold(manuscriptAccept, into: &state)
        XCTAssertEqual(state.diagnostics, ["m1: claude_accept is not a figure op"])
    }

    /// **An accept on a parked figure folds nothing**, and one naming a row
    /// no insert has shown waits for it, as a cell set does.
    func test_anAcceptIsContent_parkedDropsIt_andAnUnseenRowHoldsIt() throws {
        let s = try suggestion()
        let parked = figureOp(.figureParked, .init(parkedPath: "research/t.csv", parkedHash: "h"))
        let accept = FigureAnnotationOps.accept(
            annotationId: s.opId, cell: c3Key, next: num(12), prior: nil, stamp: stamp())
        XCTAssertNil(FigureDeriver.derive(base() + [parked, accept]).table[c3Key])

        let r9 = RowID("r9zzzzzz")
        let early = FigureAnnotationOps.accept(
            annotationId: s.opId, cell: CellKey(row: r9, column: c1), next: num(9), prior: nil, stamp: stamp())
        let insert = figureOp(.figureStructure, .init(structure: .insertRow(r9, after: r3)))
        XCTAssertEqual(FigureDeriver.derive(base() + [early, insert]).table[CellKey(row: r9, column: c1)], num(9),
                       "held, then replayed once its row exists")
    }

    /// **The accept's inverse is its revert, carrying the note's id**: the
    /// tuple inverse swaps the kinds and the cell, and the change form keeps
    /// `sourceAnnotationId` through undo and redo — what a grid visit takes back.
    func test_theAcceptsInverseIsItsRevert_andTheNotesIdRidesAlong() {
        let payload = FigureOpPayload(cell: c3Key, next: num(12), prior: num(11.5))
        let inv = FigureInverse.inverse(of: payload, kind: .claudeAccept)
        XCTAssertEqual(inv?.0, .claudeAcceptRevert)
        XCTAssertEqual(inv?.1, FigureOpPayload(cell: c3Key, next: num(11.5), prior: num(12)))
        XCTAssertEqual(FigureInverse.inverse(of: inv!.1, kind: .claudeAcceptRevert)?.0, .claudeAccept)

        let visit = [
            FigureReturnDiff.Change(kind: .figureCellSet, payload: .init(cell: CellKey(row: r1, column: c1), next: num(1))),
            FigureReturnDiff.Change(kind: .claudeAccept, payload: payload, sourceAnnotationId: "note1"),
        ]
        let undo = FigureInverse.compensating(visit)
        XCTAssertEqual(undo.map(\.kind), [.claudeAcceptRevert, .figureCellSet])
        XCTAssertEqual(undo.map(\.sourceAnnotationId), ["note1", nil])
        XCTAssertEqual(FigureInverse.compensating(undo), visit, "the redo is the visit again")

        var state = FigureDeriver.derive(base())
        state.table.setCell(num(11.5), at: c3Key)
        XCTAssertNotNil(FigureReturnDiff.applied([visit[1]], onto: state), "an accept describes the cell it replaces")
        state.table.setCell(num(3), at: c3Key)
        XCTAssertNil(FigureReturnDiff.applied([visit[1]], onto: state), "and is refused when the cell moved")
    }

    // MARK: - Status-only accept and revert; accepted only in the table (Task 7)

    /// A reply is a status-only accept carrying the writer's words; its ⌘Z
    /// is a status-only revert. Neither folds as a cell.
    func test_statusOnlyAcceptWithAReply_thenItsRevert_reopen() throws {
        let query = try FigureAnnotationOps.creation(
            kind: .query, anchor: FigureCellAnchor(row: r3, column: c3), body: "Source?",
            author: claude, stamp: stamp())
        let reply = FigureAnnotationOps.statusOnlyAccept(
            annotationId: query.opId, userResponse: "The 2023 census", stamp: stamp())
        XCTAssertNil(reply.figure)
        XCTAssertFalse(FigureOpPayload.folds(reply))
        var notes = derive(base() + [query, reply])
        XCTAssertEqual(notes.first?.status, .accepted)
        XCTAssertEqual(notes.first?.userResponse, "The 2023 census")
        let revert = FigureAnnotationOps.statusOnlyRevert(annotationId: query.opId, stamp: stamp())
        XCTAssertEqual(revert.kind, .claudeAcceptRevert)
        XCTAssertEqual(revert.provenance?.sourceAnnotationId, query.opId)
        XCTAssertFalse(FigureOpPayload.folds(revert))
        notes = derive(base() + [query, reply, revert])
        XCTAssertEqual(notes.first?.status, .open)
        XCTAssertEqual(FigureDeriver.derive(base() + [query, reply, revert]).table, table)
    }

    /// Accepted only in the table: a suggestion on a figure's stream (by its
    /// anchor, or by the stream when the anchor is missing); never a figure
    /// comment, and never a paragraph's suggestion.
    func test_acceptsOnlyInTheTable() throws {
        let notes = derive(base() + [try suggestion(),
            try FigureAnnotationOps.creation(kind: .comment, anchor: nil, body: "c", author: claude, stamp: stamp())])
        let figSuggestion = try XCTUnwrap(notes.first { $0.kind == .suggestedChange })
        let figComment = try XCTUnwrap(notes.first { $0.kind == .comment })
        XCTAssertTrue(FigureAnnotationOps.acceptsOnlyInTheTable(figSuggestion, docId: figureId))
        XCTAssertFalse(FigureAnnotationOps.acceptsOnlyInTheTable(figComment, docId: figureId))
        let paragraph = Annotation(
            id: "p", kind: .suggestedChange, paragraphId: "abcd", body: "", suggestedText: "x",
            priorText: "y", createdAt: Date(), createdBySession: nil, status: .open,
            userResponse: nil, resolvedAt: nil, isStale: false)
        XCTAssertFalse(FigureAnnotationOps.acceptsOnlyInTheTable(paragraph, docId: "doc-abcdef12"))
        XCTAssertTrue(FigureAnnotationOps.acceptsOnlyInTheTable(paragraph, docId: figureId),
                      "a suggestion on a figure's stream is the table's even with no anchor")
    }
}
