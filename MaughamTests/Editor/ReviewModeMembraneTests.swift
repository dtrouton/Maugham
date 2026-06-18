import XCTest
@testable import Maugham

final class ReviewModeMembraneTests: XCTestCase {
    func test_reviewMode_disallowsTextMutation() {
        XCTAssertFalse(EditorEditPolicy.allowsTextMutation(isReviewMode: true))
        XCTAssertTrue(EditorEditPolicy.allowsTextMutation(isReviewMode: false))
    }
}
