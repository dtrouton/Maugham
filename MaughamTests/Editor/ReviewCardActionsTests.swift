import XCTest
import MaughamCore
@testable import Maugham

/// The interactive margin card's per-kind / per-ownership action set must mirror
/// `AnnotationsPane.actionRow` (disposition) + `ownAffordances` (edit/delete).
final class ReviewCardActionsTests: XCTestCase {

    func test_comment_notOwn_acceptAndArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .comment, isOwn: false),
            [.accept, .archive])
    }

    func test_suggestedChange_notOwn_acceptRejectArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .suggestedChange, isOwn: false),
            [.accept, .reject, .archive])
    }

    func test_query_notOwn_replyAndArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .query, isOwn: false),
            [.reply, .archive])
    }

    func test_craftNote_notOwn_acceptRejectArchive() {
        XCTAssertEqual(
            ReviewCardActions.actions(for: .craftNote, isOwn: false),
            [.accept, .reject, .archive])
    }

    func test_own_appendsEditAndDelete() {
        // Own annotations add Edit + Delete on top of the kind's disposition set.
        XCTAssertEqual(
            ReviewCardActions.actions(for: .comment, isOwn: true),
            [.accept, .archive, .edit, .delete])
        XCTAssertEqual(
            ReviewCardActions.actions(for: .query, isOwn: true),
            [.reply, .archive, .edit, .delete])
        XCTAssertEqual(
            ReviewCardActions.actions(for: .suggestedChange, isOwn: true),
            [.accept, .reject, .archive, .edit, .delete])
    }

    func test_acceptLabel_isGotIt_forComment_acceptOtherwise() {
        XCTAssertEqual(ReviewCardAction.accept.label(for: .comment), "Got it")
        XCTAssertEqual(ReviewCardAction.accept.label(for: .suggestedChange), "Accept")
        XCTAssertEqual(ReviewCardAction.accept.label(for: .craftNote), "Accept")
    }
}
