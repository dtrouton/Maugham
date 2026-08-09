import XCTest
import MaughamCore
@testable import Maugham

final class ProjectASTBuilderTests: XCTestCase {

    struct FixtureSource: ProjectASTBuilder.Source {
        let pieces: [(id: String, title: String, mode: ProjectAST.Mode, text: String)]
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            pieces.map { .init(pieceID: $0.id, title: $0.title, mode: $0.mode, displayText: $0.text) }
        }
    }

    func testBuilds_emptyAST_fromNoPieces() throws {
        let src = FixtureSource(pieces: [])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertTrue(ast.sections.isEmpty)
    }

    func testBuilds_singleProseSection_oneParagraph() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "Chapter 1", mode: .prose, text: "Hello.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections.count, 1)
        let s = ast.sections[0]
        XCTAssertEqual(s.pieceID, "p1")
        XCTAssertEqual(s.title, "Chapter 1")
        XCTAssertEqual(s.mode, .prose)
        XCTAssertEqual(s.nodes, [.paragraph("Hello.")])
    }

    func testBuilds_proseParagraphsSplit_onBlankLine() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "One.\n\nTwo.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.paragraph("One."), .paragraph("Two.")])
    }

    func testProseSceneBreak_lineOfAsterisks_becomesSceneBreak() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "Before.\n\n* * *\n\nAfter.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .paragraph("Before."), .sceneBreak, .paragraph("After.")
        ])
    }

    func testProseSceneBreak_fourOrMoreDashes_becomesSceneBreak() throws {
        // Editor parity: the tokenizer's horizontal-rule rule accepts
        // `-{3,}` (any run of 3+ dashes), not just exactly `---`.
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "Before.\n\n----\n\nAfter.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .paragraph("Before."), .sceneBreak, .paragraph("After.")
        ])
    }

    func testProseStripsAnchors_fromBody() throws {
        // Manuscript paragraphs carry <!-- ¶XXXX --> anchors on their own line
        // (the Materializer format: anchor-line + blank + text). The AST is
        // anchor-stripped (publishing pipeline never emits them).
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose,
             text: "<!-- ¶abcd -->\n\nHello.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.paragraph("Hello.")])
    }

    // MARK: - block parsing (headings, blockquotes, multi-line paragraphs)

    func testProseHeading_atxBecomesHeadingNode() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "## Day 1/3\n\nMorning.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .heading(level: 2, [.text("Day 1/3")]),
            .paragraph([.text("Morning.")]),
        ])
    }

    func testProseHeading_levelCountedFromHashes() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "# Top\n\n### Deep")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .heading(level: 1, [.text("Top")]),
            .heading(level: 3, [.text("Deep")]),
        ])
    }

    func testBareHashes_areSceneBreakNotHeading() throws {
        // `###` with no space + content is an ornament, not a heading.
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "Before.\n\n###\n\nAfter.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .paragraph([.text("Before.")]), .sceneBreak, .paragraph([.text("After.")]),
        ])
    }

    func testProseBlockquote_nestsParagraph() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "> Quoted line.\n> Still quoted.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .blockquote([.paragraph([.text("Quoted line. Still quoted.")])]),
        ])
    }

    func testProseParagraph_softLineBreakJoinsWithSpace() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "Line one\nline two")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.paragraph([.text("Line one line two")])])
    }

    func testProseParagraph_inlineEmphasisParsed() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "C", mode: .prose, text: "A *word* and **bold**.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .paragraph([
                .text("A "), .emphasis([.text("word")]),
                .text(" and "), .strong([.text("bold")]), .text("."),
            ]),
        ])
    }

    func testFountainStripsAnchors_fromAction() throws {
        // Fountain manuscripts carry <!-- ¶XXXX --> anchors on their own line
        // (Materializer format: anchor-line + blank + text). They must never
        // leak into a rendered screenplay (regression: Good Luck Babe's PDF
        // showed raw <!-- ¶XXXX --> text).
        let src = FixtureSource(pieces: [
            (id: "p1", title: "Scene 1", mode: .fountain,
             text: "<!-- ¶abcd -->\n\nAaron pours coffee.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.fountain(.action("Aaron pours coffee."))])
    }

    func testFountainSection_parsesElements() throws {
        let text = """
        INT. KITCHEN - DAY

        Aaron pours coffee.

        AARON
        Morning.
        """
        let src = FixtureSource(pieces: [
            (id: "p1", title: "Scene 1", mode: .fountain, text: text)
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].mode, .fountain)
        let nodes = ast.sections[0].nodes
        XCTAssertTrue(nodes.contains(.fountain(.sceneHeading("INT. KITCHEN - DAY"))))
        XCTAssertTrue(nodes.contains(.fountain(.action("Aaron pours coffee."))))
        XCTAssertTrue(nodes.contains(.fountain(.character("AARON"))))
        XCTAssertTrue(nodes.contains(.fountain(.dialogue("Morning."))))
    }

    func testFountainTransition_contextualTO_notMisreadAsCharacter() throws {
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
        let ast = try ProjectASTBuilder.build(from: src)
        let nodes = ast.sections[0].nodes
        XCTAssertTrue(nodes.contains(.fountain(.transition("CUT TO:"))),
                      "CUT TO: should be a transition, got \(nodes)")
        XCTAssertFalse(nodes.contains(.fountain(.character("CUT TO:"))))
    }

    func testFountainTransition_forcedWithLeadingAngle() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: "> Fade to black.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [.fountain(.transition("Fade to black."))])
    }

    func testFountainAction_parsesInlineEmphasis() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: "She runs *fast* and **hard**.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .fountain(.action([
                .text("She runs "), .emphasis([.text("fast")]),
                .text(" and "), .strong([.text("hard")]), .text("."),
            ]))
        ])
    }

    func testFountainDialogue_parsesInlineEmphasis() throws {
        let text = """
        AARON
        I said *no*.
        """
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: text)
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .fountain(.character("AARON")),
            .fountain(.dialogue([.text("I said "), .emphasis([.text("no")]), .text(".")])),
        ])
    }

    func testFountainTitlePage_parsedAsStructuredNode() throws {
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
        let ast = try ProjectASTBuilder.build(from: src)
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

    func testFountainNoTitlePage_whenFirstLineIsNotATitleKey() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: "INT. CLUB - NIGHT\n\nAaron enters.")
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        let hasTitlePage = ast.sections[0].nodes.contains {
            if case .fountain(.titlePage) = $0 { return true }
            return false
        }
        XCTAssertFalse(hasTitlePage)
    }

    func testFountainDialogue_multipleLinesCoalesceIntoOneNode() throws {
        // A hard-wrapped speech must render as ONE dialogue block, not one
        // \dialogue{} (one minipage) per source line.
        let text = """
        AARON
        First line of the speech
        second line of the same speech.
        """
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: text)
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .fountain(.character("AARON")),
            .fountain(.dialogue([.text("First line of the speech second line of the same speech.")])),
        ])
    }

    func testFountainDialogue_parentheticalSplitsSpeech() throws {
        let text = """
        AARON
        Before the beat.
        (beat)
        After the beat.
        """
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: text)
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .fountain(.character("AARON")),
            .fountain(.dialogue([.text("Before the beat.")])),
            .fountain(.parenthetical([.text("(beat)")])),
            .fountain(.dialogue([.text("After the beat.")])),
        ])
    }

    func testFountainAction_multipleLinesCoalesceIntoOneParagraph() throws {
        let text = """
        Aaron crosses the room
        and opens the window.

        BETH
        Hello.
        """
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: text)
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .fountain(.action([.text("Aaron crosses the room and opens the window.")])),
            .fountain(.character("BETH")),
            .fountain(.dialogue([.text("Hello.")])),
        ])
    }

    func testFountainEndToEnd_viaRealTokenizer_omitsAuthorContentAndPairsDual() throws {
        // End-to-end through the real FountainTokenizer (Task 7 cutover): one
        // fixture that exercises title page + scene heading + an inline note +
        // a boneyard block + dual dialogue (`^`) + lyric + centered + page break.
        // Author-only material (boneyard, inline note) is omitted; lyric,
        // centered, and page break survive; the `^`-marked second cue pairs the
        // two speeches into one .dualDialogue. The old hand-rolled classifier
        // could produce NONE of this (audit A1): it leaked boneyard/note/caret
        // text and had no lyric/centered/pageBreak/dualDialogue path at all.
        let text = """
        Title: Good Luck Babe
        Author: Chappell Roan

        INT. CLUB - NIGHT

        Aaron enters [[check the lighting]] and pauses.

        /*
        This whole beat is cut.
        */

        AARON
        Morning.

        BETH ^
        Evening.

        ~And so we sing

        > THE END <

        ===
        """
        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: text)
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections[0].nodes, [
            .fountain(.titlePage([
                .init(key: "Title", value: "Good Luck Babe"),
                .init(key: "Author", value: "Chappell Roan"),
            ])),
            .fountain(.sceneHeading("INT. CLUB - NIGHT")),
            // inline [[note]] stripped from the action; surrounding text remains.
            .fountain(.action("Aaron enters and pauses.")),
            // boneyard block (/* … */) omitted entirely.
            .fountain(.dualDialogue(
                left: [.character("AARON"), .dialogue("Morning.")],
                right: [.character("BETH"), .dialogue("Evening.")])),
            .fountain(.lyric("And so we sing")),
            .fountain(.centered("THE END")),
            .fountain(.pageBreak),
        ])
    }

    // MARK: - lists + fenced verbatim

    /// Mirrors `SinglePieceSource` (EmissionContract.swift) — a tiny one-piece
    /// prose builder for tests that only care about the resulting nodes.
    private func buildProse(_ text: String) throws -> [ProjectAST.Node] {
        let src = FixtureSource(pieces: [(id: "p1", title: "T", mode: .prose, text: text)])
        return try ProjectASTBuilder.build(from: src).sections[0].nodes
    }

    func test_unorderedList_parses() throws {
        let nodes = try buildProse("- one\n- two *em*\n")
        XCTAssertEqual(nodes, [.prose(.list(ordered: false,
            items: [[.text("one")], [.text("two "), .emphasis([.text("em")])]]))])
    }

    func test_orderedList_bothDelimiters() {
        XCTAssertEqual(try buildProse("1. a\n2) b\n"),
            [.prose(.list(ordered: true, items: [[.text("a")], [.text("b")]]))])
    }

    func test_list_indentedContinuation_joinsCurrentItem() {
        XCTAssertEqual(try buildProse("- one\n  still one\n- two\n"),
            [.prose(.list(ordered: false, items: [[.text("one still one")], [.text("two")]]))])
    }

    func test_list_blankLineEndsBlock() {
        XCTAssertEqual(try buildProse("- one\n\nAfter."),
            [.prose(.list(ordered: false, items: [[.text("one")]])), .prose(.paragraph([.text("After.")]))])
    }

    func test_fence_verbatim_noInlineMangle() throws {
        let nodes = try buildProse("```\n*not em*\n`nor code`\n```\n")
        XCTAssertEqual(nodes, [.prose(.verbatim(["*not em*", "`nor code`"]))])
    }

    func test_fence_unterminated_collectsToEndOfInput() {
        XCTAssertEqual(try buildProse("```\nline one\nline two"),
            [.prose(.verbatim(["line one", "line two"]))])
    }

    // An UNINDENTED non-marker line ends the list and is reprocessed by the
    // normal block loop — so a trailing scene-break/heading isn't swallowed
    // as list-item text (regression: the original implementation treated any
    // non-blank line as a continuation regardless of indentation).
    func test_list_unindentedSceneBreak_endsListAndBecomesSceneBreak() {
        XCTAssertEqual(try buildProse("- item\n***\n"),
            [.prose(.list(ordered: false, items: [[.text("item")]])), .prose(.sceneBreak)])
    }

    func test_list_unindentedHeading_endsListAndBecomesHeading() {
        XCTAssertEqual(try buildProse("- item\n# H\n"),
            [.prose(.list(ordered: false, items: [[.text("item")]])),
             .prose(.heading(level: 1, [.text("H")]))])
    }

    // Mixing markers is lossy-but-intentional (spec ledger: flat/tight
    // lists) — the FIRST item's marker decides ordered-vs-unordered for the
    // whole block; a later numeral is just item text, not a mode switch.
    func test_list_mixedMarkers_firstMarkerWins_unordered() {
        XCTAssertEqual(try buildProse("- a\n2. b\n"),
            [.prose(.list(ordered: false, items: [[.text("a")], [.text("b")]]))])
    }

    // MARK: - degrade pins (Task 5: table + solo image → literal paragraph)

    // A GFM pipe table is display-only grammar the publish path does not
    // render; today it falls through the block loop as literal paragraph text
    // (no block rule claims a `|` line). This pin captures that exact
    // literal-paragraph AST so the shared-parser cutover — which recognizes the
    // table as its own block, then DEGRADES it back through the same paragraph
    // helper — stays byte-identical.
    func test_pipeTable_degradesToLiteralParagraph() throws {
        let nodes = try buildProse("| a | b |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertEqual(nodes, [.prose(.paragraph([
            .text("| a | b | | --- | --- | | 1 | 2 |")]))])
    }

    // A whole-line `./`-relative image reference is likewise display-only;
    // today it is swallowed as literal paragraph text. The cutover recognizes
    // it as a solo-image block and degrades it back through the same paragraph
    // helper — this pin locks the byte-identical result.
    func test_soloImageLine_degradesToParagraph() throws {
        let nodes = try buildProse("![Alt](./img/pic.png)")
        XCTAssertEqual(nodes, [.prose(.paragraph([
            .text("![Alt](./img/pic.png)")]))])
    }

    // A LEADING table/image block followed by prose with no blank line splits
    // into TWO nodes post-cutover, where the pre-cutover glue produced ONE
    // accumulated paragraph. This is an INTENTIONAL, ledger-sanctioned
    // deviation (Task 5 review, resolved option (a): the shared parser's
    // uniform block grammar is the accepted behavior; re-gluing table/image
    // lines back into a trailing paragraph would reintroduce the divergence the
    // shared parser exists to remove). These pins lock the accepted shape.
    func test_leadingTable_thenProse_splitsIntoTwoNodes() throws {
        let nodes = try buildProse("| a |\n|---|\ntrailing prose")
        XCTAssertEqual(nodes, [
            .prose(.paragraph([.text("| a | |---|")])),
            .prose(.paragraph([.text("trailing prose")])),
        ])
    }

    func test_leadingSoloImage_thenCaption_splitsIntoTwoNodes() throws {
        let nodes = try buildProse("![Alt](./img.png)\nCaption line")
        XCTAssertEqual(nodes, [
            .prose(.paragraph([.text("![Alt](./img.png)")])),
            .prose(.paragraph([.text("Caption line")])),
        ])
    }

    // MARK: - E1 (MCP smoke): held blank survives the op-log round trip

    /// The full E1 fixture through the real publish path: a Fountain piece whose
    /// text went through a `ParagraphParser` -> `Materializer` round trip (the
    /// op-log paragraph layer) before reaching `ProjectASTBuilder.build`. Task 13
    /// made a two-space "held blank" a paused dialogue continuation; the op-log
    /// layer used to eat it (split the paragraph on the whitespace-only line), so
    /// the held line re-materialized as a REAL blank and the continuation became
    /// `.action` — which also broke the FOLLOWING dual-dialogue block. With the
    /// mode-aware parse both knock-ons are fixed: ONE `.dialogue` node carries a
    /// `.lineBreak` for the held pause, and the later `^` block still pairs into a
    /// `.dualDialogue`, with no spurious `.action` node.
    func testHeldBlank_survivesOpLogRoundTrip_intoAST() throws {
        let fixture = """
        ALICE
        I wrote you every day for a *year*.
        \u{20}\u{20}
        And you never answered once.

        BOB
        Then explain the letters.

        CAROL ^
        I burned them.
        """
        // Round-trip through the op-log paragraph layer exactly as a Fountain
        // document does: parse held-blank-preserving, then materialize the stored
        // form the publish path reads back (anchors and all).
        let parsed = ParagraphParser.parse(fixture, preservesHeldBlankLines: true)
        // 4-char alphabet-restricted ids (tripwire 8) — this crosses the
        // .md <-> op-log boundary via materialize.
        let ids = ["aaaa", "bbbb", "cccc"]
        XCTAssertEqual(parsed.count, ids.count,
            "the held blank must keep ALICE's speech as ONE paragraph")
        var paragraphs: [String: String] = [:]
        for (id, p) in zip(ids, parsed) { paragraphs[id] = p.text }
        let materialized = Materializer.materialize(
            paragraphs: paragraphs, sequence: ids)

        let src = FixtureSource(pieces: [
            (id: "p1", title: "S", mode: .fountain, text: materialized)
        ])
        let nodes = try ProjectASTBuilder.build(from: src).sections[0].nodes

        // Knock-on 1: the held pause survives as ONE dialogue node with a
        // `.lineBreak`, NOT two paragraphs with a real blank between them.
        let dialogueWithBreak = nodes.contains { node in
            if case .fountain(.dialogue(let inlines)) = node {
                return inlines.contains(.lineBreak)
            }
            return false
        }
        XCTAssertTrue(dialogueWithBreak,
            "held blank must render as one .dialogue containing a .lineBreak, got \(nodes)")

        // Knock-on 2: the later `^` block still pairs into a dual dialogue —
        // no spurious action node severed it.
        let hasDualDialogue = nodes.contains { node in
            if case .fountain(.dualDialogue) = node { return true }
            return false
        }
        XCTAssertTrue(hasDualDialogue,
            "BOB / CAROL ^ must still pair into a .dualDialogue, got \(nodes)")

        // The held continuation must NEVER leak as an action line.
        let leakedAsAction = nodes.contains { node in
            if case .fountain(.action(let inlines)) = node {
                return inlines.contains { inline in
                    if case .text(let s) = inline {
                        return s.contains("And you never answered once")
                    }
                    return false
                }
            }
            return false
        }
        XCTAssertFalse(leakedAsAction,
            "the dialogue continuation must not re-materialize as an .action, got \(nodes)")
    }

    func testMixedPieces_preserveOrder() throws {
        let src = FixtureSource(pieces: [
            (id: "p1", title: "First", mode: .prose, text: "Hello."),
            (id: "p2", title: "Second", mode: .fountain, text: "INT. ROOM - DAY"),
            (id: "p3", title: "Third", mode: .prose, text: "World."),
        ])
        let ast = try ProjectASTBuilder.build(from: src)
        XCTAssertEqual(ast.sections.map(\.pieceID), ["p1", "p2", "p3"])
        XCTAssertEqual(ast.sections.map(\.mode), [.prose, .fountain, .prose])
    }
}
