import XCTest
@testable import Maugham

final class ProjectASTBuilderTests: XCTestCase {

    struct FixtureSource: ProjectASTBuilder.Source {
        let pieces: [(id: String, title: String, mode: ProjectAST.Mode, text: String)]
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            pieces.map { .init(pieceID: $0.id, title: $0.title, mode: $0.mode, displayText: $0.text) }
        }
    }

    func testBuilds_emptyAST_fromNoPieces() {
        let src = FixtureSource(pieces: [])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertTrue(ast.sections.isEmpty)
    }

    func testBuilds_singleProseSection_oneParagraph() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "Chapter 1", mode: .prose, text: "Hello.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections.count, 1)
        let s = ast.sections[0]
        XCTAssertEqual(s.pieceID, "p1")
        XCTAssertEqual(s.title, "Chapter 1")
        XCTAssertEqual(s.mode, .prose)
        XCTAssertEqual(s.nodes, [.paragraph("Hello.")])
    }

    func testBuilds_proseParagraphsSplit_onBlankLine() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "One.\n\nTwo.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.paragraph("One."), .paragraph("Two.")])
    }

    func testProseSceneBreak_lineOfAsterisks_becomesSceneBreak() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "Before.\n\n* * *\n\nAfter.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .paragraph("Before."), .sceneBreak, .paragraph("After.")
        ])
    }

    func testProseStripsAnchors_fromBody() {
        // Manuscript paragraphs carry inline <!-- ¶XXXX --> anchors;
        // the AST is anchor-stripped (publishing pipeline never emits them).
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose,
             text: "<!-- ¶abcd -->Hello.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.paragraph("Hello.")])
    }

    // MARK: - block parsing (headings, blockquotes, multi-line paragraphs)

    func testProseHeading_atxBecomesHeadingNode() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "## Day 1/3\n\nMorning.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .heading(level: 2, [.text("Day 1/3")]),
            .paragraph([.text("Morning.")]),
        ])
    }

    func testProseHeading_levelCountedFromHashes() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "# Top\n\n### Deep")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .heading(level: 1, [.text("Top")]),
            .heading(level: 3, [.text("Deep")]),
        ])
    }

    func testBareHashes_areSceneBreakNotHeading() {
        // `###` with no space + content is an ornament, not a heading.
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "Before.\n\n###\n\nAfter.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .paragraph([.text("Before.")]), .sceneBreak, .paragraph([.text("After.")]),
        ])
    }

    func testProseBlockquote_nestsParagraph() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "> Quoted line.\n> Still quoted.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .blockquote([.paragraph([.text("Quoted line. Still quoted.")])]),
        ])
    }

    func testProseParagraph_softLineBreakJoinsWithSpace() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "Line one\nline two")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.paragraph([.text("Line one line two")])])
    }

    func testProseParagraph_inlineEmphasisParsed() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "A *word* and **bold**.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .paragraph([
                .text("A "), .emphasis([.text("word")]),
                .text(" and "), .strong([.text("bold")]), .text("."),
            ]),
        ])
    }

    func testFountainStripsAnchors_fromAction() {
        // Fountain manuscripts carry the same inline <!-- ¶XXXX --> op-log
        // anchors as prose. They must never leak into a rendered screenplay
        // (regression: Good Luck Babe's PDF showed raw <!-- ¶XXXX --> text).
        let src = FixtureSource(pieces: [
            (id: "p1", title: "Scene 1", mode: .fountain,
             text: "<!-- ¶abcd -->Aaron pours coffee.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.fountain(.action("Aaron pours coffee."))])
    }

    func testFountainSection_parsesElements() {
        let text = """
        INT. KITCHEN - DAY

        Aaron pours coffee.

        AARON
        Morning.
        """
        let src = FixtureSource(pieces: [
            (id: "p1", title: "Scene 1", mode: .fountain, text: text)
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].mode, .fountain)
        let nodes = ast.sections[0].nodes
        XCTAssertTrue(nodes.contains(.fountain(.sceneHeading("INT. KITCHEN - DAY"))))
        XCTAssertTrue(nodes.contains(.fountain(.action("Aaron pours coffee."))))
        XCTAssertTrue(nodes.contains(.fountain(.character("AARON"))))
        XCTAssertTrue(nodes.contains(.fountain(.dialogue("Morning."))))
    }

    func testFountainTransition_contextualTO_notMisreadAsCharacter() {
        // "CUT TO:" is all-caps with no period, so the old classifier mislabeled
        // it a character cue (and swallowed the next line as dialogue).
        let text = """
        Aaron leaves.

        CUT TO:

        INT. HALL - DAY
        """
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: text)
        ])
        let ast = ProjectASTBuilder.build(from: src)
        let nodes = ast.sections[0].nodes
        XCTAssertTrue(nodes.contains(.fountain(.transition("CUT TO:"))),
                      "CUT TO: should be a transition, got \(nodes)")
        XCTAssertFalse(nodes.contains(.fountain(.character("CUT TO:"))))
    }

    func testFountainTransition_forcedWithLeadingAngle() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: "> Fade to black.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.fountain(.transition("Fade to black."))])
    }

    func testFountainAction_parsesInlineEmphasis() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: "She runs *fast* and **hard**.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .fountain(.action([
                .text("She runs "), .emphasis([.text("fast")]),
                .text(" and "), .strong([.text("hard")]), .text("."),
            ]))
        ])
    }

    func testFountainDialogue_parsesInlineEmphasis() {
        let text = """
        AARON
        I said *no*.
        """
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: text)
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .fountain(.character("AARON")),
            .fountain(.dialogue([.text("I said "), .emphasis([.text("no")]), .text(".")])),
        ])
    }

    func testFountainTitlePage_parsedAsStructuredNode() {
        let text = """
        Title: Good Luck Babe
        Credit: Written by
        Author: Chappell Roan

        INT. CLUB - NIGHT

        Aaron enters.
        """
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: text)
        ])
        let ast = ProjectASTBuilder.build(from: src)
        let nodes = ast.sections[0].nodes
        XCTAssertEqual(nodes.first, .fountain(.titlePage([
            .init(key: "Title", value: "Good Luck Babe"),
            .init(key: "Credit", value: "Written by"),
            .init(key: "Author", value: "Chappell Roan"),
        ])))
        // The title-page keys do not leak into the body as action lines.
        XCTAssertTrue(nodes.contains(.fountain(.sceneHeading("INT. CLUB - NIGHT"))))
        XCTAssertFalse(nodes.contains(.fountain(.action([.text("Title: Good Luck Babe")]))))
    }

    func testFountainNoTitlePage_whenFirstLineIsNotATitleKey() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: "INT. CLUB - NIGHT\n\nAaron enters.")
        ])
        let ast = ProjectASTBuilder.build(from: src)
        let hasTitlePage = ast.sections[0].nodes.contains {
            if case .fountain(.titlePage) = $0 { return true }
            return false
        }
        XCTAssertFalse(hasTitlePage)
    }

    func testMixedPieces_preserveOrder() {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "First", mode: .prose, text: "Hello."),
            (id: "p2", title: "Second", mode: .fountain, text: "INT. ROOM - DAY"),
            (id: "p3", title: "Third", mode: .prose, text: "World."),
        ])
        let ast = ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections.map(\.pieceID), ["p1", "p2", "p3"])
        XCTAssertEqual(ast.sections.map(\.mode), [.prose, .fountain, .prose])
    }
}
