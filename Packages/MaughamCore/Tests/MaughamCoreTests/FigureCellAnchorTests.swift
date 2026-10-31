import XCTest
@testable import MaughamCore

/// Report plan 9c-1 Task 1: a figure note's cell anchor and a figure
/// suggestion's cell, projected onto `Annotation` and resolved against the
/// figure's table — by id, so the anchor follows inserts, is orphaned when its
/// row or column is deleted, and comes back with a revive (spec §10.1).
final class FigureCellAnchorTests: XCTestCase {

    private let figureId = "fig-k3m9q2zt"
    private let r1 = RowID("r1aaaaaa"), r2 = RowID("r2bbbbbb"), r3 = RowID("r3cccccc")
    private let c1 = ColumnID("c1dddddd"), c2 = ColumnID("c2eeeeee"), c3 = ColumnID("c3ffffff")
    private var counter = 0

    private func op(
        _ kind: OpKind, figure: FigureOpPayload? = nil, provenance: Op.Provenance? = nil
    ) -> Op {
        counter += 1
        return Op(opId: String(format: "op%04d", counter), docId: figureId,
                  at: Date(timeIntervalSince1970: TimeInterval(1_000 + counter)),
                  device: "macA", session: "s", kind: kind, changes: [],
                  provenance: provenance, figure: figure)
    }

    private func num(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }
    private func structure(_ change: FigureStructureChange, removed: FigureRemovedSlice? = nil) -> Op {
        op(.figureStructure, figure: FigureOpPayload(structure: change, removed: removed))
    }

    /// A 3×3 table: rows r1 r2 r3, columns c1 c2 c3 — so (r3, c3) is "C3".
    private func base() -> [Op] {
        [op(.figureCreate, figure: FigureOpPayload(kind: .table)),
         structure(.insertRow(r1, after: nil)), structure(.insertRow(r2, after: r1)),
         structure(.insertRow(r3, after: r2)),
         structure(.insertColumn(c1, after: nil)), structure(.insertColumn(c2, after: c1)),
         structure(.insertColumn(c3, after: c2))]
    }

    private func comment(
        row: RowID? = nil, rowEnd: RowID? = nil, column: ColumnID? = nil, columnEnd: ColumnID? = nil
    ) -> Op {
        op(.claudeComment, provenance: Op.Provenance(
            annotationBody: "Check this",
            figureRowId: row?.raw, figureRowEndId: rowEnd?.raw,
            figureColId: column?.raw, figureColEndId: columnEnd?.raw))
    }

    private func derive(_ ops: [Op]) -> [Annotation] {
        AnnotationAggregation.allAnnotations(
            ops: ops, paragraphs: [:], figureTable: AnnotationAggregation.figureTable(in: ops))
    }

    private func table(_ ops: [Op]) -> FigureTable { FigureDeriver.derive(ops).table }

    // MARK: - Projection

    func test_theFourScalars_deriveTheAnchor() throws {
        let ops = base() + [comment(row: r1, rowEnd: r2, column: c2, columnEnd: c3)]
        let note = try XCTUnwrap(derive(ops).first)
        XCTAssertEqual(note.figureAnchor, FigureCellAnchor(row: r1, rowEnd: r2, column: c2, columnEnd: c3))
        XCTAssertEqual(note.figureAddress, "B1:C2")
        XCTAssertFalse(note.isStale)
        XCTAssertNil(note.paragraphId)
    }

    func test_aFigureNoteWithNoScalars_isOnTheWholeFigure() throws {
        let note = try XCTUnwrap(derive(base() + [comment()]).first)
        XCTAssertNil(note.figureAnchor)
        XCTAssertNil(note.figureAddress)
        XCTAssertFalse(note.isStale)
    }

    func test_aRowWithoutAColumn_namesNoCell() {
        XCTAssertNil(FigureCellAnchor(provenance: Op.Provenance(figureRowId: r1.raw)))
        XCTAssertNil(FigureCellAnchor(provenance: Op.Provenance(figureColId: c1.raw)))
        XCTAssertNil(FigureCellAnchor(provenance: nil))
    }

    func test_withNoTable_theAnchorIsProjectedButNeverResolved() throws {
        let ops = base() + [comment(row: r3, column: c3)]
        let note = try XCTUnwrap(AnnotationAggregation.allAnnotations(ops: ops, paragraphs: [:]).first)
        XCTAssertEqual(note.figureAnchor, FigureCellAnchor(row: r3, column: c3))
        XCTAssertNil(note.figureAddress)
        XCTAssertFalse(note.isStale)
    }

    /// The overload that derives the paragraphs itself derives the figure's
    /// table too, so the phone's one-call read resolves anchors as the Mac's
    /// figure walk does.
    func test_theSelfDerivingOverload_resolvesAgainstTheStreamsOwnTable() throws {
        let ops = base() + [comment(row: r3, column: c3)]
        let note = try XCTUnwrap(AnnotationAggregation.allAnnotations(ops: ops).first)
        XCTAssertEqual(note.figureAddress, "C3")
    }

    func test_aStreamWithNoFigureOps_hasNoTable() {
        XCTAssertNil(AnnotationAggregation.figureTable(in: [comment(row: r1, column: c1)]))
        XCTAssertNil(AnnotationAggregation.figureTable(in: []))
    }

    // MARK: - Resolution by id

    func test_resolve_followsARowInsertedAbove() {
        let anchor = FigureCellAnchor(row: r3, column: c3)
        var ops = base()
        XCTAssertEqual(anchor.resolve(in: table(ops)), .live(a1: "C3"))
        ops.append(structure(.insertRow(RowID("rNnnnnnn"), after: r1)))
        XCTAssertEqual(anchor.resolve(in: table(ops)), .live(a1: "C4"))
    }

    func test_resolve_isOrphanedByTheRowsDelete_andBackOnItsRevive() throws {
        let anchor = FigureCellAnchor(row: r3, column: c3)
        var ops = base() + [op(.figureCellSet, figure: FigureOpPayload(cell: CellKey(row: r3, column: c3), next: num(7)))]
        let slice = FigureDeriver.derive(ops).removedSlice(row: r3)
        ops.append(structure(.deleteRow(r3), removed: slice))
        XCTAssertEqual(anchor.resolve(in: table(ops)), .orphaned)

        let orphaned = try XCTUnwrap(derive(ops + [comment(row: r3, column: c3)]).first)
        XCTAssertTrue(orphaned.isStale, "an orphaned anchor is stale")
        XCTAssertNil(orphaned.figureAddress)
        XCTAssertEqual(orphaned.figureAnchor, anchor, "the anchor stays by id while orphaned")

        ops.append(structure(.reviveRow(r3), removed: slice))
        XCTAssertEqual(anchor.resolve(in: table(ops)), .live(a1: "C3"))
        let revived = try XCTUnwrap(derive(ops + [comment(row: r3, column: c3)]).first)
        XCTAssertFalse(revived.isStale)
        XCTAssertEqual(revived.figureAddress, "C3")
    }

    func test_aRange_isOrphanedWhenOneCornerColumnIsDeleted() {
        let anchor = FigureCellAnchor(row: r1, rowEnd: r2, column: c1, columnEnd: c3)
        var ops = base()
        XCTAssertEqual(anchor.resolve(in: table(ops)), .live(a1: "A1:C2"))
        ops.append(structure(.deleteColumn(c3), removed: FigureRemovedSlice()))
        XCTAssertEqual(anchor.resolve(in: table(ops)), .orphaned)
    }

    func test_anIdTheTableNeverHeld_isOrphaned() {
        XCTAssertEqual(FigureCellAnchor(row: RowID("rZzzzzzz"), column: c1).resolve(in: table(base())), .orphaned)
    }

    // MARK: - The suggested cell

    func test_aSuggestionCarryingAFigurePayload_derivesSuggestedCell() throws {
        let key = CellKey(row: r2, column: c2)
        let suggestion = op(.claudeSuggestion,
                            figure: FigureOpPayload(cell: key, next: num(42), prior: nil),
                            provenance: Op.Provenance(annotationBody: "Should be 42",
                                                      figureRowId: r2.raw, figureColId: c2.raw))
        let note = try XCTUnwrap(derive(base() + [suggestion]).first)
        XCTAssertEqual(note.kind, .suggestedChange)
        XCTAssertEqual(note.suggestedCell, num(42))
        XCTAssertEqual(note.figureAddress, "B2")
        XCTAssertNil(note.suggestedText)
    }

    func test_aCommentCarriesNoSuggestedCell() throws {
        let stray = op(.claudeComment, figure: FigureOpPayload(cell: CellKey(row: r1, column: c1), next: num(1)),
                       provenance: Op.Provenance(figureRowId: r1.raw, figureColId: c1.raw))
        XCTAssertNil(try XCTUnwrap(derive(base() + [stray]).first).suggestedCell)
    }

    /// The suggestion stays a suggestion until accepted: no figure derivation
    /// folds its payload as a cell write.
    func test_aSuggestionIsNeverFoldedAsACellWrite() {
        let key = CellKey(row: r2, column: c2)
        let ops = base() + [
            op(.figureCellSet, figure: FigureOpPayload(cell: key, next: num(1))),
            op(.claudeSuggestion, figure: FigureOpPayload(cell: key, next: num(42), prior: num(1)),
               provenance: Op.Provenance(figureRowId: r2.raw, figureColId: c2.raw)),
        ]
        XCTAssertEqual(FigureDeriver.derive(ops).table[key], num(1), "the deriver folds figure kinds only")
        XCTAssertEqual(AnnotationAggregation.figureTable(in: ops)?[key], num(1))
    }
}
