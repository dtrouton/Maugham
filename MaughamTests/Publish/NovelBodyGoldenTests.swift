import XCTest
@testable import Maugham

/// An existing novel republishes byte-identically (plan 2's review focus 1).
///
/// The two fixtures under `MaughamTests/Fixtures/` were captured from the
/// emitters BEFORE the AST builder switched onto the manuscript grammar
/// (`ManuscriptBlocks` / `ManuscriptInlineScanner`), and are never
/// regenerated to make a later change pass. The fixture novel holds none of
/// the report syntax (no pipe table, no `![…](…)` line, no `[^…]`, `[@…]` or
/// `@kind:name`), so every element in it must keep emitting exactly what it
/// always did: headings, emphasis, strong, strikethrough, lists, blockquote,
/// verbatim, a scene break, a hard break, inline code, a wiki link, the
/// paragraph anchors and a Fountain piece with a cross-linked slugline.
///
/// A missing fixture is written and the test fails once, as
/// `EmissionContractTests` does with `EMISSION.md`.
final class NovelBodyGoldenTests: XCTestCase {

    private struct NovelSource: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            NovelBodyGoldenTests.pieces
        }
    }

    /// `displayText` is the paragraphs joined by the blank-line separator, as
    /// `Materializer` writes it, so the builder reconciles the anchors.
    private static func piece(_ id: String, _ title: String, _ mode: ProjectAST.Mode,
                              _ paragraphs: [(id: String, text: String)]) -> ProjectASTBuilder.PieceRef {
        .init(pieceID: id, title: title, mode: mode,
              displayText: paragraphs.map(\.text).joined(separator: "\n\n"),
              paragraphs: paragraphs)
    }

    static let pieces: [ProjectASTBuilder.PieceRef] = [
        piece("ch01", "Chapter One", .prose, [
            ("a1b2", "# The Arrival"),
            ("c3d4", "It was a *dark* and **stormy** night, and ~~nobody~~ everybody knew it."),
            ("e5f6", "She opened the [[Letters|letter]] and read it\ntwice, slowly."),
            ("g7h8", "> The house is yours.\n> Do not sell it to *him*."),
            ("j9k0", "- bread\n- *salt*\n- candles"),
            ("m1n2", "* * *"),
            ("p3q4", "1. first\n2. second"),
            ("r5s6", "```\nraw $text & {braces} 100%\n[bracketed] line\n```"),
            ("t7v8", "## A smaller _heading_"),
            ("w9x0", "A line with a hard break  \nand its tail, plus `code` and 100% of #hash_tags."),
            ("y1z2", "An email to mary@example.com costs $5 & a ~tilde~ ^caret^."),
        ]),
        // No paragraphs: the anchors are empty and nothing is tagged.
        .init(pieceID: "ch02", title: "Chapter Two", mode: .prose,
              displayText: "### Deep\n\n**Bold *nested* run** and *em with **strong** inside*.\n\nThe end."),
        piece("sc01", "The Kitchen", .fountain, [
            ("b3c4", "INT. KITCHEN - NIGHT"),
            ("d5e6", "Mary stands at the *window*."),
            ("f7g8", "MARY\n(quietly)\nIs anyone there?"),
            ("h9j0", "CUT TO:"),
        ]),
    ]

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Publish/
            .deletingLastPathComponent()   // MaughamTests/
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private func assertGolden(_ generated: String, _ name: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let url = fixtures.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try generated.write(to: url, atomically: true, encoding: .utf8)
            XCTFail("\(name) did not exist — wrote it. Re-run; commit the file.", file: file, line: line)
            return
        }
        let committed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(generated, committed,
            "\(name): the novel body changed. A novel with none of the report syntax must "
          + "republish byte-identically; never regenerate this fixture to make a change pass.",
            file: file, line: line)
    }

    func test_latexBody_isByteIdenticalToTheGolden() throws {
        let ast = try ProjectASTBuilder.build(from: NovelSource())
        try assertGolden(LaTeXBodyEmitter.emit(ast, anchorTag: "en", crossLinkTags: ["sr"]),
                         "novel-golden-body.tex")
    }

    /// Every real compile now passes the book's resolution (Task 5): a novel
    /// with none of the report syntax must emit the same bytes WITH one, under
    /// the same golden, whatever its switches (a novel may turn them on).
    func test_latexBody_withTheBooksResolution_isByteIdenticalToTheGolden() throws {
        let ast = try ProjectASTBuilder.build(from: NovelSource())
        for on in [false, true] {
            var context = PublishContext.empty
            context.switches = (numberSections: false, listOfFigures: on, listOfTables: on)
            let resolution = PublishResolution.resolve(ast, context: context, bodyTag: nil,
                                                       imageAllowed: ["png", "jpg", "jpeg", "pdf"])
            try assertGolden(LaTeXBodyEmitter.emit(ast, anchorTag: "en", crossLinkTags: ["sr"],
                                                   resolution: resolution),
                             "novel-golden-body.tex")
        }
    }

    func test_xhtmlBody_isByteIdenticalToTheGolden() throws {
        let ast = try ProjectASTBuilder.build(from: NovelSource())
        try assertGolden(XHTMLBodyEmitter.emit(ast, anchorTag: "en",
                                               crossLinks: [(tag: "sr", href: "section-sr-003.xhtml")]),
                         "novel-golden-body.xhtml")
    }
}
