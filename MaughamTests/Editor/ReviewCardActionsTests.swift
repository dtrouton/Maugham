import XCTest
import MaughamCore
@testable import Maugham

/// The interactive margin card's per-kind / per-ownership action set must mirror
/// `AnnotationsPane.actionRow` (disposition) + `ownAffordances` (edit/delete).
final class ReviewCardActionsTests: XCTestCase {

    func test_comment_notOwn_acceptStetArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .comment, isOwn: false, posture: nil),
            [.accept, .stet, .archive])
    }

    func test_suggestedChange_notOwn_acceptRejectStetArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .suggestedChange, isOwn: false, posture: nil),
            [.accept, .reject, .stet, .archive])
    }

    func test_query_notOwn_replyStetArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .query, isOwn: false, posture: nil),
            [.reply, .stet, .archive])
    }

    func test_craftNote_notOwn_acceptRejectStetArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .craftNote, isOwn: false, posture: nil),
            [.accept, .reject, .stet, .archive])
    }

    func test_own_appendsEditAndDelete() {
        // Own annotations add Edit + Delete on top of the kind's disposition set.
        XCTAssertEqual(
            ReviewCardActions.actions(for: .comment, isOwn: true, posture: nil),
            [.accept, .stet, .archive, .edit, .delete])
        XCTAssertEqual(
            ReviewCardActions.actions(for: .query, isOwn: true, posture: nil),
            [.reply, .stet, .archive, .edit, .delete])
        XCTAssertEqual(
            ReviewCardActions.actions(for: .suggestedChange, isOwn: true, posture: nil),
            [.accept, .reject, .stet, .archive, .edit, .delete])
    }

    /// M3 P2: stet is a resolution, so it reaches the margin card wherever
    /// Archive does — the card and the pane offer the same four answers.
    func test_stetIsOfferedForEveryKindThatOffersArchive() {
        for kind in AnnotationKind.allCases {
            let actions = ReviewCardActions.actions(for: kind, isOwn: false, posture: nil)
            XCTAssertTrue(actions.contains(.archive), "\(kind) offers Archive")
            XCTAssertTrue(actions.contains(.stet), "\(kind) must also offer Stet")
        }
    }

    /// Triage is deliberately NOT here: it is a queue verb (how the writer plans
    /// a pass over many notes), not a margin verb. The card answers one note in
    /// front of the writer; the pane sorts the pile.
    func test_triageIsNotAMarginCardAction() {
        for kind in AnnotationKind.allCases {
            for isOwn in [true, false] {
                let labels = ReviewCardActions.actions(for: kind, isOwn: isOwn, posture: nil)
                    .map { $0.label(for: kind).lowercased() }
                XCTAssertFalse(labels.contains { ["do", "decline", "discuss"].contains($0) },
                               "\(kind)/isOwn=\(isOwn) must not carry a triage mark")
            }
        }
    }

    func test_acceptLabel_isGotIt_forComment_acceptOtherwise() {
        XCTAssertEqual(ReviewCardAction.accept.label(for: .comment), "Got it")
        XCTAssertEqual(ReviewCardAction.accept.label(for: .suggestedChange), "Accept")
        XCTAssertEqual(ReviewCardAction.accept.label(for: .craftNote), "Accept")
    }

    /// The one user-facing word for the verb is "Stet" — the pane's button, the
    /// card's tooltip and the undo action name all say it (three phrasings
    /// existed mid-milestone; this pins the card's half).
    func test_stetLabelIsTheOneWord() {
        for kind in AnnotationKind.allCases {
            XCTAssertEqual(ReviewCardAction.stet.label(for: kind), "Stet")
        }
    }

    // MARK: - The posture (P3c Task 5)

    private func posture(_ permit: Permit, in cls: DocumentClass) -> Posture {
        Posture(LocalWritePermit(permit: permit, actor: .author, documentClass: cls))
    }

    /// A reviewer's card: no disposition for any kind, and Edit / Delete of
    /// HER note stay — the reviewer row.
    func test_aReviewersCardOffersNoDispositionAndKeepsHerOwnEditAndDelete() {
        let reviewer = posture(.reviewer, in: .piece("doc-a"))
        for kind in AnnotationKind.allCases {
            XCTAssertEqual(
                ReviewCardActions.actions(for: kind, isOwn: false, posture: reviewer), [],
                "\(kind): nothing to press on somebody else's note")
            XCTAssertEqual(
                ReviewCardActions.actions(for: kind, isOwn: true, posture: reviewer),
                [.edit, .delete], "\(kind): her own note keeps Edit and Delete")
        }
    }

    /// The other direction: in her own piece every verb comes back, exactly
    /// the card with no posture at all; outside it, none of them.
    func test_aPiecesAuthorsCardFollowsTheDocumentsPosture() {
        let mine = posture(.author(.pieces(["doc-a"])), in: .piece("doc-a"))
        let theirs = posture(.author(.pieces(["doc-a"])), in: .piece("doc-b"))
        for kind in AnnotationKind.allCases {
            for isOwn in [false, true] {
                XCTAssertEqual(
                    ReviewCardActions.actions(for: kind, isOwn: isOwn, posture: mine),
                    ReviewCardActions.actions(for: kind, isOwn: isOwn, posture: nil),
                    "\(kind)/isOwn=\(isOwn): her own piece offers every verb")
                XCTAssertEqual(
                    ReviewCardActions.actions(for: kind, isOwn: isOwn, posture: theirs),
                    isOwn ? [.edit, .delete] : [],
                    "\(kind)/isOwn=\(isOwn): somebody else's piece offers none")
            }
        }
    }
}
