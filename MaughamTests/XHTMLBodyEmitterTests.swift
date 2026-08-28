import XCTest
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
