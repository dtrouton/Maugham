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

    /// Audit A5: `![alt](url)` image syntax was mis-tokenizing its
    /// `[alt](url)` tail as a link.
    func test_imageSyntax_producesNoLinkToken() {
        let tokens = tokenizer.tokenize("![alt](x.png)")
        XCTAssertFalse(tokens.contains { if case .link = $0.kind { return true }; return false },
                       "image alt/url tail should not be link-styled")
    }

    func test_plainLink_stillLinkStyled() {
        let tokens = tokenizer.tokenize("[a](b)")
        XCTAssertTrue(tokens.contains { $0.kind == .link(href: "b") })
    }

    func test_imageFollowedByLink_onlyLinkIsTokenized() {
        let tokens = tokenizer.tokenize("a ![i](u) b [l](v)")
        let linkTokens = tokens.filter { if case .link = $0.kind { return true }; return false }
        XCTAssertEqual(linkTokens.count, 1)
        XCTAssertEqual(linkTokens.first?.kind, .link(href: "v"))
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

    func test_tripleAsterisk_alone_producesHR() {
        let tokens = tokenizer.tokenize("***")
        XCTAssertTrue(tokens.contains { $0.kind == .horizontalRule })
    }

    func test_tripleHash_alone_producesHR() {
        let tokens = tokenizer.tokenize("###")
        XCTAssertTrue(tokens.contains { $0.kind == .horizontalRule })
    }

    func test_headingStillWorks_withTripleHashPrefix() {
        let tokens = tokenizer.tokenize("# H")
        XCTAssertTrue(tokens.contains { $0.kind == .heading(level: 1) })
    }

    func test_tripleAsteriskEmphasis_stillEmphasis_notHR() {
        let tokens = tokenizer.tokenize("***x***")
        let emph = tokens.first { if case .emphasis = $0.kind { return true }; return false }
        XCTAssertNotNil(emph)
        XCTAssertFalse(tokens.contains { $0.kind == .horizontalRule })
    }

    func test_quadHash_alone_notHR() {
        let tokens = tokenizer.tokenize("####")
        XCTAssertFalse(tokens.contains { $0.kind == .horizontalRule })
    }

    func test_tripleAsteriskLine_insideProse_isHR_noEmphasisSpanningIt() {
        let text = "text\n***\ntext"
        let tokens = MarkdownTokenizer().tokenize(text)
        XCTAssertTrue(tokens.contains { $0.kind == .horizontalRule })
        let nsText = text as NSString
        let hrRange = nsText.range(of: "***")
        XCTAssertFalse(tokens.contains {
            guard case .emphasis = $0.kind else { return false }
            return $0.range.intersection(hrRange) != nil
        }, "emphasis run must not span the scene-break line")
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

    func test_emphasisSpansHardBreakWithinParagraph_stanzaCase() {
        let text = "She read it. *How could he\npossibly have known?* Odd."
        let tokens = MarkdownTokenizer().tokenize(text)
        // one italic run covering "How could he\npossibly have known?"
        XCTAssertTrue(tokens.contains { $0.kind == .emphasis(.italic)
            && (text as NSString).substring(with: $0.range)
                == "How could he\npossibly have known?" })
    }
    func test_emphasisDoesNotCrossBlankLine() {
        let tokens = MarkdownTokenizer().tokenize("*open\n\nclose*")
        XCTAssertFalse(tokens.contains { if case .emphasis = $0.kind { return true }
                                         else { return false } })
    }
    func test_strikethrough_stylesInProse() {
        let text = "keep ~~cut this~~ keep"
        let tokens = MarkdownTokenizer().tokenize(text)
        XCTAssertTrue(tokens.contains { $0.kind == .emphasis(.strikethrough)
            && (text as NSString).substring(with: $0.range) == "cut this" })
    }
    func test_escapedAsterisk_backslashFades_noEmphasis() {
        let text = #"\*literal\*"#
        let tokens = MarkdownTokenizer().tokenize(text)
        XCTAssertFalse(tokens.contains { if case .emphasis = $0.kind { return true }
                                         else { return false } })
        // backslashes fade as syntax punctuation
        XCTAssertTrue(tokens.contains { $0.kind == .syntaxPunctuation
            && $0.range == NSRange(location: 0, length: 1) })
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
