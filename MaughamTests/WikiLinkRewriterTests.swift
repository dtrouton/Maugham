import XCTest
@testable import Maugham

final class WikiLinkRewriterTests: XCTestCase {

    func test_simpleReplacement() {
        let result = WikiLinkRewriter.rewrite(
            body: "Margaret returns to [[Chapter 1]] for context.",
            oldTitle: "Chapter 1",
            newTitle: "The Opening")
        XCTAssertEqual(
            result,
            "Margaret returns to [[The Opening]] for context.")
    }

    func test_caseInsensitiveMatch() {
        let result = WikiLinkRewriter.rewrite(
            body: "See [[chapter 1]] and [[CHAPTER 1]].",
            oldTitle: "Chapter 1",
            newTitle: "The Opening")
        XCTAssertEqual(
            result,
            "See [[The Opening]] and [[The Opening]].")
    }

    func test_whitespaceInsideBracketsTrimmed() {
        let result = WikiLinkRewriter.rewrite(
            body: "Reference [[  Chapter 1  ]] here.",
            oldTitle: "Chapter 1",
            newTitle: "Opening")
        XCTAssertEqual(result, "Reference [[Opening]] here.")
    }

    func test_unrelatedWikiLinksUnchanged() {
        let result = WikiLinkRewriter.rewrite(
            body: "Links to [[Chapter 1]] and [[Chapter 2]] both.",
            oldTitle: "Chapter 1",
            newTitle: "Opening")
        XCTAssertEqual(
            result,
            "Links to [[Opening]] and [[Chapter 2]] both.")
    }

    func test_noWikiLinks_returnsNil() {
        let result = WikiLinkRewriter.rewrite(
            body: "No links in this body.",
            oldTitle: "Chapter 1",
            newTitle: "Opening")
        XCTAssertNil(result)
    }

    func test_noMatchingWikiLink_returnsNil() {
        let result = WikiLinkRewriter.rewrite(
            body: "Has [[Chapter 2]] only.",
            oldTitle: "Chapter 1",
            newTitle: "Opening")
        XCTAssertNil(result)
    }

    func test_multipleSameLinkAllReplaced() {
        let result = WikiLinkRewriter.rewrite(
            body: "[[A]] and [[A]] and [[A]].",
            oldTitle: "A",
            newTitle: "B")
        XCTAssertEqual(result, "[[B]] and [[B]] and [[B]].")
    }

    func test_emptyOldTitle_returnsNil() {
        let result = WikiLinkRewriter.rewrite(
            body: "[[Foo]]",
            oldTitle: "",
            newTitle: "Bar")
        XCTAssertNil(result)
    }

    func test_newTitleWithSpaces_preservedExactly() {
        let result = WikiLinkRewriter.rewrite(
            body: "Visit [[Old Name]] today.",
            oldTitle: "Old Name",
            newTitle: "Brand New Title With Many Words")
        XCTAssertEqual(
            result,
            "Visit [[Brand New Title With Many Words]] today.")
    }
}
