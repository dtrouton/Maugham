import XCTest
@testable import Maugham

final class GuideMarkdownViewTests: XCTestCase {
    func test_parsesHeadingsParagraphsBulletsAndCode() {
        let md = """
        # Title
        Intro line.
        - first
        - second
        ```
        let x = 1
        ```
        """
        let blocks = GuideMarkdownView.parse(md)
        guard case .heading(let level, let text) = blocks[0] else { return XCTFail("expected heading") }
        XCTAssertEqual(level, 1); XCTAssertEqual(text, "Title")
        guard case .paragraph = blocks[1] else { return XCTFail("expected paragraph") }
        guard case .bullet = blocks[2] else { return XCTFail("expected bullet") }
        guard case .bullet = blocks[3] else { return XCTFail("expected bullet") }
        guard case .code(let code) = blocks[4] else { return XCTFail("expected code") }
        XCTAssertEqual(code, "let x = 1")
    }
}
