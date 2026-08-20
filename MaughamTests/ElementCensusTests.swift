import XCTest
@testable import Maugham

/// Task 1: `ElementCensus` — what the book actually contains.
///
/// `take(from:)` switches exhaustively over `ProjectAST.Node`,
/// `.ProseNode`, `.FountainNode` and `.Inline` with no `default:` arm, so
/// this file fails to compile the moment `ProjectAST` grows a case this
/// census doesn't know about — no test can pin that better than the build
/// itself.
final class ElementCensusTests: XCTestCase {

    func testEmptyProject_reportsEmptyCensus() {
        let ast = ProjectAST(sections: [])
        let census = ElementCensus.take(from: ast)
        XCTAssertTrue(census.kinds.isEmpty)
        XCTAssertTrue(census.firstPiece.isEmpty)
    }

    func testProjectWithNoNodes_reportsEmptyCensus() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "One", mode: .prose, nodes: []),
        ])
        let census = ElementCensus.take(from: ast)
        XCTAssertTrue(census.kinds.isEmpty)
    }

    func testEveryProseKind_reportedWithFirstPiece() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "One", mode: .prose, nodes: [
                .paragraph([.text("plain")]),
                .heading(level: 2, [.text("Day 1/3")]),
                .blockquote([.paragraph([.text("quoted")])]),
                .sceneBreak,
                .prose(.list(ordered: false, items: [[.text("x")]])),
                .prose(.verbatim(["code"])),
            ]),
        ])
        let census = ElementCensus.take(from: ast)
        let expected: Set<ElementCensus.Kind> = [
            .paragraph, .heading, .blockquote, .sceneBreak, .list, .verbatim,
        ]
        XCTAssertEqual(census.kinds, expected)
        for kind in expected {
            XCTAssertEqual(census.firstPiece[kind], "p1")
        }
    }

    func testEveryFountainKind_reportedAsItsOwnKind() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Scene", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. KITCHEN - DAY")),
                .fountain(.action("Aaron pours coffee.")),
                .fountain(.character("AARON")),
                .fountain(.dialogue("Morning.")),
                .fountain(.parenthetical("(quietly)")),
                .fountain(.transition("CUT TO:")),
                .fountain(.lyric("La la la")),
                .fountain(.centered("THE END")),
                .fountain(.pageBreak),
                .fountain(.titlePage([.init(key: "Title", value: "Kitchen")])),
                .fountain(.dualDialogue(
                    left: [.character("AARON"), .dialogue("Hi.")],
                    right: [.character("BETH"), .dialogue("Hi.")]
                )),
            ]),
        ])
        let census = ElementCensus.take(from: ast)
        let expected: Set<ElementCensus.Kind> = [
            .sceneHeading, .action, .character, .dialogue, .parenthetical,
            .transition, .lyric, .centered, .pageBreak, .titlePage, .dualDialogue,
        ]
        XCTAssertEqual(census.kinds, expected)
        // Fountain elements census as their own kinds, distinct from prose's
        // (no collapsing e.g. .heading and .sceneHeading together).
        XCTAssertFalse(census.kinds.contains(.heading))
        XCTAssertFalse(census.kinds.contains(.paragraph))
    }

    func testDualDialogue_recursesIntoBothSides() {
        // A kind that appears only inside dualDialogue's nested nodes (here,
        // .character/.dialogue) must still be picked up by the walk.
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Scene", mode: .fountain, nodes: [
                .fountain(.dualDialogue(
                    left: [.parenthetical("(overlapping)")],
                    right: [.transition("CUT TO:")]
                )),
            ]),
        ])
        let census = ElementCensus.take(from: ast)
        XCTAssertTrue(census.kinds.contains(.dualDialogue))
        XCTAssertTrue(census.kinds.contains(.parenthetical))
        XCTAssertTrue(census.kinds.contains(.transition))
    }

    func testInlineKinds_censusedInsideParagraphsAndNestedInlines() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "One", mode: .prose, nodes: [
                .paragraph([
                    .strong([.text("bold "), .emphasis([.text("italic")])]),
                    .strikethrough([.text("gone")]),
                    .code("x"),
                    .wikiLink(target: "Aaron", display: "him"),
                    .lineBreak,
                ]),
            ]),
        ])
        let census = ElementCensus.take(from: ast)
        let expected: Set<ElementCensus.Kind> = [
            .paragraph, .strong, .emphasis, .strikethrough, .code, .wikiLink, .lineBreak,
        ]
        XCTAssertEqual(census.kinds, expected)
    }

    func testUnderline_censusedFromFountainInlines() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Scene", mode: .fountain, nodes: [
                .fountain(.action([.underline([.text("emphasized")])])),
            ]),
        ])
        let census = ElementCensus.take(from: ast)
        XCTAssertTrue(census.kinds.contains(.underline))
        XCTAssertTrue(census.kinds.contains(.action))
    }

    func testFirstPiece_recordsTheFirstOccurrenceOnly() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "One", mode: .prose, nodes: [.paragraph("a")]),
            .init(pieceID: "p2", title: "Two", mode: .prose, nodes: [.paragraph("b")]),
        ])
        let census = ElementCensus.take(from: ast)
        XCTAssertEqual(census.firstPiece[.paragraph], "p1")
    }

    func testBlockquote_recursesIntoNestedProseNodes() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "One", mode: .prose, nodes: [
                .blockquote([.sceneBreak]),
            ]),
        ])
        let census = ElementCensus.take(from: ast)
        XCTAssertTrue(census.kinds.contains(.blockquote))
        XCTAssertTrue(census.kinds.contains(.sceneBreak))
        XCTAssertEqual(census.firstPiece[.sceneBreak], "p1")
    }
}
