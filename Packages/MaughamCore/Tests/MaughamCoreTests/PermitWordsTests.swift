import XCTest
@testable import MaughamCore

/// **The words both surfaces say about a rung** (signed op log P3c plan 2,
/// Task 1). Moved byte-identical from the Mac's `PermitControl` and
/// `PeopleAndDevicesModel`; pinned here so the phone and the Mac cannot drift.
final class PermitWordsTests: XCTestCase {

    func test_everyRungHasItsTitle() {
        XCTAssertEqual(Permit.Rung.reviewer.title, "Reviewer")
        XCTAssertEqual(Permit.Rung.somePieces.title, "Author of some pieces")
        XCTAssertEqual(Permit.Rung.wholeBook.title, "Author of the whole book")
    }

    func test_everyRungHasItsExplanation() {
        XCTAssertEqual(
            Permit.Rung.reviewer.explanation,
            "Can leave notes and send captures. Anything they write in the "
                + "manuscript itself is set aside.")
        XCTAssertEqual(
            Permit.Rung.somePieces.explanation,
            "Can write anything in the pieces you choose, and leaves notes "
                + "everywhere else.")
        XCTAssertEqual(
            Permit.Rung.wholeBook.explanation,
            "Can write anywhere in the book, as you can.")
    }

    func test_onlySomePiecesPicksPieces() {
        for rung in Permit.Rung.allCases {
            XCTAssertEqual(rung.picksPieces, rung == .somePieces, "\(rung)")
        }
    }

    func test_theSentenceForEachRung() {
        XCTAssertEqual(
            PermitWords.sentence(rung: .reviewer, pieceTitles: ["Ignored"]),
            "Reviewer", "a rung with no pieces names no pieces")
        XCTAssertEqual(
            PermitWords.sentence(rung: .wholeBook, pieceTitles: []),
            "Author of the whole book")
        XCTAssertEqual(
            PermitWords.sentence(rung: .somePieces, pieceTitles: ["Chapter 4", "Coda"]),
            "Author of some pieces: Chapter 4, Coda")
        XCTAssertEqual(
            PermitWords.sentence(rung: .somePieces, pieceTitles: []),
            "Author of some pieces \u{2014} none chosen yet")
        XCTAssertEqual(
            PermitWords.sentence(rung: nil, pieceTitles: []),
            "This book says something about what they may write that this "
                + "version of Maugham doesn\u{2019}t recognise.")
    }
}
