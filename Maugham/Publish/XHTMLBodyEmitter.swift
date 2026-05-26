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
        case .paragraph(let s):
            out.append("<p>\(XHTMLEscape.escape(s))</p>")
        case .emphasis(let s):
            out.append("<p><em>\(XHTMLEscape.escape(s))</em></p>")
        case .strong(let s):
            out.append("<p><strong>\(XHTMLEscape.escape(s))</strong></p>")
        case .wikiLink(let target, let display):
            out.append(
                "<p><span class=\"wiki-link\" data-target=\"\(XHTMLEscape.attribute(target))\">"
                + XHTMLEscape.escape(display)
                + "</span></p>")
        case .sceneBreak:
            out.append("<hr class=\"scene-break\"/>")
        }
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
