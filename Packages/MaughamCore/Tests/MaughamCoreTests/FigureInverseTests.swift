import XCTest
@testable import MaughamCore

/// Report plan 6a Task 3: each invertible figure op has an inverse that puts
/// the table back, and a visit's compensating ops undo it as one.
final class FigureInverseTests: XCTestCase {

    private let r1 = RowID("r1aaaaaa"), r2 = RowID("r2bbbbbb"), r3 = RowID("r3cccccc")
    private let c1 = ColumnID("c1dddddd"), c2 = ColumnID("c2eeeeee")
    private var counter = 0

    private func num(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }
    private func key(_ r: RowID, _ c: ColumnID) -> CellKey { CellKey(row: r, column: c) }

    private func op(_ step: (OpKind, FigureOpPayload)) -> Op {
        counter += 1
        return Op(opId: "op\(counter)", docId: "fig-k3m9q2zt", at: Date(timeIntervalSince1970: TimeInterval(counter)),
                  device: "macA", session: "s", kind: step.0, changes: [], figure: step.1)
    }

    private func apply(_ steps: [(OpKind, FigureOpPayload)], to state: FigureState) -> FigureState {
        var s = state
        for step in steps { FigureDeriver.fold(op(step), into: &s) }
        return s
    }

    /// A 3×2 table with cells, settings and an image.
    private func start() -> FigureState {
        apply([
            (.figureCreate, FigureOpPayload(kind: .table)),
            (.figureStructure, FigureOpPayload(structure: .insertRow(r1, after: nil))),
            (.figureStructure, FigureOpPayload(structure: .insertRow(r2, after: r1))),
            (.figureStructure, FigureOpPayload(structure: .insertRow(r3, after: r2))),
            (.figureStructure, FigureOpPayload(structure: .insertColumn(c1, after: nil))),
            (.figureStructure, FigureOpPayload(structure: .insertColumn(c2, after: c1))),
            (.figureCellSet, FigureOpPayload(cell: key(r1, c1), next: num(1))),
            (.figureCellSet, FigureOpPayload(cell: key(r2, c2), next: num(2))),
            (.figureSettings, FigureOpPayload(settings: .columnWidth(c1, 60, prior: nil))),
            (.figureImageSet, FigureOpPayload(image: FigureImageRef(filename: "a.png", contentHash: "ha"))),
        ], to: FigureState())
    }

    /// What the writer sees: live rows and columns, cells and settings. An undone
    /// insert leaves its tombstone slot by design (the table never forgets an id).
    private func assertSameView(_ a: FigureState, _ b: FigureState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.table.rows, b.table.rows, "rows", file: file, line: line)
        XCTAssertEqual(a.table.columns, b.table.columns, "columns", file: file, line: line)
        XCTAssertEqual(a.table.cells, b.table.cells, "cells", file: file, line: line)
        XCTAssertEqual(a.table.headerRows, b.table.headerRows, file: file, line: line)
        XCTAssertEqual(a.table.hasTotalRow, b.table.hasTotalRow, file: file, line: line)
        XCTAssertEqual(a.table.columnWidths, b.table.columnWidths, file: file, line: line)
        XCTAssertEqual(a.image, b.image, file: file, line: line)
    }

    private func roundTrip(_ step: (OpKind, FigureOpPayload), exact: Bool = true,
                           file: StaticString = #filePath, line: UInt = #line) {
        let before = start()
        let after = apply([step], to: before)
        XCTAssertNotEqual(after, before, "control: the op changed something", file: file, line: line)
        guard let inv = FigureInverse.inverse(of: step.1, kind: step.0) else {
            return XCTFail("\(step.0) has no inverse", file: file, line: line)
        }
        XCTAssertTrue(FigureOpPayload.validate(kind: inv.0, payload: inv.1), "the inverse is a valid op", file: file, line: line)
        let undone = apply([inv], to: after)
        if exact { XCTAssertEqual(undone.table, before.table, file: file, line: line) }
        assertSameView(undone, before, file: file, line: line)
        XCTAssertEqual(undone.diagnostics, [], file: file, line: line)
    }

    // MARK: - Round trips

    func test_cellSet_roundTrips() {
        roundTrip((.figureCellSet, FigureOpPayload(cell: key(r1, c1), next: num(9), prior: num(1))))
        roundTrip((.figureCellSet, FigureOpPayload(cell: key(r3, c2), next: num(9), prior: nil)))
        roundTrip((.figureCellSet, FigureOpPayload(cell: key(r2, c2), next: nil, prior: num(2))))
    }

    func test_insert_roundTrips_asADelete() {
        let r4 = RowID("r4ffffff"), c3 = ColumnID("c3gggggg")
        roundTrip((.figureStructure, FigureOpPayload(structure: .insertRow(r4, after: r1))), exact: false)
        roundTrip((.figureStructure, FigureOpPayload(structure: .insertColumn(c3, after: nil))), exact: false)
        XCTAssertEqual(
            FigureInverse.inverse(of: FigureOpPayload(structure: .insertRow(r4, after: r1)), kind: .figureStructure)?.1.structure,
            .deleteRow(r4))
    }

    /// **A delete carrying its slice undoes to a revive** (rulings P-1/P-2):
    /// the table is exactly as it was — the same slot, cells and width.
    func test_deleteWithItsSlice_roundTrips_asARevive() {
        let s = start()
        roundTrip((.figureStructure, FigureOpPayload(structure: .deleteRow(r1), removed: s.removedSlice(row: r1))))
        roundTrip((.figureStructure, FigureOpPayload(structure: .deleteColumn(c1), removed: s.removedSlice(column: c1))))
        let slice = s.removedSlice(row: r2)
        let inv = FigureInverse.inverse(of: FigureOpPayload(structure: .deleteRow(r2), removed: slice), kind: .figureStructure)
        XCTAssertEqual(inv?.1, FigureOpPayload(structure: .reviveRow(r2), removed: slice))
    }

    /// The revive's inverse is the delete again, carrying the same slice;
    /// an insert's is a delete with an empty slice, whose inverse is a revive
    /// with an empty slice — an insert's redo.
    func test_reviveAndInsert_invertThroughTheSlice() {
        let slice = FigureRemovedSlice(cells: [.init(at: c1.raw, cell: num(1))])
        XCTAssertEqual(
            FigureInverse.inverse(of: FigureOpPayload(structure: .reviveColumn(c2), removed: slice), kind: .figureStructure)?.1,
            FigureOpPayload(structure: .deleteColumn(c2), removed: slice))
        let r4 = RowID("r4ffffff")
        let undo = FigureInverse.inverse(of: FigureOpPayload(structure: .insertRow(r4, after: r1)), kind: .figureStructure)
        XCTAssertEqual(undo?.1, FigureOpPayload(structure: .deleteRow(r4), removed: FigureRemovedSlice()))
        let redo = undo.flatMap { FigureInverse.inverse(of: $0.1, kind: $0.0) }
        XCTAssertEqual(redo?.1, FigureOpPayload(structure: .reviveRow(r4), removed: FigureRemovedSlice()))
        // Folded: insert, undo, redo — the row is back where it was inserted.
        let back = apply([(.figureStructure, FigureOpPayload(structure: .insertRow(r4, after: r1))),
                          undo!, redo!], to: start())
        XCTAssertEqual(back.table.rows, [r1, r4, r2, r3])
        XCTAssertEqual(back.diagnostics, [])
    }

    func test_move_roundTrips_asAMoveBack() {
        roundTrip((.figureStructure, FigureOpPayload(structure: .moveRow(r3, after: nil, priorAfter: r2))))
        roundTrip((.figureStructure, FigureOpPayload(structure: .moveRow(r1, after: r3, priorAfter: nil))))
        roundTrip((.figureStructure, FigureOpPayload(structure: .moveColumn(c1, after: c2, priorAfter: nil))))
    }

    func test_settings_roundTrip() {
        roundTrip((.figureSettings, FigureOpPayload(settings: .headerRows(1, prior: 0))))
        roundTrip((.figureSettings, FigureOpPayload(settings: .totalRow(true, prior: false))))
        roundTrip((.figureSettings, FigureOpPayload(settings: .columnWidth(c1, 90, prior: 60))))
        roundTrip((.figureSettings, FigureOpPayload(settings: .columnWidth(c2, 90, prior: nil))))
    }

    func test_imageSet_roundTrips_toThePriorImage() {
        let a = FigureImageRef(filename: "a.png", contentHash: "ha")
        let b = FigureImageRef(filename: "b.png", contentHash: "hb")
        roundTrip((.figureImageSet, FigureOpPayload(image: b, priorImage: a)))
    }

    // MARK: - No inverse

    /// A delete with nothing recorded has no inverse: what it took is not
    /// known, and a revive would bring the row back as if it held nothing.
    func test_aDeleteWithoutASlice_hasNoInverse() {
        XCTAssertNil(FigureInverse.inverse(of: FigureOpPayload(structure: .deleteRow(r1)), kind: .figureStructure))
        XCTAssertNil(FigureInverse.inverse(of: FigureOpPayload(structure: .deleteColumn(c1)), kind: .figureStructure))
    }

    func test_firstImage_hasNoInverse_becauseThereIsNoClear() {
        let a = FigureImageRef(filename: "a.png", contentHash: "ha")
        XCTAssertNil(FigureInverse.inverse(of: FigureOpPayload(image: a, priorImage: nil), kind: .figureImageSet))
    }

    /// Ruling P-8: a pin refresh is undone from its payload alone — a pin
    /// that replaced one swaps back to it, a cell's first pin is cleared.
    func test_aPinSet_swapsToItsPriorPin_orClearsAFirstPin() throws {
        let old = FigureResearchPin(research: "res-a", row: 2, column: 1, value: .number(10), sourceHash: "h1",
                                    at: Date(timeIntervalSince1970: 1))
        let new = FigureResearchPin(research: "res-a", row: 2, column: 1, value: .number(12), sourceHash: "h2",
                                    at: Date(timeIntervalSince1970: 2))
        let swap = try XCTUnwrap(FigureInverse.inverse(
            of: FigureOpPayload(cell: key(r1, c1), pin: new, priorPin: old), kind: .figurePinSet))
        XCTAssertEqual(swap.0, .figurePinSet)
        XCTAssertEqual(swap.1, FigureOpPayload(cell: key(r1, c1), pin: old, priorPin: new))
        let first = try XCTUnwrap(FigureInverse.inverse(
            of: FigureOpPayload(cell: key(r1, c1), pin: new), kind: .figurePinSet))
        XCTAssertEqual(first.0, .figurePinClear)
        XCTAssertEqual(first.1, FigureOpPayload(cell: key(r1, c1), pin: new))
        // Folded, the swap puts the old pin back and the clear leaves none.
        var state = FigureState(kind: .table, table: FigureTable(rows: 3, columns: 3))
        let k = CellKey(row: state.table.rows[0], column: state.table.columns[0])
        func fold(_ kind: OpKind, _ p: FigureOpPayload) {
            FigureDeriver.fold(Op(opId: ULID.generate(), docId: "fig-a", at: Date(), device: "d", session: "s",
                                  kind: kind, changes: [], figure: p), into: &state)
        }
        fold(.figurePinSet, FigureOpPayload(cell: k, pin: old))
        fold(.figurePinSet, FigureOpPayload(cell: k, pin: new, priorPin: old))
        let back = try XCTUnwrap(FigureInverse.inverse(
            of: FigureOpPayload(cell: k, pin: new, priorPin: old), kind: .figurePinSet))
        fold(back.0, back.1)
        XCTAssertEqual(state.pins[k], [old])
        let clear = try XCTUnwrap(FigureInverse.inverse(of: FigureOpPayload(cell: k, pin: old), kind: .figurePinSet))
        fold(clear.0, clear.1)
        XCTAssertNil(state.pins[k])
    }

    func test_lifecycleKindsAndAPinClear_haveNoInverse() {
        let cases: [(OpKind, FigureOpPayload)] = [
            (.figureCreate, FigureOpPayload(kind: .table)),
            (.figureParked, FigureOpPayload(parkedPath: "research/x.csv", parkedHash: "h")),
            (.figureResumed, FigureOpPayload()),
            (.figurePinClear, FigureOpPayload(cell: key(r1, c1))),
            (.typingBurst, FigureOpPayload(cell: key(r1, c1), next: num(1))),
        ]
        for (kind, payload) in cases {
            XCTAssertNil(FigureInverse.inverse(of: payload, kind: kind), "\(kind)")
        }
    }

    // MARK: - A visit

    func test_compensating_overAFiveOpVisit_restoresTheTable() {
        let r4 = RowID("r4ffffff")
        let visit: [(OpKind, FigureOpPayload)] = [
            (.figureStructure, FigureOpPayload(structure: .insertRow(r4, after: r1))),
            (.figureCellSet, FigureOpPayload(cell: key(r4, c1), next: num(4), prior: nil)),
            (.figureCellSet, FigureOpPayload(cell: key(r1, c1), next: num(10), prior: num(1))),
            (.figureStructure, FigureOpPayload(structure: .moveRow(r4, after: r3, priorAfter: r1))),
            (.figureSettings, FigureOpPayload(settings: .headerRows(1, prior: 0))),
        ]
        let before = start()
        let after = apply(visit, to: before)
        XCTAssertEqual(after.table.rows, [r1, r2, r3, r4], "control: the visit changed the table")
        let comp = FigureInverse.compensating(visit: visit)
        XCTAssertEqual(comp.count, 5)
        XCTAssertEqual(comp.first?.0, .figureSettings, "reversed: the last op is undone first")
        let undone = apply(comp, to: after)
        assertSameView(undone, before)
        XCTAssertEqual(undone.diagnostics, [])
    }

    func test_compensating_isAllOrNothing() {
        let visit: [(OpKind, FigureOpPayload)] = [
            (.figureCellSet, FigureOpPayload(cell: key(r1, c1), next: num(10), prior: num(1))),
            (.figureStructure, FigureOpPayload(structure: .deleteRow(r2))),
        ]
        XCTAssertTrue(FigureInverse.compensating(visit: visit).isEmpty,
                      "a visit holding an op with no inverse offers no undo, never half of one")
    }
}
