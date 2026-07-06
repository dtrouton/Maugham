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
}
