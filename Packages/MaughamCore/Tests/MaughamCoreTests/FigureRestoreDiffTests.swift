import XCTest
@testable import MaughamCore

/// **A figure wound back to a checkpoint, by id** (report plan 6c Task 1):
/// `FigureRestoreDiff` turns the figure as its stream now says into the figure
/// as it stood at the checkpoint's op pointer, with ordinary figure ops.
final class FigureRestoreDiffTests: XCTestCase {

    // MARK: - Building histories

    private let r1 = RowID("r1aaaaaa"), r2 = RowID("r2aaaaaa"), r3 = RowID("r3aaaaaa"), r4 = RowID("r4aaaaaa")
    private let c1 = ColumnID("c1aaaaaa"), c2 = ColumnID("c2aaaaaa"), c3 = ColumnID("c3aaaaaa")

    /// A figure's stream, built op by op with sortable op ids, each made
    /// against the state the ones before it left (a delete's slice, a
    /// cell's `prior`), as a host would.
    private struct History {
        var ops: [Op] = []
        var state = FigureState()
        /// The op id of the last op so far: a checkpoint taken now.
        var pointer: String { ops.last?.opId ?? "" }

        mutating func emit(_ kind: OpKind, _ payload: FigureOpPayload, device: String = "macA") {
            let op = Op(opId: String(format: "01H%06d", ops.count + 1), docId: "fig-k3m9q2zt",
                        at: Date(timeIntervalSince1970: TimeInterval(ops.count)), device: device,
                        session: "s", kind: kind, changes: [], figure: payload)
            ops.append(op)
            FigureDeriver.fold(op, into: &state)
        }

        mutating func create() { emit(.figureCreate, FigureOpPayload(kind: .table)) }
        mutating func insert(_ r: RowID, after: RowID?) {
            emit(.figureStructure, FigureOpPayload(structure: .insertRow(r, after: after)))
        }
        mutating func insert(_ c: ColumnID, after: ColumnID?) {
            emit(.figureStructure, FigureOpPayload(structure: .insertColumn(c, after: after)))
        }
        mutating func delete(_ r: RowID) {
            emit(.figureStructure, FigureOpPayload(structure: .deleteRow(r), removed: state.removedSlice(row: r)))
        }
        mutating func delete(_ c: ColumnID) {
            emit(.figureStructure, FigureOpPayload(structure: .deleteColumn(c), removed: state.removedSlice(column: c)))
        }
        mutating func move(_ r: RowID, after: RowID?) {
            emit(.figureStructure, FigureOpPayload(structure: .moveRow(r, after: after, priorAfter: nil)))
        }
        mutating func move(_ c: ColumnID, after: ColumnID?) {
            emit(.figureStructure, FigureOpPayload(structure: .moveColumn(c, after: after, priorAfter: nil)))
        }
        mutating func set(_ r: RowID, _ c: ColumnID, _ content: CellContent?, format: CellFormat = .init(),
                          device: String = "macA") {
            let key = CellKey(row: r, column: c)
            emit(.figureCellSet, FigureOpPayload(
                cell: key, next: content.map { Cell(content: $0, format: format) }, prior: state.table[key]),
                 device: device)
        }
        mutating func pin(_ r: RowID, _ c: ColumnID, research: String, row: Int, value: Double, park: String? = nil) {
            emit(.figurePinSet, FigureOpPayload(
                cell: CellKey(row: r, column: c),
                pin: FigureResearchPin(research: research, row: row, column: 0, value: .number(value),
                                       sourceHash: "h\(Int(value))", at: Date(timeIntervalSince1970: value),
                                       park: park)))
        }
        mutating func unpin(_ r: RowID, _ c: ColumnID) {
            emit(.figurePinClear, FigureOpPayload(cell: CellKey(row: r, column: c)))
        }
        mutating func setting(_ change: FigureSettingsChange) {
            emit(.figureSettings, FigureOpPayload(settings: change))
        }
        mutating func revive(_ r: RowID, slice: FigureRemovedSlice) {
            emit(.figureStructure, FigureOpPayload(structure: .reviveRow(r), removed: slice))
        }
        mutating func revive(_ c: ColumnID, slice: FigureRemovedSlice) {
            emit(.figureStructure, FigureOpPayload(structure: .reviveColumn(c), removed: slice))
        }
        mutating func image(_ name: String, _ hash: String) {
            emit(.figureImageSet, FigureOpPayload(image: FigureImageRef(filename: name, contentHash: hash),
                                                  priorImage: state.image))
        }
    }

    /// A two-by-two table with a header row: r1 (header), r2; columns c1, c2.
    private func starter() -> History {
        var h = History()
        h.create()
        h.insert(r1, after: nil); h.insert(r2, after: r1)
        h.insert(c1, after: nil); h.insert(c2, after: c1)
        h.set(r1, c1, .value(.text("Item"))); h.set(r1, c2, .value(.text("Amount")))
        h.set(r2, c1, .value(.text("Rent"))); h.set(r2, c2, .value(.number(1200)))
        h.setting(.headerRows(1, prior: 0))
        return h
    }

    // MARK: - Applying and comparing

    /// `current` with `changes` folded on, as the stream would after the
    /// host appends them; every change applies.
    private func applied(_ changes: [FigureReturnDiff.Change], to current: FigureState,
                         file: StaticString = #filePath, line: UInt = #line) -> FigureState {
        XCTAssertTrue(FigureReturnDiff.everyChangeApplies(changes, onto: current), file: file, line: line)
        var s = current
        for (i, c) in changes.enumerated() {
            FigureDeriver.fold(Op(opId: String(format: "zz%04d", i), docId: "fig-k3m9q2zt",
                                  at: Date(timeIntervalSince1970: 0), device: "macA", session: "s",
                                  kind: c.kind, changes: [], figure: c.payload), into: &s)
        }
        XCTAssertEqual(s.diagnostics, current.diagnostics, "no change dropped", file: file, line: line)
        XCTAssertEqual(s.held.count, current.held.count, "no change waiting", file: file, line: line)
        return s
    }

    /// The restore's equality: the live order of both axes, every cell,
    /// header and total rows, widths, pins and picture. Tombstones are not
    /// content: a row inserted since and deleted again stays a tombstone.
    private func assertSameContent(_ a: FigureState, _ b: FigureState,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.table.rows, b.table.rows, "row order", file: file, line: line)
        XCTAssertEqual(a.table.columns, b.table.columns, "column order", file: file, line: line)
        XCTAssertEqual(a.table.cells, b.table.cells, "cells", file: file, line: line)
        XCTAssertEqual(a.table.headerRows, b.table.headerRows, "header rows", file: file, line: line)
        XCTAssertEqual(a.table.hasTotalRow, b.table.hasTotalRow, "total row", file: file, line: line)
        XCTAssertEqual(a.table.columnWidths, b.table.columnWidths, "widths", file: file, line: line)
        XCTAssertEqual(a.pins, b.pins, "pins", file: file, line: line)
        XCTAssertEqual(a.image, b.image, "picture", file: file, line: line)
    }

    /// Restores `history`'s current state to `pointer` and checks the round trip.
    @discardableResult
    private func roundTrip(_ history: History, to pointer: String,
                           file: StaticString = #filePath, line: UInt = #line) -> [FigureReturnDiff.Change] {
        let target = FigureRestoreDiff.target(of: history.ops, through: pointer)
        let changes = FigureRestoreDiff.changes(from: history.state, to: target, parks: [:])
        assertSameContent(applied(changes, to: history.state, file: file, line: line), target,
                          file: file, line: line)
        // A second restore from there has nothing left to do.
        let again = FigureRestoreDiff.changes(from: applied(changes, to: history.state), to: target, parks: [:])
        XCTAssertEqual(again, [], "a restored figure needs no second restore", file: file, line: line)
        return changes
    }

    // MARK: - The target

    /// The target is the fold of the ops at or below the pointer.
    func test_theTargetIsTheFoldThroughThePointer() {
        var h = starter()
        let checkpoint = h.pointer
        h.set(r2, c2, .value(.number(1250)))
        let target = FigureRestoreDiff.target(of: h.ops, through: checkpoint)
        XCTAssertEqual(target.table[CellKey(row: r2, column: c2)]?.content, .value(.number(1200)))
        XCTAssertEqual(target.table.rows, [r1, r2])
    }

    // MARK: - Review Focus 1

    /// A checkpoint taken before a row was deleted and a column added, after
    /// another device edited a cell in the added column: the row comes back in
    /// its slot with its cells, the column goes carrying that cell, and the
    /// figure equals the checkpoint state cell for cell.
    func test_reviewFocus1_theDeletedRowReturnsAndTheAddedColumnGoes() throws {
        var h = starter()
        h.insert(r3, after: r2)
        h.set(r3, c1, .value(.text("Food"))); h.set(r3, c2, .value(.number(340)))
        let checkpoint = h.pointer
        let rentCells = h.state.removedSlice(row: r2)

        h.delete(r2)
        h.insert(c3, after: c2)
        h.set(r1, c3, .value(.text("Note")))
        h.set(r3, c3, .value(.text("weekly")), device: "macB")   // another device, in the added column

        let changes = roundTrip(h, to: checkpoint)
        let target = FigureRestoreDiff.target(of: h.ops, through: checkpoint)
        let restored = applied(changes, to: h.state)

        XCTAssertEqual(restored.table.rows, [r1, r2, r3], "Rent back in its own slot")
        XCTAssertEqual(restored.table.rowSlotIndex(of: r2), h.state.table.rowSlotIndex(of: r2),
                       "revived, not re-inserted")
        XCTAssertEqual(restored.table.columns, [c1, c2])
        XCTAssertEqual(restored.table.cells, target.table.cells, "cell for cell")

        let revive = try XCTUnwrap(changes.first {
            if case .reviveRow(r2)? = $0.payload.structure { return true }; return false })
        XCTAssertEqual(revive.payload.removed, rentCells, "the revive carries the checkpoint's slice")
        let delete = try XCTUnwrap(changes.first {
            if case .deleteColumn(c3)? = $0.payload.structure { return true }; return false })
        XCTAssertEqual(delete.payload.removed?.cells.map(\.at).sorted(), [r1.raw, r3.raw],
                       "the column goes with its cells, the other device's edit among them")
        XCTAssertEqual(delete.payload.removed?.cells.first { $0.at == r3.raw }?.cell?.content,
                       .value(.text("weekly")))
    }

    // MARK: - Contract

    /// Nothing changed since the checkpoint: no ops.
    func test_nothingChangedIsAnEmptyDiff() {
        let h = starter()
        XCTAssertEqual(FigureRestoreDiff.changes(from: h.state, to: h.state, parks: [:]), [])
        XCTAssertEqual(FigureRestoreDiff.changes(
            from: h.state, to: FigureRestoreDiff.target(of: h.ops, through: h.pointer), parks: [:]), [])
    }

    /// A row live at the checkpoint and deleted now is revived with the
    /// checkpoint's cells and pins; a column the same, with its width.
    func test_aReviveCarriesTheCheckpointsSlice() throws {
        var h = starter()
        h.pin(r2, c2, research: "res-q", row: 3, value: 7)
        h.setting(.columnWidth(c2, 120, prior: nil))
        let checkpoint = h.pointer
        let rowSlice = h.state.removedSlice(row: r2)
        let columnSlice = h.state.removedSlice(column: c2)
        h.delete(r2)
        h.delete(c2)

        let changes = roundTrip(h, to: checkpoint)
        let reviveColumn = try XCTUnwrap(changes.first {
            if case .reviveColumn(c2)? = $0.payload.structure { return true }; return false })
        XCTAssertEqual(reviveColumn.payload.removed?.width, 120, "a column comes back with its width")
        let reviveRow = try XCTUnwrap(changes.first {
            if case .reviveRow(r2)? = $0.payload.structure { return true }; return false })
        // The column revives first, carrying the cells of rows live by then
        // (not Rent's); Rent's revive then carries its whole slice, the
        // crossing cell and its pin among it.
        XCTAssertEqual(reviveColumn.payload.removed, FigureRemovedSlice(
            cells: columnSlice.cells.filter { $0.at == r1.raw }, width: 120))
        XCTAssertEqual(reviveRow.payload.removed, rowSlice)
        XCTAssertEqual(rowSlice.cells.count, 2)
        let restored = applied(changes, to: h.state)
        XCTAssertEqual(restored.pins[CellKey(row: r2, column: c2)]?.map(\.research), ["res-q"])
    }

    /// A row inserted since the checkpoint (unknown to it) is deleted,
    /// carrying what it holds so the delete's undo could put it back.
    func test_aRowInsertedSinceIsDeletedWithItsSlice() throws {
        var h = starter()
        let checkpoint = h.pointer
        h.insert(r3, after: r2)
        h.set(r3, c1, .value(.text("Food"))); h.set(r3, c2, .value(.number(340)))
        let slice = h.state.removedSlice(row: r3)

        let changes = roundTrip(h, to: checkpoint)
        XCTAssertEqual(changes.count, 1, "\(changes)")
        let delete = try XCTUnwrap(changes.first)
        XCTAssertEqual(delete.payload.structure, .deleteRow(r3))
        XCTAssertEqual(delete.payload.removed, slice)
    }

    /// A cell changed since is set back, naming what it replaces.
    func test_aChangedCellIsSetBackWithItsPrior() throws {
        var h = starter()
        let checkpoint = h.pointer
        h.set(r2, c2, .value(.number(1250)), format: CellFormat(number: .currency(symbol: nil, decimals: 2)))
        let changes = roundTrip(h, to: checkpoint)
        let set = try XCTUnwrap(changes.first)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(set.kind, .figureCellSet)
        XCTAssertEqual(set.payload.prior?.content, .value(.number(1250)))
        XCTAssertEqual(set.payload.next, Cell(content: .value(.number(1200))), "the format goes back too")
    }

    /// A picture changed since is one image change back.
    func test_aChangedPictureIsOneImageChange() {
        var h = History()
        h.emit(.figureCreate, FigureOpPayload(kind: .image))
        h.image("chart.png", "aaaa")
        let checkpoint = h.pointer
        h.image("chart.png", "bbbb")
        let changes = roundTrip(h, to: checkpoint)
        XCTAssertEqual(changes, [FigureReturnDiff.Change(kind: .figureImageSet, payload: FigureOpPayload(
            image: FigureImageRef(filename: "chart.png", contentHash: "aaaa"),
            priorImage: FigureImageRef(filename: "chart.png", contentHash: "bbbb")))])
    }

    // MARK: - The round trip over hand-built histories

    /// Moves both ways, settings, widths and a total row.
    func test_roundTrip_movesAndSettings() {
        var h = starter()
        h.insert(r3, after: r2); h.set(r3, c1, .value(.text("Food")))
        h.insert(r4, after: r3); h.set(r4, c1, .value(.text("Total")))
        h.setting(.columnWidth(c1, 90, prior: nil))
        let checkpoint = h.pointer
        h.move(r4, after: r1)
        h.move(r2, after: r3)
        h.move(c2, after: nil)
        h.setting(.headerRows(0, prior: 1))
        h.setting(.totalRow(true, prior: false))
        h.setting(.columnWidth(c1, 40, prior: 90))
        h.setting(.columnWidth(c2, 200, prior: nil))
        roundTrip(h, to: checkpoint)
    }

    /// Rows and columns deleted and revived both ways, a column added and
    /// removed again since (a tombstone the checkpoint never knew), and a
    /// cell in a revived row and revived column at once.
    func test_roundTrip_deletesBothWaysAndTombstones() {
        var h = starter()
        h.insert(c3, after: c2); h.set(r2, c3, .value(.text("x"))); h.set(r1, c3, .value(.text("Tag")))
        h.insert(r3, after: r2); h.set(r3, c3, .value(.bool(true)))
        h.delete(r3)                                       // tombstoned at the checkpoint
        let checkpoint = h.pointer
        h.delete(c3)                                       // live at the checkpoint, gone now
        h.delete(r2)                                       // the same, crossing c3 at (r2, c3)
        h.insert(r4, after: r1); h.set(r4, c1, .value(.text("New")))
        h.insert(ColumnID("c4aaaaaa"), after: nil)
        h.delete(ColumnID("c4aaaaaa"))                     // added and removed since
        roundTrip(h, to: checkpoint)
    }

    /// Pins: one changed in place, one cleared, one added, a list reordered,
    /// and a pin from another park cycle — `fig-park` is not parked now, so
    /// both its pins count and the checkpoint's comes back.
    func test_roundTrip_pins() {
        var h = starter()
        h.pin(r2, c2, research: "res-a", row: 1, value: 1)
        h.pin(r2, c2, research: "res-b", row: 1, value: 2)
        h.pin(r2, c1, research: "fig-park", row: 0, value: 3, park: "cycle-1")
        let checkpoint = h.pointer
        h.unpin(r2, c2)
        h.pin(r2, c2, research: "res-b", row: 1, value: 5)
        h.pin(r2, c2, research: "res-a", row: 1, value: 1)
        h.pin(r2, c1, research: "fig-park", row: 0, value: 4, park: "cycle-2")
        h.pin(r1, c1, research: "res-c", row: 2, value: 9)
        roundTrip(h, to: checkpoint)
    }

    /// **A pin live now is never replaced by one inert now** (ruling): the
    /// checkpoint's cycle-1 pin on a figure parked now under cycle-2 would
    /// only unpin the cell, so the cycle-2 pin stays; the cell's other pin
    /// is restored as usual.
    func test_aLivePinIsNotReplacedByOneInertUnderTheCurrentPark() throws {
        var h = starter()
        h.pin(r2, c1, research: "fig-park", row: 0, value: 3, park: "cycle-1")
        h.pin(r2, c1, research: "res-a", row: 1, value: 1)
        let checkpoint = h.pointer
        h.pin(r2, c1, research: "fig-park", row: 0, value: 4, park: "cycle-2")
        h.pin(r2, c1, research: "res-a", row: 1, value: 2)
        let key = CellKey(row: r2, column: c1)
        let livePin = try XCTUnwrap(h.state.pins[key]?.first)
        let target = FigureRestoreDiff.target(of: h.ops, through: checkpoint)
        let parks = ["fig-park": "cycle-2"]

        let changes = FigureRestoreDiff.changes(from: h.state, to: target, parks: parks)
        let restored = applied(changes, to: h.state)
        XCTAssertEqual(restored.pins[key], [livePin, target.pins[key]![1]],
                       "the live cycle-2 pin stays; res-a goes back to the checkpoint's")
        XCTAssertEqual(changes.count, 1, "\(changes)")
        XCTAssertEqual(FigureRestoreDiff.changes(from: restored, to: target, parks: parks), [])

        // Parked now under a third cycle, neither counts: the checkpoint's comes back.
        let third = FigureRestoreDiff.changes(from: h.state, to: target, parks: ["fig-park": "cycle-3"])
        XCTAssertEqual(applied(third, to: h.state).pins[key], target.pins[key])
    }

    /// An image figure whose checkpoint had no picture, one set since: no op
    /// takes a picture away, so the diff is empty and the picture stays.
    func test_aPictureSetSinceAPicturelessCheckpointStays() {
        var h = History()
        h.emit(.figureCreate, FigureOpPayload(kind: .image))
        let checkpoint = h.pointer
        h.image("chart.png", "aaaa")
        let target = FigureRestoreDiff.target(of: h.ops, through: checkpoint)
        XCTAssertNil(target.image)
        XCTAssertEqual(FigureRestoreDiff.changes(from: h.state, to: target, parks: [:]), [])
    }

    /// A picture is restored by content and keeps the file name it has now
    /// (a rename is a registry act, ruling Q-1): renamed since with the same
    /// bytes, nothing; renamed and changed, one change under the new name.
    func test_aPictureRenamedSinceKeepsItsNameAndComesBackByContent() {
        var h = History()
        h.emit(.figureCreate, FigureOpPayload(kind: .image))
        h.image("chart.png", "aaaa")
        let checkpoint = h.pointer
        h.image("map.png", "aaaa")
        let target = FigureRestoreDiff.target(of: h.ops, through: checkpoint)
        XCTAssertEqual(FigureRestoreDiff.changes(from: h.state, to: target, parks: [:]), [])

        h.image("map.png", "bbbb")
        XCTAssertEqual(FigureRestoreDiff.changes(from: h.state, to: target, parks: [:]), [
            FigureReturnDiff.Change(kind: .figureImageSet, payload: FigureOpPayload(
                image: FigureImageRef(filename: "map.png", contentHash: "aaaa"),
                priorImage: FigureImageRef(filename: "map.png", contentHash: "bbbb")))])
    }

    /// A row and a column deleted and revived since the checkpoint are live
    /// in both: no revive, no delete, only their cells set back and their
    /// width restored.
    func test_roundTrip_deletedAndRevivedSince() {
        var h = starter()
        h.setting(.columnWidth(c2, 90, prior: nil))
        let checkpoint = h.pointer
        let rowSlice = h.state.removedSlice(row: r2)
        h.delete(r2)
        h.revive(r2, slice: rowSlice)
        h.set(r2, c1, .value(.text("Lodging")))
        let columnSlice = h.state.removedSlice(column: c2)
        h.delete(c2)
        h.revive(c2, slice: FigureRemovedSlice(cells: columnSlice.cells))   // its width not put back
        h.set(r1, c2, .value(.text("Cost")))
        let changes = roundTrip(h, to: checkpoint)
        XCTAssertTrue(changes.allSatisfy { $0.kind != .figureStructure }, "\(changes)")
        XCTAssertEqual(changes.filter { $0.kind == .figureCellSet }.count, 2)
        XCTAssertEqual(changes.filter { $0.kind == .figureSettings }.count, 1)
    }

    /// A stream that lost ops (a row and a column the checkpoint holds that
    /// the current state never saw): they are inserted in place, and their
    /// cells set.
    func test_roundTrip_aStreamThatLostOpsInsertsWhatTheCheckpointHolds() throws {
        var h = starter()
        h.insert(c3, after: c1)
        h.insert(r3, after: r1)
        h.set(r3, c1, .value(.text("Food"))); h.set(r3, c3, .value(.number(340))); h.set(r1, c3, .value(.text("Tag")))
        let checkpoint = h.pointer
        let lost: Set<String> = Set(h.ops.suffix(5).map(\.opId))
        let current = FigureDeriver.derive(h.ops.filter { !lost.contains($0.opId) })
        XCTAssertNil(current.table.rowSlotIndex(of: r3))
        let target = FigureRestoreDiff.target(of: h.ops, through: checkpoint)

        let changes = FigureRestoreDiff.changes(from: current, to: target, parks: [:])
        let restored = applied(changes, to: current)
        assertSameContent(restored, target)
        XCTAssertEqual(restored.table.rows, [r1, r3, r2])
        XCTAssertEqual(restored.table.columns, [c1, c3, c2])
        XCTAssertTrue(changes.contains { $0.payload.structure == .insertRow(r3, after: r1) }, "\(changes)")
        XCTAssertTrue(changes.contains { $0.payload.structure == .insertColumn(c3, after: c1) }, "\(changes)")
    }

    /// Formulas and formats edited by two devices, cells cleared and filled.
    func test_roundTrip_cellsAcrossDevices() {
        var h = starter()
        let sum = Formula(.call(name: "SUM", arguments: [.range(FormulaRange(
            start: FormulaRef(target: .this, anchor: .id(row: r2, column: c2)),
            end: FormulaRef(target: .this, anchor: .id(row: r2, column: c2))))]))
        h.insert(r3, after: r2); h.set(r3, c2, .formula(sum))
        let checkpoint = h.pointer
        h.set(r3, c2, .value(.number(0)), device: "macB")
        h.set(r2, c1, nil)
        h.set(r1, c1, .value(.text("Thing")), format: CellFormat(zeroAsDash: true), device: "macB")
        h.set(r3, c1, .value(.text("Sum")))
        roundTrip(h, to: checkpoint)
    }

    /// Everything at once, with the checkpoint in the middle of the history.
    func test_roundTrip_aLongHistory() {
        var h = starter()
        h.insert(r3, after: r2); h.insert(r4, after: r3)
        h.insert(c3, after: c2)
        h.set(r3, c3, .value(.number(3))); h.set(r4, c3, .value(.number(4)))
        h.pin(r4, c3, research: "res-a", row: 0, value: 4)
        h.move(r2, after: r4)
        h.delete(r3)
        let checkpoint = h.pointer
        h.delete(c3)
        h.move(r4, after: nil)
        h.delete(r2)
        h.insert(RowID("r5aaaaaa"), after: r4); h.set(RowID("r5aaaaaa"), c1, .value(.text("late")))
        h.move(c1, after: c2)
        h.setting(.totalRow(true, prior: false))
        h.set(r1, c2, .value(.text("Sum")))
        roundTrip(h, to: checkpoint)
        // And to the very start of the table, before any content.
        roundTrip(h, to: h.ops[5].opId)
    }
    /// A park or a resume above the pointer is a trip to Research since the
    /// checkpoint (plan 6c final review I5); one at or below it is not.
    func test_wentToResearchSinceThePointer() {
        func op(_ id: String, _ kind: OpKind) -> Op {
            Op(opId: id, docId: "fig-k3m9q2zt", at: Date(), device: "macA", session: "s",
               kind: kind, changes: [], figure: FigureOpPayload())
        }
        let parked = [op("01H01", .figureCreate), op("01H02", .figureParked)]
        XCTAssertTrue(FigureRestoreDiff.wentToResearch(since: "01H01", in: parked))
        XCTAssertFalse(FigureRestoreDiff.wentToResearch(since: "01H02", in: parked))
        let resumed = parked + [op("01H03", .figureResumed), op("01H04", .figureCellSet)]
        XCTAssertTrue(FigureRestoreDiff.wentToResearch(since: "01H02", in: resumed))
        XCTAssertFalse(FigureRestoreDiff.wentToResearch(since: "01H03", in: resumed))
    }
}
