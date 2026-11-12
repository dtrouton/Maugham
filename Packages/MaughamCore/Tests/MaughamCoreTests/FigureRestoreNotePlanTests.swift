import XCTest
@testable import MaughamCore

/// **The figure restore's note walk, in Core** (hardening 11-11 Task 1,
/// RULING-28): `FigureRestoreNotePlan.plan` answers every accepted figure
/// suggestion a restore to a checkpoint would strand — the cell change that
/// puts its cell back becomes the note's `claudeAcceptRevert`, a cell the
/// restore does not write gets a status-only revert, and a cell gone then is
/// archived (or, where the hand may not dispose, reopened status only).
/// These pin the behaviour the walk had inside `FigureDocument`.
final class FigureRestoreNotePlanTests: XCTestCase {

    private let figureId = "fig-k3m9q2zt"
    private let r1 = RowID("r1aaaaaa"), r2 = RowID("r2aaaaaa")
    private let c1 = ColumnID("c1aaaaaa")
    private let claude = AnnotationAuthor(sourceKind: .claude, displayName: "Claude")

    /// A figure's stream with sortable op ids, each op folded as a host
    /// folds it (`FigureOpPayload.folds`).
    private struct History {
        let figureId: String
        var ops: [Op] = []
        var state = FigureState()
        var pointer: String { ops.last?.opId ?? "" }
        var stamp: FigureAnnotationOps.Stamp {
            .init(figureId: figureId, device: "macA", session: "s",
                  at: Date(timeIntervalSince1970: TimeInterval(ops.count)))
        }

        /// Appends `op` under the next sortable id; answers that id.
        @discardableResult
        mutating func append(_ op: Op) -> String {
            let id = String(format: "01H%06d", ops.count + 1)
            let op = op.withReplacedOpId(id)
            ops.append(op)
            if FigureOpPayload.folds(op) { FigureDeriver.fold(op, into: &state) }
            return id
        }
        mutating func emit(_ kind: OpKind, _ payload: FigureOpPayload) {
            append(Op(opId: "", docId: figureId, at: Date(timeIntervalSince1970: TimeInterval(ops.count)),
                      device: "macA", session: "s", kind: kind, changes: [], figure: payload))
        }
        mutating func set(_ key: CellKey, _ cell: Cell?) {
            emit(.figureCellSet, FigureOpPayload(cell: key, next: cell, prior: state.table[key]))
        }
    }

    private func text(_ s: String) -> Cell { Cell(content: .value(.text(s))) }
    private func number(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }

    /// A one-row, one-column table whose cell says "old".
    private func table() -> (History, CellKey) {
        var h = History(figureId: figureId)
        h.emit(.figureCreate, FigureOpPayload(kind: .table))
        h.emit(.figureStructure, FigureOpPayload(structure: .insertRow(r1, after: nil)))
        h.emit(.figureStructure, FigureOpPayload(structure: .insertColumn(c1, after: nil)))
        let key = CellKey(row: r1, column: c1)
        h.set(key, text("old"))
        return (h, key)
    }

    /// A suggestion on `key`; answers its note id.
    private func suggest(_ cell: Cell, at key: CellKey, in h: inout History) throws -> String {
        h.append(try FigureAnnotationOps.creation(
            kind: .suggestedChange, anchor: FigureCellAnchor(row: key.row, column: key.column),
            body: "Change it", suggestedCell: cell, prior: h.state.table[key], author: claude, stamp: h.stamp))
    }

    /// The accept that writes the suggestion's cell, as `acceptSuggestion` builds it.
    private func accept(_ id: String, _ cell: Cell, at key: CellKey, in h: inout History) {
        h.append(FigureAnnotationOps.accept(
            annotationId: id, cell: key, next: cell, prior: h.state.table[key], stamp: h.stamp))
    }

    /// The restore's table changes back to `pointer`, as `restoreToCheckpoint`
    /// works them out, and the plan over them.
    private func plan(
        _ h: History, to pointer: String,
        amendments: AnnotationAmendments = .honourEverything, mayDispose: Bool = true
    ) -> (changes: [FigureReturnDiff.Change], plan: FigureRestoreNotePlan) {
        let target = FigureRestoreDiff.target(of: h.ops, through: pointer)
        let changes = FigureRestoreDiff.changes(from: h.state, to: target, parks: [:])
            .filter { $0.kind != .figureImageSet }
        let plan = FigureRestoreNotePlan.plan(
            changes: changes, ops: h.ops, amendments: amendments, table: h.state.table,
            target: target, above: pointer, mayDispose: mayDispose)
        return (changes, plan)
    }

    // MARK: - The walk

    /// **The restore writes the accepted cell back**: that cell's change
    /// becomes the note's `claudeAcceptRevert`, payload unchanged, carrying
    /// the note's id; no status-only line.
    func test_aStrandedAcceptWhoseCellTheRestoreWritesBecomesItsRevert() throws {
        var (h, key) = table()
        let id = try suggest(number(42), at: key, in: &h)
        let pointer = h.pointer
        accept(id, number(42), at: key, in: &h)

        let (changes, plan) = plan(h, to: pointer)

        XCTAssertEqual(changes.map(\.kind), [.figureCellSet], "premise: the restore writes the cell back")
        XCTAssertEqual(plan.changes, [FigureReturnDiff.Change(
            kind: .claudeAcceptRevert, payload: changes[0].payload, sourceAnnotationId: id)])
        XCTAssertEqual(plan.changes.first?.payload.next, text("old"))
        XCTAssertEqual(plan.statusLines, [])
        XCTAssertEqual(plan.notes, FigureRestoreNotes(reopened: [id]))
    }

    /// **The cell already stands as it did then**: the restore writes no
    /// change to it, so the note is reopened by a status-only revert.
    func test_aStrandedAcceptWhoseCellTheRestoreDoesNotWriteIsRevertedStatusOnly() throws {
        var (h, key) = table()
        let id = try suggest(number(42), at: key, in: &h)
        let pointer = h.pointer
        accept(id, number(42), at: key, in: &h)
        h.set(key, text("old"))

        let (changes, plan) = plan(h, to: pointer)

        XCTAssertEqual(changes, [], "premise: the cell already stands as it did then")
        XCTAssertEqual(plan.changes, [])
        XCTAssertEqual(plan.statusLines, [.init(kind: .claudeAcceptRevert, annotationId: id)])
        XCTAssertEqual(plan.notes, FigureRestoreNotes(reopened: [id]))
    }

    /// **The cell's row is gone then**: the note is archived — or, where
    /// this hand may not dispose of a note, reopened status only.
    func test_aStrandedAcceptWhoseRowIsGoneIsArchived_orRevertedWhereItMayNotDispose() throws {
        var (h, _) = table()
        let pointer = h.pointer
        h.emit(.figureStructure, FigureOpPayload(structure: .insertRow(r2, after: r1)))
        let added = CellKey(row: r2, column: c1)
        let id = try suggest(number(7), at: added, in: &h)
        accept(id, number(7), at: added, in: &h)

        let (changes, disposing) = plan(h, to: pointer)
        XCTAssertFalse(changes.contains { $0.payload.cell == added }, "premise: the restore writes no cell there")
        XCTAssertEqual(disposing.changes, changes, "no change answers the note")
        XCTAssertEqual(disposing.statusLines, [.init(kind: .claudeArchive, annotationId: id)])
        XCTAssertEqual(disposing.notes, FigureRestoreNotes(archived: [id]))

        let (_, notDisposing) = plan(h, to: pointer, mayDispose: false)
        XCTAssertEqual(notDisposing.changes, changes)
        XCTAssertEqual(notDisposing.statusLines, [.init(kind: .claudeAcceptRevert, annotationId: id)])
        XCTAssertEqual(notDisposing.notes, FigureRestoreNotes(reopened: [id]))
    }

    /// **A reopen the fold does not honour does not hide the accept** (final
    /// review M3): newest on the note, it never happened as far as the
    /// note's status goes, so the accept is still stranded.
    func test_anUnhonouredReopenDoesNotHideTheAccept() throws {
        var (h, key) = table()
        let id = try suggest(number(42), at: key, in: &h)
        let pointer = h.pointer
        accept(id, number(42), at: key, in: &h)
        h.append(FigureAnnotationOps.reopen(annotationId: id, stamp: h.stamp))
        let dishonouring = AnnotationAmendments(honours: { _, _ in true }, disposing: { _ in false })

        let (changes, plan) = plan(h, to: pointer, amendments: dishonouring)

        XCTAssertEqual(h.ops.last?.kind, .annotationReopen, "premise: the reopen is the newest line")
        XCTAssertEqual(plan.changes, [FigureReturnDiff.Change(
            kind: .claudeAcceptRevert, payload: changes[0].payload, sourceAnnotationId: id)])
        XCTAssertEqual(plan.notes, FigureRestoreNotes(reopened: [id]))
    }

    /// **A status-only re-accept is judged against the newest accept that
    /// carries a cell** (N1): accept, stet, its ⌘Z's re-accept (no cell) —
    /// the cell-carrying accept is after the pointer, so it is stranded.
    func test_aStatusOnlyReAcceptIsJudgedAgainstTheNewestCellCarryingAccept() throws {
        var (h, key) = table()
        let id = try suggest(number(42), at: key, in: &h)
        let pointer = h.pointer
        accept(id, number(42), at: key, in: &h)
        h.append(FigureAnnotationOps.stet(annotationId: id, stamp: h.stamp))
        h.append(FigureAnnotationOps.statusOnlyAccept(annotationId: id, stamp: h.stamp))

        let (changes, plan) = plan(h, to: pointer)

        XCTAssertNil(h.ops.last?.figure, "premise: the latest accept carries no cell")
        XCTAssertEqual(plan.changes, [FigureReturnDiff.Change(
            kind: .claudeAcceptRevert, payload: changes[0].payload, sourceAnnotationId: id)])
        XCTAssertEqual(plan.notes, FigureRestoreNotes(reopened: [id]))
    }

    /// **An accept at or before the pointer is not stranded**: the restore
    /// keeps it, and plans nothing for its note.
    func test_anAcceptBeforeThePointerIsNotStranded() throws {
        var (h, key) = table()
        let id = try suggest(number(42), at: key, in: &h)
        accept(id, number(42), at: key, in: &h)
        let pointer = h.pointer
        h.set(key, text("later"))

        let (changes, plan) = plan(h, to: pointer)

        XCTAssertEqual(changes.map(\.kind), [.figureCellSet], "premise: the restore writes the cell back")
        XCTAssertEqual(plan.changes, changes, "the cell change stays a plain cell set")
        XCTAssertEqual(plan.statusLines, [])
        XCTAssertEqual(plan.notes, FigureRestoreNotes())
    }
}
