import XCTest
@testable import MaughamCore

final class TranslationConstructSkeletonTests: XCTestCase {
    func test_matchingSkeleton_noWarnings() {
        XCTAssertTrue(ConstructSkeleton.warnings(
            source: "> **Doctor:** How are you feeling?",
            translation: "> **Doctora:** ¿Cómo se siente?", paragraphId: "aaaa").isEmpty)
    }
    func test_lostStrong_warns() {
        let w = ConstructSkeleton.warnings(
            source: "> **Doctor:** How are you feeling?",
            translation: "> Doctora: ¿Cómo se siente?", paragraphId: "aaaa")
        XCTAssertFalse(w.isEmpty)
        XCTAssertTrue(w[0].contains("aaaa"))
    }
    func test_blockKindChange_warns() {
        XCTAssertFalse(ConstructSkeleton.warnings(
            source: "## Session Two", translation: "Sesión dos", paragraphId: "bbbb").isEmpty)
    }
}
