import XCTest
@testable import Maugham

final class ProjectASTTests: XCTestCase {

    func testSection_holdsModeAndContent() {
        let s = ProjectAST.Section(
            pieceID: "p_abc",
            title: "Chapter 1",
            mode: .prose,
            nodes: [.paragraph("Hello.")]
        )
        XCTAssertEqual(s.mode, .prose)
        XCTAssertEqual(s.nodes.count, 1)
    }

    func testAST_holdsSectionsInOrder() {
        let a = ProjectAST(sections: [
            .init(pieceID: "p1", title: "One", mode: .prose, nodes: []),
            .init(pieceID: "p2", title: "Two", mode: .fountain, nodes: []),
        ])
        XCTAssertEqual(a.sections.map(\.pieceID), ["p1", "p2"])
    }

    func testProseNodes_haveExpectedCases() {
        let nodes: [ProjectAST.ProseNode] = [
            .paragraph([.text("plain")]),
            .heading(level: 2, [.text("Day 1/3")]),
            .blockquote([.paragraph([.text("quoted")])]),
            .sceneBreak,
        ]
        XCTAssertEqual(nodes.count, 4)
    }

    func testInline_haveExpectedCases() {
        let inlines: [ProjectAST.Inline] = [
            .text("plain"),
            .emphasis([.text("italic")]),
            .strong([.text("bold")]),
            .code("x"),
            .wikiLink(target: "Aaron", display: "him"),
            .lineBreak,
        ]
        XCTAssertEqual(inlines.count, 6)
    }

    func testInline_nests() {
        let nested: ProjectAST.Inline = .strong([.text("bold "), .emphasis([.text("italic")])])
        XCTAssertEqual(nested, .strong([.text("bold "), .emphasis([.text("italic")])]))
    }

    func testFountainNodes_haveExpectedCases() {
        let nodes: [ProjectAST.FountainNode] = [
            .sceneHeading("INT. KITCHEN - DAY"),
            .action("Aaron pours coffee."),
            .character("AARON"),
            .dialogue("Morning."),
            .parenthetical("(quietly)"),
            .transition("CUT TO:"),
            .dualDialogue(
                left: [.character("AARON"), .dialogue("Hi.")],
                right: [.character("BETH"), .dialogue("Hi.")]
            ),
        ]
        XCTAssertEqual(nodes.count, 7)
    }
}
