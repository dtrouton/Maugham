import XCTest
@testable import Maugham

/// **Whether a table figure's grid opens, and whether it may be changed**
/// (report plan 7c Task 8, R7c-5): every row of the pure gate.
final class FigureGridGateTests: XCTestCase {

    private func mode(mayEdit: Bool = true, parked: Bool = false, closed: Bool = false, share: Bool = false,
                      locked: Bool = false, readThrough: Bool = false,
                      translation: Bool = false) -> FigureGridGate.Mode {
        FigureGridGate.mode(figureMayEdit: mayEdit, parked: parked, hostClosed: closed,
                            shareIsReadOnly: share, isLocked: locked,
                            isInReadThrough: readThrough, isReadingTranslation: translation)
    }

    func test_everyRow() {
        XCTAssertEqual(mode(), .editable, "her own figure, nothing on")
        XCTAssertEqual(mode(translation: true), .noExpand, "translation review never expands")
        XCTAssertEqual(mode(parked: true), .readOnly(.parked))
        XCTAssertEqual(mode(closed: true), .readOnly(.closed))
        XCTAssertEqual(mode(mayEdit: false), .readOnly(.notYours), "the figure's posture refuses")
        XCTAssertEqual(mode(share: true), .readOnly(.viewOnlyShare), "a read-only share is read-only")
        XCTAssertEqual(mode(locked: true), .readOnly(.locked), "the window's Lock expands read-only")
        XCTAssertEqual(mode(readThrough: true), .readOnly(.readThrough), "read-through expands read-only")
    }

    /// **Read-through is asked after the share and before the Lock**, and
    /// its strip keeps every answer: Accept is a decision (shell read-through
    /// Task 2).
    func test_readThroughComesAfterTheShareAndBeforeTheLock_andKeepsAccept() {
        XCTAssertEqual(mode(share: true, readThrough: true), .readOnly(.viewOnlyShare))
        XCTAssertEqual(mode(locked: true, readThrough: true), .readOnly(.readThrough))
        XCTAssertEqual(mode(readThrough: true, translation: true), .noExpand)
        XCTAssertNil(FigureGridStrip.Plan.acceptRefusal(for: .readThrough))
        XCTAssertTrue(FigureGridStrip.Plan.keepsAnswers(.readThrough))
        XCTAssertTrue(FigureGridStrip.Plan.acceptWrites(under: .readThrough))
        XCTAssertFalse(FigureGridStrip.Plan.acceptWrites(under: .locked))
        XCTAssertEqual(FigureGridGate.Reason.readThrough.sentence,
                       "In read-through \u{2014} the table can be read, not typed into.")
    }

    /// **The Lock says the window is locked**, never that the writer is
    /// reviewing — in the grid's refusal and in the notes strip's Accept line.
    func test_theLockHasItsOwnWords() {
        XCTAssertEqual(FigureGridGate.Reason.locked.sentence,
                       "The window is locked \u{2014} the table can be read, not changed.")
        XCTAssertEqual(FigureGridStrip.Plan.acceptRefusal(for: .locked),
                       "Unlock the window to accept \u{2014} it writes the cell.")
        XCTAssertNil(FigureGridStrip.Plan.acceptRefusal(for: .viewOnlyShare))
        XCTAssertEqual(mode(share: true, locked: true), .readOnly(.viewOnlyShare))
    }

    /// First match wins: translation review over everything, then the
    /// figure's own facts (parked, closed, its posture), then the share,
    /// then read-through, then the Lock.
    func test_theOrderOfReasons() {
        XCTAssertEqual(mode(mayEdit: false, parked: true, closed: true, share: true, locked: true, translation: true),
                       .noExpand)
        XCTAssertEqual(mode(mayEdit: false, parked: true, closed: true, share: true, locked: true), .readOnly(.parked))
        XCTAssertEqual(mode(mayEdit: false, closed: true, share: true, locked: true), .readOnly(.closed))
        XCTAssertEqual(mode(mayEdit: false, share: true, locked: true), .readOnly(.notYours))
        XCTAssertEqual(mode(share: true, locked: true), .readOnly(.viewOnlyShare))
    }

    func test_eachReasonHasItsSentence_parkedIsTheHostsOwn() {
        XCTAssertEqual(FigureGridGate.Reason.parked.sentence, "This table is in Research.")
        let sentences = [FigureGridGate.Reason.parked, .closed, .notYours, .viewOnlyShare, .readThrough,
                         .locked].map(\.sentence)
        XCTAssertEqual(Set(sentences).count, sentences.count, "each reason says something of its own")
        XCTAssertNil(FigureGridGate.Mode.editable.readOnlyReason)
        XCTAssertEqual(FigureGridGate.Mode.readOnly(.notYours).readOnlyReason, .notYours)
    }
}
