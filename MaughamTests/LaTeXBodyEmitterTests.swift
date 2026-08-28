import XCTest
@testable import Maugham

final class LaTeXBodyEmitterTests: XCTestCase {

    /// P3 Task 2: this test used to assert the `\st` fallback ALONE. The
    /// prologue is now three lines and always three lines — one contract,
    /// emitted whether or not the body carries a single anchor — so a preamble
    /// that never loaded `soul` and never loaded `hyperref` still compiles.
    func testEmits_emptyAST_onlyTheThreePrologueLines() {
        let body = LaTeXBodyEmitter.emit(ProjectAST(sections: []))
        XCTAssertEqual(body.trimmingCharacters(in: .whitespacesAndNewlines), """
            \\providecommand{\\st}[1]{#1}
            \\providecommand{\\hypertarget}[2]{#2}
            \\providecommand{\\MaughamCrossLink}[2]{\\ifdefined\\hyperlink\\hyperlink{#1}{#2}\\else#2\\fi}
            """)
    }

    /// The prologue does not depend on the arguments: an anchored, cross-linked
    /// body opens with exactly the same three lines as an empty one.
    func testEmits_prologueIsTheSameThreeLines_withATagAndOtherBodies() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose,
                  nodes: [.paragraph("Hello.")], anchors: [0: "k3wq"])
        ])
        let body = LaTeXBodyEmitter.emit(ast, anchorTag: "en", crossLinkTags: ["sr"])
        XCTAssertEqual(Array(body.components(separatedBy: "\n").prefix(3)), [
            "\\providecommand{\\st}[1]{#1}",
            "\\providecommand{\\hypertarget}[2]{#2}",
            "\\providecommand{\\MaughamCrossLink}[2]"
                + "{\\ifdefined\\hyperlink\\hyperlink{#1}{#2}\\else#2\\fi}",
        ], body)
    }

    /// **The cross-link fallback links wherever hyperref is loaded**, and only
    /// degrades where it is not.
    ///
    /// Its first spelling was a flat `{#2}`, which made every cross-link inert
    /// in every project that already existed: `PublishStarter.installIfMissing`
    /// returns early for an initialised project, so a book begun before this
    /// milestone never receives the starter's `\MaughamCrossLink` definition
    /// and had nothing but the flat fallback under it — links emitted, links
    /// dead, nothing red anywhere. `\ifdefined` is decided at each USE, so the
    /// body needs to know nothing about what the preamble loaded.
    ///
    /// Disable experiment: put the fallback back to
    /// `"\\providecommand{\\MaughamCrossLink}[2]{#2}"` and this fails with
    /// `XCTAssertTrue failed - the emitted fallback must call \hyperlink when
    /// hyperref has defined it`, and `BilingualPDFTests
    /// .test_aPreambleThatLoadsHyperrefLinksWithNoCrossLinkDefinitionOfItsOwn`
    /// reads 0 link annotations where it wants 4.
    func testEmits_crossLinkFallback_linksWhenHyperrefIsLoaded() {
        let body = LaTeXBodyEmitter.emit(ProjectAST(sections: []))
        let fallback = try? XCTUnwrap(body.components(separatedBy: "\n")
            .first { $0.contains("\\providecommand{\\MaughamCrossLink}") })
        let line = fallback ?? ""
        XCTAssertTrue(line.contains("\\ifdefined\\hyperlink"),
                      "the emitted fallback must call \\hyperlink when hyperref "
                      + "has defined it \u{2014} a flat {#2} leaves every "
                      + "pre-existing project's links inert: \(line)")
        XCTAssertTrue(line.contains("\\else#2\\fi"),
                      "\u{2026}and must still degrade to its content where "
                      + "hyperref is absent: \(line)")
        // The control: the OTHER two prologue lines are untouched flat
        // fallbacks, so this is one deliberate change and not a sweep.
        XCTAssertTrue(body.contains("\\providecommand{\\hypertarget}[2]{#2}"), body)
        XCTAssertTrue(body.contains("\\providecommand{\\st}[1]{#1}"), body)
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

    func testEmits_fountainTitlePage_screenplayTitleBlockHook() {
        // F6: the title block emits through the \screenplaytitleblock hook —
        // declared once per fountain section (with the other fountain
        // providecommands) and invoked with a single argument carrying all
        // fields in DECLARED order, each escaped, so a style file can restyle
        // the whole block.
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.titlePage([
                    .init(key: "Title", value: "Good Luck Babe"),
                    .init(key: "Author", value: "Chappell Roan"),
                ]))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertEqual(
            body.components(separatedBy: "\\providecommand{\\screenplaytitleblock}").count - 1,
            1, "the providecommand declaration must appear exactly once per fountain section")
        XCTAssertTrue(body.contains(
            "\\providecommand{\\screenplaytitleblock}[1]{\\begin{center}\\vspace*{1.5in}#1\\end{center}\\clearpage}"),
            "default body must reproduce the pre-F6 hardcoded frame")
        XCTAssertTrue(body.contains(
            "\\screenplaytitleblock{{\\Large\\textbf{Good Luck Babe}}\\par\n\\vspace{1.5em}\nChappell Roan\\par}"),
            "macro call must carry the fields in declared order; body:\n\(body)")
    }

    func testEmits_fountainTitlePage_screenplayTitleBlock_preservesDeclaredOrder() {
        // The tokenizer preserves as-authored order (Credit before Title is
        // legal); the pre-F6 emitter rendered in that order, so the hook call
        // must too — the Title field keeps its typography but is NOT hoisted
        // to the front.
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.titlePage([
                    .init(key: "Credit", value: "written by"),
                    .init(key: "Title", value: "The Play"),
                    .init(key: "Author", value: "A. Writer"),
                ]))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains(
            "\\screenplaytitleblock{written by\\par\n{\\Large\\textbf{The Play}}\\par\n\\vspace{1.5em}\nA. Writer\\par}"),
            "Credit declared before Title must render before Title; body:\n\(body)")
    }

    func testEmits_fountainTitlePage_screenplayTitleBlock_escapesArgs() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.titlePage([
                    .init(key: "Title", value: "100% Payback & Co."),
                    .init(key: "Author", value: "A_B"),
                ]))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("100\\% Payback \\& Co."), "title field must be escaped")
        XCTAssertTrue(body.contains("A\\_B\\par"), "other fields must be escaped")
    }

    func testEmits_fountainTitlePage_screenplayTitleBlock_noTitleField() {
        // A title page with no "Title" key renders its fields plain (matches
        // today's behavior: only "Title" was ever special-cased).
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .fountain, nodes: [
                .fountain(.titlePage([
                    .init(key: "Contact", value: "Agent Name"),
                ]))
            ])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertTrue(body.contains("\\screenplaytitleblock{Agent Name\\par}"))
    }

    func testEmits_proseSection_screenplayTitleBlockNeverEmitted() {
        // Prose sections don't declare fountain providecommands at all —
        // \screenplaytitleblock is fountain-only vocabulary.
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose, nodes: [.paragraph("Hello.")])
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertFalse(body.contains("screenplaytitleblock"))
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

    // MARK: - P3 Task 2: paragraph anchors

    /// The `\hypertarget` is its OWN line, immediately BEFORE the node's first
    /// line. The blank line a prose paragraph emits belongs AFTER the text (it
    /// is the `\par`); an anchor landing between the text and that blank line
    /// would split the paragraph in two.
    func testEmits_anchoredParagraph_hypertargetIsItsOwnLineBeforeTheText() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose,
                  nodes: [.paragraph("Hello.")], anchors: [0: "k3wq"])
        ])
        let body = LaTeXBodyEmitter.emit(ast, anchorTag: "en")
        let lines = body.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: "\\begin{prose}{T}") else {
            return XCTFail("no prose environment in:\n\(body)")
        }
        XCTAssertEqual(Array(lines[begin...]), [
            "\\begin{prose}{T}",
            "\\hypertarget{p-en-k3wq}{}",
            "Hello.",
            "",
            "\\end{prose}",
        ], body)
    }

    /// `Section.anchors` is SPARSE. Only the indices it names get a target —
    /// the unanchored node in the middle gets none, and the ids are not
    /// shifted onto their neighbours.
    func testEmits_anchorsAreSparse_onlyTheNamedIndicesGetATarget() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose,
                  nodes: [.paragraph("One."), .paragraph("Two."), .paragraph("Three.")],
                  anchors: [0: "aaaa", 2: "cccc"])
        ])
        let body = LaTeXBodyEmitter.emit(ast, anchorTag: "en")
        XCTAssertEqual(body.components(separatedBy: "\\hypertarget{p-").count - 1, 2, body)
        XCTAssertTrue(body.contains("\\hypertarget{p-en-aaaa}{}\nOne."), body)
        XCTAssertTrue(body.contains("\\hypertarget{p-en-cccc}{}\nThree."), body)
        // The unanchored node is emitted plainly, and "Two." carries no target
        // borrowed from either neighbour.
        XCTAssertFalse(body.contains("\\hypertarget{p-en-aaaa}{}\nTwo."), body)
        XCTAssertFalse(body.contains("\\hypertarget{p-en-cccc}{}\nTwo."), body)
    }

    /// The control, and the disable experiment for every assertion above: with
    /// `anchorTag` nil — the default every existing caller and every emitter
    /// test uses — no `\hypertarget` is emitted anywhere, even though the
    /// section carries anchors. Deleting the `anchorTag.flatMap` guard in
    /// `LaTeXBodyEmitter.emitNodes` (`let anchor = anchorTag.flatMap { tag in`)
    /// fails this test.
    func testEmits_nilAnchorTag_emitsNoHypertargetAnywhere() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "T", mode: .prose,
                  nodes: [.paragraph("Hello.")], anchors: [0: "k3wq"]),
            .init(pieceID: "p2", title: "S", mode: .fountain,
                  nodes: [.fountain(.sceneHeading("INT. ROOM - DAY"))], anchors: [0: "bbbb"]),
        ])
        let body = LaTeXBodyEmitter.emit(ast)
        XCTAssertFalse(body.contains("\\hypertarget{p-"),
                       "an untagged body must be byte-identical to the pre-anchor emitter "
                       + "apart from its prologue:\n\(body)")
        XCTAssertFalse(body.contains("\\MaughamCrossLink{p-"), body)
    }

    // MARK: - P3 Task 2: cross-body slugline links

    /// One `\MaughamCrossLink` per OTHER body, NESTED, first tag outermost —
    /// and wrapping `\scene`, never wrapped by it (the starter's `\scene`
    /// applies `\MakeUppercase`, which would eat the link's target).
    func testEmits_sceneHeading_nestsOneCrossLinkPerOtherBody_firstOutermost() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "S", mode: .fountain,
                  nodes: [.fountain(.sceneHeading("INT. ROOM - DAY"))], anchors: [0: "k3wq"])
        ])
        let body = LaTeXBodyEmitter.emit(ast, anchorTag: "en", crossLinkTags: ["sr", "de"])
        XCTAssertTrue(body.contains(
            "\\MaughamCrossLink{p-sr-k3wq}{\\MaughamCrossLink{p-de-k3wq}{\\scene{INT. ROOM - DAY}}}"),
            body)
        // The anchor itself is still emitted, on its own line before the scene.
        XCTAssertTrue(body.contains("\\hypertarget{p-en-k3wq}{}\n\\MaughamCrossLink{p-sr-"), body)
    }

    /// The scene NUMBER rides inside `\scene`, so the link wraps the whole
    /// command including it.
    func testEmits_numberedSceneHeading_crossLinkWrapsTheWholeSceneCommand() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "S", mode: .fountain,
                  nodes: [.fountain(.sceneHeading("INT. ROOM - DAY", sceneNumber: "12"))],
                  anchors: [0: "k3wq"])
        ])
        let body = LaTeXBodyEmitter.emit(ast, anchorTag: "en", crossLinkTags: ["sr"])
        XCTAssertTrue(body.contains(
            "\\MaughamCrossLink{p-sr-k3wq}{\\scene{INT. ROOM - DAY\\scenenumber{12}}}"),
            body)
    }

    /// Disable experiment for the nesting: a single-language compile passes no
    /// other bodies and the slugline is a plain `\scene`. Deleting the
    /// `crossLinkTags.reversed().reduce(content)` early-out — it returns
    /// `content` unchanged for an empty list — cannot fail this test, so the
    /// assertion that bites is the `\MaughamCrossLink`-free one: emitting a
    /// self-link (`crossLinkTags` including the body's own tag) fails it.
    func testEmits_sceneHeading_withNoOtherBodies_isAPlainScene() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "S", mode: .fountain,
                  nodes: [.fountain(.sceneHeading("INT. ROOM - DAY"))], anchors: [0: "k3wq"])
        ])
        let body = LaTeXBodyEmitter.emit(ast, anchorTag: "en")
        XCTAssertTrue(body.contains("\\hypertarget{p-en-k3wq}{}\n\\scene{INT. ROOM - DAY}"), body)
        XCTAssertFalse(body.contains("\\MaughamCrossLink{p-"), body)
    }

    /// A slugline with no anchor has nothing to link TO in the other bodies —
    /// the link's target is built from the paragraph id, so without one the
    /// scene is emitted plainly even in a multi-body compile.
    func testEmits_unanchoredSceneHeading_isAPlainSceneEvenWithOtherBodies() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "S", mode: .fountain,
                  nodes: [.fountain(.sceneHeading("INT. ROOM - DAY"))])
        ])
        let body = LaTeXBodyEmitter.emit(ast, anchorTag: "en", crossLinkTags: ["sr"])
        XCTAssertTrue(body.contains("\\scene{INT. ROOM - DAY}"), body)
        XCTAssertFalse(body.contains("\\MaughamCrossLink{p-"), body)
        XCTAssertFalse(body.contains("\\hypertarget{p-"), body)
    }

    /// Only the SLUGLINE links. Action, dialogue and prose paragraphs get their
    /// `\hypertarget` (so a cross-link has somewhere to land) and nothing else.
    func testEmits_onlySluglinesAreCrossLinked() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "S", mode: .fountain, nodes: [
                .fountain(.sceneHeading("INT. ROOM - DAY")),
                .fountain(.action("He waits.")),
                .fountain(.character("AARON")),
                .fountain(.dialogue("Morning.")),
            ], anchors: [0: "aaaa", 1: "bbbb", 2: "cccc", 3: "dddd"])
        ])
        let body = LaTeXBodyEmitter.emit(ast, anchorTag: "en", crossLinkTags: ["sr"])
        XCTAssertEqual(body.components(separatedBy: "\\hypertarget{p-").count - 1, 4, body)
        XCTAssertEqual(body.components(separatedBy: "\\MaughamCrossLink{p-").count - 1, 1, body)
        XCTAssertTrue(body.contains("\\hypertarget{p-en-bbbb}{}\n\\action{He waits.}"), body)
    }

    /// A dual-dialogue block's nested nodes are not top-level nodes: they carry
    /// no index in `Section.anchors`, so nothing inside the block is anchored
    /// or linked — the block's OWN index is.
    func testEmits_dualDialogue_anchorsTheBlockAndNothingInsideIt() {
        let ast = ProjectAST(sections: [
            .init(pieceID: "p1", title: "S", mode: .fountain, nodes: [
                .fountain(.dualDialogue(left: [.character("A"), .dialogue("Left.")],
                                        right: [.character("B"), .dialogue("Right.")]))
            ], anchors: [0: "aaaa"])
        ])
        let body = LaTeXBodyEmitter.emit(ast, anchorTag: "en", crossLinkTags: ["sr"])
        XCTAssertEqual(body.components(separatedBy: "\\hypertarget{p-").count - 1, 1, body)
        XCTAssertTrue(body.contains("\\hypertarget{p-en-aaaa}{}\n\\dualdialogue{%"), body)
    }
}
