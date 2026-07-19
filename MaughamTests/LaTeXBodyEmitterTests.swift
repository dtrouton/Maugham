import XCTest
@testable import Maugham

final class LaTeXBodyEmitterTests: XCTestCase {

    func testEmits_emptyAST_onlyStrikethroughFallback() {
        // The unconditional \st providecommand fallback (task-8) is the only
        // line emitted even with zero sections.
        let body = LaTeXBodyEmitter.emit(ProjectAST(sections: []))
        XCTAssertEqual(body.trimmingCharacters(in: .whitespacesAndNewlines),
                       "\\providecommand{\\st}[1]{#1}")
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
        let body = LaTeXBodyEmitter.emit(ast)
        // Emphasis/strong render INSIDE the paragraph, not as separate blocks.
        XCTAssertTrue(body.contains("a \\emph{italic} b \\textbf{bold}"))
    }

    func testEmits_nestedEmphasis() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph([.strong([.text("bold "), .emphasis([.text("italic")])])])
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\textbf{bold \\emph{italic}}"))
    }

    func testEmits_inlineCode_asTexttt_andDoesNotInterpretInside() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph([.code("**not bold**")])
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\texttt{**not bold**}"))
        XCTAssertFalse(body.contains("\\textbf{not bold}"))
    }

    func testEmits_hardLineBreak() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph([.text("a"), .lineBreak, .text("b")])
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("a\\newline b"))
    }

    func testEmits_hardLineBreak_beforeBracketOrStar_noArgumentCapture() {
        // A bare `\\` scans forward for `*` and `[...]`: text starting with `[`
        // becomes its optional argument (compile failure "Missing number") and
        // a leading `*` is swallowed as the starred form. `\newline` scans
        // nothing.
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph([.text("a"), .lineBreak, .text("[x] bracketed")]),
                .paragraph([.text("b"), .lineBreak, .text("*starred")]),
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("a\\newline [x] bracketed"))
        XCTAssertTrue(body.contains("b\\newline *starred"))
        XCTAssertFalse(body.contains("\\\\["))
        XCTAssertFalse(body.contains("\\\\*"))
    }

    func testEmits_inlineWikiLink_command() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph([.wikiLink(target: "Aaron", display: "him")])
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\wikilink{Aaron}{him}"))
    }

    // MARK: - paragraph separation

    func testParagraphs_separatedByBlankLine_forPar() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .paragraph("One."), .paragraph("Two.")
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        // A blank line must sit between the two paragraphs so LaTeX makes a \par.
        XCTAssertTrue(body.contains("One.\n\nTwo."))
    }

    // MARK: - headings

    func testEmits_heading_sectionStarAndTocLine() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .heading(level: 2, [.text("Day 1/3")])
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\subsection*{Day 1/3}"))
        XCTAssertTrue(body.contains("\\addcontentsline{toc}{subsection}{Day 1/3}"))
    }

    func testEmits_heading_levelOne_isSection() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .heading(level: 1, [.text("Top")])
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\section*{Top}"))
        XCTAssertTrue(body.contains("\\addcontentsline{toc}{section}{Top}"))
    }

    func testEmits_heading_tocEntryIsPlainText() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .heading(level: 2, [.strong([.text("Bold")]), .text(" title")])
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        // Heading itself keeps formatting; ToC entry is flattened to plain text.
        XCTAssertTrue(body.contains("\\subsection*{\\textbf{Bold} title}"))
        XCTAssertTrue(body.contains("\\addcontentsline{toc}{subsection}{Bold title}"))
    }

    // MARK: - blockquote

    func testEmits_blockquote_quoteEnvironment() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .blockquote([.paragraph([.text("Quoted.")])])
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\begin{quote}"))
        XCTAssertTrue(body.contains("Quoted."))
        XCTAssertTrue(body.contains("\\end{quote}"))
    }

    // MARK: - lists + verbatim

    func testEmits_unorderedList_itemizeEnvironment() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .prose(.list(ordered: false, items: [[.text("one")], [.text("two")]]))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\begin{itemize}"))
        XCTAssertTrue(body.contains("\\item one"))
        XCTAssertTrue(body.contains("\\item two"))
        XCTAssertTrue(body.contains("\\end{itemize}"))
    }

    func testEmits_orderedList_enumerateEnvironment() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .prose(.list(ordered: true, items: [[.text("a")], [.text("b")]]))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\begin{enumerate}"))
        XCTAssertTrue(body.contains("\\item a"))
        XCTAssertTrue(body.contains("\\end{enumerate}"))
    }

    func testEmits_verbatim_escapedLinesJoinedByHardBreak_noMonospace() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .prose(.verbatim(["*not em*", "50% off"]))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("*not em*\\newline 50\\% off"))
        XCTAssertFalse(body.contains("\\texttt"))
        XCTAssertFalse(body.contains("\\emph"))
    }

    func testEmits_verbatim_lineStartingWithBracket_noArgumentCapture() {
        // A fenced line beginning with `[` (e.g. TOML/INI headers) must not be
        // captured as `\\`'s optional argument — that was a real compile
        // failure ("Missing number, treated as zero").
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [
                .prose(.verbatim(["[options]", "key = value"]))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("[options]\\newline key = value"))
        XCTAssertFalse(body.contains("\\\\["))
    }

    // MARK: - scene break + escaping

    func testEmits_sceneBreak_command() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [.sceneBreak])
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

    // MARK: - fountain (unchanged)

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

    func testEmits_fountainInlineEmphasis_inActionAndDialogue() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.action([.text("She runs "), .emphasis([.text("fast")])])),
                .fountain(.dialogue([.strong([.text("Now")]), .text("!")])),
                .fountain(.parenthetical([.underline([.text("sotto")])])),
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\action{She runs \\emph{fast}}"))
        XCTAssertTrue(body.contains("\\dialogue{\\textbf{Now}!}"))
        XCTAssertTrue(body.contains("\\parenthetical{\\underline{sotto}}"))
    }

    func testEmits_fountainTitlePage_centeredOnOwnPage() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.titlePage([
                    .init(key: "Title", value: "Good Luck Babe"),
                    .init(key: "Author", value: "Chappell Roan"),
                ]))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\begin{center}"))
        XCTAssertTrue(body.contains("{\\Large\\textbf{Good Luck Babe}}\\par"))
        XCTAssertTrue(body.contains("Chappell Roan\\par"))
        XCTAssertTrue(body.contains("\\end{center}"))
        // Its own page.
        XCTAssertTrue(body.contains("\\clearpage"))
    }

    func testEmits_fountainTitlePage_multilineField_noArgumentCapture() {
        // Multiline title-page fields are joined by line breaks; a continuation
        // line starting with `[` must not become `\\`'s optional argument.
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.titlePage([
                    .init(key: "Contact", value: "Agent Name\n[c/o] The Agency"),
                ]))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("Agent Name\\newline [c/o] The Agency"))
        XCTAssertFalse(body.contains("\\\\["))
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

    // MARK: - fountain vocabulary expansion (lyric/centered/pageBreak/scene numbers)

    func testEmits_sceneHeading_nilSceneNumber_isByteIdenticalToToday() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. KITCHEN - DAY", sceneNumber: nil)),
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\scene{INT. KITCHEN - DAY}"))
        // The scene command itself carries no \scenenumber invocation (the
        // providecommand *definition* legitimately mentions the token, so
        // check the call site specifically, not mere substring presence).
        XCTAssertFalse(body.contains("\\scene{INT. KITCHEN - DAY\\scenenumber"))
    }

    func testEmits_sceneHeading_withSceneNumber_appendsScenenumberInsideArgument() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. HOUSE - DAY", sceneNumber: "42")),
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\scene{INT. HOUSE - DAY\\scenenumber{42}}"))
    }

    func testEmits_lyric_command() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.lyric("Hush now, don't you cry")),
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\lyricline{Hush now, don't you cry}"))
    }

    func testEmits_centered_command() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.centered("THE END")),
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\centeredline{THE END}"))
    }

    func testEmits_pageBreak_command() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.action("Before.")),
                .fountain(.pageBreak),
                .fountain(.action("After.")),
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        // Two \clearpage: one from the providecommand-adjacent... no — just the
        // explicit page break node. Assert it appears between the two actions.
        let beforeIdx = body.range(of: "Before.")!.lowerBound
        let afterIdx = body.range(of: "After.")!.lowerBound
        let breakRange = body.range(of: "\\clearpage", range: beforeIdx..<afterIdx)
        XCTAssertNotNil(breakRange)
    }

    func testEmits_fountainSection_includesProvidecommandPrologue_onceBeforeFirstNode() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.action("Aaron pours coffee.")),
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\providecommand{\\lyricline}[1]{\\textit{#1}\\par}"))
        XCTAssertTrue(body.contains("\\providecommand{\\centeredline}[1]{\\begin{center}#1\\end{center}}"))
        XCTAssertTrue(body.contains("\\providecommand{\\scenenumber}[1]{\\hfill #1}"))
        // Prologue precedes the first content node.
        let prologueIdx = body.range(of: "\\providecommand{\\lyricline}")!.lowerBound
        let actionIdx = body.range(of: "\\action{Aaron")!.lowerBound
        XCTAssertLessThan(prologueIdx, actionIdx)
        // Emitted exactly once even though only one fountain section exists.
        XCTAssertEqual(body.components(separatedBy: "\\providecommand{\\lyricline}").count - 1, 1)
    }

    func testSubsequentSections_clearPage_firstDoesNot() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "First", mode: .prose, nodes: []),
            .init(pieceID: "p2", title: "Second", mode: .prose, nodes: [])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        // Exactly one \clearpage — before the second piece, not the first, so
        // pieces start on their own pages with no leading blank page.
        XCTAssertEqual(body.components(separatedBy: "\\clearpage").count - 1, 1)
        let clearIdx = body.range(of: "\\clearpage")!.lowerBound
        let firstIdx = body.range(of: "First")!.lowerBound
        let secondIdx = body.range(of: "Second")!.lowerBound
        XCTAssertLessThan(firstIdx, clearIdx)
        XCTAssertLessThan(clearIdx, secondIdx)
    }
}
