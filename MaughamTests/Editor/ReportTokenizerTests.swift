import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// The report elements in the prose tokenizer (plan 3a Task 2): tables,
/// footnotes, citations, cross-references, figure lines and `{#…}` labels.
/// Each element is claimed as its own `Token.Kind`, styled quietly by
/// `ProseMode`, and the Fountain mode never sees any of it.
final class ReportTokenizerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private let tokenizer = MarkdownTokenizer()

    /// The source text of every token of `kind`, in token order.
    private func texts(_ kind: Token.Kind, in text: String) -> [String] {
        let ns = text as NSString
        return tokenizer.tokenize(text)
            .filter { $0.kind == kind }
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - Tables

    private let table = """
    | Name | Year |
    |:-----|-----:|
    | Ada | 1843 |
    Table: Engines of note {#tbl:engines}
    """

    func test_tablePipesAndDelimiterRowAreTableSyntax() {
        let syntax = texts(.tableSyntax, in: table)
        // 3 pipes on the header, the whole delimiter row, 3 pipes on the body row.
        XCTAssertEqual(syntax.filter { $0 == "|" }.count, 6)
        XCTAssertTrue(syntax.contains("|:-----|-----:|"))
    }

    func test_tableHeaderCellsAreTableHeader() {
        XCTAssertEqual(texts(.tableHeader, in: table), ["Name", "Year"])
    }

    func test_bodyCellsAreNotHeader() {
        XCTAssertFalse(texts(.tableHeader, in: table).contains("Ada"))
    }

    func test_tableCaptionLineIsCaption_andItsLabelIsAnAttributeBlock() {
        XCTAssertEqual(texts(.tableCaption, in: table), ["Table: Engines of note"])
        XCTAssertEqual(texts(.attributeBlock, in: table), ["{#tbl:engines}"])
    }

    func test_tableBlockCoversTheWholeTableIncludingItsCaption() {
        XCTAssertEqual(texts(.tableBlock, in: table), [table])
    }

    func test_tableBlockRangeContainingCaret() {
        let doc = "Intro.\n\n" + table + "\n\nAfter."
        let tokens = tokenizer.tokenize(doc)
        let tableStart = (doc as NSString).range(of: "| Name").location
        let expected = NSRange(location: tableStart, length: (table as NSString).length)
        // Inside, at the very start and at the very end (the caret after the
        // last character) all find the table.
        XCTAssertEqual(MarkdownTokenizer.tableBlockRange(containing: tableStart + 3, in: tokens), expected)
        XCTAssertEqual(MarkdownTokenizer.tableBlockRange(containing: tableStart, in: tokens), expected)
        XCTAssertEqual(MarkdownTokenizer.tableBlockRange(containing: NSMaxRange(expected), in: tokens), expected)
        XCTAssertNil(MarkdownTokenizer.tableBlockRange(containing: 2, in: tokens))
        XCTAssertNil(MarkdownTokenizer.tableBlockRange(
            containing: (doc as NSString).length - 1, in: tokens))
    }

    func test_tableDirectlyAfterProseWithNoBlankLineIsNotATable() {
        let text = "Some prose.\n| a | b |\n|---|---|\n| 1 | 2 |"
        XCTAssertTrue(texts(.tableSyntax, in: text).isEmpty)
        XCTAssertTrue(texts(.tableHeader, in: text).isEmpty)
        XCTAssertTrue(texts(.tableBlock, in: text).isEmpty)
    }

    func test_aRowStartingWithADashIsClaimedByTheTableNotTheListPass() {
        let text = "- | x |\n- | - |\n- | y |"
        let tokens = tokenizer.tokenize(text)
        XCTAssertFalse(tokens.contains { $0.kind == .listMarker },
                       "a table row starting `- |` must not read as a list item")
        XCTAssertEqual(texts(.tableSyntax, in: text).filter { $0 == "|" }.count, 4)
    }

    func test_anEscapedPipeIsNotTableSyntax() {
        let text = "| a \\| b | c |\n|---|---|"
        XCTAssertEqual(texts(.tableSyntax, in: text).filter { $0 == "|" }.count, 3)
        XCTAssertEqual(texts(.tableHeader, in: text), ["a \\| b", "c"])
    }

    func test_emphasisInsideABodyCellStillStyles() {
        let text = "| a | b |\n|---|---|\n| *x* | y |"
        XCTAssertTrue(tokenizer.tokenize(text).contains { $0.kind == .emphasis([.italic]) })
    }

    // MARK: - Footnotes

    func test_footnoteReference() {
        XCTAssertEqual(texts(.footnoteReference, in: "A claim.[^1] More."), ["[^1]"])
    }

    func test_footnoteDefinitionLabel() {
        let text = "Body.[^n2]\n\n[^n2]: The note itself."
        XCTAssertEqual(texts(.footnoteLabel, in: text), ["[^n2]:"])
        XCTAssertEqual(texts(.footnoteReference, in: text), ["[^n2]"])
    }

    func test_footnoteReferenceFollowedByParensIsNotALink() {
        let text = "See[^1](x) now."
        XCTAssertEqual(texts(.footnoteReference, in: text), ["[^1]"])
    }

    // MARK: - Citations and cross-references

    func test_citation() {
        XCTAssertEqual(texts(.citation, in: "As shown [@gartner2026, p. 12]."),
                       ["[@gartner2026, p. 12]"])
    }

    func test_citationFollowedByParensIsClaimedBeforeTheLinkPass() {
        let text = "As shown [@a](x)."
        XCTAssertEqual(texts(.citation, in: text), ["[@a]"])
        XCTAssertFalse(tokenizer.tokenize(text).contains {
            if case .link = $0.kind { return true }; return false
        })
    }

    func test_bareAndBracketedCrossReferences() {
        XCTAssertEqual(texts(.crossReference, in: "See @fig:revenue and [@tbl:engines]."),
                       ["@fig:revenue", "[@tbl:engines]"])
    }

    func test_emailAndBareHandleAreNotCrossReferences() {
        let text = "Write to sarah@fig:x.com or @sarah today."
        XCTAssertTrue(texts(.crossReference, in: text).isEmpty)
        XCTAssertTrue(texts(.citation, in: text).isEmpty)
    }

    func test_markersInsideBackticksStayCode() {
        let text = "Type `[@a] [^1] @fig:x` literally."
        XCTAssertTrue(texts(.citation, in: text).isEmpty)
        XCTAssertTrue(texts(.footnoteReference, in: text).isEmpty)
        XCTAssertTrue(texts(.crossReference, in: text).isEmpty)
        XCTAssertEqual(texts(.code, in: text), ["[@a] [^1] @fig:x"])
    }

    // MARK: - Figures and labels

    func test_figureLineSyntaxAndLabel() {
        let text = "![Revenue by year](../research/rev.png){#fig:revenue}"
        XCTAssertEqual(texts(.figureSyntax, in: text), ["![", "](../research/rev.png)"])
        XCTAssertEqual(texts(.attributeBlock, in: text), ["{#fig:revenue}"])
    }

    func test_figureWithoutLabel() {
        let text = "Before.\n\n![A chart](x.png)\n\nAfter."
        XCTAssertEqual(texts(.figureSyntax, in: text), ["![", "](x.png)"])
        XCTAssertTrue(texts(.attributeBlock, in: text).isEmpty)
    }

    func test_anImageInsideProseIsNotAFigure() {
        let text = "Look ![a](x.png) here."
        XCTAssertTrue(texts(.figureSyntax, in: text).isEmpty)
    }

    func test_headingLabelIsReclaimedAsAnAttributeBlock() {
        let text = "## Method {#sec:method}"
        XCTAssertEqual(texts(.attributeBlock, in: text), ["{#sec:method}"])
        XCTAssertEqual(texts(.heading(level: 2), in: text), ["Method"])
    }

    func test_headingWithAnInvalidLabelKeepsItAsHeadingText() {
        let text = "## Method {#eq:method}"
        XCTAssertTrue(texts(.attributeBlock, in: text).isEmpty)
        XCTAssertEqual(texts(.heading(level: 2), in: text), ["Method {#eq:method}"])
    }

    // MARK: - Invariants

    /// Tokens from the main stream never overlap; only the documented
    /// overlays (`taskBody`, `invisibleAnchor`, `checkbox` from `[[todo:]]`,
    /// `tableHeader`, `tableBlock`) may sit on top of them.
    func test_mainStreamTokensNeverOverlap() {
        let text = Self.reportSample
        let overlays: (Token.Kind) -> Bool = {
            switch $0 {
            case .taskBody, .invisibleAnchor, .tableHeader, .tableBlock: return true
            default: return false
            }
        }
        let main = tokenizer.tokenize(text).filter { !overlays($0.kind) }
        for (a, b) in zip(main, main.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(a.range), b.range.location,
                                     "\(a) overlaps \(b)")
        }
        XCTAssertEqual(main.last.map { NSMaxRange($0.range) }, (text as NSString).length)
    }

    func test_fountainModeIsUnaffected() {
        let text = "INT. OFFICE - DAY\n\n| a | b |\n|---|---|\n\nSee [@a] and @fig:x.[^1]"
        let kinds = ScreenplayMode().tokenize(text).map(\.kind)
        for kind in kinds {
            switch kind {
            case .tableSyntax, .tableHeader, .tableCaption, .tableBlock,
                 .footnoteReference, .footnoteLabel, .citation,
                 .crossReference, .figureSyntax, .attributeBlock:
                XCTFail("screenplay mode emitted a report kind: \(kind)")
            default: break
            }
        }
    }

    // MARK: - Styling

    private func styled(_ text: String, theme: Theme = .light) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let mode = ProseMode()
        mode.applyTypography(in: storage, theme: theme, typography: .defaults,
                             tokens: mode.tokenize(text), wikiLinkResolver: nil)
        return storage
    }

    private func attrs(_ s: NSTextStorage, at needle: String) -> [NSAttributedString.Key: Any] {
        let loc = (s.string as NSString).range(of: needle).location
        XCTAssertNotEqual(loc, NSNotFound, "\(needle) not found")
        return s.attributes(at: loc, effectiveRange: nil)
    }

    private func isBold(_ a: [NSAttributedString.Key: Any]) -> Bool {
        (a[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
    }

    private func isItalic(_ a: [NSAttributedString.Key: Any]) -> Bool {
        (a[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
    }

    func test_styling_lightAndDark() {
        for theme in [Theme.light, .dark, .sepia] {
            let palette = theme.resolved(systemAppearanceIsDark: false).palette
            let s = styled(Self.reportSample, theme: theme)
            let body = palette.bodyText
            let muted = palette.syntaxPunctuation

            // Pipes and the delimiter row are muted.
            XCTAssertEqual(attrs(s, at: "| Name")[.foregroundColor] as? NSColor, muted)
            XCTAssertEqual(attrs(s, at: "|:--")[.foregroundColor] as? NSColor, muted)
            // The header row is bold; a body cell is not.
            XCTAssertTrue(isBold(attrs(s, at: "Name")))
            XCTAssertFalse(isBold(attrs(s, at: "Ada")))
            // The caption line is muted italic.
            let caption = attrs(s, at: "Table: Engines")
            XCTAssertEqual(caption[.foregroundColor] as? NSColor, muted)
            XCTAssertTrue(isItalic(caption))
            // A footnote reference is small, raised and tinted.
            let ref = attrs(s, at: "[^1]")
            XCTAssertGreaterThan((ref[.baselineOffset] as? CGFloat) ?? 0, 0)
            XCTAssertLessThan((ref[.font] as? NSFont)?.pointSize ?? 99,
                              CGFloat(TypographySettings.defaults.fontSize))
            XCTAssertNotEqual(ref[.foregroundColor] as? NSColor, body)
            XCTAssertNotNil(ref[.foregroundColor])
            // A footnote definition's label is muted.
            XCTAssertEqual(attrs(s, at: "[^1]:")[.foregroundColor] as? NSColor, muted)
            // Citations and cross-references are quietly tinted, with no box.
            for needle in ["[@gartner2026", "@fig:revenue"] {
                let a = attrs(s, at: needle)
                XCTAssertNotNil(a[.foregroundColor] as? NSColor)
                XCTAssertNotEqual(a[.foregroundColor] as? NSColor, body)
                XCTAssertNotEqual(a[.foregroundColor] as? NSColor, muted)
                XCTAssertNil(a[.backgroundColor])
                XCTAssertNil(a[.underlineStyle])
            }
            // Figure syntax and `{#…}` are muted.
            XCTAssertEqual(attrs(s, at: "![")[.foregroundColor] as? NSColor, muted)
            XCTAssertEqual(attrs(s, at: "{#fig:")[.foregroundColor] as? NSColor, muted)
            XCTAssertEqual(attrs(s, at: "{#sec:")[.foregroundColor] as? NSColor, muted)
        }
    }

    /// One of everything, shared with the window-equivalence cases.
    static let reportSample = """
    # Findings {#sec:findings}

    Revenue grew sharply [@gartner2026, p. 12], as @fig:revenue shows.[^1]

    | Name | Year |
    |:-----|-----:|
    | Ada | 1843 |
    | Grace | 1952 |
    Table: Engines of note {#tbl:engines}

    ![Revenue by year](../research/rev.png){#fig:revenue}

    [^1]: Figures are nominal, see [@tbl:engines].
    """
}
