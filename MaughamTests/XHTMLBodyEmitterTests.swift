import XCTest
import MaughamCore
@testable import Maugham

final class XHTMLBodyEmitterTests: XCTestCase {

    func testEmits_emptyAST_returnsEmptyBody() {
        let xhtml = XHTMLBodyEmitter.emit(ProjectAST(sections: []))
        XCTAssertEqual(xhtml.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testEmits_proseSection_wrappedInSection() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p_abc", title: "Chapter One", mode: .prose,
                  nodes: [.paragraph("Hello.")])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<section class=\"prose\" data-piece-id=\"p_abc\">"))
        XCTAssertTrue(xhtml.contains("<h1>Chapter One</h1>"))
        XCTAssertTrue(xhtml.contains("<p>Hello.</p>"))
        XCTAssertTrue(xhtml.contains("</section>"))
    }

    // MARK: - inline content

    func testEmits_inlineEmphasisAndStrong_insideParagraph() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph([
                    .text("a "), .emphasis([.text("italic")]),
                    .text(" b "), .strong([.text("bold")]),
                ])
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<p>a <em>italic</em> b <strong>bold</strong></p>"))
    }

    func testEmits_nestedEmphasis() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph([.strong([.text("bold "), .emphasis([.text("italic")])])])
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<strong>bold <em>italic</em></strong>"))
    }

    func testEmits_inlineCode_doesNotInterpretInside() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph([.code("**not bold**")])
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<code>**not bold**</code>"))
        XCTAssertFalse(xhtml.contains("<strong>not bold</strong>"))
    }

    func testEmits_hardLineBreak() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph([.text("a"), .lineBreak, .text("b")])
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<p>a<br/>b</p>"))
    }

    func testEmits_inlineWikiLink_asSpan() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph([.wikiLink(target: "Aaron", display: "him")])
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<span class=\"wiki-link\" data-target=\"Aaron\">him</span>"))
    }

    // MARK: - headings + blockquote

    func testEmits_heading_asHTag_reservingH1() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .heading(level: 1, [.text("Top")]),
                .heading(level: 2, [.text("Day 1/3")]),
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<h2>Top</h2>"))
        XCTAssertTrue(xhtml.contains("<h3>Day 1/3</h3>"))
    }

    func testEmits_blockquote_wrapsNestedParagraph() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .blockquote([.paragraph([.text("Quoted.")])])
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<blockquote>"))
        XCTAssertTrue(xhtml.contains("<p>Quoted.</p>"))
        XCTAssertTrue(xhtml.contains("</blockquote>"))
    }

    // MARK: - lists + verbatim

    func testEmits_unorderedList_ulLi() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .prose(.list(ordered: false, items: [[.text("one")], [.text("two")]]))
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<ul>"))
        XCTAssertTrue(xhtml.contains("<li>one</li>"))
        XCTAssertTrue(xhtml.contains("<li>two</li>"))
        XCTAssertTrue(xhtml.contains("</ul>"))
    }

    func testEmits_orderedList_olLi() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .prose(.list(ordered: true, items: [[.text("a")], [.text("b")]]))
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<ol>"))
        XCTAssertTrue(xhtml.contains("<li>a</li>"))
        XCTAssertTrue(xhtml.contains("</ol>"))
    }

    func testEmits_verbatim_paragraphWithBrLineBreaks() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .prose(.verbatim(["*not em*", "`nor code`"]))
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<p class=\"verbatim\">*not em*<br/>`nor code`</p>"))
    }

    // MARK: - scene break + escaping

    func testEmits_sceneBreak_asHR() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [.sceneBreak])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<hr class=\"scene-break\"/>"))
    }

    func testEscapes_specialChars() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Tom & Jerry", mode: .prose, nodes: [
                .paragraph("a<b>c & d")
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<h1>Tom &amp; Jerry</h1>"))
        XCTAssertTrue(xhtml.contains("a&lt;b&gt;c &amp; d"))
    }

    // MARK: - fountain (unchanged)

    func testEmits_fountainSection_classedParagraphs() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p_x", title: "S", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. KITCHEN - DAY")),
                .fountain(.action("Aaron pours coffee.")),
                .fountain(.character("AARON")),
                .fountain(.parenthetical("(quietly)")),
                .fountain(.dialogue("Morning.")),
                .fountain(.transition("CUT TO:"))
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<section class=\"screenplay\" data-piece-id=\"p_x\">"))
        XCTAssertTrue(xhtml.contains("<p class=\"scene-heading\">INT. KITCHEN - DAY</p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"action\">Aaron pours coffee.</p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"character\">AARON</p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"parenthetical\">(quietly)</p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"dialogue\">Morning.</p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"transition\">CUT TO:</p>"))
    }

    func testEmits_fountainInlineEmphasis_inActionAndDialogue() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.action([.text("She runs "), .emphasis([.text("fast")])])),
                .fountain(.dialogue([.strong([.text("Now")]), .text("!")])),
                .fountain(.parenthetical([.underline([.text("sotto")])])),
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<p class=\"action\">She runs <em>fast</em></p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"dialogue\"><strong>Now</strong>!</p>"))
        XCTAssertTrue(xhtml.contains("<p class=\"parenthetical\"><u>sotto</u></p>"))
    }

    func testEmits_fountainTitlePage_asHeader() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.titlePage([
                    .init(key: "Title", value: "Good Luck Babe"),
                    .init(key: "Draft date", value: "2026-05-28"),
                ]))
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<header class=\"title-page\">"))
        XCTAssertTrue(xhtml.contains("<h1 class=\"title\">Good Luck Babe</h1>"))
        XCTAssertTrue(xhtml.contains("<p class=\"draft-date\">2026-05-28</p>"))
        XCTAssertTrue(xhtml.contains("</header>"))
    }

    // MARK: - fountain vocabulary expansion (lyric/centered/pageBreak/scene numbers)

    func testEmits_sceneHeading_nilSceneNumber_isByteIdenticalToToday() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. KITCHEN - DAY", sceneNumber: nil)),
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<p class=\"scene-heading\">INT. KITCHEN - DAY</p>"))
        XCTAssertFalse(xhtml.contains("scene-number"))
    }

    func testEmits_sceneHeading_withSceneNumber_appendsSpanInsideSceneHeading() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. HOUSE - DAY", sceneNumber: "42")),
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains(
            "<p class=\"scene-heading\">INT. HOUSE - DAY<span class=\"scene-number\">42</span></p>"))
    }

    func testEmits_lyric_asPTag() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.lyric("Hush now, quiet now")),
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<p class=\"lyric\">Hush now, quiet now</p>"))
    }

    func testEmits_centered_asPTag() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.centered("THE END")),
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<p class=\"centered\">THE END</p>"))
    }

    func testEmits_pageBreak_asHR() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.action("Before.")),
                .fountain(.pageBreak),
                .fountain(.action("After.")),
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<hr class=\"page-break\"/>"))
    }

    func testEmits_dualDialogue_wrappedInDiv() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.dualDialogue(
                    left: [.character("AARON"), .dialogue("Hi.")],
                    right: [.character("BETH"), .dialogue("Hi.")]
                ))
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<div class=\"dual-dialogue\">"))
        XCTAssertTrue(xhtml.contains("<div class=\"left\">"))
        XCTAssertTrue(xhtml.contains("<div class=\"right\">"))
    }

    // MARK: - P3 Task 3: paragraph anchors

    /// The control. `Section.anchors` is POPULATED here and the emit is
    /// untagged, so this is the case that would silently change every existing
    /// EPUB in the world if the tag were not really optional. Pinned as a
    /// literal captured from `f15b8167` — BEFORE this task — rather than
    /// against a re-render, so the emitter cannot agree with itself.
    func test_anUntaggedEmitIsByteIdenticalToBeforeAnchorsExisted() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p_abc", title: "Chapter One", mode: .prose,
                  nodes: [.paragraph("Hello.")], anchors: [0: "aaaa"])
        ])
        XCTAssertEqual(XHTMLBodyEmitter.emit(ast), """
        <section class="prose" data-piece-id="p_abc">
        <h1>Chapter One</h1>
        <p>Hello.</p>
        </section>
        """)
    }

    /// The same fixture with a tag: the paragraph's own `¶id` lands on the
    /// element that paragraph produced, as `p-<tag>-<¶id>`.
    func test_aTaggedEmitPutsTheParagraphsIdOnItsParagraphElement() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p_abc", title: "Chapter One", mode: .prose,
                  nodes: [.paragraph("Hello.")], anchors: [0: "aaaa"])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast, anchorTag: "en")
        XCTAssertTrue(xhtml.contains(#"<p id="p-en-aaaa">Hello.</p>"#), xhtml)
    }

    /// Every block kind anchors on the FIRST element it emits — the container,
    /// never the first child inside it — so a link always lands at the top of
    /// what the paragraph produced.
    func test_theAnchorLandsOnTheFirstElementOfEveryBlockKind() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .heading(level: 1, [.text("Head")]),
                .blockquote([.paragraph([.text("Quoted.")])]),
                .prose(.list(ordered: false, items: [[.text("one")]])),
                .prose(.verbatim(["raw"])),
                .sceneBreak,
            ], anchors: [0: "aaaa", 1: "bbbb", 2: "cccc", 3: "dddd", 4: "eeee"])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast, anchorTag: "en")
        XCTAssertTrue(xhtml.contains(#"<h2 id="p-en-aaaa">Head</h2>"#), xhtml)
        XCTAssertTrue(xhtml.contains(#"<blockquote id="p-en-bbbb">"#), xhtml)
        XCTAssertTrue(xhtml.contains(#"<ul id="p-en-cccc">"#), xhtml)
        XCTAssertTrue(xhtml.contains(#"<p class="verbatim" id="p-en-dddd">raw</p>"#), xhtml)
        XCTAssertTrue(xhtml.contains(#"<hr class="scene-break" id="p-en-eeee"/>"#), xhtml)
    }

    /// The fountain half of the same rule, including the two containers.
    func test_theAnchorLandsOnTheFirstElementOfEveryFountainKind() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. ROOM - DAY", sceneNumber: nil)),
                .fountain(.action("He waits.")),
                .fountain(.character("AARON")),
                .fountain(.dialogue("Hi.")),
                .fountain(.parenthetical("softly")),
                .fountain(.transition("CUT TO:")),
                .fountain(.lyric("Hush now")),
                .fountain(.centered("THE END")),
                .fountain(.pageBreak),
                .fountain(.titlePage([.init(key: "Title", value: "The Play")])),
                .fountain(.dualDialogue(left: [.character("AARON")],
                                        right: [.character("BETH")])),
            ], anchors: [0: "aaaa", 1: "bbbb", 2: "cccc", 3: "dddd", 4: "eeee",
                         5: "ffff", 6: "gggg", 7: "hhhh", 8: "jjjj", 9: "kkkk",
                         10: "mmmm"])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast, anchorTag: "en")
        for expected in [
            #"<p class="scene-heading" id="p-en-aaaa">INT. ROOM - DAY</p>"#,
            #"<p class="action" id="p-en-bbbb">He waits.</p>"#,
            #"<p class="character" id="p-en-cccc">AARON</p>"#,
            #"<p class="dialogue" id="p-en-dddd">Hi.</p>"#,
            #"<p class="parenthetical" id="p-en-eeee">softly</p>"#,
            #"<p class="transition" id="p-en-ffff">CUT TO:</p>"#,
            #"<p class="lyric" id="p-en-gggg">Hush now</p>"#,
            #"<p class="centered" id="p-en-hhhh">THE END</p>"#,
            #"<hr class="page-break" id="p-en-jjjj"/>"#,
            #"<header class="title-page" id="p-en-kkkk">"#,
            #"<div class="dual-dialogue" id="p-en-mmmm">"#,
        ] {
            XCTAssertTrue(xhtml.contains(expected), "missing \(expected) in\n\(xhtml)")
        }
    }

    /// A node's children are NOT the node: one paragraph, one id. A blockquote's
    /// inner paragraph and a dual-dialogue's inner cue must carry none, or the
    /// same `¶id` would appear twice in one document and stop being an id.
    func test_anAnchorNeverReachesAChildOfTheNodeItAnchors() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .blockquote([.paragraph([.text("Quoted.")])]),
            ], anchors: [0: "aaaa"])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast, anchorTag: "en")
        XCTAssertEqual(xhtml.components(separatedBy: "p-en-aaaa").count - 1, 1, xhtml)
        XCTAssertTrue(xhtml.contains("<p>Quoted.</p>"), xhtml)
    }

    /// The map is SPARSE: an unanchored node emits exactly what it always did,
    /// beside an anchored sibling.
    func test_anUnanchoredNodeCarriesNoId() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph("First."), .paragraph("Second."),
            ], anchors: [0: "aaaa"])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast, anchorTag: "en")
        XCTAssertTrue(xhtml.contains(#"<p id="p-en-aaaa">First.</p>"#), xhtml)
        XCTAssertTrue(xhtml.contains("<p>Second.</p>"), xhtml)
    }

    // MARK: - P3 Task 3: cross-body links

    private func screenplay(_ nodes: [ProjectAST.Node],
                            anchors: [Int: String]) -> ProjectAST {
        ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain,
                  nodes: nodes, anchors: anchors)
        ])
    }

    /// One other body: the slugline's TEXT becomes a link into that body's
    /// section file, at the same paragraph's anchor there.
    func test_aSluglineLinksToTheSameSluglineInTheOtherBody() {
        let xhtml = XHTMLBodyEmitter.emit(
            screenplay([.fountain(.sceneHeading("INT. ROOM - DAY", sceneNumber: nil))],
                       anchors: [0: "aaaa"]),
            anchorTag: "en", crossLinks: [(tag: "sr", href: "section-sr-002.xhtml")])
        XCTAssertTrue(xhtml.contains(
            #"<p class="scene-heading" id="p-en-aaaa">"#
            + #"<a href="section-sr-002.xhtml#p-sr-aaaa">INT. ROOM - DAY</a></p>"#), xhtml)
    }

    /// The fragment names the TARGET body, never this one — a link to
    /// `#p-en-aaaa` from the `en` body is a link to itself and goes nowhere.
    func test_theLinksFragmentNamesTheTargetBodyNotThisOne() {
        let xhtml = XHTMLBodyEmitter.emit(
            screenplay([.fountain(.sceneHeading("INT. ROOM - DAY", sceneNumber: nil))],
                       anchors: [0: "aaaa"]),
            anchorTag: "en", crossLinks: [(tag: "sr", href: "section-sr-002.xhtml")])
        XCTAssertFalse(xhtml.contains("href=\"section-sr-002.xhtml#p-en-aaaa\""), xhtml)
    }

    /// XHTML cannot nest `<a>` — where LaTeX wraps a second `\MaughamCrossLink`
    /// around the first, XHTML emits ONE link around the text and a sibling
    /// marker per further body.
    func test_aSecondOtherBodyBecomesASiblingMarkerNotANestedLink() {
        let xhtml = XHTMLBodyEmitter.emit(
            screenplay([.fountain(.sceneHeading("INT. ROOM - DAY", sceneNumber: nil))],
                       anchors: [0: "aaaa"]),
            anchorTag: "en",
            crossLinks: [(tag: "sr", href: "section-sr-002.xhtml"),
                         (tag: "de", href: "section-de-002.xhtml")])
        XCTAssertTrue(xhtml.contains(
            #"<a href="section-sr-002.xhtml#p-sr-aaaa">INT. ROOM - DAY</a>"#
            + #"<span class="cross-links">"#
            + #"<a class="cross-link" href="section-de-002.xhtml#p-de-aaaa">→ DE</a>"#
            + "</span>"), xhtml)
        XCTAssertFalse(xhtml.contains("<a href=\"section-sr-002.xhtml#p-sr-aaaa\"><a"), xhtml)
    }

    /// The scene number is the heading's own furniture, not part of the link's
    /// clickable text; the markers follow everything.
    func test_aSceneNumberStaysOutsideTheLink() {
        let xhtml = XHTMLBodyEmitter.emit(
            screenplay([.fountain(.sceneHeading("INT. ROOM - DAY", sceneNumber: "4A"))],
                       anchors: [0: "aaaa"]),
            anchorTag: "en", crossLinks: [(tag: "sr", href: "section-sr-002.xhtml")])
        XCTAssertTrue(xhtml.contains(
            #"<a href="section-sr-002.xhtml#p-sr-aaaa">INT. ROOM - DAY</a>"#
            + #"<span class="scene-number">4A</span>"#), xhtml)
    }

    /// Only a slugline links. Every other node still anchors — that is what
    /// gives a link somewhere to land — but none of them becomes one.
    func test_noOtherNodeKindLinksEvenWhenOtherBodiesExist() {
        let xhtml = XHTMLBodyEmitter.emit(
            screenplay([.fountain(.action("He waits.")),
                        .fountain(.character("AARON")),
                        .fountain(.dialogue("Hi."))],
                       anchors: [0: "aaaa", 1: "bbbb", 2: "cccc"]),
            anchorTag: "en", crossLinks: [(tag: "sr", href: "section-sr-002.xhtml")])
        XCTAssertFalse(xhtml.contains("<a "), xhtml)
        XCTAssertFalse(xhtml.contains("<a>"), xhtml)
        XCTAssertTrue(xhtml.contains(#"<p class="action" id="p-en-aaaa">He waits.</p>"#), xhtml)
    }

    /// A slugline whose paragraph could not be identified has no id, so there
    /// is no anchor to point at in the other body either: it emits plainly.
    func test_anUnanchoredSluglineCannotLinkSoItDoesNot() {
        let xhtml = XHTMLBodyEmitter.emit(
            screenplay([.fountain(.sceneHeading("INT. ROOM - DAY", sceneNumber: nil))],
                       anchors: [:]),
            anchorTag: "en", crossLinks: [(tag: "sr", href: "section-sr-002.xhtml")])
        XCTAssertEqual(xhtml.contains("<a "), false, xhtml)
        XCTAssertTrue(xhtml.contains(#"<p class="scene-heading">INT. ROOM - DAY</p>"#), xhtml)
    }

    /// The single-body control: anchored, and not one link, because there is no
    /// other body to link to.
    func test_aBodyWithNoOthersAnchorsAndLinksNothing() {
        let xhtml = XHTMLBodyEmitter.emit(
            screenplay([.fountain(.sceneHeading("INT. ROOM - DAY", sceneNumber: nil))],
                       anchors: [0: "aaaa"]),
            anchorTag: "en")
        XCTAssertTrue(xhtml.contains(
            #"<p class="scene-heading" id="p-en-aaaa">INT. ROOM - DAY</p>"#), xhtml)
        XCTAssertFalse(xhtml.contains("<a "), xhtml)
    }
}

// MARK: - report elements (report foundations plan 2, Task 6)

/// A book of prose pieces whose paragraphs reconcile, so every node knows its
/// `¶id`; the context carries the switches and the citable research.
private struct XHTMLReportBook: ProjectASTBuilder.Source {
    let pieces: [(id: String, paragraphs: [(id: String, text: String)])]
    var context: PublishContext = .empty
    func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
        pieces.map { piece in
            .init(pieceID: piece.id, title: "Title \(piece.id)", mode: .prose,
                  displayText: piece.paragraphs.map(\.text).joined(separator: "\n\n"),
                  paragraphs: piece.paragraphs)
        }
    }
    func publishContext() -> PublishContext { context }
}

final class XHTMLReportElementEmitterTests: XCTestCase {

    private static let ids = ["a1b2", "c3d4", "e5f6", "g7h8", "j9k0", "m1n2", "p3q4", "r5s6",
                              "t7v8", "w9x0", "y1z2", "b3c4"]

    private static func context(numberSections: Bool = false, lists: Bool = false,
                                research: [ResearchItem] = []) -> PublishContext {
        PublishContext(
            library: CitationLibrary(items: research), profile: .report,
            switches: (numberSections: numberSections, listOfFigures: lists, listOfTables: lists),
            projectURL: nil, piecePaths: [:])
    }

    private func book(_ paragraphs: [String], numberSections: Bool = false,
                      lists: Bool = false, research: [ResearchItem] = []) -> XHTMLReportBook {
        XHTMLReportBook(
            pieces: [("a", paragraphs.enumerated().map { (Self.ids[$0.offset], $0.element) })],
            context: Self.context(numberSections: numberSections, lists: lists, research: research))
    }

    /// The body with the book's resolution, and the body without one.
    private func bodies(_ source: ProjectASTBuilder.Source,
                        figureFiles: [String: [Int: String]] = [:],
                        labelHrefs: [ManuscriptLabel: String] = [:],
                        anchorTag: String? = nil,
                        crossLinks: [(tag: String, href: String)] = []) throws -> (resolved: String, plain: String) {
        let ast = try ProjectASTBuilder.build(from: source)
        let resolution = try PublishResolution.forCompile(source: source, bodyTag: nil,
                                                          imageAllowed: EPUBCompiler.imageAllowed)
        return (XHTMLBodyEmitter.emit(ast, anchorTag: anchorTag, crossLinks: crossLinks,
                                      resolution: resolution, figureFiles: figureFiles,
                                      labelHrefs: labelHrefs),
                XHTMLBodyEmitter.emit(ast, anchorTag: anchorTag, crossLinks: crossLinks))
    }

    private func smith() -> ResearchItem {
        ResearchItem(id: "r1", title: "Annual Report", type: .asset,
                     citation: CitationInfo(key: "smith2026", authors: ["Smith, Jane"],
                                            sourceTitle: "Annual Report", year: 2026))
    }

    private func label(_ reference: String) throws -> ManuscriptLabel {
        try XCTUnwrap(ManuscriptLabel(reference: reference))
    }

    // MARK: tables

    func test_table_rendersWithItsNumberedCaptionHeadAndAlignedCells() throws {
        let (resolved, plain) = try bodies(book([
            "| Item & co | 100% |\n|:--|--:|\n| a_b | <#1> |\nTable: Sales & costs {#tbl:sales}",
        ]))
        XCTAssertTrue(resolved.contains("""
            <table>
            <caption id="lbl-tbl-sales"><span class="caption-number">Table 1.</span> Sales &amp; costs</caption>
            <thead>
            <tr><th style="text-align:left">Item &amp; co</th><th style="text-align:right">100%</th></tr>
            </thead>
            <tbody>
            <tr><td style="text-align:left">a_b</td><td style="text-align:right">&lt;#1&gt;</td></tr>
            </tbody>
            </table>
            """), resolved)
        XCTAssertFalse(resolved.contains("Table: "), "no literal source with a resolution: \(resolved)")
        XCTAssertTrue(plain.contains("Table: Sales &amp; costs {#tbl:sales}"),
                      "the nil-resolution path keeps the literal source: \(plain)")
        XCTAssertFalse(plain.contains("<table"), plain)
    }

    /// R-S9: a table with no caption line still prints "Table n.", and its
    /// caption carries the element id the list of tables links to.
    func test_uncaptionedTable_stillPrintsItsNumber_andAShortRowIsPadded() throws {
        let (resolved, _) = try bodies(book(["| a | b | c |\n|---|:-:|---|\n| 1 | 2 |"]))
        XCTAssertTrue(resolved.contains("""
            <caption id="tbl-1"><span class="caption-number">Table 1.</span></caption>
            <thead>
            <tr><th>a</th><th style="text-align:center">b</th><th>c</th></tr>
            </thead>
            <tbody>
            <tr><td>1</td><td style="text-align:center">2</td><td></td></tr>
            </tbody>
            """), resolved)
    }

    /// The paragraph anchor keeps the element's own `id` (the anchor
    /// contract); the label rides the caption, so neither id is lost.
    func test_aTaggedTable_keepsTheParagraphAnchorOnTheTable() throws {
        let (resolved, _) = try bodies(book(["| a |\n|---|\n| 1 |\nTable: T {#tbl:t}"]), anchorTag: "en")
        XCTAssertTrue(resolved.contains("""
            <table id="p-en-a1b2">
            <caption id="lbl-tbl-t"><span class="caption-number">Table 1.</span> T</caption>
            """), resolved)
    }

    // MARK: figures

    func test_figure_rendersItsStagedImageAltAndNumberedCaption() throws {
        let (resolved, plain) = try bodies(
            book(["Intro.", "![Revenue & 50%](../research/r.png){#fig:rev_q1}"]),
            figureFiles: ["a": [1: "images/0123abcd.png"]])
        XCTAssertTrue(resolved.contains("""
            <figure>
            <img id="lbl-fig-rev_q1" src="images/0123abcd.png" alt="Revenue &amp; 50%"/>
            <figcaption><span class="caption-number">Figure 1.</span> Revenue &amp; 50%</figcaption>
            </figure>
            """), resolved)
        XCTAssertTrue(plain.contains("<p>![Revenue &amp; 50%](../research/r.png) {#fig:rev_q1}</p>"), plain)
    }

    /// R-S9 for figures: an empty caption still prints "Figure n.", and the
    /// alt text falls back to the number. Unlabelled, its id is `fig-<n>`.
    func test_uncaptionedFigure_stillPrintsItsNumber() throws {
        let (resolved, _) = try bodies(book(["![](../research/r.png)"]),
                                       figureFiles: ["a": [0: "images/ab.png"]])
        XCTAssertTrue(resolved.contains("""
            <img id="fig-1" src="images/ab.png" alt="Figure 1"/>
            <figcaption><span class="caption-number">Figure 1.</span></figcaption>
            """), resolved)
    }

    /// A figure the compiler could not stage is unresolved: its literal
    /// source, still addressable by its id so a link or a list entry lands.
    func test_figureWithNoStagedFile_rendersItsLiteralSource() throws {
        let (resolved, _) = try bodies(book(["![Chart](../research/c.png){#fig:c}"]))
        XCTAssertFalse(resolved.contains("<figure"), resolved)
        XCTAssertFalse(resolved.contains("<img"), resolved)
        XCTAssertTrue(resolved.contains("<p><span id=\"lbl-fig-c\">![Chart](../research/c.png) {#fig:c}</span></p>"),
                      resolved)
    }

    // MARK: footnotes

    func test_footnote_isANoterefAndAnAsideAtTheEndOfTheSection_andARepeatHasNoSecondId() throws {
        let (resolved, plain) = try bodies(book([
            "First[^a] and second[^b], again[^a].", "[^b]: Bee & co.", "[^a]: Ay_1.",
        ]))
        XCTAssertTrue(resolved.contains(
            "<p>First<sup><a epub:type=\"noteref\" role=\"doc-noteref\" href=\"#fn-1\" id=\"fnref-1\">1</a></sup>"
            + " and second<sup><a epub:type=\"noteref\" role=\"doc-noteref\" href=\"#fn-2\" id=\"fnref-2\">2</a></sup>,"
            + " again<sup><a epub:type=\"noteref\" role=\"doc-noteref\" href=\"#fn-1\">1</a></sup>.</p>"), resolved)
        XCTAssertTrue(resolved.hasSuffix("""
            <aside epub:type="footnote" role="doc-footnote" id="fn-1"><p><a href="#fnref-1">1</a> Ay_1.</p></aside>
            <aside epub:type="footnote" role="doc-footnote" id="fn-2"><p><a href="#fnref-2">2</a> Bee &amp; co.</p></aside>
            </section>
            """), resolved)
        XCTAssertFalse(resolved.contains("[^"), resolved)
        // R-S6: the nil-resolution path prints the refs literally and appends
        // each definition as a literal paragraph at the end of the section.
        XCTAssertTrue(plain.contains("<p>First[^a] and second[^b], again[^a].</p>"), plain)
        XCTAssertTrue(plain.hasSuffix("""
            <p>[^a]: Ay_1.</p>
            <p>[^b]: Bee &amp; co.</p>
            </section>
            """), plain)
        XCTAssertFalse(plain.contains("<aside"), plain)
    }

    func test_footnoteWithNoDefinition_rendersLiterally() throws {
        let (resolved, _) = try bodies(book(["Dangling[^nope]."]))
        XCTAssertTrue(resolved.contains("<p>Dangling[^nope].</p>"), resolved)
        XCTAssertFalse(resolved.contains("<aside"), resolved)
    }

    /// A note inside a note gets its own aside in the same file, after its
    /// parent's; a note in a caption, a cell or a heading is the same pair.
    /// The asides read in number order, whatever order the refs rendered in
    /// (a table's caption renders before its cells).
    func test_nestedAndPlacedNotes_allEndTheirSection() throws {
        let (resolved, _) = try bodies(book([
            "# Scope[^h]",
            "| Cell[^c] |\n|---|\n| x |\nTable: Cap[^t]",
            "Body[^n].",
            "[^h]: On heading.", "[^c]: In cell.", "[^t]: In caption.",
            "[^n]: Outer[^m].", "[^m]: Inner.",
        ]))
        XCTAssertTrue(resolved.contains(
            "<h2>Scope<sup><a epub:type=\"noteref\" role=\"doc-noteref\" href=\"#fn-1\" id=\"fnref-1\">1</a></sup></h2>"), resolved)
        XCTAssertTrue(resolved.hasSuffix("""
            <aside epub:type="footnote" role="doc-footnote" id="fn-1"><p><a href="#fnref-1">1</a> On heading.</p></aside>
            <aside epub:type="footnote" role="doc-footnote" id="fn-2"><p><a href="#fnref-2">2</a> In cell.</p></aside>
            <aside epub:type="footnote" role="doc-footnote" id="fn-3"><p><a href="#fnref-3">3</a> In caption.</p></aside>
            <aside epub:type="footnote" role="doc-footnote" id="fn-4"><p><a href="#fnref-4">4</a> Outer<sup><a epub:type="noteref" role="doc-noteref" href="#fn-5" id="fnref-5">5</a></sup>.</p></aside>
            <aside epub:type="footnote" role="doc-footnote" id="fn-5"><p><a href="#fnref-5">5</a> Inner.</p></aside>
            </section>
            """), resolved)
    }

    /// R-P2-3 across files: the EPUB emits one section per call, and the
    /// second piece's `[^1]` continues the book's count rather than restarting.
    func test_footnotesNumberContinuouslyAcrossTwoSectionFiles() throws {
        let source = XHTMLReportBook(pieces: [
            ("a", [("a1b2", "One[^1]."), ("c3d4", "[^1]: First.")]),
            ("b", [("e5f6", "Two[^1]."), ("g7h8", "[^1]: Second.")]),
        ], context: Self.context())
        let ast = try ProjectASTBuilder.build(from: source)
        let r = try PublishResolution.forCompile(source: source, bodyTag: nil,
                                                 imageAllowed: EPUBCompiler.imageAllowed)
        let files = ast.sections.map { XHTMLBodyEmitter.emit(ProjectAST(sections: [$0]), resolution: r) }
        XCTAssertTrue(files[0].contains(##"href="#fn-1" id="fnref-1">1</a>"##), files[0])
        XCTAssertTrue(files[0].contains(#"<aside epub:type="footnote" role="doc-footnote" id="fn-1">"#), files[0])
        XCTAssertTrue(files[1].contains(##"href="#fn-2" id="fnref-2">2</a>"##), files[1])
        XCTAssertTrue(files[1].contains(##"<aside epub:type="footnote" role="doc-footnote" id="fn-2"><p><a href="#fnref-2">2</a> Second.</p></aside>"##),
                      files[1])
        XCTAssertFalse(files[1].contains("fn-1"), "each aside lives in its reference's file: \(files[1])")
    }

    // MARK: citations and cross-references

    func test_citation_rendersItsResolvedText_unknownKeysLiterally() throws {
        let (resolved, plain) = try bodies(book(
            ["As shown [@smith2026, p. 3]; not [@ghost]."], research: [smith()]))
        XCTAssertTrue(resolved.contains("<p>As shown (Smith 2026, p. 3); not [@ghost].</p>"), resolved)
        XCTAssertTrue(plain.contains("As shown [@smith2026, p. 3]"), plain)
    }

    /// The href names the target's own section file; a target this compile
    /// doesn't emit has no href and reads as its text, unlinked.
    func test_crossRef_linksIntoAnotherSectionsFile_orReadsItsTextWithoutAnHref() throws {
        let source = book(["![Chart](../research/c.png){#fig:chart}", "See @fig:chart and @tbl:none."])
        let href = "section-002.xhtml#lbl-fig-chart"
        let (linked, plain) = try bodies(source, figureFiles: ["a": [0: "images/c.png"]],
                                         labelHrefs: [try label("fig:chart"): href])
        XCTAssertTrue(linked.contains(
            "<p>See <a href=\"section-002.xhtml#lbl-fig-chart\">Figure 1</a> and @tbl:none.</p>"), linked)
        XCTAssertTrue(plain.contains("<p>See @fig:chart and @tbl:none.</p>"), plain)
        let (unlinked, _) = try bodies(source, figureFiles: ["a": [0: "images/c.png"]])
        XCTAssertTrue(unlinked.contains("<p>See Figure 1 and @tbl:none.</p>"), unlinked)
    }

    /// In a multi-body compile every body carries the same labels and notes,
    /// so each id names its body, as the PDF's anchors do.
    func test_aMultiBodyEmit_tagsEveryReportId() throws {
        let (resolved, _) = try bodies(
            book(["![Chart](../research/c.png){#fig:chart}", "![Two](../research/d.png)",
                  "| a |\n|---|\n| 1 |", "Note[^x].", "[^x]: Text."]),
            figureFiles: ["a": [0: "images/c.png", 1: "images/d.png"]],
            anchorTag: "sr", crossLinks: [(tag: "en", href: "section-en-001.xhtml")])
        for id in [#"id="lbl-sr-fig-chart""#, #"id="fig-sr-2""#, #"id="tbl-sr-1""#,
                   ##"href="#fn-sr-1" id="fnref-sr-1""##, #"id="fn-sr-1""#, ##"href="#fnref-sr-1""##] {
            XCTAssertTrue(resolved.contains(id), "missing \(id) in \(resolved)")
        }
        XCTAssertEqual(XHTMLBodyEmitter.labelID(try label("fig:chart"), tag: "sr"), "lbl-sr-fig-chart")
        XCTAssertEqual(XHTMLBodyEmitter.labelID(try label("fig:chart"), tag: nil), "lbl-fig-chart")
    }

    // MARK: headings

    func test_numberedHeading_carriesItsNumberAndItsLabelId() throws {
        let (resolved, plain) = try bodies(book(
            ["# Intro {#sec:intro}", "## Scope", "See @sec:intro."], numberSections: true),
            labelHrefs: [try label("sec:intro"): "section-001.xhtml#lbl-sec-intro"])
        XCTAssertTrue(resolved.contains("""
            <h2><span id="lbl-sec-intro"><span class="section-number">1</span> Intro</span></h2>
            <h3><span class="section-number">1.1</span> Scope</h3>
            """), resolved)
        XCTAssertTrue(resolved.contains("<p>See <a href=\"section-001.xhtml#lbl-sec-intro\">Section 1</a>.</p>"),
                      resolved)
        XCTAssertTrue(plain.contains("<h2>Intro {#sec:intro}</h2>"), plain)
        let (unnumbered, _) = try bodies(book(["# Intro"], numberSections: false))
        XCTAssertTrue(unnumbered.contains("<h2>Intro</h2>"), unnumbered)
    }

    // MARK: References

    func test_references_areAnXHTMLSectionOfTheCitedSources() throws {
        let source = book(["Cited [@smith2026]."], research: [smith()])
        let r = try PublishResolution.forCompile(source: source, bodyTag: nil,
                                                 imageAllowed: EPUBCompiler.imageAllowed)
        XCTAssertEqual(XHTMLBodyEmitter.references(r.references), """
            <section class="references">
            <h1>References</h1>
            <p class="reference">Smith, Jane. 2026. <em>Annual Report</em>.</p>
            </section>
            """)
    }

    // MARK: escaping

    func test_everyTextPathEscapes() throws {
        let (resolved, _) = try bodies(book([
            "# A < B & C {#sec:x}",
            "| x<y | \"z\" |\n|---|---|\n| u & v | 'w' |\nTable: C&D <b>",
            "![A <b> & \"c\"](../research/r.png)",
            "N[^q].", "[^q]: <i>&",
        ], numberSections: true), figureFiles: ["a": [2: "images/r.png"]])
        for raw in ["A < B", "x<y", "C&D", "<b>", "<i>", "u & v", "\"c\""] {
            XCTAssertFalse(resolved.contains(raw), "\(raw) reached XHTML unescaped: \(resolved)")
        }
        XCTAssertTrue(resolved.contains(#"alt="A &lt;b&gt; &amp; &quot;c&quot;""#), resolved)
    }
}
