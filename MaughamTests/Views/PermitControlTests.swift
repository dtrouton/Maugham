// MaughamTests/Views/PermitControlTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The control that says what somebody may write** (signed op log P3b Task 4,
/// spec §7.1).
///
/// Everything the admission sheet and People & Devices decide about a permit is
/// a value here, so the suites that MOUNT either surface only have to prove
/// they draw it — nothing presses a control and waits (tripwire 33).
///
/// The one thing this file must never do is compare a permit to a rung: the
/// control BUILDS permits through the permit layer's own words, and
/// `TripwireGrepTests.test_aPermitRungIsComparedOnlyInThePermitLayer` is what
/// keeps the production half honest.
final class PermitControlTests: XCTestCase {

    // MARK: - A choice builds the permit it says

    func test_eachChoiceBuildsTheRungItNames() {
        XCTAssertEqual(
            PermitControl.permit(for: .reviewer, pieces: []), .reviewer)
        XCTAssertEqual(
            PermitControl.permit(for: .wholeBook, pieces: []), .author(.book))
        XCTAssertEqual(
            PermitControl.permit(for: .somePieces, pieces: ["doc-a1b2c3d4"]),
            .author(.pieces(["doc-a1b2c3d4"])))
    }

    /// *She may write what she starts* is a real state, and it is why the wire
    /// format spells `"pieces"` rather than hanging the distinction on an
    /// absent key. An empty picker must not silently mean the whole book.
    func test_somePiecesWithNoPiecesIsAnAuthorOfNothingYetAndNotOfTheBook() {
        let permit = PermitControl.permit(for: .somePieces, pieces: [])

        XCTAssertEqual(permit, .author(.pieces([])))
        XCTAssertNotEqual(permit, .author(.book))
        XCTAssertEqual(permit.wireScope, Permit.piecesScope)
    }

    /// The pieces ride along while the writer changes their mind, so going
    /// reviewer → some pieces → reviewer does not lose the list.
    func test_theRungDecidesWhetherThePiecesAreUsedAtAll() {
        XCTAssertEqual(
            PermitControl.permit(for: .reviewer, pieces: ["doc-a1b2c3d4"]),
            .reviewer)
        XCTAssertEqual(
            PermitControl.permit(for: .wholeBook, pieces: ["doc-a1b2c3d4"]),
            .author(.book))
    }

    /// Only one of the three narrows, and the question is the permit layer's.
    func test_onlyTheWholeBookLeavesTheBookUnnarrowed() {
        XCTAssertFalse(PermitControl.permit(for: .wholeBook, pieces: []).narrows)
        XCTAssertTrue(PermitControl.permit(for: .reviewer, pieces: []).narrows)
        XCTAssertTrue(PermitControl.permit(for: .somePieces, pieces: []).narrows)
    }

    // MARK: - And reads one back

    func test_everyChoiceRoundTripsThroughThePermitItBuilds() {
        for choice in PermitControl.Choice.allCases {
            let permit = PermitControl.permit(
                for: choice, pieces: ["doc-a1b2c3d4", "doc-99887766"])
            XCTAssertEqual(PermitControl.choice(displaying: permit), choice,
                           "\(choice) must come back as itself")
        }
        XCTAssertEqual(
            PermitControl.pieces(displaying: PermitControl.permit(
                for: .somePieces, pieces: ["doc-a1b2c3d4"])),
            ["doc-a1b2c3d4"])
    }

    /// **A permit this build cannot read has no control**, and saying so is the
    /// point: a picker that drew an unknown rung as *reviewer* would offer to
    /// overwrite a permit it never showed the writer.
    func test_aPermitFromALaterBuildHasNoChoiceToDrawItWith() {
        let later = Permit.parse(role: "editor", scope: nil, pieces: nil)

        XCTAssertTrue(later.isUnjudgeable)
        XCTAssertNil(PermitControl.choice(displaying: later))
    }

    // MARK: - The pieces

    func test_thePickerListsDocumentsInBinderOrderAndNoGroups() {
        let structure = [
            StructureItem(id: "grp-1", title: "Part One", type: .group,
                          children: [
                            StructureItem(id: "doc-11111111", title: "One",
                                          type: .document),
                            StructureItem(id: "doc-22222222", title: "Two",
                                          type: .document),
                          ]),
            StructureItem(id: "doc-33333333", title: "Three", type: .document),
        ]

        XCTAssertEqual(
            PermitControl.pieces(in: structure).map(\.id),
            ["doc-11111111", "doc-22222222", "doc-33333333"],
            "a group is a place to keep pieces, not a piece")
        XCTAssertEqual(PermitControl.pieces(in: structure).first?.title, "One")
    }

    func test_aBookWithNoPiecesOffersNone() {
        XCTAssertTrue(PermitControl.pieces(in: []).isEmpty)
    }

    // MARK: - What the first narrowing does

    func test_theFirstNarrowingSaysOlderBuildsStopOpeningTheBook() throws {
        let notice = try XCTUnwrap(PermitControl.firstNarrowingNotice(
            isTheBooksFirstNarrowing: true, holdsAnUnsignedStream: false))

        XCTAssertTrue(notice.contains("Older versions of Maugham"), notice)
        XCTAssertTrue(notice.contains("no longer open this book"), notice)
        XCTAssertFalse(notice.contains("Inbox"),
                       "there is no unsigned Mac here to speak about: \(notice)")
    }

    func test_anUnsignedMacInTheBookIsNamedWithWhatHappensToIt() throws {
        let notice = try XCTUnwrap(PermitControl.firstNarrowingNotice(
            isTheBooksFirstNarrowing: true, holdsAnUnsignedStream: true))

        XCTAssertTrue(notice.contains("Older versions of Maugham"),
                      "both halves, not one: \(notice)")
        XCTAssertTrue(notice.contains("signs nothing it writes"), notice)
        XCTAssertTrue(notice.contains("Inbox"),
                      "and where its writing can be got back: \(notice)")
        XCTAssertTrue(notice.contains("Nothing it has already written changes"),
                      "the half a writer will not assume: \(notice)")
    }

    /// **Nothing to say where the book has already been narrowed.** Both costs
    /// were paid the first time, and repeating them at every later change
    /// teaches the writer to press past the one that matters.
    func test_aBookAlreadyNarrowedIsToldNothingAgain() {
        XCTAssertNil(PermitControl.firstNarrowingNotice(
            isTheBooksFirstNarrowing: false, holdsAnUnsignedStream: true))
        XCTAssertNil(PermitControl.notice(
            forGranting: PermitControl.permit(for: .reviewer, pieces: []),
            in: PermitControl.BookNarrowing(
                alreadyNarrowed: true, holdsAnUnsignedStream: true)))
    }

    /// And nothing at all for a permit that narrows nobody, in a book that has
    /// never been narrowed — the ordinary admission, which must look exactly
    /// as it did in P2b.
    func test_anAdmissionThatNarrowsNobodySaysNothing() {
        XCTAssertNil(PermitControl.notice(
            forGranting: PermitControl.permit(for: .wholeBook, pieces: []),
            in: PermitControl.BookNarrowing(
                alreadyNarrowed: false, holdsAnUnsignedStream: true)))
    }

    func test_theFirstNarrowingOfABookSpeaksWhicheverNarrowingRungItIs() {
        let book = PermitControl.BookNarrowing(
            alreadyNarrowed: false, holdsAnUnsignedStream: false)

        for choice in [PermitControl.Choice.reviewer, .somePieces] {
            XCTAssertNotNil(
                PermitControl.notice(
                    forGranting: PermitControl.permit(for: choice, pieces: []),
                    in: book),
                "\(choice) narrows the book and the writer is owed the sentence")
        }
    }

    // MARK: - Which acknowledged-loss count the confirmation carries
    //         (fix round 1, Minor 1)

    /// **The count follows the sweep.** A change that narrows takes the book's
    /// photograph (`everyExpectedStream`) as well as this person's mark, so it
    /// is decided without whatever the writer put down anywhere in the book.
    /// One that narrows nobody reads this person's streams alone.
    func test_thecountIsTheBooksWhenTheChangeNarrowsAndTheSubjectsWhenItDoesNot() {
        XCTAssertEqual(
            PermitControl.lostHistory(
                forGranting: PermitControl.permit(for: .reviewer, pieces: []),
                subject: 1, book: 4),
            4)
        XCTAssertEqual(
            PermitControl.lostHistory(
                forGranting: PermitControl.permit(for: .somePieces, pieces: ["ch1"]),
                subject: 1, book: 4),
            4,
            "an author of some pieces narrows the book too")
        XCTAssertEqual(
            PermitControl.lostHistory(
                forGranting: PermitControl.permit(for: .wholeBook, pieces: []),
                subject: 1, book: 4),
            1,
            "a promotion to the whole book sweeps this person alone")
    }
}
