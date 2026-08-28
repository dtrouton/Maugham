import Foundation

/// Emits `body.xhtml` fragment (no `<html>`/`<body>` wrappers) from a
/// `ProjectAST`. The EPUB packager wraps this in the proper XHTML envelope
/// and stitches into the spine.
public enum XHTMLBodyEmitter {

    /// - Parameters:
    ///   - anchorTag: the compiler's filename-safe tag for the body being
    ///     emitted (`en`, `sr`, or an ordinal). `nil` — the default every
    ///     hand-built caller uses — emits no `id` anywhere, so an untagged
    ///     emit is byte-identical to what this emitter produced before anchors
    ///     existed, `Section.anchors` populated or not.
    ///   - crossLinks: the compile's OTHER bodies, in order: each one's tag and
    ///     the href of the section file holding the SAME piece in that body.
    ///     Empty for a single-body compile, which is why it emits no `<a>`.
    public static func emit(_ ast: ProjectAST, config: PublishConfig = PublishConfig(),
                            anchorTag: String? = nil,
                            crossLinks: [(tag: String, href: String)] = []) -> String {
        var lines: [String] = []
        for section in ast.sections {
            emit(section: section, config: config, anchorTag: anchorTag,
                 crossLinks: crossLinks, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// Everything one anchored node needs: the name of its own `id` and, for a
    /// slugline, where the same paragraph lives in each of the other bodies.
    private struct Anchor {
        let tag: String
        let id: String
        let crossLinks: [(tag: String, href: String)]

        static func name(tag: String, id: String) -> String { "p-\(tag)-\(id)" }

        /// The attribute WITH its own leading space, so an element site can
        /// interpolate it straight after the tag's existing attributes and an
        /// unanchored node's tag stays character-for-character what it was.
        var attribute: String {
            " id=\"\(XHTMLEscape.attribute(Anchor.name(tag: tag, id: id)))\""
        }

        /// The other body's section file plus the fragment naming the same
        /// paragraph THERE — `section-sr-002.xhtml#p-sr-k3wq`. The fragment
        /// carries the TARGET's tag, never this body's: a link to one's own
        /// anchor is a link that goes nowhere.
        private func target(_ link: (tag: String, href: String)) -> String {
            link.href + "#" + Anchor.name(tag: link.tag, id: id)
        }

        /// The slugline's text, linked across the bodies.
        ///
        /// Where LaTeX NESTS a `\MaughamCrossLink` per other body, XHTML cannot:
        /// an `<a>` may not contain an `<a>`. So the first other body gets the
        /// text itself — the reader's obvious gesture, and the whole story for a
        /// two-language book — and every further body gets a sibling marker
        /// (`→ DE`) in a `<span class="cross-links">` after it. No other bodies
        /// → the text unchanged, which is what makes a single-language compile
        /// emit a plain heading.
        func crossLinked(_ text: String) -> String {
            guard let first = crossLinks.first else { return text }
            var out = "<a href=\"\(XHTMLEscape.attribute(target(first)))\">\(text)</a>"
            let rest = crossLinks.dropFirst()
            if !rest.isEmpty {
                out += "<span class=\"cross-links\">"
                    + rest.map {
                        "<a class=\"cross-link\" href=\"\(XHTMLEscape.attribute(target($0)))\">"
                            + "→ \(XHTMLEscape.escape($0.tag.uppercased()))</a>"
                    }.joined()
                    + "</span>"
            }
            return out
        }
    }

    /// The one place an `id` becomes markup. Every element site interpolates
    /// this — sixteen copies of `anchor.map { … } ?? ""` is how a kind of node
    /// quietly stops anchoring.
    private static func idAttribute(_ anchor: Anchor?) -> String {
        anchor?.attribute ?? ""
    }

    private static func emit(section: ProjectAST.Section, config: PublishConfig,
                             anchorTag: String?, crossLinks: [(tag: String, href: String)],
                             into out: inout [String]) {
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
        // `Section.anchors` is SPARSE and keyed by TOP-LEVEL node index: most
        // nodes have no entry, and a node's children never have one of their
        // own — the id belongs to the paragraph, and the paragraph is the node.
        for (index, node) in section.nodes.enumerated() {
            let anchor = anchorTag.flatMap { tag in
                section.anchors[index].map {
                    Anchor(tag: tag, id: $0, crossLinks: crossLinks)
                }
            }
            emit(node: node, anchor: anchor, into: &out)
        }
        out.append("</section>")
    }

    private static func emit(node: ProjectAST.Node, anchor: Anchor?,
                             into out: inout [String]) {
        switch node {
        case .prose(let p):    emit(prose: p, anchor: anchor, into: &out)
        case .fountain(let f): emit(fountain: f, anchor: anchor, into: &out)
        }
    }

    /// The `id` lands on the FIRST element this node emits — the `<blockquote>`
    /// or `<ul>` container, never its first child — so a link arrives at the top
    /// of what the paragraph produced. Children are emitted with a nil anchor:
    /// one paragraph, one id.
    private static func emit(prose: ProjectAST.ProseNode, anchor: Anchor?,
                             into out: inout [String]) {
        switch prose {
        case .paragraph(let inlines):
            out.append("<p\(idAttribute(anchor))>\(emitInline(inlines))</p>")
        case .heading(let level, let inlines):
            // Reserve <h1> for the section title; markdown `#` starts at <h2>.
            let tag = "h\(min(level + 1, 6))"
            out.append("<\(tag)\(idAttribute(anchor))>\(emitInline(inlines))</\(tag)>")
        case .blockquote(let nodes):
            out.append("<blockquote\(idAttribute(anchor))>")
            for n in nodes { emit(prose: n, anchor: nil, into: &out) }
            out.append("</blockquote>")
        case .sceneBreak:
            out.append("<hr class=\"scene-break\"\(idAttribute(anchor))/>")
        case .list(let ordered, let items):
            let tag = ordered ? "ol" : "ul"
            out.append("<\(tag)\(idAttribute(anchor))>")
            for item in items {
                out.append("<li>\(emitInline(item))</li>")
            }
            out.append("</\(tag)>")
        case .verbatim(let lines):
            let joined = lines.map(XHTMLEscape.escape).joined(separator: "<br/>")
            out.append("<p class=\"verbatim\"\(idAttribute(anchor))>\(joined)</p>")
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

    private static func emit(fountain: ProjectAST.FountainNode, anchor: Anchor?,
                             into out: inout [String]) {
        switch fountain {
        case .sceneHeading(let s, let number):
            // Only a slugline links, because only a slugline names a place a
            // reader of the other language is looking for. The link wraps the
            // heading TEXT alone: the scene number is the heading's own
            // furniture, and the markers follow all of it.
            let linked = anchor?.crossLinked(XHTMLEscape.escape(s)) ?? XHTMLEscape.escape(s)
            let numbered = number.map {
                "<span class=\"scene-number\">\(XHTMLEscape.escape($0))</span>"
            } ?? ""
            out.append("<p class=\"scene-heading\"\(idAttribute(anchor))>\(linked)\(numbered)</p>")
        case .action(let xs):
            out.append("<p class=\"action\"\(idAttribute(anchor))>\(emitInline(xs))</p>")
        case .character(let s):
            out.append("<p class=\"character\"\(idAttribute(anchor))>\(XHTMLEscape.escape(s))</p>")
        case .dialogue(let xs):
            out.append("<p class=\"dialogue\"\(idAttribute(anchor))>\(emitInline(xs))</p>")
        case .parenthetical(let xs):
            out.append("<p class=\"parenthetical\"\(idAttribute(anchor))>\(emitInline(xs))</p>")
        case .transition(let s):
            out.append("<p class=\"transition\"\(idAttribute(anchor))>\(XHTMLEscape.escape(s))</p>")
        case .lyric(let xs):
            out.append("<p class=\"lyric\"\(idAttribute(anchor))>\(emitInline(xs))</p>")
        case .centered(let xs):
            out.append("<p class=\"centered\"\(idAttribute(anchor))>\(emitInline(xs))</p>")
        case .pageBreak:
            out.append("<hr class=\"page-break\"\(idAttribute(anchor))/>")
        case .titlePage(let fields):
            out.append("<header class=\"title-page\"\(idAttribute(anchor))>")
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
            out.append("<div class=\"dual-dialogue\"\(idAttribute(anchor))>")
            out.append("<div class=\"left\">")
            for n in left { emit(fountain: n, anchor: nil, into: &out) }
            out.append("</div>")
            out.append("<div class=\"right\">")
            for n in right { emit(fountain: n, anchor: nil, into: &out) }
            out.append("</div>")
            out.append("</div>")
        }
    }
}
