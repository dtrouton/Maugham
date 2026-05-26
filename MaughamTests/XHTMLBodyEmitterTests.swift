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

    func testEmits_emphasis_and_strong_inline() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .emphasis("italic"), .strong("bold")
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<em>italic</em>"))
        XCTAssertTrue(xhtml.contains("<strong>bold</strong>"))
    }

    func testEmits_sceneBreak_asHR() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [.sceneBreak])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<hr class=\"scene-break\"/>"))
    }

    func testEmits_wikiLink_asSpan() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .wikiLink(target: "Aaron", display: "him")
            ])
        ])
        let xhtml = XHTMLBodyEmitter.emit(ast)
        XCTAssertTrue(xhtml.contains("<span class=\"wiki-link\" data-target=\"Aaron\">him</span>"))
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
