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

    func test_delete_hasNoInverseIn6a() {
        XCTAssertNil(FigureInverse.inverse(of: FigureOpPayload(structure: .deleteRow(r1)), kind: .figureStructure))
        XCTAssertNil(FigureInverse.inverse(of: FigureOpPayload(structure: .deleteColumn(c1)), kind: .figureStructure))
    }

    func test_firstImage_hasNoInverse_becauseThereIsNoClear() {
        let a = FigureImageRef(filename: "a.png", contentHash: "ha")
        XCTAssertNil(FigureInverse.inverse(of: FigureOpPayload(image: a, priorImage: nil), kind: .figureImageSet))
    }

    func test_lifecycleAndPinKinds_haveNoInverse() {
        let at = Date(timeIntervalSince1970: 1)
        let pin = FigureResearchPin(research: "res-a", row: 0, column: 0, value: .empty, sourceHash: "h", at: at)
        let cases: [(OpKind, FigureOpPayload)] = [
            (.figureCreate, FigureOpPayload(kind: .table)),
            (.figureParked, FigureOpPayload(parkedPath: "research/x.csv", parkedHash: "h")),
            (.figureResumed, FigureOpPayload()),
            (.figurePinSet, FigureOpPayload(cell: key(r1, c1), pin: pin)),
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
