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
        XCTAssertNil(s.parked?.itemId, "a park that recorded no item")
        s = FigureDeriver.derive(base() + [
            op(.figureParked, FigureOpPayload(parkedPath: "research/cash.csv", parkedHash: "h9")),
            op(.figureResumed, FigureOpPayload()),
        ])
        XCTAssertNil(s.parked)
    }

    // MARK: - Parked folds nothing (ruling P-5, report plan 6b Task 7)

    private func park(item: String? = "res-cash") -> Op {
        op(.figureParked, FigureOpPayload(parkedPath: "research/cash.csv", parkedHash: "h9", parkedItemId: item))
    }

    /// Every content op ordered after the park and before a resume is dropped
    /// from the view with a diagnostic naming it; the parked values stand.
    func test_everyContentOpWhileParked_isDroppedWithADiagnostic() {
        let pin = FigureResearchPin(research: "res-a", row: 0, column: 0, value: .number(1),
                                    sourceHash: "h", at: Date(timeIntervalSince1970: 5_000))
        let before = base() + [set(key(r1, c1), num(5))]
        let parked = park()
        let late: [Op] = [
            set(key(r1, c1), num(7), prior: num(5), device: "macB"),
            op(.figureStructure, FigureOpPayload(structure: .insertRow(r3, after: r2)), device: "macB"),
            op(.figureStructure, FigureOpPayload(structure: .deleteColumn(c2)), device: "macB"),
            op(.figureSettings, FigureOpPayload(settings: .headerRows(1, prior: 0)), device: "macB"),
            op(.figureSettings, FigureOpPayload(settings: .columnWidth(c1, 90, prior: nil)), device: "macB"),
            op(.figurePinSet, FigureOpPayload(cell: key(r1, c1), pin: pin), device: "macB"),
            op(.figurePinClear, FigureOpPayload(cell: key(r1, c1)), device: "macB"),
            op(.figureImageSet, FigureOpPayload(image: FigureImageRef(filename: "a.png", contentHash: "h")), device: "macB"),
        ]
        let s = FigureDeriver.derive(before + [parked] + late)
        XCTAssertEqual(s.parked, FigureParking(path: "research/cash.csv", hash: "h9", itemId: "res-cash"))
        var expected = FigureDeriver.derive(before)
        expected.parked = s.parked
        XCTAssertEqual(s.table, expected.table, "the table is exactly as it was parked")
        XCTAssertEqual(s.pins, [:])
        XCTAssertNil(s.image)
        XCTAssertEqual(s.held, [], "a dropped op never waits to replay")
        XCTAssertEqual(s.diagnostics, late.map {
            "\($0.opId): \($0.kind.rawValue) while the figure is parked in Research, not applied"
        })
    }

    /// After a resume the stream folds again; what was dropped while parked
    /// stays dropped.
    func test_aResumeFoldsAgain_andTheParkedEditStaysDropped() {
        let dropped = set(key(r1, c1), num(7))
        let s = FigureDeriver.derive(base() + [park(), dropped, op(.figureResumed, FigureOpPayload()),
                                               set(key(r2, c2), num(9))])
        XCTAssertNil(s.parked)
        XCTAssertNil(s.table[key(r1, c1)], "the edit ordered while parked never applies")
        XCTAssertEqual(s.table[key(r2, c2)], num(9), "an edit after the resume does")
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertTrue(s.diagnostics.first?.hasPrefix(dropped.opId) == true)
    }

    /// A second park while parked is dropped: the stream keeps pointing at the
    /// first working copy. A resume while not parked is dropped too.
    func test_aSecondPark_andAResumeWhileNotParked_areDropped() {
        let second = op(.figureParked, FigureOpPayload(parkedPath: "research/other.csv", parkedHash: "h2"))
        let stray = op(.figureResumed, FigureOpPayload())
        let s = FigureDeriver.derive(base() + [stray, park(), second])
        XCTAssertEqual(s.parked, FigureParking(path: "research/cash.csv", hash: "h9", itemId: "res-cash"))
        XCTAssertEqual(s.diagnostics, [
            "\(stray.opId): figure_resumed while not parked, ignored",
            "\(second.opId): a second figure_parked while parked, ignored",
        ])
    }

    /// An edit held for an insert it sorted before, whose insert is ordered
    /// after the park, never replays: the insert itself is dropped.
    func test_anEditWaitingForAnInsertOrderedWhileParked_neverApplies() {
        let early = set(key(r3, c1), num(1))
        let insert = op(.figureStructure, FigureOpPayload(structure: .insertRow(r3, after: r2)))
        let s = FigureDeriver.derive(base() + [early, park(), insert])
        XCTAssertNil(s.table.rowSlotIndex(of: r3))
        XCTAssertEqual(s.diagnostics, [
            "\(insert.opId): figure_structure while the figure is parked in Research, not applied",
            "\(early.opId): names a row or column no insert ever created, never applied",
        ])
    }

    /// **Review Focus 2, the pure half**: two devices' lines, whichever file a
    /// reader meets first, merge into one order (by op id) and fold to one
    /// state — the edit ordered after the park dropped in both.
    func test_theParkAndALaterEditConverge_whicheverArrivesFirst() {
        let before = base() + [set(key(r1, c1), num(5))]
        let parked = park()
        let edit = set(key(r1, c1), num(7), prior: num(5), device: "macB")
        let parkerFirst = OpLogStore.mergeSortedDedup(before + [parked] + [edit])
        let editorFirst = OpLogStore.mergeSortedDedup([edit] + before + [parked])
        let a = FigureDeriver.derive(parkerFirst)
        let b = FigureDeriver.derive(editorFirst)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.table[key(r1, c1)], num(5), "the parker's value stands")
        XCTAssertEqual(a.diagnostics, ["\(edit.opId): figure_cell_set while the figure is parked in Research, not applied"])
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

    // MARK: - A not-yet-seen id waits (ruling R-6a-4)

    /// Merged order is ULID order: under clock skew device A's edit of a row B
    /// inserted can sort before B's insert. It must not be lost.
    func test_anEditSortedBeforeItsInsert_survives() {
        let edit = set(key(r3, c1), num(3), device: "macA")
        let insert = insRow(r3, after: r2, device: "macB")
        let s = FigureDeriver.derive(base() + [edit, insert])
        XCTAssertEqual(s.table.rows, [r1, r2, r3])
        XCTAssertEqual(s.table[key(r3, c1)], num(3))
        XCTAssertEqual(s.held, [])
        XCTAssertEqual(s.diagnostics, [])
    }

    func test_aHeldEditThenALaterEditOfTheSameCell_theLaterWins() {
        let early = set(key(r3, c1), num(3), device: "macA")
        let insert = insRow(r3, after: r2, device: "macB")
        let later = set(key(r3, c1), num(4), device: "macB")
        XCTAssertEqual(FigureDeriver.derive(base() + [early, insert, later]).table[key(r3, c1)], num(4))
        // Both held, both replay in their original order: still the later one.
        let laterHeld = set(key(r3, c1), num(5), device: "macB")
        XCTAssertEqual(FigureDeriver.derive(base() + [early, laterHeld, insert]).table[key(r3, c1)], num(5))
    }

    func test_aDeleteSortedBeforeItsInsert_leavesTheRowDeleted() {
        let delete = op(.figureStructure, FigureOpPayload(structure: .deleteRow(r3)), device: "macA")
        let insert = insRow(r3, after: r2, device: "macB")
        let s = FigureDeriver.derive(base() + [delete, insert])
        XCTAssertEqual(s.table.rows, [r1, r2])
        XCTAssertNotNil(s.table.rowSlotIndex(of: r3), "the row is a tombstone")
        XCTAssertEqual(s.diagnostics, [])
    }

    func test_aHeldOpNeverResolved_givesExactlyOneDiagnostic() {
        let stray = set(key(r3, c1), num(3))
        // An unrelated insert re-folds the held set; the op is held again, not doubled.
        let s = FigureDeriver.derive(base() + [stray, insCol(ColumnID("c3ffffff"), after: c2, device: "macB")])
        XCTAssertNil(s.table[key(r3, c1)])
        XCTAssertEqual(s.held, [stray])
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertTrue(s.diagnostics[0].contains(stray.opId), s.diagnostics[0])
    }

    func test_foldKeepsTheHeldSetAcrossCalls() {
        var s = FigureDeriver.derive(base())
        let edit = set(key(r3, c1), num(3))
        FigureDeriver.fold(edit, into: &s)
        XCTAssertEqual(s.held, [edit])
        XCTAssertNotEqual(s, FigureDeriver.derive(base()), "the held set is part of the state")
        XCTAssertEqual(s.diagnostics, [], "fold alone never diagnoses what is still waiting")
        FigureDeriver.fold(insRow(r3, after: r2), into: &s)
        XCTAssertEqual(s.held, [])
        XCTAssertEqual(s.table[key(r3, c1)], num(3))
    }

    func test_tombstonedIdsStillDrop_notHeld() {
        let delete = op(.figureStructure, FigureOpPayload(structure: .deleteRow(r2)))
        let edit = set(key(r2, c1), num(1))
        let s = FigureDeriver.derive(base() + [delete, edit])
        XCTAssertEqual(s.held, [])
        XCTAssertEqual(s.diagnostics.count, 1)
    }

    // MARK: - Revive (report plan 6b Task 4, rulings P-1/P-2)

    private func pin(_ research: String, _ v: Double) -> FigureResearchPin {
        FigureResearchPin(research: research, row: 0, column: 0, value: .number(v),
                          sourceHash: "h", at: Date(timeIntervalSince1970: 5))
    }

    private func structure(_ change: FigureStructureChange, removed: FigureRemovedSlice? = nil,
                           device: String = "macA") -> Op {
        op(.figureStructure, FigureOpPayload(structure: change, removed: removed), device: device)
    }

    /// **Review Focus 5, in the fold**: a row deleted with its slice, then a
    /// neighbour inserted after its tombstone and a width set by another
    /// device; the revive puts the row back in its own slot with its cells
    /// and pins, and the neighbour and the width stand.
    func test_aRevivedRow_returnsInItsOwnSlotWithItsCellsAndPins() {
        let p = pin("res-a", 4)
        var ops = base() + [
            set(key(r1, c1), num(1)), set(key(r1, c2), num(2)),
            op(.figurePinSet, FigureOpPayload(cell: key(r1, c2), pin: p)),
        ]
        let before = FigureDeriver.derive(ops)
        let slice = before.removedSlice(row: r1)
        XCTAssertEqual(slice.cells.count, 2, "control: the slice holds both cells")
        ops.append(structure(.deleteRow(r1), removed: slice))
        let neighbour = RowID("rNnnnnnn")
        ops.append(insRow(neighbour, after: r1, device: "macB"))
        ops.append(op(.figureSettings, FigureOpPayload(settings: .columnWidth(c1, 90, prior: nil)), device: "macB"))
        let deleted = FigureDeriver.derive(ops)
        XCTAssertEqual(deleted.table.rows, [neighbour, r2])
        XCTAssertNil(deleted.pins[key(r1, c2)])

        ops.append(structure(.reviveRow(r1), removed: slice))
        let s = FigureDeriver.derive(ops)
        XCTAssertEqual(s.table.rows, [r1, neighbour, r2], "its own slot, before the neighbour")
        XCTAssertEqual(s.table[key(r1, c1)], num(1))
        XCTAssertEqual(s.table[key(r1, c2)], num(2))
        XCTAssertEqual(s.pins[key(r1, c2)], [p])
        XCTAssertEqual(s.table.columnWidths[c1], 90, "their width stands")
        XCTAssertEqual(s.diagnostics, [])
    }

    func test_aRevivedColumn_getsItsWidthBack() {
        var ops = base() + [
            set(key(r2, c2), num(7)),
            op(.figureSettings, FigureOpPayload(settings: .columnWidth(c2, 120, prior: nil))),
        ]
        let slice = FigureDeriver.derive(ops).removedSlice(column: c2)
        XCTAssertEqual(slice.width, 120)
        ops.append(structure(.deleteColumn(c2), removed: slice))
        XCTAssertEqual(FigureDeriver.derive(ops).table.columnWidths, [:], "control: the delete took the width")
        ops.append(structure(.reviveColumn(c2), removed: slice))
        let s = FigureDeriver.derive(ops)
        XCTAssertEqual(s.table.columns, [c1, c2])
        XCTAssertEqual(s.table[key(r2, c2)], num(7))
        XCTAssertEqual(s.table.columnWidths[c2], 120)
        XCTAssertEqual(s.diagnostics, [])
    }

    /// A revive from another device whose column was deleted here meanwhile:
    /// the row returns with its other cells; the one in the deleted column
    /// stays gone, diagnosed.
    func test_aReviveWhoseColumnWasDeletedMeanwhile_keepsTheOtherCells() {
        var ops = base() + [set(key(r1, c1), num(1)), set(key(r1, c2), num(2))]
        let slice = FigureDeriver.derive(ops).removedSlice(row: r1)
        ops.append(structure(.deleteRow(r1), removed: slice, device: "macB"))
        ops.append(structure(.deleteColumn(c2), removed: FigureRemovedSlice(), device: "macA"))
        let revive = structure(.reviveRow(r1), removed: slice, device: "macB")
        ops.append(revive)
        let s = FigureDeriver.derive(ops)
        XCTAssertEqual(s.table.rows, [r1, r2])
        XCTAssertEqual(s.table[key(r1, c1)], num(1), "the other cell is back")
        XCTAssertNil(s.table[key(r1, c2)])
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertTrue(s.diagnostics[0].contains(revive.opId) && s.diagnostics[0].contains(c2.raw), s.diagnostics[0])
    }

    func test_aReviveOfALiveRowIsDropped_andAnInsertOfATombstoneStaysRefused() {
        let liveRevive = structure(.reviveRow(r1), removed: FigureRemovedSlice(cells: [.init(at: c1.raw, cell: num(9))]))
        var s = FigureDeriver.derive(base() + [liveRevive])
        XCTAssertNil(s.table[key(r1, c1)], "a live row's revive puts nothing back")
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertTrue(s.diagnostics[0].contains(liveRevive.opId))

        let reinsert = insRow(r1, after: nil)
        s = FigureDeriver.derive(base() + [structure(.deleteRow(r1)), reinsert])
        XCTAssertEqual(s.table.rows, [r2], "only a revive brings a tombstone back (ruling P-1)")
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertTrue(s.diagnostics[0].contains(reinsert.opId))
    }

    /// A revive naming a row never seen waits like a delete does (R-6a-4):
    /// sorted before the insert and delete it follows, it replays after them.
    func test_aReviveSortedBeforeItsInsert_waitsAndReplaysInOrder() {
        let slice = FigureRemovedSlice(cells: [.init(at: c1.raw, cell: num(3))])
        let delete = structure(.deleteRow(r3), removed: slice, device: "macB")
        let revive = structure(.reviveRow(r3), removed: slice, device: "macB")
        let insert = insRow(r3, after: r2, device: "macB")
        let s = FigureDeriver.derive(base() + [delete, revive, insert])
        XCTAssertEqual(s.table.rows, [r1, r2, r3])
        XCTAssertEqual(s.table[key(r3, c1)], num(3))
        XCTAssertEqual(s.diagnostics, [])
        // Never inserted at all: held, then diagnosed once.
        let t = FigureDeriver.derive(base() + [structure(.reviveRow(RowID("nowhere1")), removed: slice)])
        XCTAssertEqual(t.diagnostics.count, 1)
    }

    func test_aReviveWithoutASlice_isMissingWhatItNeeds() {
        let bare = structure(.reviveRow(r1))
        let s = FigureDeriver.derive(base() + [structure(.deleteRow(r1)), bare])
        XCTAssertEqual(s.table.rows, [r2])
        XCTAssertEqual(s.diagnostics.count, 1)
        XCTAssertTrue(s.diagnostics[0].contains("missing"), s.diagnostics[0])
    }

    func test_theRemovedSliceIsKeyedByTheOtherAxisAndSortedByIt() {
        var ops = base() + [set(key(r2, c2), num(2)), set(key(r2, c1), num(1))]
        ops.append(op(.figurePinSet, FigureOpPayload(cell: key(r1, c1), pin: pin("res-b", 1))))
        let s = FigureDeriver.derive(ops)
        XCTAssertEqual(s.removedSlice(row: r2), FigureRemovedSlice(cells: [
            .init(at: c1.raw, cell: num(1)), .init(at: c2.raw, cell: num(2)),
        ]))
        XCTAssertEqual(s.removedSlice(row: r2).cells.map(\.at), [c1.raw, c2.raw])
        XCTAssertEqual(s.removedSlice(column: c1), FigureRemovedSlice(cells: [
            .init(at: r1.raw, pins: [pin("res-b", 1)]), .init(at: r2.raw, cell: num(1)),
        ]))
        XCTAssertTrue(s.removedSlice(column: ColumnID("nowhere0")).isEmpty)
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
