import XCTest
import MaughamCore
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

// MARK: - report elements (report foundations plan 2, Task 5)

/// A book of prose pieces whose paragraphs reconcile, so every node knows its
/// `¶id`; the context carries the switches and the citable research.
private struct ReportBook: ProjectASTBuilder.Source {
    let pieces: [(id: String, paragraphs: [(id: String, text: String)])]
    var context: PublishContext = .empty
    func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
        pieces.map { piece in
            .init(pieceID: piece.id, title: "Title \(piece.id)", mode: .prose,
                  displayText: piece.paragraphs.map(\.text).joined(separator: "\n\n"),
                  paragraphs: piece.paragraphs)
        }
    }
    func publishContext() -> PublishContext { context }
}

final class LaTeXReportElementEmitterTests: XCTestCase {

    private static let ids = ["a1b2", "c3d4", "e5f6", "g7h8", "j9k0", "m1n2", "p3q4", "r5s6"]

    private func book(_ paragraphs: [String], numberSections: Bool = false,
                      lists: Bool = false, research: [ResearchItem] = []) -> ReportBook {
        ReportBook(
            pieces: [("a", paragraphs.enumerated().map { (Self.ids[$0.offset], $0.element) })],
            context: PublishContext(
                library: CitationLibrary(items: research), profile: .report,
                switches: (numberSections: numberSections, listOfFigures: lists, listOfTables: lists),
                projectURL: nil, piecePaths: [:]))
    }

    /// The body with the book's resolution, and the body without one.
    private func bodies(_ source: ProjectASTBuilder.Source,
                        figureFiles: [String: [Int: String]] = [:],
                        crossLinkTags: [String] = [],
                        isFirstBody: Bool = true) throws -> (resolved: String, plain: String) {
        let ast = try ProjectASTBuilder.build(from: source)
        let resolution = try PublishResolution.forCompile(source: source, bodyTag: nil,
                                                          imageAllowed: ["png"])
        return (LaTeXBodyEmitter.emit(ast, crossLinkTags: crossLinkTags, resolution: resolution,
                                      figureFiles: figureFiles, isFirstBody: isFirstBody),
                LaTeXBodyEmitter.emit(ast, crossLinkTags: crossLinkTags))
    }

    private func smith() -> ResearchItem {
        ResearchItem(id: "r1", title: "Annual Report", type: .asset,
                     citation: CitationInfo(key: "smith2026", authors: ["Smith, Jane"],
                                            sourceTitle: "Annual Report", year: 2026))
    }

    // MARK: tables

    func test_table_rendersAsAMaughamTableWithItsNumberAnchorAndEscapedCells() throws {
        let (resolved, plain) = try bodies(book([
            "| Item & co | 100% |\n|:--|--:|\n| a_b | #1 |\nTable: Sales & costs_q1 {#tbl:sales}",
        ]))
        XCTAssertTrue(resolved.contains("""
            \\setcounter{table}{0}
            \\hypertarget{lbl-tbl-sales}{}
            \\begin{MaughamTable}{lr}{Sales \\& costs\\_q1}{Sales \\& costs\\_q1}{Item \\& co & 100\\%}
            a\\_b & \\#1 \\\\
            \\end{MaughamTable}
            """), resolved)
        XCTAssertFalse(resolved.contains("Table: "), "no literal source with a resolution: \(resolved)")
        XCTAssertTrue(plain.contains("Table: Sales \\& costs\\_q1 \\{\\#tbl:sales\\}"),
                      "the nil-resolution path keeps the literal source: \(plain)")
        XCTAssertFalse(plain.contains("MaughamTable"), plain)
    }

    /// R-S9: a table with no caption line is still numbered, so it still
    /// prints "Table n" — a `@tbl:` reference always lands on a visible number.
    /// Its list entry is `\\relax`, so longtable lists it as the float does.
    func test_uncaptionedTable_stillPrintsItsNumber_andAlignmentNoneIsL() throws {
        let (resolved, _) = try bodies(book(["| a | b | c |\n|---|:-:|---|\n| 1 | 2 | 3 |"]))
        XCTAssertTrue(resolved.contains("""
            \\setcounter{table}{0}
            \\begin{MaughamTable}{lcl}{\\relax}{}{a & b & c}
            1 & 2 & 3 \\\\
            \\end{MaughamTable}
            """), resolved)
    }

    /// I1: `\\\\` peeks past spaces for `[` and `*`, so a row (or a header,
    /// which follows one inside the longtable branch) that opens with either
    /// is guarded by `\\relax`, or the compile dies with "Missing number".
    func test_aRowOrHeaderOpeningWithABracketOrStar_isGuarded() throws {
        let (resolved, _) = try bodies(book([
            "| [h] | b |\n|---|---|\n| [draft] | x |\n| [@ghost] | y |\n| plain | z |",
        ]))
        XCTAssertTrue(resolved.contains("""
            \\begin{MaughamTable}{ll}{\\relax}{}{\\relax [h] & b}
            \\relax [draft] & x \\\\
            \\relax [@ghost] & y \\\\
            plain & z \\\\
            """), resolved)
        XCTAssertEqual(LaTeXBodyEmitter.rowStart("*x & y"), "\\relax *x & y")
        XCTAssertEqual(LaTeXBodyEmitter.rowStart("  [x"), "\\relax   [x")
        XCTAssertEqual(LaTeXBodyEmitter.rowStart("x & [y]"), "x & [y]")
    }

    /// m4: `\\item` reads a following `[` as its label argument.
    func test_aListItemOpeningWithABracket_keepsIt() throws {
        let (resolved, plain) = try bodies(book(["- [draft] first\n- second [x]"]))
        for body in [resolved, plain] {
            XCTAssertTrue(body.contains("\\item\\relax [draft] first\n\\item second [x]"), body)
        }
    }

    /// m2: a bilingual book's later body captions the same numbers; its
    /// figures and tables keep their captions but stay out of the lists.
    func test_aLaterBody_keepsItsElementsOutOfTheLists() throws {
        let source = book(["| a |\n|---|\n| 1 |\nTable: T", "![F](../research/f.png)"], lists: true)
        let files = ["a": [1: "build/figures/f.png"]]
        let (first, _) = try bodies(source, figureFiles: files)
        XCTAssertFalse(first.contains("\\renewcommand{\\addcontentsline}"), first)
        let (later, _) = try bodies(source, figureFiles: files, isFirstBody: false)
        XCTAssertTrue(later.contains("""
            \\begingroup\\renewcommand{\\addcontentsline}[3]{}
            \\setcounter{table}{0}
            \\begin{MaughamTable}{l}{T}{T}{a}
            1 \\\\
            \\end{MaughamTable}
            \\endgroup
            \\begingroup\\renewcommand{\\addcontentsline}[3]{}
            \\setcounter{figure}{0}
            """), later)
        XCTAssertTrue(later.contains("\\end{figure}\n\\endgroup"), later)
    }

    /// The environments are defined in the body, guarded, with a longtable
    /// branch and a table-float-around-tabular branch, so a preamble without
    /// longtable still compiles; and only when the body has a table, so a
    /// novel's body keeps its three prologue lines.
    func test_tableEnvironments_areDefinedOnlyWhenTheBodyHasATable() throws {
        let (withTable, _) = try bodies(book(["| a |\n|---|\n| 1 |\nTable: T"]))
        XCTAssertTrue(withTable.contains("""
            \\ifdefined\\MaughamTable\\else\\ifdefined\\longtable
            \\newenvironment{MaughamTable}[4]{\\begin{longtable}{#1}\\caption[{#2}]{#3}\\\\#4\\\\\\hline\\endfirsthead\\caption[]{#3}\\\\#4\\\\\\hline\\endhead}{\\end{longtable}}
            \\else
            \\newenvironment{MaughamTable}[4]{\\begin{table}[htbp]\\centering\\caption[{#2}]{#3}\\begin{tabular}{#1}#4\\\\\\hline}{\\end{tabular}\\end{table}}
            \\fi\\fi
            """), withTable)
        XCTAssertFalse(withTable.contains("MaughamPlainTable"), "every table is captioned (R-S9)")
        let (without, _) = try bodies(book(["Just prose."]))
        XCTAssertFalse(without.contains("MaughamTable"), without)
    }

    // MARK: figures

    func test_figure_rendersWithGraphicsOrAFramedCaption() throws {
        let (resolved, plain) = try bodies(
            book(["Intro.", "![Revenue & 50%](../research/r.png){#fig:rev_q1}"]),
            figureFiles: ["a": [1: "build/figures/0123abcd.png"]])
        XCTAssertTrue(resolved.contains("""
            \\setcounter{figure}{0}
            \\begin{figure}[htbp]
            \\centering
            \\hypertarget{lbl-fig-rev_q1}{}
            \\ifdefined\\includegraphics\\includegraphics[width=\\linewidth]{build/figures/0123abcd.png}\\else\\fbox{\\parbox{0.9\\linewidth}{\\centering Revenue \\& 50\\%}}\\fi
            \\caption[{Revenue \\& 50\\%}]{Revenue \\& 50\\%}
            \\end{figure}
            """), resolved)
        XCTAssertTrue(plain.contains("![Revenue \\& 50\\%](../research/r.png) \\{\\#fig:rev\\_q1\\}"), plain)
    }

    /// A figure the compiler could not stage (or whose image was refused) is
    /// unresolved: its literal source, never a broken `\includegraphics`.
    func test_figureWithNoStagedFile_orAnUnsafePath_rendersItsLiteralSource() throws {
        let source = book(["![Chart](../research/c.png)"])
        let (unstaged, _) = try bodies(source)
        XCTAssertFalse(unstaged.contains("\\begin{figure}"), unstaged)
        XCTAssertTrue(unstaged.contains("![Chart](../research/c.png)"), unstaged)
        for unsafe in ["build/figures/a b.png", "build/figures/x}.png", "/abs/x.png", "build/figures/x%.png"] {
            let (body, _) = try bodies(source, figureFiles: ["a": [0: unsafe]])
            XCTAssertFalse(body.contains("\\includegraphics"), "\(unsafe): \(body)")
        }
        let (prefixed, _) = try bodies(source, figureFiles: ["a": [0: "../../build/figures/ab.png"]])
        XCTAssertTrue(prefixed.contains("{../../build/figures/ab.png}"),
                      "the template-directory prefix is allowed: \(prefixed)")
    }

    // MARK: footnotes

    func test_footnote_rendersWithItsResolvedNumber_andARepeatIsAMark() throws {
        let (resolved, plain) = try bodies(book([
            "First[^a] and second[^b], again[^a].", "[^b]: Bee & co.", "[^a]: Ay_1.",
        ]))
        XCTAssertTrue(resolved.contains(
            "First\\footnote[1]{Ay\\_1.} and second\\footnote[2]{Bee \\& co.}, again\\footnotemark[1]."),
            resolved)
        XCTAssertFalse(resolved.contains("[^"), resolved)
        XCTAssertFalse(resolved.contains("textasciicircum"), resolved)
        // R-S6: the nil-resolution path prints the refs literally and appends
        // each definition as a literal paragraph at the end of the section.
        XCTAssertTrue(plain.contains("First[\\textasciicircum{}a] and second[\\textasciicircum{}b]"), plain)
        XCTAssertTrue(plain.contains("""
            [\\textasciicircum{}a]: Ay\\_1.

            [\\textasciicircum{}b]: Bee \\& co.

            \\end{prose}
            """), plain)
    }

    func test_footnoteWithNoDefinition_rendersLiterally() throws {
        let (resolved, _) = try bodies(book(["Dangling[^nope]."]))
        XCTAssertTrue(resolved.contains("Dangling[\\textasciicircum{}nope]."), resolved)
    }

    /// `\footnote` inside a caption, a table cell or a heading is lost or
    /// breaks the compile; there the mark goes inline and the text follows
    /// the element. A note inside a note is the same pair.
    func test_footnotesInCaptionsCellsHeadingsAndNotes_areMarkAndTextPairs() throws {
        let (resolved, _) = try bodies(book([
            "# Scope[^h]",
            "| Cell[^c] |\n|---|\n| x |\nTable: Cap[^t]",
            "![Fig[^f]](../research/x.png)",
            "Body[^n].",
            "[^h]: On heading.", "[^c]: In cell.", "[^t]: In caption.", "[^f]: In figure.",
        ], numberSections: false).withExtra("[^n]: Outer[^m].", "[^m]: Inner."),
            figureFiles: ["a": [2: "build/figures/ab.png"]])
        XCTAssertTrue(resolved.contains("""
            \\section*{Scope\\footnotemark[1]}
            \\addcontentsline{toc}{section}{Scope}
            \\footnotetext[1]{On heading.}
            """), resolved)
        XCTAssertTrue(resolved.contains(
            "\\begin{MaughamTable}{l}{Cap}{Cap\\footnotemark[3]}{Cell\\footnotemark[2]}"), resolved)
        XCTAssertTrue(resolved.contains("""
            \\end{MaughamTable}
            \\footnotetext[3]{In caption.}
            \\footnotetext[2]{In cell.}
            """), resolved)
        XCTAssertTrue(resolved.contains("\\caption[{Fig}]{Fig\\footnotemark[4]}\n\\end{figure}\n\\footnotetext[4]{In figure.}"),
                      resolved)
        XCTAssertTrue(resolved.contains(
            "Body\\footnote[5]{Outer\\footnotemark[6].}\\footnotetext[6]{Inner.}."), resolved)
    }

    // MARK: citations and cross-references

    func test_citation_rendersItsResolvedText_unknownKeysLiterally() throws {
        let (resolved, plain) = try bodies(book(
            ["As shown [@smith2026, p. 3]; not [@ghost]."], research: [smith()]))
        XCTAssertTrue(resolved.contains("As shown (Smith 2026, p. 3); not [@ghost]."), resolved)
        XCTAssertTrue(plain.contains("As shown [@smith2026, p. 3]"), plain)
    }

    func test_crossRef_linksToTheLabelAnchorWithTheTargetText() throws {
        let source = book(["![Chart](../research/c.png){#fig:chart}", "See @fig:chart and @tbl:none."])
        let (resolved, plain) = try bodies(source, figureFiles: ["a": [0: "build/figures/c.png"]])
        XCTAssertTrue(resolved.contains(
            "See \\MaughamCrossLink{lbl-fig-chart}{Figure 1} and @tbl:none."), resolved)
        XCTAssertTrue(plain.contains("See @fig:chart and @tbl:none."), plain)
        // In a multi-body compile every body carries the same labels, so the
        // anchor names its body: a link never lands in the other language.
        let ast = try ProjectASTBuilder.build(from: source)
        let r = try PublishResolution.forCompile(source: source, bodyTag: "sr", imageAllowed: ["png"])
        let sr = LaTeXBodyEmitter.emit(ast, anchorTag: "sr", crossLinkTags: ["en"], resolution: r,
                                       figureFiles: ["a": [0: "build/figures/c.png"]])
        XCTAssertTrue(sr.contains("\\hypertarget{lbl-sr-fig-chart}{}"), sr)
        XCTAssertTrue(sr.contains("\\MaughamCrossLink{lbl-sr-fig-chart}{Figure 1}"), sr)
    }

    // MARK: headings

    func test_numberedHeading_carriesItsNumberIntoTheTitleAndTheContents() throws {
        let (resolved, plain) = try bodies(book(
            ["# Intro {#sec:intro}", "## Scope", "See @sec:intro."], numberSections: true))
        XCTAssertTrue(resolved.contains("""
            \\hypertarget{lbl-sec-intro}{}
            \\section*{1\\quad Intro}
            \\addcontentsline{toc}{section}{1\\quad Intro}
            \\subsection*{1.1\\quad Scope}
            \\addcontentsline{toc}{subsection}{1.1\\quad Scope}
            """), resolved)
        XCTAssertTrue(resolved.contains("See \\MaughamCrossLink{lbl-sec-intro}{Section 1}."), resolved)
        XCTAssertTrue(plain.contains("\\section*{Intro \\{\\#sec:intro\\}}"), plain)
        let (unnumbered, _) = try bodies(book(["# Intro {#sec:intro}"], numberSections: false))
        XCTAssertTrue(unnumbered.contains("\\section*{Intro}\n\\addcontentsline{toc}{section}{Intro}"),
                      unnumbered)
    }

    // MARK: References and the lists

    func test_references_closeTheBodyWithAHangingIndentList() throws {
        let (resolved, plain) = try bodies(book(["Cited [@smith2026]."], research: [smith()]))
        XCTAssertTrue(resolved.hasSuffix("""
            \\end{prose}
            \\clearpage
            \\section*{References}
            \\addcontentsline{toc}{section}{References}
            \\begingroup
            \\setlength{\\parindent}{0pt}
            \\setlength{\\parskip}{0.5em}
            \\hangindent=1.5em\\hangafter=1 Smith, Jane. 2026. \\emph{Annual Report}.\\par
            \\endgroup
            """), resolved)
        XCTAssertFalse(plain.contains("References"), plain)
        let (uncited, _) = try bodies(book(["Nothing cited."], research: [smith()]))
        XCTAssertFalse(uncited.contains("References"), uncited)
    }

    func test_lists_openTheFirstBodyWhenSwitchedOnAndNonEmpty() throws {
        let source = book(["| a |\n|---|\n| 1 |\nTable: T", "![F](../research/f.png)"], lists: true)
        let files = ["a": [1: "build/figures/f.png"]]
        let (resolved, plain) = try bodies(source, figureFiles: files)
        XCTAssertTrue(resolved.contains("""
            \\ifdefined\\listoffigures\\listoffigures\\clearpage\\fi
            \\ifdefined\\listoftables\\listoftables\\clearpage\\fi
            \\begin{prose}{Title a}
            """), resolved)
        XCTAssertFalse(plain.contains("listof"), plain)
        let (second, _) = try bodies(source, figureFiles: files, isFirstBody: false)
        XCTAssertFalse(second.contains("listof"), "only the first body opens with the lists: \(second)")
        let (off, _) = try bodies(book(["| a |\n|---|\n| 1 |"], lists: false))
        XCTAssertFalse(off.contains("listof"), off)
        let (empty, _) = try bodies(book(["Prose only."], lists: true))
        XCTAssertFalse(empty.contains("listof"), "no figures, no tables, no lists: \(empty)")
    }

    // MARK: subsets

    /// A preview AST is built from a filtered source and the resolution from
    /// the whole book; node indices are per piece, so the subset's figure
    /// still finds its whole-book number (Figure 2, not Figure 1).
    func test_aSubsetBody_usesTheWholeBooksNumbers() throws {
        let whole = ReportBook(pieces: [
            ("a", [("a1b2", "![One](../research/1.png){#fig:one}")]),
            ("b", [("c3d4", "Text first."), ("e5f6", "![Two](../research/2.png){#fig:two}"),
                   ("g7h8", "See @fig:one.")]),
        ], context: book([]).context)
        let subset = FilteredASTSource(base: whole, sectionIDs: ["b"], editionExcludedSectionIDs: [])
        let ast = try ProjectASTBuilder.build(from: subset)
        XCTAssertEqual(ast.sections.map(\.pieceID), ["b"], "premise: a subset")
        let r = try PublishResolution.forCompile(source: subset, bodyTag: nil, imageAllowed: ["png"])
        let body = LaTeXBodyEmitter.emit(ast, resolution: r, figureFiles: ["b": [1: "build/figures/2.png"]])
        XCTAssertTrue(body.contains("\\setcounter{figure}{1}\n\\begin{figure}[htbp]"), body)
        XCTAssertTrue(body.contains("See \\MaughamCrossLink{lbl-fig-one}{Figure 1}."), body)
    }

    // MARK: escaping

    func test_everyTextPathEscapes() throws {
        let (resolved, _) = try bodies(book([
            "# A & B_1 {#sec:x}",
            "| x%y | #z |\n|---|---|\n| _u_ & | 50% |\nTable: C&D % #1 _x_",
        ], numberSections: true))
        for raw in ["A & B", "x%y", "| #z", "C&D", "% #1", "50% "] {
            XCTAssertFalse(resolved.contains(raw), "\(raw) reached TeX unescaped: \(resolved)")
        }
        XCTAssertTrue(resolved.contains("\\section*{1\\quad A \\& B\\_1}"), resolved)
        XCTAssertTrue(resolved.contains(
            "\\begin{MaughamTable}{ll}{C\\&D \\% \\#1 \\_x\\_}{C\\&D \\% \\#1 \\_x\\_}{x\\%y & \\#z}"), resolved)
        XCTAssertTrue(resolved.contains("\\_u\\_ \\& & 50\\% \\\\"), resolved)
    }
}

private extension ReportBook {
    /// The same book with paragraphs appended, ids continuing.
    func withExtra(_ texts: String...) -> ReportBook {
        let extra = ["t7v8", "w9x0", "y1z2", "b3c4"]
        var piece = pieces[0]
        for (i, t) in texts.enumerated() { piece.paragraphs.append((extra[i], t)) }
        return ReportBook(pieces: [piece], context: context)
    }
}
