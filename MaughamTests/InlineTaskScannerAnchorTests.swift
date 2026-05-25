import XCTest
@testable import Maugham

/// Tests for Task 3 of the task-anchors milestone — the markdown checkbox
/// and Fountain boneyard scanners must surface an optional `anchorId`
/// alongside the body, and the body capture must NOT include the anchor
/// markup or its leading whitespace.
final class InlineTaskScannerAnchorTests: XCTestCase {

    // MARK: - MarkdownCheckboxScanner

    func test_markdownScanner_recognizesAnchor() {
        let match = MarkdownCheckboxScanner.match(
            "- [ ] tighten this <!--t-9k2x6a-->")
        XCTAssertEqual(match?.body, "tighten this")
        XCTAssertEqual(match?.anchorId, "9k2x6a")
    }

    func test_markdownScanner_unanchoredLine_anchorIdIsNil() {
        let match = MarkdownCheckboxScanner.match("- [ ] tighten this")
        XCTAssertEqual(match?.body, "tighten this")
        XCTAssertNil(match?.anchorId)
    }

    func test_markdownScanner_anchorMustBeAtEndOfLine() {
        // Trailing content after anchor is not allowed (well-formed lines
        // only have anchor at very end after a single space). The whole tail
        // — anchor markup and trailing text — falls into the body capture,
        // and anchorId stays nil.
        let match = MarkdownCheckboxScanner.match(
            "- [ ] tighten this <!--t-9k2x6a--> extra stuff")
        XCTAssertNil(match?.anchorId)
    }

    func test_fountainScanner_matchAll_recognizesAnchors() {
        let para = "First [[todo: a]]<!--t-aaaaaa--> middle [[done: b]]<!--t-bbbbbb--> last."
        let matches = FountainBoneyardScanner.matchAll(para)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].body, "a")
        XCTAssertEqual(matches[0].anchorId, "aaaaaa")
        XCTAssertEqual(matches[0].done, false)
        XCTAssertEqual(matches[1].body, "b")
        XCTAssertEqual(matches[1].anchorId, "bbbbbb")
        XCTAssertEqual(matches[1].done, true)
    }

    func test_fountainScanner_unanchoredTodo_anchorIdIsNil() {
        let matches = FountainBoneyardScanner.matchAll("[[todo: x]]")
        XCTAssertEqual(matches.count, 1)
        XCTAssertNil(matches[0].anchorId)
    }

    // MARK: - Additional regressions

    func test_markdownScanner_bodyExcludesAnchorAndItsLeadingSpace() {
        let match = MarkdownCheckboxScanner.match("- [ ] tighten this <!--t-9k2x6a-->")
        XCTAssertEqual(match?.body, "tighten this",
            "body must not include the trailing space or anchor markup")
    }

    func test_markdownScanner_lineContaining_FoutainBracket_doesNotMatch() {
        // A line like "- [ ] foo [[todo: bar]]<!--t-X-->" should match
        // markdown checkbox at line start; the inner [[todo:]] is just body
        // text from the markdown scanner's perspective.
        // (FountainBoneyardScanner picks up the inner [[todo:]] separately.)
        let match = MarkdownCheckboxScanner.match(
            "- [ ] mention [[todo: stale ref]] in body")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.body, "mention [[todo: stale ref]] in body")
        XCTAssertNil(match?.anchorId)
    }

    func test_fountainScanner_multipleAnchored_allCaptured() {
        let para = "First [[todo: a]]<!--t-aaaaaa--> middle [[done: b]]<!--t-bbbbbb--> last."
        let matches = FountainBoneyardScanner.matchAll(para)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].anchorId, "aaaaaa")
        XCTAssertEqual(matches[1].anchorId, "bbbbbb")
    }

    func test_fountainScanner_mixedAnchoredAndUnanchored() {
        let para = "[[todo: anchored]]<!--t-aaaaaa--> and [[todo: unanchored]] here."
        let matches = FountainBoneyardScanner.matchAll(para)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].anchorId, "aaaaaa")
        XCTAssertNil(matches[1].anchorId)
    }

    func test_markdownScanner_anchorIdRoundTripsToTaskAnchorIDParse() {
        let match = MarkdownCheckboxScanner.match(
            "- [ ] foo <!--t-9k2x6a-->")
        // The scanner-captured id must parse identically via TaskAnchorID's
        // own parseComment — sanity that the alphabets agree.
        XCTAssertEqual(match?.anchorId, "9k2x6a")
        XCTAssertEqual(TaskAnchorID.parseComment("<!--t-9k2x6a-->"), match?.anchorId)
    }
}
