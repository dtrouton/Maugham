import XCTest
import MaughamCore
@testable import Maugham

/// The publish AST carries plan 1's report elements: labelled headings,
/// tables, figures, footnotes, citations and cross-references, read through
/// `ManuscriptBlocks` and `ManuscriptInlineScanner`. `nodeParagraphs` and
/// `footnoteParagraphs` say which `¶id` each came from, so a later publish
/// problem can name its paragraph.
final class ReportElementsASTTests: XCTestCase {

    private struct OneSource: ProjectASTBuilder.Source {
        let piece: ProjectASTBuilder.PieceRef
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] { [piece] }
    }

    private func section(_ text: String, mode: ProjectAST.Mode = .prose) throws -> ProjectAST.Section {
        try ProjectASTBuilder.build(from: OneSource(piece: .init(
            pieceID: "p1", title: "T", mode: mode, displayText: text))).sections[0]
    }

    /// A piece whose display text is its paragraphs joined, so they reconcile.
    private func section(paragraphs: [(id: String, text: String)],
                         mode: ProjectAST.Mode = .prose) throws -> ProjectAST.Section {
        try ProjectASTBuilder.build(from: OneSource(piece: .init(
            pieceID: "p1", title: "T", mode: mode,
            displayText: paragraphs.map(\.text).joined(separator: "\n\n"),
            paragraphs: paragraphs))).sections[0]
    }

    private func label(_ reference: String) -> ManuscriptLabel {
        ManuscriptLabel(reference: reference)!
    }

    // MARK: - blocks

    func test_heading_withLabel_isStrippedOfItsBlock() throws {
        let s = try section("## Method {#sec:method}")
        XCTAssertEqual(s.nodes, [.prose(.heading(level: 2, [.text("Method")], label: label("sec:method")))])
    }

    func test_plainHeading_hasNoLabel() throws {
        XCTAssertEqual(try section("# Plain").nodes,
                       [.prose(.heading(level: 1, [.text("Plain")], label: nil))])
    }

    func test_table_parsesCellsCaptionAlignmentsAndLabel() throws {
        let s = try section("| a | *b* |\n|:--|--:|\n| 1 | `2` |\nTable: The *sales* {#tbl:sales}")
        XCTAssertEqual(s.nodes, [.prose(.table(
            header: [[.text("a")], [.emphasis([.text("b")])]],
            alignments: [.leading, .trailing],
            rows: [[[.text("1")], [.code("2")]]],
            caption: [.text("The "), .emphasis([.text("sales")])],
            label: label("tbl:sales")))])
    }

    func test_figure_parsesCaptionPathAndLabel() throws {
        let s = try section("![The *chart*](../research/c.png) {#fig:chart}")
        XCTAssertEqual(s.nodes, [.prose(.figure(
            caption: [.text("The "), .emphasis([.text("chart")])],
            path: "../research/c.png", label: label("fig:chart")))])
    }

    // MARK: - footnotes

    func test_footnoteDefinitions_produceNoNode_andFillFootnotes() throws {
        let s = try section("Text[^1] and[^n2].\n\n[^1]: First *note*.\n[^n2]: Second\n  continued.")
        XCTAssertEqual(s.nodes, [.prose(.paragraph([
            .text("Text"), .footnoteRef(label: "1"), .text(" and"),
            .footnoteRef(label: "n2"), .text("."),
        ]))])
        XCTAssertEqual(s.footnotes, [
            "1": [.text("First "), .emphasis([.text("note")]), .text(".")],
            "n2": [.text("Second continued.")],
        ])
    }

    func test_stackedFootnoteDefinitions_firstDefinitionWins() throws {
        let s = try section("A[^x].\n\n[^x]: One.\n[^x]: Two.\n\nAfter.")
        XCTAssertEqual(s.footnotes, ["x": [.text("One.")]])
        XCTAssertEqual(s.nodes.count, 2, "definitions yield no node: the reference paragraph and After.")
    }

    // MARK: - inlines

    func test_mixedBracket_givesACitationAndACrossRef() throws {
        let s = try section("See [@a; @fig:x] here.")
        XCTAssertEqual(s.nodes, [.prose(.paragraph([
            .text("See ["), .citation([CitationItem(key: "a", locator: nil)]),
            .text("; "), .crossRef(label("fig:x")), .text("] here."),
        ]))])
    }

    func test_citationWithLocators_andBareCrossRef() throws {
        let s = try section("As shown [@smith, p. 12; @doe] and in @tbl:t.")
        XCTAssertEqual(s.nodes, [.prose(.paragraph([
            .text("As shown "),
            .citation([CitationItem(key: "smith", locator: "p. 12"), CitationItem(key: "doe", locator: nil)]),
            .text(" and in "), .crossRef(label("tbl:t")), .text("."),
        ]))])
    }

    func test_markerInBackticks_staysCode() throws {
        let s = try section("Write `[@a]` or `@fig:x` or `[^1]`.")
        XCTAssertEqual(s.nodes, [.prose(.paragraph([
            .text("Write "), .code("[@a]"), .text(" or "), .code("@fig:x"),
            .text(" or "), .code("[^1]"), .text("."),
        ]))])
    }

    /// The overlap rule's planted case: the scanner reads a citation whose
    /// locator holds a backtick, while this parser reads a code span opening
    /// at that backtick. The two overlap, and the code span wins — without
    /// the rule the citation would swallow the code span's opening half.
    func test_markerOverlappingACodeSpan_isDropped_andTheCodeSpanWins() throws {
        let s = try section("[@a, p`1] x`")
        XCTAssertEqual(s.nodes, [.prose(.paragraph([.text("[@a, p"), .code("1] x")]))])
    }

    func test_markerInsideWikiLink_staysWikiLink() throws {
        let s = try section("Go to [[Note @fig:x]] now.")
        XCTAssertEqual(s.nodes, [.prose(.paragraph([
            .text("Go to "), .wikiLink(target: "Note @fig:x", display: "Note @fig:x"), .text(" now."),
        ]))])
    }

    func test_markerInsideEmphasis_isAProtectedSpan() throws {
        // The emphasis shape around it is EmphasisRunConverter's; the marker
        // itself must survive as a node, never as literal text.
        let s = try section("*see @fig:x*")
        XCTAssertTrue(Self.contains(s.nodes, .crossRef(label("fig:x"))), "\(s.nodes)")
    }

    func test_fountainIsUntouched_byTheReportInlines() throws {
        let s = try section("INT. ROOM - DAY\n\nShe reads [@a] and @fig:x.", mode: .fountain)
        XCTAssertFalse(Self.contains(s.nodes, .crossRef(label("fig:x"))))
        XCTAssertFalse(Self.contains(s.nodes, .citation([CitationItem(key: "a", locator: nil)])))
    }

    // MARK: - nodeParagraphs

    func test_nodeParagraphs_mapTableFigureAndFootnoteHost() throws {
        let s = try section(paragraphs: [
            ("a1b2", "Intro[^1]."),
            ("c3d4", "| a |\n|---|\n| 1 |"),
            ("e5f6", "![Cap](x.png)"),
            ("g7h8", "[^1]: The note.\n[^2]: Another."),
            ("j9k0", "Outro[^2]."),
        ])
        XCTAssertEqual(s.nodes.count, 4)
        guard case .prose(.table) = s.nodes[1], case .prose(.figure) = s.nodes[2] else {
            return XCTFail("expected table then figure, got \(s.nodes)")
        }
        XCTAssertEqual(s.nodeParagraphs, [0: "a1b2", 1: "c3d4", 2: "e5f6", 3: "j9k0"])
        XCTAssertEqual(s.footnoteParagraphs, ["1": "g7h8", "2": "g7h8"])
        XCTAssertEqual(s.anchors, [0: "a1b2", 1: "c3d4", 2: "e5f6", 3: "j9k0"])
    }

    func test_nodeParagraphs_coverEveryNode_whereAnchorsTakeOnlyTheFirst() throws {
        let s = try section(paragraphs: [
            ("a1b2", "INT. ROOM - DAY"),
            ("c3d4", "MARY\n(quietly)\nHello."),
        ], mode: .fountain)
        XCTAssertEqual(s.nodes.count, 4)
        XCTAssertEqual(s.anchors, [0: "a1b2", 1: "c3d4"])
        XCTAssertEqual(s.nodeParagraphs, [0: "a1b2", 1: "c3d4", 2: "c3d4", 3: "c3d4"])
    }

    func test_nodeParagraphs_areEmpty_whenTheParagraphsDoNotReconcile() throws {
        let s = try ProjectASTBuilder.build(from: OneSource(piece: .init(
            pieceID: "p1", title: "T", mode: .prose,
            displayText: "One.\n\n[^1]: Note.",
            paragraphs: [("a1b2", "Different.")]))).sections[0]
        XCTAssertEqual(s.nodeParagraphs, [:])
        XCTAssertEqual(s.footnoteParagraphs, [:])
        XCTAssertEqual(s.footnotes, ["1": [.text("Note.")]])
    }

    func test_nodeParagraphs_areEmpty_withoutParagraphs() throws {
        let s = try section("One.\n\n[^1]: Note.")
        XCTAssertEqual(s.nodeParagraphs, [:])
        XCTAssertEqual(s.footnoteParagraphs, [:])
    }

    // MARK: - interim emitter arms (Tasks 5 and 6 replace them)

    /// Until the emitters render the elements, each prints the literal source
    /// it came from — for these spellings, exactly what the pre-switch builder
    /// produced (the source as one literal paragraph or heading).
    func test_interimArms_printTheLiteralSource() throws {
        let text = "## Method {#sec:method}\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n"
            + "![Alt](./img/pic.png) {#fig:pic}\n\nSee @fig:pic and [^1] and [@a, p. 2]."
        let ast = try ProjectASTBuilder.build(from: OneSource(piece: .init(
            pieceID: "p1", title: "T", mode: .prose, displayText: text)))
        let latex = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(latex.contains("\\subsection*{Method \\{\\#sec:method\\}}"), latex)
        XCTAssertTrue(latex.contains("\\addcontentsline{toc}{subsection}{Method \\{\\#sec:method\\}}"), latex)
        XCTAssertTrue(latex.contains("\n| a | b | | --- | --- | | 1 | 2 |\n"), latex)
        XCTAssertTrue(latex.contains("\n![Alt](./img/pic.png) \\{\\#fig:pic\\}\n"), latex)
        XCTAssertTrue(latex.contains("\nSee @fig:pic and [\\textasciicircum{}1] and [@a, p. 2].\n"), latex)

        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<h3>Method {#sec:method}</h3>"), xhtml)
        XCTAssertTrue(xhtml.contains("<p>| a | b | | --- | --- | | 1 | 2 |</p>"), xhtml)
        XCTAssertTrue(xhtml.contains("<p>![Alt](./img/pic.png) {#fig:pic}</p>"), xhtml)
        XCTAssertTrue(xhtml.contains("<p>See @fig:pic and [^1] and [@a, p. 2].</p>"), xhtml)
    }

    // MARK: - helpers

    private static func contains(_ nodes: [ProjectAST.Node], _ target: ProjectAST.Inline) -> Bool {
        func walk(_ xs: [ProjectAST.Inline]) -> Bool {
            xs.contains { inline in
                if inline == target { return true }
                switch inline {
                case .emphasis(let i), .strong(let i), .strikethrough(let i), .underline(let i): return walk(i)
                default: return false
                }
            }
        }
        return nodes.contains { node in
            switch node {
            case .prose(.paragraph(let i)): return walk(i)
            case .fountain(.action(let i)): return walk(i)
            default: return false
            }
        }
    }
}
