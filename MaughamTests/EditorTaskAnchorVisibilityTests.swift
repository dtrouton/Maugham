import XCTest
@testable import Maugham

final class EditorTaskAnchorVisibilityTests: XCTestCase {

    // MARK: - Markdown tokenizer

    func test_markdownTokenizer_emitsTaskBodyAndInvisibleAnchor() {
        let line = "- [ ] tighten this <!--t-9k2x6a-->"
        let tokens = MarkdownTokenizer().tokenize(line)
        let kinds = tokens.map(\.kind)
        XCTAssertTrue(kinds.contains { if case .checkbox = $0 { return true }; return false },
                      "expected checkbox token")
        XCTAssertTrue(kinds.contains { if case .taskBody = $0 { return true }; return false },
                      "expected taskBody token")
        XCTAssertTrue(kinds.contains { if case .invisibleAnchor = $0 { return true }; return false },
                      "expected invisibleAnchor token")
    }

    func test_markdownTokenizer_unanchoredCheckbox_noInvisibleAnchorEmitted() {
        let line = "- [ ] tighten this"
        let tokens = MarkdownTokenizer().tokenize(line)
        let kinds = tokens.map(\.kind)
        XCTAssertTrue(kinds.contains { if case .checkbox = $0 { return true }; return false },
                      "expected checkbox token")
        XCTAssertTrue(kinds.contains { if case .taskBody = $0 { return true }; return false },
                      "expected taskBody token for unanchored checkbox")
        XCTAssertFalse(kinds.contains { if case .invisibleAnchor = $0 { return true }; return false },
                       "expected no invisibleAnchor for unanchored checkbox")
    }

    func test_taskBodyTokenRange_excludesBracketAndAnchor() {
        // For "- [ ] foo <!--t-9k2x6a-->", taskBody range should cover
        // just "foo" (not the leading "- [ ] " nor the trailing anchor span).
        let line = "- [ ] foo <!--t-9k2x6a-->"
        let tokens = MarkdownTokenizer().tokenize(line)
        guard let bodyToken = tokens.first(where: {
            if case .taskBody = $0.kind { return true }; return false
        }) else {
            XCTFail("no taskBody token")
            return
        }
        let ns = line as NSString
        let bodyText = ns.substring(with: bodyToken.range)
        XCTAssertEqual(bodyText, "foo")
    }

    func test_invisibleAnchorTokenRange_coversAnchorSpanWithLeadingSpace() {
        let line = "- [ ] foo <!--t-9k2x6a-->"
        let tokens = MarkdownTokenizer().tokenize(line)
        guard let anchorToken = tokens.first(where: {
            if case .invisibleAnchor = $0.kind { return true }; return false
        }) else {
            XCTFail("no invisibleAnchor token")
            return
        }
        let ns = line as NSString
        let anchorText = ns.substring(with: anchorToken.range)
        // The anchor token includes the leading space: " <!--t-9k2x6a-->"
        XCTAssertEqual(anchorText, " <!--t-9k2x6a-->")
    }

    func test_markdownTokenizer_checkedCheckboxWithAnchor_emitsTaskBodyAndAnchor() {
        let line = "- [x] done task <!--t-abcdef-->"
        let tokens = MarkdownTokenizer().tokenize(line)
        let kinds = tokens.map(\.kind)
        XCTAssertTrue(kinds.contains {
            if case .checkbox(let checked) = $0, checked { return true }; return false
        }, "expected checked checkbox token")
        XCTAssertTrue(kinds.contains { if case .taskBody = $0 { return true }; return false })
        XCTAssertTrue(kinds.contains { if case .invisibleAnchor = $0 { return true }; return false })
    }

    // MARK: - Fountain tokenizer (via ScreenplayMode.tokenize)

    func test_screenplayMode_emitsTaskBodyForFountainTodo() {
        let mode = ScreenplayMode()
        let tokens = mode.tokenize("[[todo: tighten this]]\n")
        XCTAssertTrue(tokens.contains { if case .taskBody = $0.kind { return true }; return false },
                      "expected taskBody token for [[todo:]] without anchor")
    }

    func test_screenplayMode_emitsTaskBodyAndInvisibleAnchorForAnchoredFountainTodo() {
        let mode = ScreenplayMode()
        let tokens = mode.tokenize("[[todo: tighten]]<!--t-9k2x6a-->\n")
        let kinds = tokens.map(\.kind)
        XCTAssertTrue(kinds.contains { if case .taskBody = $0 { return true }; return false },
                      "expected taskBody token")
        XCTAssertTrue(kinds.contains { if case .invisibleAnchor = $0 { return true }; return false },
                      "expected invisibleAnchor token")
    }

    func test_screenplayMode_invisibleAnchorRange_coversAnchorSpanNoleadingSpace() {
        // Fountain anchors are glued to `]]` — no leading space.
        let mode = ScreenplayMode()
        let line = "[[todo: foo]]<!--t-9k2x6a-->"
        let tokens = mode.tokenize(line + "\n")
        guard let anchorToken = tokens.first(where: {
            if case .invisibleAnchor = $0.kind { return true }; return false
        }) else {
            XCTFail("no invisibleAnchor token")
            return
        }
        let ns = (line + "\n") as NSString
        let anchorText = ns.substring(with: anchorToken.range)
        XCTAssertEqual(anchorText, "<!--t-9k2x6a-->")
    }
}
