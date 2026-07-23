import Foundation

/// Emits `body.tex` content from a `ProjectAST`. The template the writer-
/// Claude pair authors must \input{build/body} and define the environments
/// (\begin{prose}{title}, \begin{screenplay}{title}) plus per-mode commands
/// referenced below (\scenebreak, \wikilink, \scene, \action, \character,
/// \dialogue, \parenthetical, \transition, \dualdialogue). The barebones
/// starter provides working defaults.
public enum LaTeXBodyEmitter {

    public static func emit(_ ast: ProjectAST, config: PublishConfig = PublishConfig()) -> String {
        var lines: [String] = [strikethroughProvidecommand]
        for (index, section) in ast.sections.enumerated() {
            emit(section: section, isFirst: index == 0, config: config, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// Fallback for `\st` (strikethrough): the starter `preamble.tex` loads
    /// `soul` so `\st` normally renders a real strikethrough, but an EXISTING
    /// per-project preamble authored before this package was added won't have
    /// it. `\providecommand` (never `\newcommand`) keeps `soul`'s own
    /// definition when present and only degrades to plain text — never a
    /// compile failure — when it isn't. Emitted once, unconditionally, at the
    /// top of the body so both prose and fountain sections are covered
    /// regardless of which mode first uses `~~strikethrough~~`.
    private static let strikethroughProvidecommand =
        "\\providecommand{\\st}[1]{#1}"

    // MARK: - section

    private static func emit(section: ProjectAST.Section, isFirst: Bool,
                             config: PublishConfig, into out: inout [String]) {
        let ov = config.sections[section.pieceID]
        // A per-piece style file's `\renewcommand`s must be scoped so they
        // revert after this piece — otherwise a styled piece leaks its
        // redefinitions into the next one. The group opens BEFORE the page
        // break and environment and closes after `\end{...}`. Emission order is
        // contractual: \begingroup → \input{pieces/<file>} → page-break →
        // \begin{...} → nodes → \end{...} → \endgroup.
        let styled = ov?.styleFile != nil
        if let styleFile = ov?.styleFile {
            out.append("\\begingroup")
            // LaTeX injection guard (finding 1.4): validate the styleFile name
            // at emit time as a second line of defence. `set_piece_style` already
            // validates via `LaTeXSafeFilename` before writing to disk, but a
            // config.json edited outside MCP (or a snapshot carrying an old
            // value) could bypass that gate. Emit a compile-failing placeholder
            // instead of injecting unsafe content — tectonic will surface a
            // clear error rather than execute the injected TeX.
            if LaTeXSafeFilename(styleFile) != nil {
                out.append("\\input{pieces/\(styleFile)}")
            } else {
                out.append("\\undefined_style_file_unsafe_name")
            }
        }
        // Each piece starts on a fresh page. The first piece follows the
        // frontmatter (which already broke the page) so it's skipped to avoid
        // a leading blank page. The break honors the per-section `start_on`
        // override: `.recto`/`.verso` need global page parity so they live in
        // config; `.any` (the default) is a plain page break.
        if !isFirst {
            switch ov?.startOn ?? .any {
            case .recto: out.append("\\cleardoublepage")
            case .verso: out.append("\\cleardoublepage\\thispagestyle{empty}\\null\\clearpage")
            case .any:   out.append("\\clearpage")
            }
        }
        let title = LaTeXEscape.escape(ov?.titleOverride ?? section.title)
        let opt = (ov?.includeInToc == false) ? "[notoc]" : ""
        switch section.mode {
        case .prose:
            out.append("\\begin{prose}\(opt){\(title)}")
            for node in section.nodes { emit(node: node, into: &out) }
            out.append("\\end{prose}")
        case .fountain:
            out.append("\\begin{screenplay}\(opt){\(title)}")
            out.append(contentsOf: fountainProvidecommands)
            for node in section.nodes { emit(node: node, into: &out) }
            out.append("\\end{screenplay}")
        }
        if styled {
            out.append("\\endgroup")
        }
    }

    // MARK: - nodes

    private static func emit(node: ProjectAST.Node, into out: inout [String]) {
        switch node {
        case .prose(let p):    emit(prose: p, into: &out)
        case .fountain(let f): emit(fountain: f, into: &out)
        }
    }

    private static func emit(prose: ProjectAST.ProseNode, into out: inout [String]) {
        switch prose {
        case .paragraph(let inlines):
            out.append(emitInline(inlines))
            out.append("")   // blank line → \par so paragraphs don't run together
        case .heading(let level, let inlines):
            let cmd = ["section", "subsection", "subsubsection"][min(max(level - 1, 0), 2)]
            out.append("\\\(cmd)*{\(emitInline(inlines))}")
            out.append("\\addcontentsline{toc}{\(cmd)}{\(plainText(inlines))}")
        case .blockquote(let nodes):
            out.append("\\begin{quote}")
            for n in nodes { emit(prose: n, into: &out) }
            out.append("\\end{quote}")
        case .sceneBreak:
            out.append("\\scenebreak")
        case .list(let ordered, let items):
            let env = ordered ? "enumerate" : "itemize"
            out.append("\\begin{\(env)}")
            for item in items {
                out.append("\\item \(emitInline(item))")
            }
            out.append("\\end{\(env)}")
        case .verbatim(let lines):
            // A mangle guard, not code support: escaped text joined by
            // `\newline` in a plain paragraph — no `\texttt`, no monospace
            // pretension. `\newline`, never bare `\\`: `\\` scans forward for
            // `*` and `[...]`, so a fenced line starting with `[` became its
            // optional argument and killed the compile ("Missing number").
            out.append(lines.map(LaTeXEscape.escape).joined(separator: "\\newline "))
            out.append("")   // blank line → \par, matching .paragraph
        }
    }

    /// Render a run of inline nodes into a single LaTeX string.
    private static func emitInline(_ inlines: [ProjectAST.Inline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s):     return LaTeXEscape.escape(s)
            case .emphasis(let xs): return "\\emph{\(emitInline(xs))}"
            case .strong(let xs):   return "\\textbf{\(emitInline(xs))}"
            case .strikethrough(let xs): return "\\st{\(emitInline(xs))}"
            case .underline(let xs): return "\\underline{\(emitInline(xs))}"
            case .code(let s):      return "\\texttt{\(LaTeXEscape.escape(s))}"
            case .wikiLink(let target, let display):
                return "\\wikilink{\(LaTeXEscape.escape(target))}{\(LaTeXEscape.escape(display))}"
            // `\newline`, not `\\`: a following `[` or `*` in the text would
            // be captured as `\\`'s optional/star argument. Trailing space
            // stops the control word absorbing a following letter.
            case .lineBreak:        return "\\newline "
            }
        }.joined()
    }

    /// Flatten inline runs to escaped plain text (no formatting commands) for
    /// `\addcontentsline` — running `\emph`/`\textbf` through the ToC entry is
    /// fragile, so headings appear unformatted in the contents.
    private static func plainText(_ inlines: [ProjectAST.Inline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s):              return LaTeXEscape.escape(s)
            case .emphasis(let xs):         return plainText(xs)
            case .strong(let xs):           return plainText(xs)
            case .strikethrough(let xs):    return plainText(xs)
            case .underline(let xs):        return plainText(xs)
            case .code(let s):              return LaTeXEscape.escape(s)
            case .wikiLink(_, let display): return LaTeXEscape.escape(display)
            case .lineBreak:                return " "
            }
        }.joined()
    }

    /// Fallback definitions for the fountain-mode commands introduced by the
    /// lyric/centered/scene-number vocabulary expansion. `\providecommand`
    /// (not `\newcommand`) so an EXISTING per-project template that already
    /// defines one of these keeps its own definition — this is what lets
    /// the expanded vocabulary compile against templates authored before it
    /// existed.
    ///
    /// `\screenplaytitleblock` (F6) joins this group: it's the fountain title
    /// page hook, `\screenplaytitleblock{body}`. The default body reproduces
    /// the pre-F6 hardcoded frame exactly (centered, pushed down 1.5in, page
    /// break after); the single argument carries the fields — in DECLARED
    /// order, Title in `\Large\textbf`, everything else plain
    /// `\par`-terminated. A per-piece style file can restyle it
    /// (`\RenewDocumentCommand` inside the pieceheading-hook discipline,
    /// EMISSION.md).
    private static let fountainProvidecommands: [String] = [
        "\\providecommand{\\lyricline}[1]{\\textit{#1}\\par}",
        "\\providecommand{\\centeredline}[1]{\\begin{center}#1\\end{center}}",
        "\\providecommand{\\scenenumber}[1]{\\hfill #1}",
        "\\providecommand{\\screenplaytitleblock}[1]{\\begin{center}\\vspace*{1.5in}#1\\end{center}\\clearpage}",
    ]

    private static func emit(fountain: ProjectAST.FountainNode, into out: inout [String]) {
        switch fountain {
        case .sceneHeading(let s, let number):
            if let number {
                out.append("\\scene{\(LaTeXEscape.escape(s))\\scenenumber{\(LaTeXEscape.escape(number))}}")
            } else {
                out.append("\\scene{\(LaTeXEscape.escape(s))}")
            }
        case .action(let xs):       out.append("\\action{\(emitInline(xs))}")
        case .character(let s):     out.append("\\character{\(LaTeXEscape.escape(s))}")
        case .dialogue(let xs):     out.append("\\dialogue{\(emitInline(xs))}")
        case .parenthetical(let xs): out.append("\\parenthetical{\(emitInline(xs))}")
        case .transition(let s):    out.append("\\transition{\(LaTeXEscape.escape(s))}")
        case .lyric(let xs):        out.append("\\lyricline{\(emitInline(xs))}")
        case .centered(let xs):     out.append("\\centeredline{\(emitInline(xs))}")
        case .pageBreak:            out.append("\\clearpage")
        case .titlePage(let fields): emitTitlePage(fields, into: &out)
        case .dualDialogue(let left, let right):
            var leftLines: [String] = []
            var rightLines: [String] = []
            for n in left  { emit(fountain: n, into: &leftLines) }
            for n in right { emit(fountain: n, into: &rightLines) }
            out.append("\\dualdialogue{%")
            out.append(leftLines.joined(separator: "\n"))
            out.append("}{%")
            out.append(rightLines.joined(separator: "\n"))
            out.append("}")
        }
    }

    /// A Fountain title page, rendered on its own page (industry standard):
    /// the title pushed down and centered, supporting fields centered below
    /// it, then a page break.
    ///
    /// F6: emitted through the `\screenplaytitleblock{body}` hook (declared
    /// in `fountainProvidecommands`) rather than inline
    /// `\begin{center}…\end{center}` so a per-piece style file can restyle
    /// the whole block — the field incident that motivated this had no
    /// sanctioned hook to control a leaking title block (see EMISSION.md).
    ///
    /// Arity decision (documented per the task's judgment point): the AST's
    /// `[TitleField]` is an ARBITRARY ordered list — the Fountain tokenizer
    /// canonicalizes up to eight keys (Title, Credit, Author, Source, Draft
    /// date, Contact, Copyright, Notes), passes unrecognized keys through
    /// as-typed, and preserves as-authored declaration order (Credit before
    /// Title is legal and preserved). The pre-F6 emitter rendered fields in
    /// that DECLARED order, special-casing only "Title"'s typography — so
    /// any multi-arg split that reassembles fields positionally (the plan's
    /// sketched 4 named args, or a title/rest pair) changes rendering order
    /// for pages not authored Title-first. The only shape that reproduces
    /// today's output for ANY field set/order/count is a SINGLE argument:
    /// all fields, declared order, each rendered exactly as today. That is
    /// also what the motivating incident needed — whole-block restyling.
    /// Per-field restyling (e.g. "Draft date" alone) would need a wider,
    /// canonical-key-keyed surface; noted as a follow-up if a style ever
    /// needs it.
    private static func emitTitlePage(_ fields: [ProjectAST.TitleField],
                                      into out: inout [String]) {
        func escapeMultiline(_ s: String) -> String {
            // `\newline`, not `\\` — same `[`/`*` argument-capture hazard as
            // the fence join above.
            s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { LaTeXEscape.escape(String($0)) }
                .joined(separator: "\\newline ")
        }
        // `\par` is a control WORD: with no separator after it, a following
        // letter (e.g. a field starting "First...") is gobbled into the
        // control sequence name itself ("\parFirst" — undefined control
        // sequence, a hard compile failure). The original per-line `out`
        // array had an implicit "\n" between fields (the array is later
        // `.joined(separator: "\n")`); joining these fragments into a single
        // macro-argument string must reproduce that separator explicitly.
        let body = fields.map { field -> String in
            let value = escapeMultiline(field.value)
            if field.key == "Title" {
                return "{\\Large\\textbf{\(value)}}\\par\n\\vspace{1.5em}"
            } else {
                return "\(value)\\par"
            }
        }.joined(separator: "\n")
        out.append("\\screenplaytitleblock{\(body)}")
    }
}
