import XCTest
@testable import Maugham

final class WikiLinkTokenizerTests: XCTestCase {

    private let tokenizer = MarkdownTokenizer()

    private func wikiLinks(_ text: String) -> [(NSRange, String)] {
        tokenizer.tokenize(text).compactMap { tok in
            if case .wikiLink(let title) = tok.kind {
                return (tok.range, title)
            }
            return nil
        }
    }

    func test_simpleWikiLink_isTokenized() {
        let result = wikiLinks("See [[Chapter 2]] for context.")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].1, "Chapter 2")
    }

    func test_multipleWikiLinks_eachTokenized() {
        let result = wikiLinks("[[A]] and [[B]] and [[C]]")
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.1), ["A", "B", "C"])
    }

    func test_wikiLinkRangeIncludesBrackets() {
        let result = wikiLinks("x [[Foo]] y")
        XCTAssertEqual(result.count, 1)
        let nsText = "x [[Foo]] y" as NSString
        let range = result[0].0
        XCTAssertEqual(nsText.substring(with: range), "[[Foo]]")
    }

    func test_titleTrimmed() {
        let result = wikiLinks("[[  Spacious Title  ]]")
        XCTAssertEqual(result[0].1, "Spacious Title")
    }

    func test_newlineInsideBracketsBreaksMatch() {
        let result = wikiLinks("[[Foo\nBar]]")
        XCTAssertEqual(result.count, 0)
    }

    func test_singleBracketsNotMatched() {
        let result = wikiLinks("[Foo] bar")
        XCTAssertEqual(result.count, 0)
    }

    func test_emptyBracketsNotMatched() {
        let result = wikiLinks("[[]]")
        XCTAssertEqual(result.count, 0)
    }
}
