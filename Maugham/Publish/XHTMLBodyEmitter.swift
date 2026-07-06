import Foundation

/// Emits `body.xhtml` fragment (no `<html>`/`<body>` wrappers) from a
/// `ProjectAST`. The EPUB packager wraps this in the proper XHTML envelope
/// and stitches into the spine.
public enum XHTMLBodyEmitter {

    public static func emit(_ ast: ProjectAST, config: PublishConfig = PublishConfig()) -> String {
        var lines: [String] = []
        for section in ast.sections {
            emit(section: section, config: config, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func emit(section: ProjectAST.Section, config: PublishConfig, into out: inout [String]) {
        let modeClass: String
        switch section.mode {
        case .prose:    modeClass = "prose"
        case .fountain: modeClass = "screenplay"
        }
        let ov = config.sections[section.pieceID]
        let tocAttr = (ov?.includeInToc == false) ? " data-toc=\"false\"" : ""
        out.append("<section class=\"\(modeClass)\" data-piece-id=\"\(XHTMLEscape.attribute(section.pieceID))\"\(tocAttr)>")
        let title = XHTMLEscape.escape(ov?.titleOverride ?? section.title)
        out.append("<h1>\(title)</h1>")
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
            case .strikethrough(let xs): return "<s>\(emitInline(xs))</s>"
            case .underline(let xs): return "<u>\(emitInline(xs))</u>"
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
        case .sceneHeading(let s, let number):
            if let number {
                out.append("<p class=\"scene-heading\">\(XHTMLEscape.escape(s))"
                    + "<span class=\"scene-number\">\(XHTMLEscape.escape(number))</span></p>")
            } else {
                out.append("<p class=\"scene-heading\">\(XHTMLEscape.escape(s))</p>")
            }
        case .action(let xs):       out.append("<p class=\"action\">\(emitInline(xs))</p>")
        case .character(let s):     out.append("<p class=\"character\">\(XHTMLEscape.escape(s))</p>")
        case .dialogue(let xs):     out.append("<p class=\"dialogue\">\(emitInline(xs))</p>")
        case .parenthetical(let xs): out.append("<p class=\"parenthetical\">\(emitInline(xs))</p>")
        case .transition(let s):    out.append("<p class=\"transition\">\(XHTMLEscape.escape(s))</p>")
        case .lyric(let xs):        out.append("<p class=\"lyric\">\(emitInline(xs))</p>")
        case .centered(let xs):     out.append("<p class=\"centered\">\(emitInline(xs))</p>")
        case .pageBreak:            out.append("<hr class=\"page-break\"/>")
        case .titlePage(let fields):
            out.append("<header class=\"title-page\">")
            for field in fields {
                let value = XHTMLEscape.escape(field.value)
                    .replacingOccurrences(of: "\n", with: "<br/>")
                if field.key == "Title" {
                    out.append("<h1 class=\"title\">\(value)</h1>")
                } else {
                    let cls = field.key.lowercased().replacingOccurrences(of: " ", with: "-")
                    out.append("<p class=\"\(XHTMLEscape.attribute(cls))\">\(value)</p>")
                }
            }
            out.append("</header>")
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
