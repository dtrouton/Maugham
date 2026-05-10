import XCTest
@testable import Maugham

final class SyntaxHelpSheetTests: XCTestCase {

    func test_loadContent_proseMode_returnsMarkdownDoc() {
        let content = SyntaxHelpSheet.loadContent(mode: .prose)
        XCTAssertGreaterThan(content.characters.count, 100)
    }

    func test_loadContent_screenplayMode_returnsFountainDoc() {
        let content = SyntaxHelpSheet.loadContent(mode: .screenplay)
        XCTAssertGreaterThan(content.characters.count, 100)
    }

    func test_loadContent_modes_returnDifferentContent() {
        let prose = SyntaxHelpSheet.loadContent(mode: .prose)
        let screenplay = SyntaxHelpSheet.loadContent(mode: .screenplay)
        XCTAssertNotEqual(String(prose.characters), String(screenplay.characters))
    }
}
