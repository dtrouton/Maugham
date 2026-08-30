import XCTest
@testable import Maugham

final class TranslationPreflightTests: XCTestCase {

    func test_wordCountSplitsOnWhitespaceLikeTheCheckpointsOwnCount() {
        XCTAssertEqual(TranslationPreflight.wordCount("The fog came in."), 4)
        XCTAssertEqual(TranslationPreflight.wordCount("one\n\ntwo   three\tfour"), 4)
        XCTAssertEqual(TranslationPreflight.wordCount(""), 0)
        XCTAssertEqual(TranslationPreflight.wordCount("   "), 0)
    }

    /// The budget is source words plus translated words of every document in
    /// the set — the two texts every leg is briefed with.
    func test_theBudgetSumsSourceAndTranslationAcrossTheSet() throws {
        XCTAssertEqual(TranslationPreflight.sum(source: ["a b c", "d e"], translations: ["x y", nil]), 7)
        XCTAssertEqual(TranslationPreflight.sum(source: [], translations: []), 0)
    }
}
