import XCTest
import MaughamCore
@testable import Maugham

/// Exercises `FountainNodeMapper.map` by feeding REAL Fountain source through
/// the real `FountainTokenizer` (no hand-built `FountainScript` fixtures) so the
/// mapper is pinned against the tokenizer's actual classification/content output.
final class FountainNodeMapperTests: XCTestCase {
    private func map(_ src: String) -> [ProjectAST.FountainNode] {
        FountainNodeMapper.map(FountainTokenizer().parse(src))
    }

    // MARK: - Normative (from the task brief)

    func test_boneyardAndNotes_omitted() {
        let src = "INT. HOUSE - DAY\n\n/* cut this */\n\nAction stays. [[fix me]]\n"
        let nodes = map(src)
        XCTAssertEqual(nodes.count, 2)   // sceneHeading + action
        guard case .action(let inlines) = nodes[1] else { return XCTFail() }
        // inline note span excluded from published action text
        XCTAssertFalse(inlines.contains {
            if case .text(let t) = $0 { return t.contains("[[") }
            return false
        })
    }

    func test_synopsisAndSection_omitted() {
        let nodes = map("# Act One\n\n= She discovers the letter.\n\nINT. A - DAY\n")
        XCTAssertEqual(nodes, [.sceneHeading("INT. A - DAY", sceneNumber: nil)])
    }

    func test_dualDialogue_pairs() {
        let src = "ALICE\nHello.\n\nBOB ^\nHi.\n"
        let nodes = map(src)
        guard case .dualDialogue(let left, let right) = nodes[0] else { return XCTFail() }
        XCTAssertEqual(left.first, .character("ALICE"))
        XCTAssertEqual(right.first, .character("BOB"))   // caret stripped by tokenizer
    }

    func test_lyric_centered_pageBreak() {
        let nodes = map("~The moon is out\n\n> THE END <\n\n===\n")
        XCTAssertEqual(nodes[0], .lyric([.text("The moon is out")]))
        XCTAssertEqual(nodes[1], .centered([.text("THE END")]))
        XCTAssertEqual(nodes[2], .pageBreak)
    }

    func test_forcedElements_markersStripped() {
        let nodes = map(".SNIPER SCOPE\n\n@McClane\nYippee.\n\n!LOUD NOISE\n")
        XCTAssertEqual(nodes[0], .sceneHeading("SNIPER SCOPE", sceneNumber: nil))
        XCTAssertEqual(nodes[1], .character("McClane"))
        // !LOUD NOISE is action, not a character cue
        XCTAssertEqual(nodes[3], .action([.text("LOUD NOISE")]))
    }

    // MARK: - Action coalescing

    func test_action_consecutiveLinesCoalesceWithSpace() {
        let nodes = map("Line one\nline two\nline three\n")
        XCTAssertEqual(nodes, [.action([.text("Line one line two line three")])])
    }

    func test_action_blankLineSeparatesGroups() {
        let nodes = map("First para.\n\nSecond para.\n")
        XCTAssertEqual(nodes, [.action([.text("First para.")]),
                               .action([.text("Second para.")])])
    }

    func test_action_inlineNoteStrippedBeforeParse() {
        // Whole-line notes are omitted; inline notes embedded in an action line
        // are removed textually. The surrounding text and its spacing survive.
        let nodes = map("Before [[skip me]] after.\n")
        XCTAssertEqual(nodes, [.action([.text("Before after.")])])
    }

    // MARK: - Character / dialogue blocks

    func test_dialogueLinesCoalesce_parentheticalFlushes() {
        let src = "JANE\nHello there.\n(quietly)\nGoodbye now.\n"
        let nodes = map(src)
        XCTAssertEqual(nodes, [
            .character("JANE"),
            .dialogue([.text("Hello there.")]),
            .parenthetical([.text("(quietly)")]),   // parens kept — emitter expects them
            .dialogue([.text("Goodbye now.")]),
        ])
    }

    func test_dialogueHeldBlank_staysOneDialogueNode_withLineBreak() {
        // A two-space "held" blank line inside a dialogue block (Task 13) is
        // tokenized as a `.dialogue` line with empty content — the mapper must
        // treat it as a continuation, not a block end, and preserve the pause
        // as an explicit `.lineBreak` inside the single coalesced `.dialogue`
        // node (rather than silently losing it to a joining space, or ending
        // the block and splitting into two separate nodes).
        let src = "DAN\nThen.\n  \nWhaddya want?\n"
        let nodes = map(src)
        XCTAssertEqual(nodes, [
            .character("DAN"),
            .dialogue([.text("Then."), .lineBreak, .text("Whaddya want?")]),
        ])
    }

    func test_dialogueHeldBlank_doesNotEndBlock_parentheticalAfterStillAttaches() {
        // A held blank followed by a parenthetical: the dialogue-so-far
        // flushes with a trailing lineBreak, and the parenthetical still
        // attaches to the SAME character block (not treated as orphaned).
        let src = "DAN\nThen.\n  \n(beat)\nMore.\n"
        let nodes = map(src)
        XCTAssertEqual(nodes, [
            .character("DAN"),
            .dialogue([.text("Then."), .lineBreak]),
            .parenthetical([.text("(beat)")]),
            .dialogue([.text("More.")]),
        ])
    }

    func test_emptyLine_stillEndsDialogueBlock_atMapperLevel() {
        // A truly empty line (not a held blank) still ends the block: the
        // following action text is NOT folded into the dialogue node.
        let src = "DAN\nThen.\n\nAction now.\n"
        let nodes = map(src)
        XCTAssertEqual(nodes, [
            .character("DAN"),
            .dialogue([.text("Then.")]),
            .action([.text("Action now.")]),
        ])
    }

    func test_dialogue_inlineNoteStripped() {
        let nodes = map("JANE\nHello [[TODO polish]] world.\n")
        XCTAssertEqual(nodes, [
            .character("JANE"),
            .dialogue([.text("Hello world.")]),
        ])
    }

    // MARK: - Transitions and title page

    func test_transition_emitted() {
        let nodes = map("INT. A - DAY\n\nStuff.\n\nCUT TO:\n\nINT. B - DAY\n")
        XCTAssertTrue(nodes.contains(.transition("CUT TO:")))
    }

    func test_titlePage_emittedAsLeadingNode() {
        let src = "Title: My Play\nAuthor: Jane Doe\n\nINT. A - DAY\n"
        let nodes = map(src)
        guard case .titlePage(let fields) = nodes[0] else { return XCTFail() }
        XCTAssertEqual(fields, [
            .init(key: "Title", value: "My Play"),
            .init(key: "Author", value: "Jane Doe"),
        ])
        XCTAssertEqual(nodes[1], .sceneHeading("INT. A - DAY", sceneNumber: nil))
    }

    func test_noTitlePage_noLeadingTitleNode() {
        let nodes = map("INT. A - DAY\n")
        XCTAssertEqual(nodes, [.sceneHeading("INT. A - DAY", sceneNumber: nil)])
    }
}
