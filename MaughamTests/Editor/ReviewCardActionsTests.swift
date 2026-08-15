import XCTest
import MaughamCore
@testable import Maugham

/// The interactive margin card's per-kind / per-ownership action set must mirror
/// `AnnotationsPane.actionRow` (disposition) + `ownAffordances` (edit/delete).
final class ReviewCardActionsTests: XCTestCase {

    func test_comment_notOwn_acceptStetArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .comment, isOwn: false),
            [.accept, .stet, .archive])
    }

    func test_suggestedChange_notOwn_acceptRejectStetArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .suggestedChange, isOwn: false),
            [.accept, .reject, .stet, .archive])
    }

    func test_query_notOwn_replyStetArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .query, isOwn: false),
            [.reply, .stet, .archive])
    }

    func test_craftNote_notOwn_acceptRejectStetArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .craftNote, isOwn: false),
            [.accept, .reject, .stet, .archive])
    }

    func test_own_appendsEditAndDelete() {
        // Own annotations add Edit + Delete on top of the kind's disposition set.
        XCTAssertEqual(
            ReviewCardActions.actions(for: .comment, isOwn: true),
            [.accept, .stet, .archive, .edit, .delete])
        XCTAssertEqual(
            ReviewCardActions.actions(for: .query, isOwn: true),
            [.reply, .stet, .archive, .edit, .delete])
        XCTAssertEqual(
            ReviewCardActions.actions(for: .suggestedChange, isOwn: true),
            [.accept, .reject, .stet, .archive, .edit, .delete])
    }

    /// M3 P2: stet is a resolution, so it reaches the margin card wherever
    /// Archive does — the card and the pane offer the same four answers.
    func test_stetIsOfferedForEveryKindThatOffersArchive() {
        for kind in AnnotationKind.allCases {
            let actions = ReviewCardActions.actions(for: kind, isOwn: false)
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
                let labels = ReviewCardActions.actions(for: kind, isOwn: isOwn)
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
}
