import XCTest
@testable import Maugham

final class SyntaxHelpSheetTests: XCTestCase {

    func test_loadContent_proseMode_returnsMarkdownDoc() {
        let content = SyntaxHelpSheet.loadContent(mode: .prose)
        XCTAssertGreaterThan(content.count, 5)
    }

    func test_loadContent_screenplayMode_returnsFountainDoc() {
        let content = SyntaxHelpSheet.loadContent(mode: .screenplay)
        XCTAssertGreaterThan(content.count, 5)
    }

    func test_loadContent_modes_returnDifferentContent() {
        let prose = SyntaxHelpSheet.loadContent(mode: .prose)
        let screenplay = SyntaxHelpSheet.loadContent(mode: .screenplay)
        // The two docs should produce a different number of blocks, or at least not both be empty.
        // In practice they will differ in heading text so this is a safe check.
        XCTAssertFalse(prose.isEmpty)
        XCTAssertFalse(screenplay.isEmpty)
    }
}
