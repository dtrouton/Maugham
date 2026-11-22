import XCTest
@testable import Maugham

/// **Whether a table figure's grid opens, and whether it may be changed**
/// (report plan 7c Task 8, R7c-5): every row of the pure gate.
final class FigureGridGateTests: XCTestCase {

    private func mode(mayEdit: Bool = true, parked: Bool = false, closed: Bool = false, share: Bool = false,
                      readThrough: Bool = false,
                      translation: Bool = false) -> FigureGridGate.Mode {
        FigureGridGate.mode(figureMayEdit: mayEdit, parked: parked, hostClosed: closed,
                            shareIsReadOnly: share,
                            isInReadThrough: readThrough, naming: nil, isReadingTranslation: translation)
    }

    func test_everyRow() {
        XCTAssertEqual(mode(), .editable, "her own figure, nothing on")
        XCTAssertEqual(mode(translation: true), .noExpand, "translation review never expands")
        XCTAssertEqual(mode(parked: true), .readOnly(.parked))
        XCTAssertEqual(mode(closed: true), .readOnly(.closed))
        XCTAssertEqual(mode(mayEdit: false), .readOnly(.notYours), "the figure's posture refuses")
        XCTAssertEqual(mode(share: true), .readOnly(.viewOnlyShare), "a read-only share is read-only")
        XCTAssertEqual(mode(readThrough: true), .readOnly(.readThrough(nil)), "read-through expands read-only")
    }

    /// **Read-through is asked after the share**, and its strip keeps every
    /// answer: Accept is a decision (shell read-through Task 2). It is the
    /// only read-only reason that keeps them (the Lock went in Task 4).
    func test_readThroughComesAfterTheShare_andKeepsAccept() {
        XCTAssertEqual(mode(share: true, readThrough: true), .readOnly(.viewOnlyShare))
        XCTAssertEqual(mode(readThrough: true, translation: true), .noExpand)
        XCTAssertTrue(FigureGridStrip.Plan.keepsAnswers(.readThrough(nil)))
        XCTAssertTrue(FigureGridStrip.Plan.acceptWrites(under: .readThrough(nil)))
        for other in [FigureGridGate.Reason.parked, .closed, .notYours, .viewOnlyShare] {
            XCTAssertFalse(FigureGridStrip.Plan.keepsAnswers(other), "\(other)")
            XCTAssertFalse(FigureGridStrip.Plan.acceptWrites(under: other), "\(other)")
        }
        XCTAssertEqual(FigureGridGate.Reason.readThrough(nil).sentence,
                       "In read-through \u{2014} the table can be read, not typed into.")
        // Named, as every gate built from the window's `ReadThroughGate` is.
        let three = ReadThroughRefusal(pieceId: "ch-3", title: "Chapter Three", others: 0)
        XCTAssertEqual(FigureGridGate.mode(figureMayEdit: true, parked: false, hostClosed: false,
                                           shareIsReadOnly: false, isInReadThrough: true, naming: three,
                                           isReadingTranslation: false), .readOnly(.readThrough(three)))
        XCTAssertEqual(FigureGridGate.Reason.readThrough(three).sentence,
                       "\u{201C}Chapter Three\u{201D} is in read-through \u{2014} resume writing there "
                       + "to change this table.")
        XCTAssertEqual(FigureGridGate.Reason.readThrough(
            ReadThroughRefusal(pieceId: "ch-3", title: "Chapter Three", others: 2)).sentence(noun: "note"),
            "\u{201C}Chapter Three\u{201D} and 2 more are in read-through \u{2014} resume writing there "
            + "to change this note.")
    }

    /// First match wins: translation review over everything, then the
    /// figure's own facts (parked, closed, its posture), then the share,
    /// then read-through.
    func test_theOrderOfReasons() {
        XCTAssertEqual(mode(mayEdit: false, parked: true, closed: true, share: true, readThrough: true,
                            translation: true), .noExpand)
        XCTAssertEqual(mode(mayEdit: false, parked: true, closed: true, share: true, readThrough: true),
                       .readOnly(.parked))
        XCTAssertEqual(mode(mayEdit: false, closed: true, share: true, readThrough: true), .readOnly(.closed))
        XCTAssertEqual(mode(mayEdit: false, share: true, readThrough: true), .readOnly(.notYours))
        XCTAssertEqual(mode(share: true, readThrough: true), .readOnly(.viewOnlyShare))
    }

    func test_eachReasonHasItsSentence_parkedIsTheHostsOwn() {
        XCTAssertEqual(FigureGridGate.Reason.parked.sentence, "This table is in Research.")
        let sentences = [FigureGridGate.Reason.parked, .closed, .notYours, .viewOnlyShare,
                         .readThrough(nil)].map(\.sentence)
        XCTAssertEqual(Set(sentences).count, sentences.count, "each reason says something of its own")
        XCTAssertNil(FigureGridGate.Mode.editable.readOnlyReason)
        XCTAssertEqual(FigureGridGate.Mode.readOnly(.notYours).readOnlyReason, .notYours)
    }
}
