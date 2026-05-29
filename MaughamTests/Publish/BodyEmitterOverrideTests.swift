import XCTest
@testable import Maugham

final class BodyEmitterOverrideTests: XCTestCase {
    private func proseAST(pieceID: String, title: String, _ text: String) -> ProjectAST {
        ProjectASTBuilder.build(from: SinglePieceSource(pieceID: pieceID, title: title, mode: .prose, text: text))
    }

    func test_titleOverride_replacesSectionTitle() {
        var cfg = PublishConfig(); cfg.sections["ab12"] = .init(titleOverride: "New Title")
        let out = LaTeXBodyEmitter.emit(proseAST(pieceID: "ab12", title: "Old Title", "Body."), config: cfg)
        XCTAssertTrue(out.contains("\\begin{prose}{New Title}"))
        XCTAssertFalse(out.contains("Old Title"))
    }

    func test_includeInTocFalse_emitsNotocOptionalArg() {
        var cfg = PublishConfig(); cfg.sections["ab12"] = .init(includeInToc: false)
        let out = LaTeXBodyEmitter.emit(proseAST(pieceID: "ab12", title: "T", "Body."), config: cfg)
        XCTAssertTrue(out.contains("\\begin{prose}[notoc]{T}"))
    }

    func test_includeInTocTrue_isDefaultNoOptionalArg() {
        let out = LaTeXBodyEmitter.emit(proseAST(pieceID: "ab12", title: "T", "Body."), config: PublishConfig())
        XCTAssertTrue(out.contains("\\begin{prose}{T}"))
        XCTAssertFalse(out.contains("[notoc]"))
    }

    func test_startOnRecto_emitsCleardoublepage() {
        var cfg = PublishConfig()
        cfg.sections["bb22"] = .init(startOn: .recto)
        let ast = ProjectAST(sections: [
            proseAST(pieceID: "aa11", title: "One", "A.").sections[0],
            proseAST(pieceID: "bb22", title: "Two", "B.").sections[0],
        ])
        let out = LaTeXBodyEmitter.emit(ast, config: cfg)
        XCTAssertTrue(out.contains("\\cleardoublepage"))
    }
}
