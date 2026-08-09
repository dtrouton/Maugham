import XCTest
@testable import Maugham

final class BodyEmitterOverrideTests: XCTestCase {
    private func proseAST(pieceID: String, title: String, _ text: String) -> ProjectAST {
        // try! is sound: SinglePieceSource is in-memory and cannot throw.
        try! ProjectASTBuilder.build(from: SinglePieceSource(pieceID: pieceID, title: title, mode: .prose, text: text))
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

    // MARK: - styleFile scoped group

    func test_styleFile_wrapsSectionInScopedGroupBeforeEnvironment() throws {
        var cfg = PublishConfig(); cfg.sections["ab12"] = .init(styleFile: "tribute.tex")
        let ast = try ProjectASTBuilder.build(from: SinglePieceSource(pieceID: "ab12", title: "T", mode: .prose, text: "Body."))
        let out = LaTeXBodyEmitter.emit(ast, config: cfg)
        let g = out.range(of: "\\begingroup")!
        let inp = out.range(of: "\\input{pieces/tribute.tex}")!
        let env = out.range(of: "\\begin{prose}")!
        let end = out.range(of: "\\endgroup")!
        XCTAssertTrue(g.lowerBound < inp.lowerBound)
        XCTAssertTrue(inp.lowerBound < env.lowerBound, "input before environment (title-page pattern depends on this)")
        XCTAssertTrue(env.lowerBound < end.lowerBound)
    }

    /// THE INVARIANT THE SCOPED GROUP EXISTS FOR. If \input is ever hoisted out of
    /// \begingroup, a styled piece leaks its redefinitions into the next piece.
    func test_styleFile_scopeDoesNotLeakIntoNextPiece() throws {
        var cfg = PublishConfig(); cfg.sections["aa11"] = .init(styleFile: "x.tex")  // bb22 has no styleFile
        let ast = ProjectAST(sections: [
            try ProjectASTBuilder.build(from: SinglePieceSource(pieceID: "aa11", title: "One", mode: .prose, text: "A.")).sections[0],
            try ProjectASTBuilder.build(from: SinglePieceSource(pieceID: "bb22", title: "Two", mode: .prose, text: "B.")).sections[0],
        ])
        let out = LaTeXBodyEmitter.emit(ast, config: cfg)
        let endgroup = out.range(of: "\\endgroup")!
        let twoEnv = out.range(of: "\\begin{prose}{Two}")!
        XCTAssertTrue(endgroup.lowerBound < twoEnv.lowerBound, "second piece must follow \\endgroup (scope closed)")
        let after = String(out[twoEnv.lowerBound...])
        XCTAssertFalse(after.contains("\\input{pieces/"), "unstyled piece must not source any style file")
    }

    func test_noStyleFile_emitsNoGroup() throws {
        let ast = try ProjectASTBuilder.build(from: SinglePieceSource(pieceID: "ab12", title: "T", mode: .prose, text: "Body."))
        let out = LaTeXBodyEmitter.emit(ast, config: PublishConfig())
        XCTAssertFalse(out.contains("\\begingroup"))
        XCTAssertFalse(out.contains("\\input{pieces/"))
    }

    // MARK: - XHTMLBodyEmitter overrides

    func test_xhtml_titleOverride_replacesH1() throws {
        var cfg = PublishConfig(); cfg.sections["ab12"] = .init(titleOverride: "New")
        let ast = try ProjectASTBuilder.build(from: SinglePieceSource(pieceID: "ab12", title: "Old", mode: .prose, text: "Body."))
        let out = XHTMLBodyEmitter.emit(ast, config: cfg)
        XCTAssertTrue(out.contains("<h1>New</h1>"))
        XCTAssertFalse(out.contains("Old"))
    }

    func test_xhtml_includeInTocFalse_marksSection() throws {
        var cfg = PublishConfig(); cfg.sections["ab12"] = .init(includeInToc: false)
        let ast = try ProjectASTBuilder.build(from: SinglePieceSource(pieceID: "ab12", title: "T", mode: .prose, text: "Body."))
        let out = XHTMLBodyEmitter.emit(ast, config: cfg)
        XCTAssertTrue(out.contains("data-toc=\"false\""))
    }

    func test_xhtml_defaultConfig_unchanged() throws {
        let ast = try ProjectASTBuilder.build(from: SinglePieceSource(pieceID: "ab12", title: "T", mode: .prose, text: "Body."))
        let out = XHTMLBodyEmitter.emit(ast, config: PublishConfig())
        XCTAssertTrue(out.contains("<h1>T</h1>"))
        XCTAssertFalse(out.contains("data-toc"))
    }
}
