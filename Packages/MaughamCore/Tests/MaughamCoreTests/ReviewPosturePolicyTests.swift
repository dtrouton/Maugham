import XCTest
@testable import MaughamCore

final class ReviewPosturePolicyTests: XCTestCase {

    // Author, not manually reviewing → editable: no render, no lock.
    func test_author_notManual_isEditable() {
        let e = ReviewPosturePolicy.effective(role: .author, manualReview: false)
        XCTAssertFalse(e.isReviewMode)
        XCTAssertFalse(e.lockEditing)
    }

    // Author who manually entered review → render on, but NOT locked: they may
    // leave review and edit freely.
    func test_author_manual_showsReviewButNotLocked() {
        let e = ReviewPosturePolicy.effective(role: .author, manualReview: true)
        XCTAssertTrue(e.isReviewMode)
        XCTAssertFalse(e.lockEditing)
    }

    // Reviewer → review render FORCED on and editing LOCKED, regardless of the
    // manual toggle. ⌘⌥R can never unlock a reviewer.
    func test_reviewer_notManual_isForcedReviewAndLocked() {
        let e = ReviewPosturePolicy.effective(role: .reviewer, manualReview: false)
        XCTAssertTrue(e.isReviewMode)
        XCTAssertTrue(e.lockEditing)
    }

    func test_reviewer_manual_staysForcedReviewAndLocked() {
        // A reviewer toggling ⌘⌥R off (manualReview false here would be the same
        // as a fast off-toggle) must STILL be locked — the manual flag cannot
        // unlock editing for a non-author.
        let off = ReviewPosturePolicy.effective(role: .reviewer, manualReview: false)
        let on = ReviewPosturePolicy.effective(role: .reviewer, manualReview: true)
        XCTAssertTrue(off.lockEditing)
        XCTAssertTrue(on.lockEditing)
        XCTAssertTrue(off.isReviewMode)
        XCTAssertTrue(on.isReviewMode)
    }

    // Unknown (still resolving) → cautious: review render on + locked until the
    // real role resolves, so author affordances don't flash then get yanked.
    func test_unknown_isCautiousReviewAndLocked() {
        let e = ReviewPosturePolicy.effective(role: .unknown, manualReview: false)
        XCTAssertTrue(e.isReviewMode)
        XCTAssertTrue(e.lockEditing)
        // Manual toggle can't loosen unknown either.
        let m = ReviewPosturePolicy.effective(role: .unknown, manualReview: true)
        XCTAssertTrue(m.lockEditing)
    }
}
