import XCTest
@testable import Maugham

final class LaTeXBodyEmitterTests: XCTestCase {

    func testEmits_emptyAST_emptyBody() {
        let body = LaTeXBodyEmitter.emit(ProjectAST(sections: []))
        XCTAssertEqual(body.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testEmits_proseSection_environment() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Chapter 1", mode: .prose,
                  nodes: [.paragraph("Hello.")])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\begin{prose}{Chapter 1}"))
        XCTAssertTrue(body.contains("Hello."))
        XCTAssertTrue(body.contains("\\end{prose}"))
    }

    func testEmits_emphasisAndStrong() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph("plain "),
                .prose(.emphasis("italic")),
                .paragraph(" "),
                .prose(.strong("bold"))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\emph{italic}"))
        XCTAssertTrue(body.contains("\\textbf{bold}"))
    }

    func testEmits_wikiLink_command() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .prose(.wikiLink(target: "Aaron", display: "him"))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\wikilink{Aaron}{him}"))
    }

    func testEmits_sceneBreak_command() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [.prose(.sceneBreak)])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\scenebreak"))
    }

    func testEscapes_specialChars_inProseText() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph("50% off & $5 #1")
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("50\\% off \\& \\$5 \\#1"))
    }

    func testEscapes_sectionTitle() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Tom & Jerry", mode: .prose, nodes: [])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\begin{prose}{Tom \\& Jerry}"))
    }

    func testEmits_fountainSection_environment_andAllCommands() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "Scene Snippet", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. KITCHEN - DAY")),
                .fountain(.action("Aaron pours coffee.")),
                .fountain(.character("AARON")),
                .fountain(.parenthetical("(quietly)")),
                .fountain(.dialogue("Morning.")),
                .fountain(.transition("CUT TO:"))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\begin{screenplay}{Scene Snippet}"))
        XCTAssertTrue(body.contains("\\scene{INT. KITCHEN - DAY}"))
        XCTAssertTrue(body.contains("\\action{Aaron pours coffee.}"))
        XCTAssertTrue(body.contains("\\character{AARON}"))
        XCTAssertTrue(body.contains("\\parenthetical{(quietly)}"))
        XCTAssertTrue(body.contains("\\dialogue{Morning.}"))
        XCTAssertTrue(body.contains("\\transition{CUT TO:}"))
        XCTAssertTrue(body.contains("\\end{screenplay}"))
    }

    func testEmits_dualDialogue_command() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.dualDialogue(
                    left: [.character("AARON"), .dialogue("Left.")],
                    right: [.character("BETH"), .dialogue("Right.")]
                ))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\dualdialogue"))
        XCTAssertTrue(body.contains("AARON"))
        XCTAssertTrue(body.contains("BETH"))
    }

    func testMultipleSections_emittedInOrder() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "First", mode: .prose, nodes: []),
            .init(pieceID: "p2", title: "Second", mode: .fountain, nodes: [])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        let firstIdx = body.range(of: "First")!.lowerBound
        let secondIdx = body.range(of: "Second")!.lowerBound
        XCTAssertLessThan(firstIdx, secondIdx)
    }
}
