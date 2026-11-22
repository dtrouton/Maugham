import XCTest
@testable import Maugham

/// **Whether a table figure's grid opens, and whether it may be changed**
/// (report plan 7c Task 8, R7c-5): every row of the pure gate.
final class FigureGridGateTests: XCTestCase {

    private func mode(mayEdit: Bool = true, parked: Bool = false, closed: Bool = false, share: Bool = false,
                      review: Bool = false, locked: Bool = false, translation: Bool = false) -> FigureGridGate.Mode {
        FigureGridGate.mode(figureMayEdit: mayEdit, parked: parked, hostClosed: closed,
                            shareIsReadOnly: share, isReviewMode: review, isLocked: locked,
                            isReadingTranslation: translation)
    }

    func test_everyRow() {
        XCTAssertEqual(mode(), .editable, "her own figure, nothing on")
        XCTAssertEqual(mode(translation: true), .noExpand, "translation review never expands")
        XCTAssertEqual(mode(parked: true), .readOnly(.parked))
        XCTAssertEqual(mode(closed: true), .readOnly(.closed))
        XCTAssertEqual(mode(mayEdit: false), .readOnly(.notYours), "the figure's posture refuses")
        XCTAssertEqual(mode(share: true), .readOnly(.viewOnlyShare), "a read-only share is read-only")
        XCTAssertEqual(mode(review: true), .readOnly(.reviewMode), "review mode expands read-only")
        XCTAssertEqual(mode(locked: true), .readOnly(.locked), "the window's Lock expands read-only")
    }

    /// **The Lock says the window is locked**, never that the writer is
    /// reviewing — in the grid's refusal and in the notes strip's Accept line.
    func test_theLockHasItsOwnWords() {
        XCTAssertEqual(FigureGridGate.Reason.locked.sentence,
                       "The window is locked \u{2014} the table can be read, not changed.")
        XCTAssertEqual(FigureGridStrip.Plan.acceptRefusal(for: .locked),
                       "Unlock the window to accept \u{2014} it writes the cell.")
        XCTAssertEqual(FigureGridStrip.Plan.acceptRefusal(for: .reviewMode),
                       "Turn off review mode to accept \u{2014} it writes the cell.")
        XCTAssertNil(FigureGridStrip.Plan.acceptRefusal(for: .viewOnlyShare))
        XCTAssertEqual(mode(review: true, locked: true), .readOnly(.reviewMode), "the explicit ⌘⌥⇧R is said first")
        XCTAssertEqual(mode(share: true, locked: true), .readOnly(.viewOnlyShare))
    }

    /// First match wins: translation review over everything, then the
    /// figure's own facts (parked, closed, its posture), then the share,
    /// then review mode.
    func test_theOrderOfReasons() {
        XCTAssertEqual(mode(mayEdit: false, parked: true, closed: true, share: true, review: true, translation: true),
                       .noExpand)
        XCTAssertEqual(mode(mayEdit: false, parked: true, closed: true, share: true, review: true), .readOnly(.parked))
        XCTAssertEqual(mode(mayEdit: false, closed: true, share: true, review: true), .readOnly(.closed))
        XCTAssertEqual(mode(mayEdit: false, share: true, review: true), .readOnly(.notYours))
        XCTAssertEqual(mode(share: true, review: true), .readOnly(.viewOnlyShare))
    }

    func test_eachReasonHasItsSentence_parkedIsTheHostsOwn() {
        XCTAssertEqual(FigureGridGate.Reason.parked.sentence, "This table is in Research.")
        let sentences = [FigureGridGate.Reason.parked, .closed, .notYours, .viewOnlyShare, .reviewMode, .locked].map(\.sentence)
        XCTAssertEqual(Set(sentences).count, sentences.count, "each reason says something of its own")
        XCTAssertNil(FigureGridGate.Mode.editable.readOnlyReason)
        XCTAssertEqual(FigureGridGate.Mode.readOnly(.notYours).readOnlyReason, .notYours)
    }
}
