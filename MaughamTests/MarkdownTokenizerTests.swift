import XCTest
import MaughamCore
@testable import Maugham

final class MarkdownTokenizerTests: XCTestCase {
    private let tokenizer = MarkdownTokenizer()

    func testBoldItalicTripleAsterisk() {
        let tokens = MarkdownTokenizer().tokenize("***word***")
        let emph = tokens.first { if case .emphasis = $0.kind { return true }; return false }
        XCTAssertNotNil(emph)
        if case .emphasis(let traits)? = emph?.kind {
            XCTAssertEqual(traits, [.bold, .italic])
        }
        // The inner content is "word"; the six asterisks are syntaxPunctuation.
        XCTAssertEqual((("***word***" as NSString)).substring(with: emph!.range), "word")
    }

    func testNestedEmphasisInProse() {
        let tokens = MarkdownTokenizer().tokenize("*a **b** a*")
        let bothTrait = tokens.first {
            if case .emphasis(let t) = $0.kind { return t == [.italic, .bold] }
            return false
        }
        XCTAssertNotNil(bothTrait, "middle 'b' should be bold+italic")
    }

    func test_emptyText_producesNoTokens() {
        XCTAssertEqual(tokenizer.tokenize(""), [])
    }

    func test_plainText_producesPlainToken() {
        let tokens = tokenizer.tokenize("just words")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .plain)
        XCTAssertEqual(tokens[0].range, NSRange(location: 0, length: 10))
    }

    func test_h1_producesHeadingAndPunctuation() {
        let tokens = tokenizer.tokenize("# Hello")
        let kinds = tokens.map(\.kind)
        XCTAssertTrue(kinds.contains(.syntaxPunctuation))
        XCTAssertTrue(kinds.contains(.heading(level: 1)))
    }

    func test_h3_producesHeading3() {
        let tokens = tokenizer.tokenize("### Hello")
        XCTAssertTrue(tokens.contains { $0.kind == .heading(level: 3) })
    }

    func test_bold_producesEmphasisStrongAndPunctuation() {
        let tokens = tokenizer.tokenize("**bold**")
        let kinds = tokens.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .syntaxPunctuation }.count, 2)
        XCTAssertTrue(kinds.contains(.emphasis([.bold])))
    }

    func test_italic_producesEmphasisAndPunctuation() {
        let tokens = tokenizer.tokenize("*italic*")
        let kinds = tokens.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .syntaxPunctuation }.count, 2)
        XCTAssertTrue(kinds.contains(.emphasis([.italic])))
    }

    func test_inlineCode_producesCodeAndPunctuation() {
        let tokens = tokenizer.tokenize("`code`")
        let kinds = tokens.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .syntaxPunctuation }.count, 2)
        XCTAssertTrue(kinds.contains(.code))
    }

    func test_link_producesLinkAndPunctuation() {
        let tokens = tokenizer.tokenize("[hi](https://x.com)")
        let kinds = tokens.map(\.kind)
        XCTAssertTrue(kinds.contains(.link(href: "https://x.com")))
        XCTAssertTrue(kinds.contains(.syntaxPunctuation))
    }

    func test_listMarker_producesListMarker() {
        let tokens = tokenizer.tokenize("- item")
        XCTAssertTrue(tokens.contains { $0.kind == .listMarker })
    }

    func test_blockquote_producesBlockquote() {
        let tokens = tokenizer.tokenize("> quoted")
        XCTAssertTrue(tokens.contains { $0.kind == .blockquote })
    }

    func test_horizontalRule_producesHR() {
        let tokens = tokenizer.tokenize("---")
        XCTAssertTrue(tokens.contains { $0.kind == .horizontalRule })
    }

    func test_multilineDocument_tokenizesEachLine() {
        let md = """
        # Title

        Some **bold** text and a [link](https://x.com).
        """
        let tokens = tokenizer.tokenize(md)
        let kinds = Set(tokens.map { String(describing: $0.kind) })
        XCTAssertTrue(kinds.contains { $0.contains("heading") })
        XCTAssertTrue(kinds.contains { $0.contains("emphasis") })
        XCTAssertTrue(kinds.contains { $0.contains("link") })
    }

    func testEmphasisDoesNotSpanLineBreak() {
        // An unclosed * on one line must not emphasize across the newline.
        let tokens = MarkdownTokenizer().tokenize("*foo\nbar*")
        let hasEmphasis = tokens.contains { if case .emphasis = $0.kind { return true }; return false }
        XCTAssertFalse(hasEmphasis, "emphasis must not span a line break")
    }

    func testEmphasisStillWorksWithinOneLineOfMultiline() {
        // Same-line emphasis on line 2 still works.
        let tokens = MarkdownTokenizer().tokenize("plain line\nsome **bold** here")
        let emph = tokens.first { if case .emphasis(let t) = $0.kind { return t == [.bold] }; return false }
        XCTAssertNotNil(emph)
        XCTAssertEqual(("plain line\nsome **bold** here" as NSString).substring(with: emph!.range), "bold")
    }

    func test_tokensAreNonOverlapping_andSortedByLocation() {
        let md = "# A\n\n**b** and *c*"
        let tokens = tokenizer.tokenize(md)
        let sorted = tokens.sorted { $0.range.location < $1.range.location }
        XCTAssertEqual(tokens, sorted, "tokens must be in source order")
        for i in 1..<tokens.count {
            let prev = tokens[i - 1].range
            let cur = tokens[i].range
            XCTAssertGreaterThanOrEqual(cur.location, prev.location + prev.length,
                                        "tokens must not overlap")
        }
    }
}
