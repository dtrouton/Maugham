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
        XCTAssertEqual(s.duplicateFootnotes, ["x": [nil]], "no paragraphs: the duplicate is kept, unlocated")
    }

    // Ruling R-S5: a dropped duplicate definition is recorded with its paragraph.
    func test_duplicateFootnoteDefinitions_areRecordedWithTheirParagraphs() throws {
        let s = try section(paragraphs: [
            ("a1b2", "A[^x] and[^y]."),
            ("c3d4", "[^x]: One.\n[^x]: Two.\n[^y]: Why."),
            ("e5f6", "[^x]: Three."),
        ])
        XCTAssertEqual(s.footnotes, ["x": [.text("One.")], "y": [.text("Why.")]])
        XCTAssertEqual(s.footnoteParagraphs, ["x": "c3d4", "y": "c3d4"])
        XCTAssertEqual(s.duplicateFootnotes, ["x": ["c3d4", "e5f6"]])
    }

    func test_noDuplicateFootnotes_whenEachLabelIsDefinedOnce() throws {
        XCTAssertEqual(try section("A[^x].\n\n[^x]: One.").duplicateFootnotes, [:])
    }

    // MARK: - inlines

    // Ruling R-S4: a bracket mixing keys and labels is consumed WHOLE — the
    // citation of every key, then "; " and a cross-reference per label. No
    // bracket and no later key is left behind as text.
    func test_mixedBracket_givesACitationAndACrossRef() throws {
        let s = try section("See [@a; @fig:x] here.")
        XCTAssertEqual(s.nodes, [.prose(.paragraph([
            .text("See "), .citation([CitationItem(key: "a", locator: nil)]),
            .text("; "), .crossRef(label("fig:x")), .text(" here."),
        ]))])
    }

    func test_mixedBracket_severalKeysAndLabels_isConsumedWhole() throws {
        let s = try section("See [@a, p. 3; @b; @fig:x; @tbl:y] here.")
        XCTAssertEqual(s.nodes, [.prose(.paragraph([
            .text("See "),
            .citation([CitationItem(key: "a", locator: "p. 3"), CitationItem(key: "b", locator: nil)]),
            .text("; "), .crossRef(label("fig:x")),
            .text("; "), .crossRef(label("tbl:y")),
            .text(" here."),
        ]))])
    }

    func test_mixedBracketInsideEmphasis_isConsumedWhole() throws {
        let s = try section("*see [@a; @b; @fig:x] now*")
        let census = ElementCensus.take(from: ProjectAST(sections: [s]))
        XCTAssertTrue(census.kinds.isSuperset(of: [.citation, .crossReference, .emphasis]), "\(s.nodes)")
        let text = Self.plainText(s.nodes)
        XCTAssertFalse(text.contains("["), "no bracket left behind: \(s.nodes)")
        XCTAssertFalse(text.contains("@"), "no key left behind: \(s.nodes)")
        XCTAssertTrue(Self.inlines(s.nodes).contains(
            .citation([CitationItem(key: "a", locator: nil), CitationItem(key: "b", locator: nil)])))
    }

    func test_labelOnlyBracket_keepsOneCrossRefPerLabel() throws {
        let s = try section("See [@fig:x; @tbl:y].")
        XCTAssertEqual(s.nodes, [.prose(.paragraph([
            .text("See ["), .crossRef(label("fig:x")), .text("; "),
            .crossRef(label("tbl:y")), .text("]."),
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
        XCTAssertTrue(Self.inlines(s.nodes).contains(.crossRef(label("fig:x"))), "\(s.nodes)")
    }

    func test_fountainIsUntouched_byTheReportInlines() throws {
        let s = try section("INT. ROOM - DAY\n\nShe reads [@a] and @fig:x.\n\nMARY\nSee [^1] and [@b; @tbl:t].",
                            mode: .fountain)
        let census = ElementCensus.take(from: ProjectAST(sections: [s]))
        XCTAssertTrue(census.kinds.contains(.dialogue), "the walk must reach dialogue: \(s.nodes)")
        XCTAssertTrue(census.kinds.isDisjoint(with: [.footnote, .citation, .crossReference]),
                      "Fountain never produces report markers: \(s.nodes)")
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

    func test_interimArm_mixedBracketReadsCitationThenLabels() throws {
        let ast = try ProjectASTBuilder.build(from: OneSource(piece: .init(
            pieceID: "p1", title: "T", mode: .prose, displayText: "See [@a; @b; @fig:x].")))
        XCTAssertTrue(LaTeXBodyEmitter.emit(ast).contains("\nSee [@a; @b]; @fig:x.\n"))
        XCTAssertTrue(XHTMLBodyEmitter.emit(ast).contains("<p>See [@a; @b]; @fig:x.</p>"))
    }

    // MARK: - helpers

    /// Every inline in the nodes, depth-first, through every node kind
    /// (exhaustive: no `default:`, so a node kind can't be silently skipped).
    private static func inlines(_ nodes: [ProjectAST.Node]) -> [ProjectAST.Inline] {
        func walk(_ xs: [ProjectAST.Inline]) -> [ProjectAST.Inline] {
            xs.flatMap { inline -> [ProjectAST.Inline] in
                switch inline {
                case .emphasis(let i), .strong(let i), .strikethrough(let i), .underline(let i):
                    return [inline] + walk(i)
                case .text, .code, .wikiLink, .lineBreak, .footnoteRef, .citation, .crossRef:
                    return [inline]
                }
            }
        }
        func prose(_ node: ProjectAST.ProseNode) -> [ProjectAST.Inline] {
            switch node {
            case .paragraph(let i), .heading(_, let i, _): return walk(i)
            case .blockquote(let inner): return inner.flatMap(prose)
            case .list(_, let items): return items.flatMap(walk)
            case .table(let header, _, let rows, let caption, _):
                return header.flatMap(walk) + rows.flatMap { $0.flatMap(walk) } + walk(caption ?? [])
            case .figure(let caption, _, _): return walk(caption)
            case .sceneBreak, .verbatim: return []
            }
        }
        func fountain(_ node: ProjectAST.FountainNode) -> [ProjectAST.Inline] {
            switch node {
            case .action(let i), .dialogue(let i), .parenthetical(let i), .lyric(let i), .centered(let i):
                return walk(i)
            case .dualDialogue(let left, let right): return (left + right).flatMap(fountain)
            case .sceneHeading, .character, .transition, .pageBreak, .titlePage: return []
            }
        }
        return nodes.flatMap { node -> [ProjectAST.Inline] in
            switch node {
            case .prose(let p): return prose(p)
            case .fountain(let f): return fountain(f)
            }
        }
    }

    /// The plain `.text` content of the nodes, joined.
    private static func plainText(_ nodes: [ProjectAST.Node]) -> String {
        inlines(nodes).compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
    }
}
