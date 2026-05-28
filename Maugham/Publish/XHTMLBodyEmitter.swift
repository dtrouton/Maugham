import Foundation

/// Emits `body.xhtml` fragment (no `<html>`/`<body>` wrappers) from a
/// `ProjectAST`. The EPUB packager wraps this in the proper XHTML envelope
/// and stitches into the spine.
public enum XHTMLBodyEmitter {

    public static func emit(_ ast: ProjectAST) -> String {
        var lines: [String] = []
        for section in ast.sections {
            emit(section: section, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func emit(section: ProjectAST.Section, into out: inout [String]) {
        let modeClass: String
        switch section.mode {
        case .prose:    modeClass = "prose"
        case .fountain: modeClass = "screenplay"
        }
        out.append("<section class=\"\(modeClass)\" data-piece-id=\"\(XHTMLEscape.attribute(section.pieceID))\">")
        out.append("<h1>\(XHTMLEscape.escape(section.title))</h1>")
        for node in section.nodes { emit(node: node, into: &out) }
        out.append("</section>")
    }

    private static func emit(node: ProjectAST.Node, into out: inout [String]) {
        switch node {
        case .prose(let p):    emit(prose: p, into: &out)
        case .fountain(let f): emit(fountain: f, into: &out)
        }
    }

    private static func emit(prose: ProjectAST.ProseNode, into out: inout [String]) {
        switch prose {
        case .paragraph(let inlines):
            out.append("<p>\(emitInline(inlines))</p>")
        case .heading(let level, let inlines):
            // Reserve <h1> for the section title; markdown `#` starts at <h2>.
            let tag = "h\(min(level + 1, 6))"
            out.append("<\(tag)>\(emitInline(inlines))</\(tag)>")
        case .blockquote(let nodes):
            out.append("<blockquote>")
            for n in nodes { emit(prose: n, into: &out) }
            out.append("</blockquote>")
        case .sceneBreak:
            out.append("<hr class=\"scene-break\"/>")
        }
    }

    /// Render a run of inline nodes into a single XHTML string.
    private static func emitInline(_ inlines: [ProjectAST.Inline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s):      return XHTMLEscape.escape(s)
            case .emphasis(let xs): return "<em>\(emitInline(xs))</em>"
            case .strong(let xs):   return "<strong>\(emitInline(xs))</strong>"
            case .code(let s):      return "<code>\(XHTMLEscape.escape(s))</code>"
            case .wikiLink(let target, let display):
                return "<span class=\"wiki-link\" data-target=\"\(XHTMLEscape.attribute(target))\">"
                    + XHTMLEscape.escape(display) + "</span>"
            case .lineBreak:        return "<br/>"
            }
        }.joined()
    }

    private static func emit(fountain: ProjectAST.FountainNode, into out: inout [String]) {
        switch fountain {
        case .sceneHeading(let s):  out.append("<p class=\"scene-heading\">\(XHTMLEscape.escape(s))</p>")
        case .action(let s):        out.append("<p class=\"action\">\(XHTMLEscape.escape(s))</p>")
        case .character(let s):     out.append("<p class=\"character\">\(XHTMLEscape.escape(s))</p>")
        case .dialogue(let s):      out.append("<p class=\"dialogue\">\(XHTMLEscape.escape(s))</p>")
        case .parenthetical(let s): out.append("<p class=\"parenthetical\">\(XHTMLEscape.escape(s))</p>")
        case .transition(let s):    out.append("<p class=\"transition\">\(XHTMLEscape.escape(s))</p>")
        case .dualDialogue(let left, let right):
            out.append("<div class=\"dual-dialogue\">")
            out.append("<div class=\"left\">")
            for n in left { emit(fountain: n, into: &out) }
            out.append("</div>")
            out.append("<div class=\"right\">")
            for n in right { emit(fountain: n, into: &out) }
            out.append("</div>")
            out.append("</div>")
        }
    }
}
