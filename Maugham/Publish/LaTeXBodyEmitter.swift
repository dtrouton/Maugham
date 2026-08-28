import Foundation

/// Emits `body.tex` content from a `ProjectAST`. The template the writer-
/// Claude pair authors must \input{build/body} and define the environments
/// (\begin{prose}{title}, \begin{screenplay}{title}) plus per-mode commands
/// referenced below (\scenebreak, \wikilink, \scene, \action, \character,
/// \dialogue, \parenthetical, \transition, \dualdialogue). The barebones
/// starter provides working defaults.
public enum LaTeXBodyEmitter {

    /// - Parameters:
    ///   - anchorTag: the compiler's filename-safe tag for the body being
    ///     emitted (`en`, `sr`, or an ordinal). `nil` — the default every
    ///     hand-built caller uses — emits no `\hypertarget` anywhere, so an
    ///     AST that carries anchors still produces exactly the bytes it
    ///     produced before anchors existed.
    ///   - crossLinkTags: the tags of the compile's OTHER bodies, in order.
    ///     Each slugline that has an anchor is wrapped in one
    ///     `\MaughamCrossLink` per entry so a reader can jump to the same
    ///     scene in the other language. Empty for a single-language compile.
    public static func emit(_ ast: ProjectAST, config: PublishConfig = PublishConfig(),
                            anchorTag: String? = nil,
                            crossLinkTags: [String] = []) -> String {
        var lines: [String] = prologue
        for (index, section) in ast.sections.enumerated() {
            emit(section: section, isFirst: index == 0, config: config,
                 anchorTag: anchorTag, crossLinkTags: crossLinkTags, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// One contract, always three lines, whatever the arguments: a body that
    /// anchors nothing opens exactly as one that anchors everything. Each is a
    /// `\providecommand`, so a preamble that defines the real thing — `soul`'s
    /// `\st`, hyperref's `\hypertarget`, the starter's `\MaughamCrossLink` —
    /// wins (it is read first, and these then no-op), and a project whose
    /// preamble predates any of them degrades to the plain content rather than
    /// failing the compile.
    private static let prologue: [String] = [
        strikethroughProvidecommand,
        hypertargetProvidecommand,
        crossLinkProvidecommand,
    ]

    /// Fallback for hyperref's `\hypertarget{name}{text}`. Anchors are emitted
    /// with an EMPTY second argument — a target marks a position, it typesets
    /// nothing — so degrading to `#2` degrades to nothing at all.
    private static let hypertargetProvidecommand =
        "\\providecommand{\\hypertarget}[2]{#2}"

    /// Fallback for `\MaughamCrossLink{target}{content}`, the cross-body
    /// slugline link. The starter `preamble.tex` defines it as
    /// `\hyperlink{#1}{#2}` and, being a `\providecommand`, still wins over
    /// this one.
    ///
    /// **It links wherever hyperref is loaded, and only degrades where it is
    /// not.** The first spelling of this fallback was a flat `{#2}`, which made
    /// every cross-link in every PRE-EXISTING project inert: `PublishStarter
    /// .installIfMissing` returns early for an initialised project, so a book
    /// begun before this milestone never receives the starter's
    /// `\MaughamCrossLink` definition and had nothing but the flat fallback to
    /// fall back to — links emitted, links dead, nothing red anywhere. The
    /// `\ifdefined\hyperlink` test is decided at each USE, so the body needs
    /// to know nothing about what the preamble loaded: hyperref present and the
    /// slugline links; absent and it sets plainly, which is what a preamble
    /// with no hyperref could ever have done.
    private static let crossLinkProvidecommand =
        "\\providecommand{\\MaughamCrossLink}[2]"
        + "{\\ifdefined\\hyperlink\\hyperlink{#1}{#2}\\else#2\\fi}"

    /// Everything one anchored node needs: the name of its own target and the
    /// names of the same paragraph's targets in the compile's other bodies.
    private struct Anchor {
        let tag: String
        let id: String
        let crossLinkTags: [String]

        var name: String { Anchor.name(tag: tag, id: id) }

        static func name(tag: String, id: String) -> String { "p-\(tag)-\(id)" }

        /// Wrap `content` in one `\MaughamCrossLink` per OTHER body, NESTED,
        /// first tag outermost. No other bodies → `content` unchanged, which is
        /// what makes a single-language compile emit a plain `\scene`.
        func crossLinked(_ content: String) -> String {
            crossLinkTags.reversed().reduce(content) { inner, other in
                "\\MaughamCrossLink{\(Anchor.name(tag: other, id: id))}{\(inner)}"
            }
        }
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
                             config: PublishConfig, anchorTag: String?,
                             crossLinkTags: [String], into out: inout [String]) {
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
            emitNodes(of: section, anchorTag: anchorTag,
                      crossLinkTags: crossLinkTags, into: &out)
            out.append("\\end{prose}")
        case .fountain:
            out.append("\\begin{screenplay}\(opt){\(title)}")
            out.append(contentsOf: fountainProvidecommands)
            emitNodes(of: section, anchorTag: anchorTag,
                      crossLinkTags: crossLinkTags, into: &out)
            out.append("\\end{screenplay}")
        }
        if styled {
            out.append("\\endgroup")
        }
    }

    // MARK: - nodes

    /// The section's top-level nodes, each preceded by its `\hypertarget` when
    /// this body is tagged AND `Section.anchors` names that index. The map is
    /// SPARSE — most nodes have no entry — so most nodes emit exactly what they
    /// always did.
    ///
    /// The target is its OWN line, BEFORE the node's first line. A prose
    /// paragraph writes its text and then a blank line (the `\par`), so an
    /// anchor placed after the text would land between a paragraph and its own
    /// terminator and split it in two.
    private static func emitNodes(of section: ProjectAST.Section, anchorTag: String?,
                                  crossLinkTags: [String], into out: inout [String]) {
        for (index, node) in section.nodes.enumerated() {
            let anchor = anchorTag.flatMap { tag in
                section.anchors[index].map {
                    Anchor(tag: tag, id: $0, crossLinkTags: crossLinkTags)
                }
            }
            if let anchor { out.append("\\hypertarget{\(anchor.name)}{}") }
            emit(node: node, anchor: anchor, into: &out)
        }
    }

    private static func emit(node: ProjectAST.Node, anchor: Anchor?,
                             into out: inout [String]) {
        switch node {
        // Prose has no cross-linked node kind: only a slugline links, because
        // only a slugline names a place a reader of the other language is
        // looking for. Prose still anchors, so a link HAS somewhere to land.
        case .prose(let p):    emit(prose: p, into: &out)
        case .fountain(let f): emit(fountain: f, anchor: anchor, into: &out)
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
    /// `\par`-terminated. A per-piece style file can restyle it by defining
    /// the macro in the style file itself — the emitted `\providecommand`
    /// will then no-op (matching the `\lyricline` precedent documented in
    /// EMISSION.md).
    private static let fountainProvidecommands: [String] = [
        "\\providecommand{\\lyricline}[1]{\\textit{#1}\\par}",
        "\\providecommand{\\centeredline}[1]{\\begin{center}#1\\end{center}}",
        "\\providecommand{\\scenenumber}[1]{\\hfill #1}",
        "\\providecommand{\\screenplaytitleblock}[1]{\\begin{center}\\vspace*{1.5in}#1\\end{center}\\clearpage}",
    ]

    private static func emit(fountain: ProjectAST.FountainNode, anchor: Anchor?,
                             into out: inout [String]) {
        switch fountain {
        case .sceneHeading(let s, let number):
            // The link WRAPS `\scene`, never the reverse: the starter's
            // `\scene` applies `\MakeUppercase` to its argument, which would
            // uppercase — and so break — a link target passed inside it.
            let scene: String
            if let number {
                scene = "\\scene{\(LaTeXEscape.escape(s))\\scenenumber{\(LaTeXEscape.escape(number))}}"
            } else {
                scene = "\\scene{\(LaTeXEscape.escape(s))}"
            }
            out.append(anchor?.crossLinked(scene) ?? scene)
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
            // A dual-dialogue block's members are not top-level nodes, so
            // `Section.anchors` cannot name them: the BLOCK carries the anchor.
            for n in left  { emit(fountain: n, anchor: nil, into: &leftLines) }
            for n in right { emit(fountain: n, anchor: nil, into: &rightLines) }
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
