import Foundation

/// Emits `body.tex` content from a `ProjectAST`. The template the writer-
/// Claude pair authors must \input{build/body} and define the environments
/// (\begin{prose}{title}, \begin{screenplay}{title}) plus per-mode commands
/// referenced below (\scenebreak, \wikilink, \scene, \action, \character,
/// \dialogue, \parenthetical, \transition, \dualdialogue). The barebones
/// starter provides working defaults.
public enum LaTeXBodyEmitter {

    public static func emit(_ ast: ProjectAST) -> String {
        var lines: [String] = []
        for (index, section) in ast.sections.enumerated() {
            emit(section: section, isFirst: index == 0, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - section

    private static func emit(section: ProjectAST.Section, isFirst: Bool,
                             into out: inout [String]) {
        // Each piece starts on a fresh page. The first piece follows the
        // frontmatter (which already broke the page) so it's skipped to avoid
        // a leading blank page. This is what makes pieces start on their own
        // pages without any per-section start_on configuration.
        if !isFirst { out.append("\\clearpage") }
        let title = LaTeXEscape.escape(section.title)
        switch section.mode {
        case .prose:
            out.append("\\begin{prose}{\(title)}")
            for node in section.nodes { emit(node: node, into: &out) }
            out.append("\\end{prose}")
        case .fountain:
            out.append("\\begin{screenplay}{\(title)}")
            for node in section.nodes { emit(node: node, into: &out) }
            out.append("\\end{screenplay}")
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
        }
    }

    /// Render a run of inline nodes into a single LaTeX string.
    private static func emitInline(_ inlines: [ProjectAST.Inline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s):     return LaTeXEscape.escape(s)
            case .emphasis(let xs): return "\\emph{\(emitInline(xs))}"
            case .strong(let xs):   return "\\textbf{\(emitInline(xs))}"
            case .underline(let xs): return "\\underline{\(emitInline(xs))}"
            case .code(let s):      return "\\texttt{\(LaTeXEscape.escape(s))}"
            case .wikiLink(let target, let display):
                return "\\wikilink{\(LaTeXEscape.escape(target))}{\(LaTeXEscape.escape(display))}"
            case .lineBreak:        return "\\\\"
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
            case .underline(let xs):        return plainText(xs)
            case .code(let s):              return LaTeXEscape.escape(s)
            case .wikiLink(_, let display): return LaTeXEscape.escape(display)
            case .lineBreak:                return " "
            }
        }.joined()
    }

    private static func emit(fountain: ProjectAST.FountainNode, into out: inout [String]) {
        switch fountain {
        case .sceneHeading(let s):  out.append("\\scene{\(LaTeXEscape.escape(s))}")
        case .action(let xs):       out.append("\\action{\(emitInline(xs))}")
        case .character(let s):     out.append("\\character{\(LaTeXEscape.escape(s))}")
        case .dialogue(let xs):     out.append("\\dialogue{\(emitInline(xs))}")
        case .parenthetical(let xs): out.append("\\parenthetical{\(emitInline(xs))}")
        case .transition(let s):    out.append("\\transition{\(LaTeXEscape.escape(s))}")
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
    /// it, then a page break. Standard LaTeX only — no custom command — so it
    /// compiles against any project's template.
    private static func emitTitlePage(_ fields: [ProjectAST.TitleField],
                                      into out: inout [String]) {
        func escapeMultiline(_ s: String) -> String {
            s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { LaTeXEscape.escape(String($0)) }
                .joined(separator: "\\\\")
        }
        out.append("\\begin{center}")
        out.append("\\vspace*{1.5in}")
        for field in fields {
            let value = escapeMultiline(field.value)
            if field.key == "Title" {
                out.append("{\\Large\\textbf{\(value)}}\\par")
                out.append("\\vspace{1.5em}")
            } else {
                out.append("\(value)\\par")
            }
        }
        out.append("\\end{center}")
        out.append("\\clearpage")
    }
}
