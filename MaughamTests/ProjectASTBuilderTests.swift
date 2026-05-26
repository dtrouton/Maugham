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
