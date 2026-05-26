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
            .paragraph("plain"),
            .emphasis("italic"),
            .strong("bold"),
            .wikiLink(target: "Aaron", display: "him"),
            .sceneBreak,
        ]
        XCTAssertEqual(nodes.count, 5)
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
