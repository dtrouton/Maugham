import XCTest
@testable import MaughamCore

/// **The figure restore's note walk, in Core** (hardening 11-11 Tasks 1–2,
/// RULING-28, RULING-57, ruling R-A): `FigureRestoreNotePlan.plan` answers
/// the figure suggestions whose status a restore to a checkpoint would
/// contradict — a stranded accept's cell change becomes its
/// `claudeAcceptRevert`, a returning note's (reverted since the checkpoint,
/// its accepted value written back) becomes its `claudeAccept`, a cell gone
/// then is archived (or, where the hand may not dispose, reverted status
/// only), and a cell the restore does not write keeps its note's status. The
/// manuscript's twin is `RewindImpact.travelStatusChanges`, pinned by
/// `RewindReturningAcceptTests` and `PartialRestoreStrandedAcceptTests`.
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

    /// The writer's Revert of an accept: the cell put back to `cell`, the note reopened.
    private func revert(_ id: String, to cell: Cell?, at key: CellKey, in h: inout History) {
        h.append(Op(opId: "", docId: figureId, at: h.stamp.at, device: "macA", session: "s",
                    kind: .claudeAcceptRevert, changes: [],
                    provenance: FigureAnnotationOps.lifecycleProvenance(annotationId: id, stamp: h.stamp),
                    figure: FigureOpPayload(cell: key, next: cell, prior: h.state.table[key])))
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

    /// **The cell already stands as it did then** (re-pinned by ruling R-A,
    /// hardening 11-11 Task 2): the restore writes no change to it, so the
    /// note keeps its status — no status-only revert, nothing planned. Was:
    /// reopened by a status-only revert.
    func test_aStrandedAcceptWhoseCellTheRestoreDoesNotWriteKeepsItsStatus() throws {
        var (h, key) = table()
        let id = try suggest(number(42), at: key, in: &h)
        let pointer = h.pointer
        accept(id, number(42), at: key, in: &h)
        h.set(key, text("old"))

        let (changes, plan) = plan(h, to: pointer)

        XCTAssertEqual(changes, [], "premise: the cell already stands as it did then")
        XCTAssertEqual(plan.changes, [])
        XCTAssertEqual(plan.statusLines, [], "R-A: a cell the restore does not write keeps its note")
        XCTAssertEqual(plan.notes, FigureRestoreNotes())
    }

    /// **A returning accept** (RULING-57's figure twin,
    /// `RewindReturningAcceptTests`): accepted at the pointer, reverted since,
    /// open now — the restore writes its accepted value back, so that cell's
    /// change becomes the note's `claudeAccept`, payload unchanged.
    func test_aRevertedAcceptReturnsWhenTheRestoreWritesItsValueBack() throws {
        var (h, key) = table()
        let id = try suggest(number(42), at: key, in: &h)
        accept(id, number(42), at: key, in: &h)
        let pointer = h.pointer
        revert(id, to: text("old"), at: key, in: &h)

        let (changes, plan) = plan(h, to: pointer)

        XCTAssertEqual(changes.map(\.payload.next), [number(42)], "premise: the restore writes the value back")
        XCTAssertEqual(plan.changes, [FigureReturnDiff.Change(
            kind: .claudeAccept, payload: changes[0].payload, sourceAnnotationId: id)])
        XCTAssertEqual(plan.statusLines, [])
        XCTAssertEqual(plan.notes, FigureRestoreNotes(reaccepted: [id]))
    }

    /// **A returning accept answers a note** (Review Focus 4): the restore
    /// asks `.acceptOrReject` of `answersANote`, so a hand that may not
    /// answer notes is refused before any op though no status line is
    /// planned; a plan that answers none does not ask.
    func test_aReturningAcceptAnswersANote_soTheRestoreAsksAcceptOrReject() throws {
        var (h, key) = table()
        let id = try suggest(number(42), at: key, in: &h)
        accept(id, number(42), at: key, in: &h)
        let pointer = h.pointer
        revert(id, to: text("old"), at: key, in: &h)

        let (_, returning) = plan(h, to: pointer)
        XCTAssertEqual(returning.statusLines, [], "premise: no status line")
        XCTAssertEqual(returning.changes.map(\.kind), [.claudeAccept], "premise: the change carries the note")
        XCTAssertTrue(returning.answersANote)

        h.set(key, text("hand"))
        let (changes, plain) = plan(h, to: h.ops[h.ops.count - 2].opId)
        XCTAssertEqual(plain.changes, changes, "premise: a plain cell set, no note carried")
        XCTAssertFalse(plain.answersANote)
    }

    /// **Accepted at the pointer and now is never stranded** (the manuscript's
    /// `acceptedAtTarget`, M4-RW-042): accept, checkpoint, Revert, accept
    /// again, a hand edit — the restore writes the accepted value back as a
    /// plain cell set and plans nothing for the note.
    func test_acceptedAtThePointerAndNow_isNotStranded() throws {
        var (h, key) = table()
        let id = try suggest(number(42), at: key, in: &h)
        accept(id, number(42), at: key, in: &h)
        let pointer = h.pointer
        revert(id, to: text("old"), at: key, in: &h)
        accept(id, number(42), at: key, in: &h)
        h.set(key, text("hand"))

        let (changes, plan) = plan(h, to: pointer)

        XCTAssertEqual(changes.map(\.kind), [.figureCellSet], "premise: the restore writes the cell back")
        XCTAssertEqual(plan.changes, changes, "a plain cell set")
        XCTAssertEqual(plan.statusLines, [])
        XCTAssertEqual(plan.notes, FigureRestoreNotes())
    }

    /// **Two stranded notes on one written cell** (coordinator's ruling,
    /// Review Focus 3): the change carries the note whose cell-carrying
    /// accept is newest; the other — its cell WAS written — is reverted
    /// status only.
    func test_twoStrandedNotesOnOneCell_theNewestAcceptCarriesTheChange() throws {
        var (h, key) = table()
        let first = try suggest(number(42), at: key, in: &h)
        let second = try suggest(number(7), at: key, in: &h)
        let pointer = h.pointer
        accept(first, number(42), at: key, in: &h)
        accept(second, number(7), at: key, in: &h)
        XCTAssertLessThan(first, second, "premise: the id order is not the accept order's answer")

        let (changes, plan) = plan(h, to: pointer)

        XCTAssertEqual(plan.changes, [FigureReturnDiff.Change(
            kind: .claudeAcceptRevert, payload: changes[0].payload, sourceAnnotationId: second)])
        XCTAssertEqual(plan.statusLines, [.init(kind: .claudeAcceptRevert, annotationId: first)])
        XCTAssertEqual(plan.notes, FigureRestoreNotes(reopened: [second, first]))
    }

    /// **A returning note takes its cell's change before a stranded one**:
    /// the value written is the one it accepted; the stranded note on that
    /// written cell is reverted status only.
    func test_aReturningNoteTakesTheChangeBeforeAStrandedOne() throws {
        var (h, key) = table()
        let returning = try suggest(number(42), at: key, in: &h)
        accept(returning, number(42), at: key, in: &h)
        let pointer = h.pointer
        revert(returning, to: text("old"), at: key, in: &h)
        let stranded = try suggest(number(7), at: key, in: &h)
        accept(stranded, number(7), at: key, in: &h)

        let (changes, plan) = plan(h, to: pointer)

        XCTAssertEqual(changes.map(\.payload.next), [number(42)], "premise: the restore writes 42 back")
        XCTAssertEqual(plan.changes, [FigureReturnDiff.Change(
            kind: .claudeAccept, payload: changes[0].payload, sourceAnnotationId: returning)])
        XCTAssertEqual(plan.statusLines, [.init(kind: .claudeAcceptRevert, annotationId: stranded)])
        XCTAssertEqual(plan.notes, FigureRestoreNotes(reopened: [stranded], reaccepted: [returning]))
    }

    /// **A returning note whose cell the restore writes to another value
    /// stays open**: the accept the pointer held wrote 42, a hand edit before
    /// the pointer made it 43, so the value written back is not its own.
    func test_aReturningNoteWhoseCellIsWrittenToAnotherValueStaysOpen() throws {
        var (h, key) = table()
        let id = try suggest(number(42), at: key, in: &h)
        accept(id, number(42), at: key, in: &h)
        h.set(key, number(43))
        let pointer = h.pointer
        revert(id, to: text("old"), at: key, in: &h)

        let (changes, plan) = plan(h, to: pointer)

        XCTAssertEqual(changes.map(\.payload.next), [number(43)], "premise: the restore writes 43")
        XCTAssertEqual(plan.changes, changes, "a plain cell set")
        XCTAssertEqual(plan.statusLines, [])
        XCTAssertEqual(plan.notes, FigureRestoreNotes())
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
