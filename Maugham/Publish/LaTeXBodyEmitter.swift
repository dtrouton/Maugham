import Foundation
import MaughamCore

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
    ///   - resolution: the WHOLE book's resolution (report foundations plan 2),
    ///     read and never recomputed: numbers, footnotes, citations,
    ///     cross-references, References and the lists. `nil` — every hand-built
    ///     caller and the emission contract — renders each report element as its
    ///     literal source (`InterimReportLiteral`) and appends each piece's
    ///     footnote definitions as literal paragraphs (R-S6), so a body without
    ///     one emits what it did before the plan. With one, an element the
    ///     resolution could not resolve still renders literally: output never
    ///     prints "??".
    ///   - figureFiles: pieceID → top-level node index → the figure's STAGED
    ///     image, relative to the template's directory (`build/figures/<hash>.png`
    ///     behind the template's `../` prefix) — keyed like
    ///     `PublishResolution.figureFiles`, whose resolved files the compiler
    ///     staged. A figure without an entry, or whose path is not a safe TeX
    ///     argument, renders as its literal source.
    ///   - isFirstBody: the first rendered body opens with the lists of
    ///     figures and tables (R-P2-6), and only its figures and tables enter
    ///     them: a later body (a bilingual book's second half) captions the
    ///     same numbers, and would list every element twice.
    public static func emit(_ ast: ProjectAST, config: PublishConfig = PublishConfig(),
                            anchorTag: String? = nil,
                            crossLinkTags: [String] = [],
                            resolution: PublishResolution? = nil,
                            figureFiles: [String: [Int: String]] = [:],
                            isFirstBody: Bool = true) -> String {
        var lines: [String] = prologue
        if let resolution {
            if ast.sections.contains(where: { $0.nodes.contains(where: isTable) }) {
                lines += tableEnvironments
            }
            if isFirstBody {
                if !resolution.listOfFigures.isEmpty {
                    lines.append("\\ifdefined\\listoffigures\\listoffigures\\clearpage\\fi")
                }
                if !resolution.listOfTables.isEmpty {
                    lines.append("\\ifdefined\\listoftables\\listoftables\\clearpage\\fi")
                }
            }
        }
        for (index, section) in ast.sections.enumerated() {
            let scope = Scope(section: section, resolution: resolution,
                              figureFiles: figureFiles[section.pieceID] ?? [:],
                              labelTag: crossLinkTags.isEmpty ? nil : anchorTag,
                              listsItsElements: isFirstBody)
            emit(section: section, isFirst: index == 0, config: config,
                 anchorTag: anchorTag, crossLinkTags: crossLinkTags, scope: scope, into: &lines)
        }
        if let resolution, !resolution.references.isEmpty {
            lines += references(resolution.references)
        }
        return lines.joined(separator: "\n")
    }

    private static func isTable(_ node: ProjectAST.Node) -> Bool {
        guard case .prose(.table) = node else { return false }
        return true
    }

    // MARK: - report elements

    /// What one section's report elements read while it is emitted: the
    /// book's resolution, this piece's footnote definitions and staged
    /// figures, and the notes already set. A class because the inline walk
    /// both reads and appends to it at every depth.
    private final class Scope {
        let resolution: PublishResolution?
        let section: ProjectAST.Section
        let figureFiles: [Int: String]
        /// The body's tag when the compile has OTHER bodies: every body carries
        /// the same labels, so its anchors must name it or a link would land
        /// in the first language. Nil for a single body: `lbl-<kind>-<name>`.
        let labelTag: String?
        /// False in every body after the first: its figures and tables keep
        /// their captions but stay out of the lists (`isFirstBody`).
        let listsItsElements: Bool
        /// Footnote labels already set in this piece: a second reference to
        /// one is a mark, never a second copy of its text.
        var setNotes = Set<String>()
        /// `\footnotetext`s owed by a construct that cannot hold a
        /// `\footnote` (a caption, a table cell, a heading, a note's own text).
        var pending: [String] = []

        init(section: ProjectAST.Section, resolution: PublishResolution?,
             figureFiles: [Int: String], labelTag: String?, listsItsElements: Bool) {
            self.section = section
            self.resolution = resolution
            self.figureFiles = figureFiles
            self.labelTag = labelTag
            self.listsItsElements = listsItsElements
        }

        var pieceID: String { section.pieceID }

        func anchorName(_ label: ManuscriptLabel) -> String {
            "lbl-" + (labelTag.map { "\($0)-" } ?? "") + "\(label.kind.rawValue)-\(label.name)"
        }

        /// The label's anchor, when the resolution gave this very element the
        /// label (right kind, not a duplicate): a target's piece, paragraph and
        /// text all match it.
        func anchor(_ label: ManuscriptLabel?, kind: ManuscriptLabel.Kind,
                    index: Int, text: String?) -> String? {
            guard let label, label.kind == kind, let target = resolution?.targets[label],
                  target.pieceID == pieceID,
                  target.paragraphID == section.nodeParagraphs[index],
                  text == nil || target.text == text else { return nil }
            return "\\hypertarget{\(anchorName(label))}{}"
        }

        /// The owed `\footnotetext`s, emptied.
        func flush(into out: inout [String]) {
            out += pending
            pending.removeAll()
        }
    }

    /// `MaughamTable`, guarded so a template that defines its own wins, with
    /// two branches decided by what the preamble loaded: a `longtable` that
    /// repeats its header on every page (the caption on the first page only;
    /// `\caption[]` keeps the repeat out of the list of tables), or — a
    /// preamble without longtable — a `table` float around a plain `tabular`.
    /// Every table is captioned, so its number is always visible (R-S9).
    /// Emitted only into a body that has a table, so every other body keeps
    /// its three prologue lines.
    ///
    /// A `\\` peeks past spaces for `*` and `[`: the header (`#4`) and every
    /// row that follows one are guarded by `rowStart`, never by a trailing
    /// `\\\relax` — that would start a cell, so a following `\hline` is a
    /// misplaced `\noalign` and the last row grows an empty one.
    private static let tableEnvironments: [String] = [
        "\\ifdefined\\MaughamTable\\else\\ifdefined\\longtable",
        "\\newenvironment{MaughamTable}[4]{\\begin{longtable}{#1}\\caption[{#2}]{#3}\\\\#4\\\\\\hline"
            + "\\endfirsthead\\caption[]{#3}\\\\#4\\\\\\hline\\endhead}{\\end{longtable}}",
        "\\else",
        "\\newenvironment{MaughamTable}[4]{\\begin{table}[htbp]\\centering\\caption[{#2}]{#3}"
            + "\\begin{tabular}{#1}#4\\\\\\hline}{\\end{tabular}\\end{table}}",
        "\\fi\\fi",
    ]

    /// What follows a `\\` must not open with `[` or `*` (after spaces), or
    /// `\\` reads it as its optional argument or star — "Missing number" on a
    /// cell that reads `[draft]` or a literal `[@ghost]`. Such a row starts
    /// with `\relax`; any other is left as it is.
    static func rowStart(_ row: String) -> String {
        let first = row.first { $0 != " " }
        return first == "[" || first == "*" ? "\\relax " + row : row
    }

    /// A list entry's short caption: `\relax` when the caption has no text, so
    /// the element is still listed under its number (longtable drops an entry
    /// whose short caption is empty; the kernel's float keeps it).
    private static func listEntry(_ short: String) -> String {
        short.isEmpty ? "\\relax" : short
    }

    /// In a body after the first, the element keeps its caption but its list
    /// entry is gobbled: `\addcontentsline` is a no-op inside this group, in a
    /// longtable and a float alike (`\caption[]` would quiet only longtable;
    /// the kernel's float lists an empty short caption too).
    private static func openUnlisted(_ scope: Scope, into out: inout [String]) {
        guard !scope.listsItsElements else { return }
        out.append("\\begingroup\\renewcommand{\\addcontentsline}[3]{}")
    }

    private static func closeUnlisted(_ scope: Scope, into out: inout [String]) {
        guard !scope.listsItsElements else { return }
        out.append("\\endgroup")
    }

    /// R-P2-5: one unnumbered section closing the body, in the contents, its
    /// entries a hanging-indent list built only from kernel commands.
    private static func references(_ entries: [[CitationStyle.Run]]) -> [String] {
        var out = [
            "\\clearpage",
            "\\section*{References}",
            "\\addcontentsline{toc}{section}{References}",
            "\\begingroup",
            "\\setlength{\\parindent}{0pt}",
            "\\setlength{\\parskip}{0.5em}",
        ]
        for runs in entries {
            let text = runs.map { run in
                run.italic ? "\\emph{\(LaTeXEscape.escape(run.text))}" : LaTeXEscape.escape(run.text)
            }.joined()
            out.append("\\hangindent=1.5em\\hangafter=1 \(text)\\par")
        }
        out.append("\\endgroup")
        return out
    }

    /// A staged image path is safe to put inside `\includegraphics{}`: every
    /// segment is a `..` (the template-directory prefix) or a
    /// `LaTeXSafeFilename`. Staging names files `<sha256-prefix>.<ext>`, so a
    /// real one always passes; this is the second line of defence.
    static func isSafeGraphicsPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), let last = parts.last,
              LaTeXSafeFilename(String(last)) != nil else { return false }
        return parts.dropLast().allSatisfy { $0 == ".." || LaTeXSafeFilename(String($0)) != nil }
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
                             crossLinkTags: [String], scope: Scope, into out: inout [String]) {
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
                      crossLinkTags: crossLinkTags, scope: scope, into: &out)
            if scope.resolution == nil { emitLiteralFootnoteDefinitions(scope, into: &out) }
            out.append("\\end{prose}")
        case .fountain:
            out.append("\\begin{screenplay}\(opt){\(title)}")
            out.append(contentsOf: fountainProvidecommands)
            emitNodes(of: section, anchorTag: anchorTag,
                      crossLinkTags: crossLinkTags, scope: scope, into: &out)
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
                                  crossLinkTags: [String], scope: Scope,
                                  into out: inout [String]) {
        for (index, node) in section.nodes.enumerated() {
            let anchor = anchorTag.flatMap { tag in
                section.anchors[index].map {
                    Anchor(tag: tag, id: $0, crossLinkTags: crossLinkTags)
                }
            }
            if let anchor { out.append("\\hypertarget{\(anchor.name)}{}") }
            emit(node: node, index: index, anchor: anchor, scope: scope, into: &out)
        }
    }

    private static func emit(node: ProjectAST.Node, index: Int, anchor: Anchor?,
                             scope: Scope, into out: inout [String]) {
        switch node {
        // Prose has no cross-linked node kind: only a slugline links, because
        // only a slugline names a place a reader of the other language is
        // looking for. Prose still anchors, so a link HAS somewhere to land.
        case .prose(let p):    emit(prose: p, index: index, scope: scope, into: &out)
        case .fountain(let f): emit(fountain: f, anchor: anchor, scope: scope, into: &out)
        }
    }

    /// - Parameter index: the node's top-level index in its section, by which
    ///   the resolution numbers it; nil inside a blockquote, where nothing is
    ///   numbered or labelled and a table or figure renders literally.
    private static func emit(prose: ProjectAST.ProseNode, index: Int?, scope: Scope,
                             into out: inout [String]) {
        switch prose {
        case .paragraph(let inlines):
            out.append(emitInline(inlines, scope))
            out.append("")   // blank line → \par so paragraphs don't run together
        case .heading(let level, let headingInlines, let label):
            let cmd = ["section", "subsection", "subsubsection"][min(max(level - 1, 0), 2)]
            guard let resolution = scope.resolution else {
                // No resolution: the label prints as the literal `{#kind:name}`
                // it was written as.
                let inlines = headingInlines + InterimReportLiteral.labelSuffix(label)
                out.append("\\\(cmd)*{\(emitInline(inlines, scope))}")
                out.append("\\addcontentsline{toc}{\(cmd)}{\(plainText(inlines, scope))}")
                return
            }
            // Starred, so LaTeX numbers nothing: the resolution's number is
            // the text, in the title and its contents line alike.
            let number = index.flatMap { resolution.headingNumbers[scope.pieceID]?[$0] }
            let prefix = number.map { "\($0)\\quad " } ?? ""
            if let index, let a = scope.anchor(label, kind: .sec, index: index,
                                               text: number.map { "Section \($0)" }) {
                out.append(a)
            }
            out.append("\\\(cmd)*{\(prefix)\(emitInline(headingInlines, scope, deferred: true))}")
            out.append("\\addcontentsline{toc}{\(cmd)}{\(prefix)\(plainText(headingInlines, scope))}")
            scope.flush(into: &out)
        case .blockquote(let nodes):
            out.append("\\begin{quote}")
            for n in nodes { emit(prose: n, index: nil, scope: scope, into: &out) }
            out.append("\\end{quote}")
        case .sceneBreak:
            out.append("\\scenebreak")
        case .list(let ordered, let items):
            let env = ordered ? "enumerate" : "itemize"
            out.append("\\begin{\(env)}")
            for item in items {
                // `\item` peeks for `[` as its label argument: an item whose
                // text opens with one would lose it to the label.
                let text = emitInline(item, scope)
                out.append((text.hasPrefix("[") ? "\\item\\relax " : "\\item ") + text)
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
        case .table(let header, let alignments, let rows, let caption, let label):
            guard let index, let n = scope.resolution?.tableNumbers[scope.pieceID]?[index] else {
                // No resolution, or not a top-level table: its literal source.
                emit(prose: .paragraph(InterimReportLiteral.table(
                    header: header, alignments: alignments, rows: rows,
                    caption: caption, label: label)), index: nil, scope: scope, into: &out)
                return
            }
            emitTable(number: n, index: index, header: header, alignments: alignments,
                      rows: rows, caption: caption, label: label, scope: scope, into: &out)
        case .figure(let caption, let path, let label):
            guard let index, let n = scope.resolution?.figureNumbers[scope.pieceID]?[index],
                  let file = scope.figureFiles[index], isSafeGraphicsPath(file) else {
                // No resolution, an image that was refused or never staged:
                // its literal source.
                emit(prose: .paragraph(InterimReportLiteral.figure(
                    caption: caption, path: path, label: label)), index: nil, scope: scope, into: &out)
                return
            }
            emitFigure(number: n, index: index, caption: caption, file: file, label: label,
                       scope: scope, into: &out)
        }
    }

    /// `\begin{MaughamTable}{<colspec>}{<short caption>}{<caption>}{<header>}`,
    /// the body's rows, `\end{MaughamTable}`; a table without a caption line
    /// gets an empty caption, so its number still prints (R-S9). The counter is set first so `\caption` prints the
    /// resolution's number in any subset. Cells, headers and captions defer
    /// their footnotes; the texts follow the table.
    private static func emitTable(number: Int, index: Int, header: [[ProjectAST.Inline]],
                                  alignments: [TableAlignment], rows: [[[ProjectAST.Inline]]],
                                  caption: [ProjectAST.Inline]?, label: ManuscriptLabel?,
                                  scope: Scope, into out: inout [String]) {
        let columns = max(header.count, 1)
        let spec = (0..<columns).map { column -> String in
            guard column < alignments.count else { return "l" }
            switch alignments[column] {
            case .none, .leading: return "l"
            case .center:         return "c"
            case .trailing:       return "r"
            }
        }.joined()
        func row(_ cells: [[ProjectAST.Inline]]) -> String {
            (0..<columns).map { column in
                column < cells.count ? emitInline(cells[column], scope, deferred: true) : ""
            }.joined(separator: " & ")
        }
        openUnlisted(scope, into: &out)
        out.append("\\setcounter{table}{\(number - 1)}")
        if let a = scope.anchor(label, kind: .tbl, index: index, text: "Table \(number)") {
            out.append(a)
        }
        // R-S9: captioned or not, the table prints "Table n".
        let text = caption ?? []
        out.append("\\begin{MaughamTable}{\(spec)}{\(listEntry(plainText(text, scope)))}"
                   + "{\(emitInline(text, scope, deferred: true))}{\(rowStart(row(header)))}")
        for r in rows { out.append(rowStart(row(r)) + " \\\\") }
        out.append("\\end{MaughamTable}")
        closeUnlisted(scope, into: &out)
        scope.flush(into: &out)
    }

    /// A `figure` float: the image when graphicx is loaded, else its caption
    /// in a framed box (a preamble that predates the plan, or a redesigned
    /// template without `build/metadata`), then the caption. The counter is
    /// set first so `\caption` prints the resolution's number in any subset.
    private static func emitFigure(number: Int, index: Int, caption: [ProjectAST.Inline],
                                   file: String, label: ManuscriptLabel?,
                                   scope: Scope, into out: inout [String]) {
        let short = plainText(caption, scope)
        openUnlisted(scope, into: &out)
        out.append("\\setcounter{figure}{\(number - 1)}")
        out.append("\\begin{figure}[htbp]")
        out.append("\\centering")
        if let a = scope.anchor(label, kind: .fig, index: index, text: "Figure \(number)") {
            out.append(a)
        }
        out.append("\\ifdefined\\includegraphics\\includegraphics[width=\\linewidth]{\(file)}"
                   + "\\else\\fbox{\\parbox{0.9\\linewidth}{\\centering \(short)}}\\fi")
        out.append("\\caption[{\(listEntry(short))}]{\(emitInline(caption, scope, deferred: true))}")
        out.append("\\end{figure}")
        closeUnlisted(scope, into: &out)
        scope.flush(into: &out)
    }

    /// R-S6: with no resolution a footnote definition has nowhere to render,
    /// so each prints as the literal paragraph it was written as, at the end
    /// of its piece, in label order (numbers numerically).
    private static func emitLiteralFootnoteDefinitions(_ scope: Scope, into out: inout [String]) {
        let labels = scope.section.footnotes.keys.sorted {
            $0.compare($1, options: .numeric) == .orderedAscending
        }
        for label in labels {
            out.append(LaTeXEscape.escape(InterimReportLiteral.footnoteRef(label) + ": ")
                       + emitInline(scope.section.footnotes[label] ?? [], scope))
            out.append("")
        }
    }

    /// Render a run of inline nodes into a single LaTeX string.
    ///
    /// - Parameter deferred: the run sits where `\footnote` is lost or breaks
    ///   the compile (a caption, a table cell, a heading, a note's own text):
    ///   a footnote there is `\footnotemark[n]`, and its `\footnotetext[n]`
    ///   waits in `scope.pending` for the construct to close.
    private static func emitInline(_ inlines: [ProjectAST.Inline], _ scope: Scope,
                                   deferred: Bool = false) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s):     return LaTeXEscape.escape(s)
            case .emphasis(let xs): return "\\emph{\(emitInline(xs, scope, deferred: deferred))}"
            case .strong(let xs):   return "\\textbf{\(emitInline(xs, scope, deferred: deferred))}"
            case .strikethrough(let xs): return "\\st{\(emitInline(xs, scope, deferred: deferred))}"
            case .underline(let xs): return "\\underline{\(emitInline(xs, scope, deferred: deferred))}"
            case .code(let s):      return "\\texttt{\(LaTeXEscape.escape(s))}"
            case .wikiLink(let target, let display):
                return "\\wikilink{\(LaTeXEscape.escape(target))}{\(LaTeXEscape.escape(display))}"
            // `\newline`, not `\\`: a following `[` or `*` in the text would
            // be captured as `\\`'s optional/star argument. Trailing space
            // stops the control word absorbing a following letter.
            case .lineBreak:        return "\\newline "
            case .footnoteRef(let label): return footnote(label, scope, deferred: deferred)
            case .citation(let items):
                return LaTeXEscape.escape(citationText(items, scope) ?? InterimReportLiteral.citation(items))
            case .crossRef(let label):
                guard let target = scope.resolution?.targets[label] else {
                    return LaTeXEscape.escape(InterimReportLiteral.crossRef(label))
                }
                return "\\MaughamCrossLink{\(scope.anchorName(label))}{\(LaTeXEscape.escape(target.text))}"
            }
        }.joined()
    }

    private static func citationText(_ items: [CitationItem], _ scope: Scope) -> String? {
        scope.resolution?.citationText[PublishResolution.citationKey(items)]
    }

    /// R-S8: `\footnote[n]` with the resolution's number, so the PDF and the
    /// EPUB agree even for a note inside a note. Its first reference sets the
    /// text; a later one in the piece is `\footnotemark[n]`. No number (no
    /// resolution, or no definition) → the literal `[^label]`.
    private static func footnote(_ label: String, _ scope: Scope, deferred: Bool) -> String {
        guard let n = scope.resolution?.footnoteNumbers[scope.pieceID]?[label],
              let definition = scope.section.footnotes[label] else {
            return LaTeXEscape.escape(InterimReportLiteral.footnoteRef(label))
        }
        guard scope.setNotes.insert(label).inserted else { return "\\footnotemark[\(n)]" }
        // A note inside this note's text is itself a mark and a text.
        let mark = scope.pending.count
        let body = emitInline(definition, scope, deferred: true)
        if deferred {
            scope.pending.insert("\\footnotetext[\(n)]{\(body)}", at: mark)
            return "\\footnotemark[\(n)]"
        }
        let nested = scope.pending[mark...].joined()
        scope.pending.removeSubrange(mark...)
        return "\\footnote[\(n)]{\(body)}" + nested
    }

    /// Flatten inline runs to escaped plain text (no formatting commands) for
    /// `\addcontentsline` and a caption's list entry — running `\emph`/
    /// `\textbf` through the ToC entry is fragile, so headings appear
    /// unformatted in the contents. A resolved footnote drops out; a citation
    /// or cross-reference reads as it does in the text.
    private static func plainText(_ inlines: [ProjectAST.Inline], _ scope: Scope) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s):              return LaTeXEscape.escape(s)
            case .emphasis(let xs):         return plainText(xs, scope)
            case .strong(let xs):           return plainText(xs, scope)
            case .strikethrough(let xs):    return plainText(xs, scope)
            case .underline(let xs):        return plainText(xs, scope)
            case .code(let s):              return LaTeXEscape.escape(s)
            case .wikiLink(_, let display): return LaTeXEscape.escape(display)
            case .lineBreak:                return " "
            case .footnoteRef(let label):
                let numbered = scope.resolution?.footnoteNumbers[scope.pieceID]?[label] != nil
                    && scope.section.footnotes[label] != nil
                return numbered ? "" : LaTeXEscape.escape(InterimReportLiteral.footnoteRef(label))
            case .citation(let items):
                return LaTeXEscape.escape(citationText(items, scope) ?? InterimReportLiteral.citation(items))
            case .crossRef(let label):
                return LaTeXEscape.escape(scope.resolution?.targets[label]?.text
                                          ?? InterimReportLiteral.crossRef(label))
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
                             scope: Scope, into out: inout [String]) {
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
        case .action(let xs):       out.append("\\action{\(emitInline(xs, scope))}")
        case .character(let s):     out.append("\\character{\(LaTeXEscape.escape(s))}")
        case .dialogue(let xs):     out.append("\\dialogue{\(emitInline(xs, scope))}")
        case .parenthetical(let xs): out.append("\\parenthetical{\(emitInline(xs, scope))}")
        case .transition(let s):    out.append("\\transition{\(LaTeXEscape.escape(s))}")
        case .lyric(let xs):        out.append("\\lyricline{\(emitInline(xs, scope))}")
        case .centered(let xs):     out.append("\\centeredline{\(emitInline(xs, scope))}")
        case .pageBreak:            out.append("\\clearpage")
        case .titlePage(let fields): emitTitlePage(fields, into: &out)
        case .dualDialogue(let left, let right):
            var leftLines: [String] = []
            var rightLines: [String] = []
            // A dual-dialogue block's members are not top-level nodes, so
            // `Section.anchors` cannot name them: the BLOCK carries the anchor.
            for n in left  { emit(fountain: n, anchor: nil, scope: scope, into: &leftLines) }
            for n in right { emit(fountain: n, anchor: nil, scope: scope, into: &rightLines) }
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
