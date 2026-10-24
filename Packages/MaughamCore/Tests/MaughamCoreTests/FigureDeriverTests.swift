import XCTest
@testable import MaughamCore

/// Report plan 6a Task 3: a figure's ops fold onto a `FigureTable` in the
/// merged order `OpLogStore` returns — per-cell last writer, delete beats
/// edit (spec §11.5), concurrent inserts both survive.
final class FigureDeriverTests: XCTestCase {

    private let r1 = RowID("r1aaaaaa"), r2 = RowID("r2bbbbbb"), r3 = RowID("r3cccccc")
    private let c1 = ColumnID("c1dddddd"), c2 = ColumnID("c2eeeeee")
    private var counter = 0

    private func op(_ kind: OpKind, _ payload: FigureOpPayload?, device: String = "macA") -> Op {
        counter += 1
        return Op(opId: String(format: "op%04d", counter), docId: "fig-k3m9q2zt",
                  at: Date(timeIntervalSince1970: TimeInterval(1_000 + counter)),
                  device: device, session: "s", kind: kind, changes: [], figure: payload)
    }

    private func num(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }
    private func key(_ r: RowID, _ c: ColumnID) -> CellKey { CellKey(row: r, column: c) }

    private func create(device: String = "macA") -> Op { op(.figureCreate, FigureOpPayload(kind: .table), device: device) }
    private func insRow(_ r: RowID, after: RowID?, device: String = "macA") -> Op {
        op(.figureStructure, FigureOpPayload(structure: .insertRow(r, after: after)), device: device)
    }
    private func insCol(_ c: ColumnID, after: ColumnID?, device: String = "macA") -> Op {
        op(.figureStructure, FigureOpPayload(structure: .insertColumn(c, after: after)), device: device)
    }
    private func set(_ k: CellKey, _ next: Cell?, prior: Cell? = nil, device: String = "macA") -> Op {
        op(.figureCellSet, FigureOpPayload(cell: k, next: next, prior: prior), device: device)
    }

    /// A 2×2 table: rows r1 r2, columns c1 c2.
    private func base() -> [Op] {
        [create(), insRow(r1, after: nil), insRow(r2, after: r1), insCol(c1, after: nil), insCol(c2, after: c1)]
    }

    // MARK: - Single device, every kind

    func test_create_setsKindAndCreator() {
        let s = FigureDeriver.derive([create(device: "macB")])
        XCTAssertEqual(s.kind, .table)
        XCTAssertEqual(s.createdBy, "macB")
        XCTAssertEqual(s.table.rows, [])
        XCTAssertEqual(s.diagnostics, [])
    }

    func test_emptyStream_isAnEmptyState() {
        let s = FigureDeriver.derive([])
        XCTAssertNil(s.kind)
        XCTAssertNil(s.createdBy)
        XCTAssertEqual(s, FigureState())
    }

    func test_inserts_buildTheTableInOrder() {
        let s = FigureDeriver.derive(base())
        XCTAssertEqual(s.table.rows, [r1, r2])
        XCTAssertEqual(s.table.columns, [c1, c2])
        XCTAssertEqual(s.diagnostics, [])
    }

    func test_cellSet_andClear() {
        var ops = base()
        ops.append(set(key(r1, c1), num(1)))
        ops.append(set(key(r2, c2), num(2)))
        ops.append(set(key(r2, c2), nil, prior: num(2)))
        let s = FigureDeriver.derive(ops)
        XCTAssertEqual(s.table[key(r1, c1)], num(1))
        XCTAssertNil(s.table[key(r2, c2)])
        XCTAssertEqual(s.diagnostics, [])
    }

    func test_deletes_tombstoneAndTakeTheirCells() {
        var ops = base()
        ops.append(set(key(r1, c1), num(1)))
        ops.append(set(key(r2, c2), num(2)))
        ops.append(op(.figureStructure, FigureOpPayload(structure: .deleteRow(r1))))
        ops.append(op(.figureStructure, FigureOpPayload(structure: .deleteColumn(c1))))
        let s = FigureDeriver.derive(ops)
        XCTAssertEqual(s.table.rows, [r2])
        XCTAssertEqual(s.table.columns, [c2])
        XCTAssertEqual(s.table.rowSlotIndex(of: r1), 0, "a deleted row stays as a tombstone")
        XCTAssertNil(s.table[key(r1, c1)])
        XCTAssertEqual(s.table[key(r2, c2)], num(2))
        XCTAssertEqual(s.diagnostics, [])
    }

    func test_moves_applyInOrder() {
        var ops = base()
        ops.append(insRow(r3, after: r2))
        ops.append(op(.figureStructure, FigureOpPayload(structure: .moveRow(r3, after: nil, priorAfter: r2))))
        ops.append(op(.figureStructure, FigureOpPayload(structure: .moveColumn(c1, after: c2, priorAfter: nil))))
        let s = FigureDeriver.derive(ops)
        XCTAssertEqual(s.table.rows, [r3, r1, r2])
        XCTAssertEqual(s.table.columns, [c2, c1])
    }

    func test_settings_applyInOrder() {
        var ops = base()
        ops.append(op(.figureSettings, FigureOpPayload(settings: .headerRows(1, prior: 0))))
        ops.append(op(.figureSettings, FigureOpPayload(settings: .totalRow(true, prior: false))))
        ops.append(op(.figureSettings, FigureOpPayload(settings: .columnWidth(c2, 80, prior: nil))))
        ops.append(op(.figureSettings, FigureOpPayload(settings: .columnWidth(c2, 120, prior: 80))))
        let s = FigureDeriver.derive(ops)
        XCTAssertEqual(s.table.headerRows, 1)
        XCTAssertTrue(s.table.hasTotalRow)
        XCTAssertEqual(s.table.columnWidths[c2], 120)
        XCTAssertEqual(s.diagnostics, [])
    }

    func test_imageSet_lastWins() {
        let a = FigureImageRef(filename: "a.png", contentHash: "ha")
        let b = FigureImageRef(filename: "b.png", contentHash: "hb")
        let s = FigureDeriver.derive([
            op(.figureCreate, FigureOpPayload(kind: .image)),
            op(.figureImageSet, FigureOpPayload(image: a)),
            op(.figureImageSet, FigureOpPayload(image: b, priorImage: a)),
        ])
        XCTAssertEqual(s.kind, .image)
        XCTAssertEqual(s.image, b)
    }

    func test_parkedThenResumed() {
        var s = FigureDeriver.derive(base() + [
            op(.figureParked, FigureOpPayload(parkedPath: "research/cash.csv", parkedHash: "h9")),
        ])
        XCTAssertEqual(s.parked, FigureParking(path: "research/cash.csv", hash: "h9"))
        s = FigureDeriver.derive(base() + [
            op(.figureParked, FigureOpPayload(parkedPath: "research/cash.csv", parkedHash: "h9")),
            op(.figureResumed, FigureOpPayload()),
        ])
        XCTAssertNil(s.parked)
    }

    func test_contentWhileParked_stillFolds() {
        let s = FigureDeriver.derive(base() + [
            op(.figureParked, FigureOpPayload(parkedPath: "research/cash.csv", parkedHash: "h9")),
            set(key(r1, c1), num(7)),
        ])
        XCTAssertNotNil(s.parked)
        XCTAssertEqual(s.table[key(r1, c1)], num(7))
    }

    func test_pins_setReplaceAndClear() {
        let at = Date(timeIntervalSince1970: 5_000)
        let p1 = FigureResearchPin(research: "res-a", row: 1, column: 2, value: .number(1), sourceHash: "h1", at: at)
        let p1b = FigureResearchPin(research: "res-a", row: 1, column: 2, value: .number(9), sourceHash: "h2", at: at)
        let p2 = FigureResearchPin(research: "res-b", row: 0, column: 0, value: .text("x"), sourceHash: "h3", at: at)
        let k = key(r1, c1)
        var s = FigureDeriver.derive(base() + [
            op(.figurePinSet, FigureOpPayload(cell: k, pin: p1)),
            op(.figurePinSet, FigureOpPayload(cell: k, pin: p2)),
            op(.figurePinSet, FigureOpPayload(cell: k, pin: p1b)),
        ])
        XCTAssertEqual(s.pins[k], [p1b, p2], "a pin on the same source address is refreshed in place")
        s = FigureDeriver.derive(base() + [
            op(.figurePinSet, FigureOpPayload(cell: k, pin: p1)),
            op(.figurePinSet, FigureOpPayload(cell: k, pin: p2)),
            op(.figurePinClear, FigureOpPayload(cell: k, pin: p1)),
        ])
        XCTAssertEqual(s.pins[k], [p2])
        s = FigureDeriver.derive(base() + [
            op(.figurePinSet, FigureOpPayload(cell: k, pin: p1)),
            op(.figurePinClear, FigureOpPayload(cell: k)),
        ])
        XCTAssertNil(s.pins[k], "a clear naming no pin clears the cell's pins")
        s = FigureDeriver.derive(base() + [
            op(.figurePinSet, FigureOpPayload(cell: k, pin: p1)),
            op(.figureStructure, FigureOpPayload(structure: .deleteRow(r1))),
        ])
        XCTAssertNil(s.pins[k], "a deleted row takes its pins")
    }

    // MARK: - Two devices, merged in a fixed order

    func test_twoDevices_differentCellsBothSurvive() {
        let a = [set(key(r1, c1), num(1), device: "macA")]
        let b = [set(key(r2, c2), num(2), device: "macB")]
        let s = FigureDeriver.derive(base() + a + b)
        XCTAssertEqual(s.table[key(r1, c1)], num(1))
        XCTAssertEqual(s.table[key(r2, c2)], num(2))
    }

    func test_twoDevices_sameCell_laterOpWins() {
        let a = set(key(r1, c1), num(1), device: "macA")
        let b = set(key(r1, c1), num(2), device: "macB")
        XCTAssertEqual(FigureDeriver.derive(base() + [a, b]).table[key(r1, c1)], num(2))
        XCTAssertEqual(FigureDeriver.derive(base() + [b, a]).table[key(r1, c1)], num(1))
    }

    func test_twoDevices_concurrentInsertsAfterTheSameRow_bothSurvive_inAStableOrder() {
        let ra = RowID("rAaaaaaa"), rb = RowID("rBbbbbbb")
        let a = insRow(ra, after: r1, device: "macA")
        let b = insRow(rb, after: r1, device: "macB")
        let merged = base() + [a, b]
        let s = FigureDeriver.derive(merged)
        XCTAssertEqual(Set(s.table.rows), [r1, r2, ra, rb])
        XCTAssertEqual(s.table.rows, [r1, rb, ra, r2], "each insert lands right after r1, the later one first")
        XCTAssertEqual(FigureDeriver.derive(merged).table.rows, s.table.rows, "the same merged order folds the same way")
        // Both devices then edit their own row: both edits land.
        let more = merged + [set(key(ra, c1), num(1), device: "macA"), set(key(rb, c1), num(2), device: "macB")]
        let t = FigureDeriver.derive(more)
        XCTAssertEqual(t.table[key(ra, c1)], num(1))
        XCTAssertEqual(t.table[key(rb, c1)], num(2))
        XCTAssertEqual(t.diagnostics, [])
    }

    func test_twoDevices_deleteColumnBeatsAnEditInIt() {
        let del = op(.figureStructure, FigureOpPayload(structure: .deleteColumn(c2)), device: "macA")
        let edit = set(key(r1, c2), num(5), device: "macB")
        let s = FigureDeriver.derive(base() + [del, edit])
        XCTAssertEqual(s.table.columns, [c1], "the column is gone")
        XCTAssertNil(s.table[key(r1, c2)], "the edit is dropped from the view")
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertTrue(s.diagnostics[0].contains(edit.opId), s.diagnostics[0])
        // Edit first, then the delete: the column is still gone, and nothing failed to apply.
        let t = FigureDeriver.derive(base() + [edit, del])
        XCTAssertEqual(t.table.columns, [c1])
        XCTAssertNil(t.table[key(r1, c2)])
        XCTAssertEqual(t.diagnostics, [])
    }

    func test_cellSetOnAnUnknownRow_isDroppedWithADiagnostic() {
        let stray = set(key(RowID("nowhere1"), c1), num(1))
        let s = FigureDeriver.derive(base() + [stray])
        XCTAssertEqual(s.table.cells.count, 0)
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertTrue(s.diagnostics[0].contains(stray.opId))
    }

    // MARK: - Odd input

    func test_createSeenTwice_firstWins_withADiagnostic() {
        let first = create(device: "macA")
        let second = op(.figureCreate, FigureOpPayload(kind: .image), device: "macB")
        let s = FigureDeriver.derive([first, second])
        XCTAssertEqual(s.kind, .table)
        XCTAssertEqual(s.createdBy, "macA")
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertTrue(s.diagnostics[0].contains(second.opId))
    }

    func test_missingOrInvalidPayload_andForeignKinds_areDiagnosedNotApplied() {
        let noPayload = op(.figureCellSet, nil)
        let invalid = op(.figureStructure, FigureOpPayload())
        let foreign = op(.typingBurst, nil)
        let s = FigureDeriver.derive(base() + [noPayload, invalid, foreign])
        XCTAssertEqual(s.table.rows, [r1, r2])
        XCTAssertEqual(s.diagnostics.count, 3)
    }

    func test_structureOnUnknownIds_isDiagnosed() {
        let s = FigureDeriver.derive(base() + [
            op(.figureStructure, FigureOpPayload(structure: .deleteRow(RowID("nowhere1")))),
            op(.figureStructure, FigureOpPayload(structure: .moveColumn(ColumnID("nowhere2"), after: nil, priorAfter: nil))),
            insRow(r1, after: r2),   // a duplicate id
            op(.figureSettings, FigureOpPayload(settings: .columnWidth(ColumnID("nowhere3"), 10, prior: nil))),
        ])
        XCTAssertEqual(s.table.rows, [r1, r2])
        XCTAssertEqual(s.table.columnWidths, [:])
        XCTAssertEqual(s.diagnostics.count, 4)
    }
}
