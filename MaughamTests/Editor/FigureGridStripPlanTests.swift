import XCTest
@testable import Maugham
@testable import MaughamCore

/// **What the suggestion strip shows** (report plan 9c-2 Task 5): the pure
/// plan over the controller's cached notes and the active cell — a
/// suggestion's before → after with Accept and Reject, a comment's or a
/// query's words with Got it and Reject (Reply stays in the queue), "1 of 2"
/// paging, the empty line, and the buttons hidden (read-only) or disabled
/// (a refusing posture) with the reason.
@MainActor
final class FigureGridStripPlanTests: XCTestCase {

    private let en = TableLocale(languageTag: "en-GB", fallbackRegion: "GB")
    private var table = FigureTable(rows: 3, columns: 3)

    private func key(_ row: Int, _ column: Int) -> CellKey {
        CellKey(row: table.rows[row], column: table.columns[column])
    }

    private func note(
        _ id: String, _ kind: AnnotationKind, at key: CellKey, to end: CellKey? = nil,
        body: String = "Check this", suggested: Cell? = nil
    ) -> Annotation {
        Annotation(
            id: id, kind: kind, paragraphId: nil, body: body, suggestedText: nil, priorText: nil,
            createdAt: Date(timeIntervalSince1970: 1_000), createdBySession: nil, status: .open,
            userResponse: nil, resolvedAt: nil, isStale: false,
            figureAnchor: FigureCellAnchor(row: key.row, rowEnd: end?.row, column: key.column, columnEnd: end?.column),
            suggestedCell: suggested)
    }

    private func plan(
        _ notes: [Annotation], active: CellKey?, mayAccept: Bool = true, mayReject: Bool = true,
        readOnly: FigureGridGate.Reason? = nil
    ) -> FigureGridStrip.Plan {
        FigureGridStrip.Plan.make(
            notes: FigureCellNotes(notes: notes, table: table), active: active, table: table, names: .empty,
            locale: en, mayAccept: mayAccept, mayReject: mayReject, readOnly: readOnly)
    }

    private func number(_ n: Double) -> Cell { Cell(content: .value(.number(n))) }

    func test_aSuggestionShowsItsChangeWithAcceptAndReject() {
        table.setCell(number(12), at: key(1, 1))
        let p = plan([note("s1", .suggestedChange, at: key(1, 1), body: "Should be 14", suggested: number(14))],
                     active: key(1, 1))
        XCTAssertEqual(p.entries.count, 1)
        let entry = p.entries[0]
        XCTAssertEqual(entry.noteId, "s1")
        XCTAssertEqual(entry.heading, "Suggested change \u{00B7} B2")
        XCTAssertEqual(entry.body, "Should be 14")
        XCTAssertEqual(entry.change, "12 \u{2192} 14")
        XCTAssertEqual(entry.actions, [.init(verb: .accept, isEnabled: true), .init(verb: .reject, isEnabled: true)])
        XCTAssertNil(p.reason)
        XCTAssertNil(p.page(0)?.label, "one note, no paging")
    }

    func test_aSuggestionToClearAnEmptyCellReadsAsTheQueuesEmpty() {
        let p = plan([note("s1", .suggestedChange, at: key(0, 0), suggested: nil)], active: key(0, 0))
        XCTAssertEqual(p.entries.first?.change, "\(AnnotationRow.emptyCell) \u{2192} \(AnnotationRow.emptyCell)")
    }

    func test_aCommentAndAQueryGetGotItAndReject_noChangeLine() {
        for kind in [AnnotationKind.comment, .query] {
            let p = plan([note("n1", kind, at: key(0, 2))], active: key(0, 2))
            let entry = try! XCTUnwrap(p.entries.first)
            XCTAssertEqual(entry.heading, "\(kind.displayName) \u{00B7} C1")
            XCTAssertNil(entry.change, "\(kind)")
            XCTAssertEqual(entry.actions, [.init(verb: .gotIt, isEnabled: true), .init(verb: .reject, isEnabled: true)],
                           "\(kind): Got it and Reject; Reply stays in the queue")
        }
    }

    func test_noNoteOnTheActiveCellShowsTheEmptyLine() {
        let notes = [note("n1", .comment, at: key(0, 0))]
        XCTAssertEqual(plan(notes, active: key(2, 2)), .empty)
        XCTAssertEqual(plan(notes, active: nil), .empty, "no selection")
        XCTAssertNil(FigureGridStrip.Plan.empty.page(0))
        XCTAssertEqual(FigureGridStrip.Plan.noNotes, "No notes on this cell")
    }

    func test_twoNotesPage_aRangeShowsFromAnInnerCell() {
        let notes = [note("r1", .comment, at: key(0, 0), to: key(1, 1), body: "Range"),
                     note("s1", .suggestedChange, at: key(1, 1), suggested: number(3))]
        let p = plan(notes, active: key(1, 1))
        XCTAssertEqual(p.entries.map(\.noteId), ["r1", "s1"], "the projection's order")
        XCTAssertEqual(p.entries[0].heading, "Comment \u{00B7} A1:B2", "the range's address")
        XCTAssertEqual(p.page(0)?.label, "1 of 2")
        XCTAssertEqual(p.page(1)?.label, "2 of 2")
        XCTAssertEqual(p.page(1)?.entry.noteId, "s1")
        XCTAssertEqual(p.page(7)?.entry.noteId, "s1", "a page past the end is the last")
        XCTAssertEqual(plan(notes, active: key(0, 1)).entries.map(\.noteId), ["r1"], "inner cell, range only")
    }

    func test_readOnlyHidesTheButtonsAndSaysWhy() {
        let p = plan([note("s1", .suggestedChange, at: key(0, 0), suggested: number(1))], active: key(0, 0),
                     mayAccept: false, mayReject: true, readOnly: .reviewMode)
        XCTAssertEqual(p.entries.first?.actions, [], "no buttons on a read-only grid")
        XCTAssertNotNil(p.entries.first?.change, "the note is still read")
        XCTAssertEqual(p.reason, FigureGridGate.Reason.reviewMode.sentence)
    }

    func test_aRefusingPostureDisablesTheButtonsAndSaysWhy() {
        let notes = [note("s1", .suggestedChange, at: key(0, 0), suggested: number(1)),
                     note("c1", .comment, at: key(0, 0))]
        let p = plan(notes, active: key(0, 0), mayAccept: false, mayReject: false)
        XCTAssertEqual(p.entries[0].actions, [.init(verb: .accept, isEnabled: false), .init(verb: .reject, isEnabled: false)])
        XCTAssertEqual(p.entries[1].actions, [.init(verb: .gotIt, isEnabled: false), .init(verb: .reject, isEnabled: false)])
        XCTAssertEqual(p.reason, FigureGridStrip.Plan.notPermitted)
    }

    /// The view shows the plan's page: the empty line, then an entry's
    /// buttons hidden or disabled as planned.
    func test_theViewShowsThePlan() {
        let view = FigureGridStripView()
        view.show(.empty, page: 0)
        XCTAssertEqual(view.bodyLabel.stringValue, FigureGridStrip.Plan.noNotes)
        XCTAssertTrue(view.acceptButton.isHidden && view.rejectButton.isHidden && view.gotItButton.isHidden)
        XCTAssertNil(view.shownNoteId)

        let notes = [note("s1", .suggestedChange, at: key(0, 0), suggested: number(1)),
                     note("c1", .comment, at: key(0, 0), body: "Hmm")]
        view.show(plan(notes, active: key(0, 0)), page: 1)
        XCTAssertEqual(view.shownNoteId, "c1")
        XCTAssertEqual(view.bodyLabel.stringValue, "Hmm")
        XCTAssertEqual(view.pageLabel.stringValue, "2 of 2")
        XCTAssertFalse(view.gotItButton.isHidden)
        XCTAssertTrue(view.acceptButton.isHidden)
        XCTAssertTrue(view.changeLabel.isHidden)

        view.show(plan(notes, active: key(0, 0), mayAccept: false, mayReject: false), page: 0)
        XCTAssertFalse(view.acceptButton.isHidden)
        XCTAssertFalse(view.acceptButton.isEnabled)
        XCTAssertEqual(view.reasonLabel.stringValue, FigureGridStrip.Plan.notPermitted)

        view.show(plan(notes, active: key(0, 0), readOnly: .notYours), page: 0)
        XCTAssertTrue(view.acceptButton.isHidden && view.rejectButton.isHidden)
        XCTAssertEqual(view.reasonLabel.stringValue, FigureGridGate.Reason.notYours.sentence)
    }
}
