import XCTest
@testable import Maugham

/// **Whether a table figure's grid opens, and whether it may be changed**
/// (report plan 7c Task 8, R7c-5): every row of the pure gate.
final class FigureGridGateTests: XCTestCase {

    private func mode(mayEdit: Bool = true, parked: Bool = false, closed: Bool = false, share: Bool = false,
                      review: Bool = false, translation: Bool = false) -> FigureGridGate.Mode {
        FigureGridGate.mode(figureMayEdit: mayEdit, parked: parked, hostClosed: closed,
                            shareIsReadOnly: share, isReviewMode: review, isTranslationReview: translation)
    }

    func test_everyRow() {
        XCTAssertEqual(mode(), .editable, "her own figure, nothing on")
        XCTAssertEqual(mode(translation: true), .noExpand, "translation review never expands")
        XCTAssertEqual(mode(parked: true), .readOnly(.parked))
        XCTAssertEqual(mode(closed: true), .readOnly(.closed))
        XCTAssertEqual(mode(mayEdit: false), .readOnly(.notYours), "the figure's posture refuses")
        XCTAssertEqual(mode(share: true), .readOnly(.viewOnlyShare), "a read-only share is read-only")
        XCTAssertEqual(mode(review: true), .readOnly(.reviewMode), "review mode expands read-only")
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
        let sentences = [FigureGridGate.Reason.parked, .closed, .notYours, .viewOnlyShare, .reviewMode].map(\.sentence)
        XCTAssertEqual(Set(sentences).count, sentences.count, "each reason says something of its own")
        XCTAssertNil(FigureGridGate.Mode.editable.readOnlyReason)
        XCTAssertEqual(FigureGridGate.Mode.readOnly(.notYours).readOnlyReason, .notYours)
    }
}
