import Foundation
import MaughamCore

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
    ///     Non-empty also means every report id names this body (`anchorTag`):
    ///     every body carries the same labels and notes, as the PDF's do.
    ///   - resolution: the WHOLE book's resolution (report foundations plan 2),
    ///     read and never recomputed. `nil` — every hand-built caller and the
    ///     emission contract — renders each report element as its literal
    ///     source (`InterimReportLiteral`) and appends each prose section's
    ///     footnote definitions as literal paragraphs (R-S6). With one, an
    ///     element it could not resolve still renders literally: output never
    ///     prints "??".
    ///   - figureFiles: pieceID → top-level node index → the figure's packaged
    ///     image, relative to `OEBPS/` (`images/<hash>.<ext>`), keyed like
    ///     `PublishResolution.figureFiles`. A numbered figure without an entry
    ///     renders as its literal source.
    ///   - labelHrefs: label → `section-…xhtml#lbl-…`, the file its target is
    ///     emitted in (`EPUBCompiler.labelHrefs`). A resolved cross-reference
    ///     with no href — its target is in a piece this compile does not emit —
    ///     reads as its text ("Figure 7"), unlinked.
    ///
    /// The EPUB calls this once per section file, so a section's footnote
    /// asides close that section: a note always lives in its reference's file.
    public static func emit(_ ast: ProjectAST, config: PublishConfig = PublishConfig(),
                            anchorTag: String? = nil,
                            crossLinks: [(tag: String, href: String)] = [],
                            resolution: PublishResolution? = nil,
                            figureFiles: [String: [Int: String]] = [:],
                            labelHrefs: [ManuscriptLabel: String] = [:]) -> String {
        var lines: [String] = []
        let idTag = crossLinks.isEmpty ? nil : anchorTag
        for section in ast.sections {
            let scope = Scope(section: section, resolution: resolution,
                              figureFiles: figureFiles[section.pieceID] ?? [:],
                              labelHrefs: labelHrefs, idTag: idTag)
            emit(section: section, config: config, anchorTag: anchorTag,
                 crossLinks: crossLinks, scope: scope, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - report ids

    /// A label's element id: `lbl-<kind>-<name>`, or `lbl-<tag>-<kind>-<name>`
    /// when the compile has several bodies — the PDF's anchor names exactly.
    static func labelID(_ label: ManuscriptLabel, tag: String?) -> String {
        "lbl-" + (tag.map { "\($0)-" } ?? "") + "\(label.kind.rawValue)-\(label.name)"
    }

    /// The id of a numbered figure or table that owns no label — `fig-3`,
    /// `tbl-2` (`fig-<tag>-3` with several bodies) — so the nav's lists can
    /// link to every element, labelled or not.
    static func elementID(_ kind: ManuscriptLabel.Kind, number: Int, tag: String?) -> String {
        "\(kind.rawValue)-" + (tag.map { "\($0)-" } ?? "") + "\(number)"
    }

    /// Where a numbered figure or table is addressed: its label's id when the
    /// resolution gave it that label (the target IS this element), else its
    /// `elementID`. One id per element, read by the emitter and by the
    /// compiler's list hrefs alike, so a list entry lands where the element is.
    static func elementAddress(_ kind: ManuscriptLabel.Kind, number: Int,
                               target: PublishResolution.Target,
                               resolution: PublishResolution, tag: String?) -> String {
        let owned = resolution.targets.first { $0.key.kind == kind && $0.value == target }?.key
        return owned.map { labelID($0, tag: tag) } ?? elementID(kind, number: number, tag: tag)
    }

    /// A figure's or table's target, as the resolution built it.
    static func elementTarget(_ kind: ManuscriptLabel.Kind, number: Int, pieceID: String,
                              paragraphID: String?) -> PublishResolution.Target {
        .init(pieceID: pieceID, paragraphID: paragraphID, text: "\(captionWord(kind)) \(number)")
    }

    private static func captionWord(_ kind: ManuscriptLabel.Kind) -> String {
        switch kind {
        case .fig: return "Figure"
        case .tbl: return "Table"
        case .sec: return "Section"
        }
    }

    /// "Figure 3. Revenue by quarter" — "Figure 3." alone for an empty
    /// caption — as plain text, for the nav's lists. The separator is a full
    /// stop for tables and figures alike, as in `<caption>`/`<figcaption>`.
    static func listTitle(_ kind: ManuscriptLabel.Kind, number: Int, caption: [ProjectAST.Inline],
                          resolution: PublishResolution, pieceID: String) -> String {
        let text = plainText(caption, resolution: resolution, pieceID: pieceID)
        return "\(captionWord(kind)) \(number)." + (text.isEmpty ? "" : " " + text)
    }

    // MARK: - References

    /// R-P2-5: a body's References, the body of its own section file
    /// (`references.xhtml`), one paragraph per cited source.
    static func references(_ entries: [[CitationStyle.Run]]) -> String {
        var out = ["<section class=\"references\">", "<h1>References</h1>"]
        for runs in entries {
            let text = runs.map { run in
                run.italic ? "<em>\(XHTMLEscape.escape(run.text))</em>" : XHTMLEscape.escape(run.text)
            }.joined()
            out.append("<p class=\"reference\">\(text)</p>")
        }
        out.append("</section>")
        return out.joined(separator: "\n")
    }

    // MARK: - the section's report scope

    /// What one section's report elements read while it is emitted: the
    /// book's resolution, this piece's staged images and the label hrefs, and
    /// the notes already referenced. A class because the inline walk both
    /// reads and appends to it at every depth.
    private final class Scope {
        let section: ProjectAST.Section
        let resolution: PublishResolution?
        let figureFiles: [Int: String]
        let labelHrefs: [ManuscriptLabel: String]
        /// The body's tag when the compile has other bodies; nil for one.
        let idTag: String?
        /// Footnote labels already referenced in this section, in first-
        /// reference order: each gets one aside, and only the first reference
        /// carries the `fnref` id its aside links back to.
        var notes: [String] = []

        init(section: ProjectAST.Section, resolution: PublishResolution?,
             figureFiles: [Int: String], labelHrefs: [ManuscriptLabel: String], idTag: String?) {
            self.section = section
            self.resolution = resolution
            self.figureFiles = figureFiles
            self.labelHrefs = labelHrefs
            self.idTag = idTag
        }

        var pieceID: String { section.pieceID }

        func footnoteID(_ n: Int) -> String { "fn-" + (idTag.map { "\($0)-" } ?? "") + "\(n)" }
        func footnoteRefID(_ n: Int) -> String { "fnref-" + (idTag.map { "\($0)-" } ?? "") + "\(n)" }

        /// The heading's label, when the resolution gave this very heading
        /// that label (right kind, not a duplicate) — `LaTeXBodyEmitter`'s rule.
        func ownedHeadingLabel(_ label: ManuscriptLabel?, index: Int, text: String?) -> ManuscriptLabel? {
            guard let label, label.kind == .sec, let target = resolution?.targets[label],
                  target.pieceID == pieceID,
                  target.paragraphID == section.nodeParagraphs[index],
                  text == nil || target.text == text else { return nil }
            return label
        }

        func address(_ kind: ManuscriptLabel.Kind, number: Int, index: Int,
                     resolution: PublishResolution) -> String {
            XHTMLBodyEmitter.elementAddress(
                kind, number: number,
                target: XHTMLBodyEmitter.elementTarget(kind, number: number, pieceID: pieceID,
                                                       paragraphID: section.nodeParagraphs[index]),
                resolution: resolution, tag: idTag)
        }
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
                             scope: Scope, into out: inout [String]) {
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
            emit(node: node, index: index, anchor: anchor, scope: scope, into: &out)
        }
        if scope.resolution == nil {
            if section.mode == .prose { emitLiteralFootnoteDefinitions(scope, into: &out) }
        } else {
            emitFootnoteAsides(scope, into: &out)
        }
        out.append("</section>")
    }

    private static func emit(node: ProjectAST.Node, index: Int, anchor: Anchor?,
                             scope: Scope, into out: inout [String]) {
        switch node {
        case .prose(let p):    emit(prose: p, index: index, anchor: anchor, scope: scope, into: &out)
        case .fountain(let f): emit(fountain: f, anchor: anchor, scope: scope, into: &out)
        }
    }

    /// R-S6: with no resolution a footnote definition has nowhere to render,
    /// so each prints as the literal paragraph it was written as, at the end
    /// of its section, in label order (numbers numerically) — the PDF's rule.
    private static func emitLiteralFootnoteDefinitions(_ scope: Scope, into out: inout [String]) {
        let labels = scope.section.footnotes.keys.sorted {
            $0.compare($1, options: .numeric) == .orderedAscending
        }
        for label in labels {
            out.append("<p>" + XHTMLEscape.escape(InterimReportLiteral.footnoteRef(label) + ": ")
                       + emitInline(scope.section.footnotes[label] ?? [], scope) + "</p>")
        }
    }

    /// R-S2/R-S8: one EPUB 3 pop-up footnote per note referenced in this
    /// section, `<aside epub:type="footnote" id="fn-n">`, closing the section
    /// file that holds the reference. A note referenced inside a note's own
    /// text is referenced HERE, so its aside joins this file too — the walk
    /// runs until no new note appears. The asides read in number order
    /// whatever order their references rendered in (a table's caption
    /// renders before its cells, a nested note after its parent's text).
    private static func emitFootnoteAsides(_ scope: Scope, into out: inout [String]) {
        var asides: [(number: Int, html: String)] = []
        var next = 0
        while next < scope.notes.count {
            let label = scope.notes[next]
            next += 1
            guard let n = scope.resolution?.footnoteNumbers[scope.pieceID]?[label] else { continue }
            let body = emitInline(scope.section.footnotes[label] ?? [], scope)
            asides.append((n, "<aside epub:type=\"footnote\" id=\"\(scope.footnoteID(n))\">"
                + "<p><a href=\"#\(scope.footnoteRefID(n))\">\(n)</a> \(body)</p></aside>"))
        }
        out += asides.sorted { $0.number < $1.number }.map(\.html)
    }

    /// The `id` lands on the FIRST element this node emits — the `<blockquote>`
    /// or `<ul>` container, never its first child — so a link arrives at the top
    /// of what the paragraph produced. Children are emitted with a nil anchor:
    /// one paragraph, one id.
    ///
    /// A report element's own id (its label's, or `fig-n`/`tbl-n`) therefore
    /// never takes the element's `id`: the paragraph anchor keeps it (the
    /// anchor contract) and the report id rides inside — the `<img>`, the
    /// `<caption>`, a `<span>` around a heading's text.
    ///
    /// - Parameter index: the node's top-level index in its section, by which
    ///   the resolution numbers it; nil inside a blockquote, where nothing is
    ///   numbered or labelled and a table or figure renders literally.
    private static func emit(prose: ProjectAST.ProseNode, index: Int?, anchor: Anchor?,
                             scope: Scope, into out: inout [String]) {
        switch prose {
        case .paragraph(let inlines):
            out.append("<p\(idAttribute(anchor))>\(emitInline(inlines, scope))</p>")
        case .heading(let level, let headingInlines, let label):
            // Reserve <h1> for the section title; markdown `#` starts at <h2>.
            let tag = "h\(min(level + 1, 6))"
            guard let resolution = scope.resolution else {
                // No resolution: the label prints as the literal `{#kind:name}`
                // it was written as.
                let inlines = headingInlines + InterimReportLiteral.labelSuffix(label)
                out.append("<\(tag)\(idAttribute(anchor))>\(emitInline(inlines, scope))</\(tag)>")
                return
            }
            let number = index.flatMap { resolution.headingNumbers[scope.pieceID]?[$0] }
            var content = (number.map { "<span class=\"section-number\">\($0)</span> " } ?? "")
                + emitInline(headingInlines, scope)
            if let index, let owned = scope.ownedHeadingLabel(label, index: index,
                                                              text: number.map { "Section \($0)" }) {
                content = "<span id=\"\(XHTMLEscape.attribute(labelID(owned, tag: scope.idTag)))\">\(content)</span>"
            }
            out.append("<\(tag)\(idAttribute(anchor))>\(content)</\(tag)>")
        case .blockquote(let nodes):
            out.append("<blockquote\(idAttribute(anchor))>")
            for n in nodes { emit(prose: n, index: nil, anchor: nil, scope: scope, into: &out) }
            out.append("</blockquote>")
        case .sceneBreak:
            out.append("<hr class=\"scene-break\"\(idAttribute(anchor))/>")
        case .list(let ordered, let items):
            let tag = ordered ? "ol" : "ul"
            out.append("<\(tag)\(idAttribute(anchor))>")
            for item in items {
                out.append("<li>\(emitInline(item, scope))</li>")
            }
            out.append("</\(tag)>")
        case .verbatim(let lines):
            let joined = lines.map(XHTMLEscape.escape).joined(separator: "<br/>")
            out.append("<p class=\"verbatim\"\(idAttribute(anchor))>\(joined)</p>")
        case .table(let header, let alignments, let rows, let caption, let label):
            guard let index, let resolution = scope.resolution,
                  let n = resolution.tableNumbers[scope.pieceID]?[index] else {
                // No resolution, or not a top-level table: its literal source.
                emit(prose: .paragraph(InterimReportLiteral.table(
                    header: header, alignments: alignments, rows: rows,
                    caption: caption, label: label)), index: nil, anchor: anchor, scope: scope, into: &out)
                return
            }
            emitTable(number: n, address: scope.address(.tbl, number: n, index: index, resolution: resolution),
                      header: header, alignments: alignments, rows: rows, caption: caption ?? [],
                      anchor: anchor, scope: scope, into: &out)
        case .figure(let caption, let path, let label):
            let literal = InterimReportLiteral.figure(caption: caption, path: path, label: label)
            guard let index, let resolution = scope.resolution,
                  let n = resolution.figureNumbers[scope.pieceID]?[index] else {
                emit(prose: .paragraph(literal), index: nil, anchor: anchor, scope: scope, into: &out)
                return
            }
            let address = scope.address(.fig, number: n, index: index, resolution: resolution)
            guard let file = scope.figureFiles[index] else {
                // An image that was refused or never packaged: its literal
                // source, still carrying the figure's id so a cross-reference
                // or a list entry lands on it.
                out.append("<p\(idAttribute(anchor))><span id=\"\(XHTMLEscape.attribute(address))\">"
                           + emitInline(literal, scope) + "</span></p>")
                return
            }
            let alt = plainText(caption, resolution: resolution, pieceID: scope.pieceID)
            out.append("<figure\(idAttribute(anchor))>")
            out.append("<img id=\"\(XHTMLEscape.attribute(address))\" src=\"\(XHTMLEscape.attribute(file))\""
                       + " alt=\"\(XHTMLEscape.attribute(alt.isEmpty ? "Figure \(n)" : alt))\"/>")
            out.append("<figcaption>\(captionHTML("Figure", number: n, caption, scope))</figcaption>")
            out.append("</figure>")
        }
    }

    /// R-S9: "Table n." / "Figure n." always prints, captioned or not, so a
    /// reference always lands on a visible number. The number is a span a
    /// stylesheet can set apart.
    private static func captionHTML(_ word: String, number: Int, _ caption: [ProjectAST.Inline],
                                    _ scope: Scope) -> String {
        let text = emitInline(caption, scope)
        return "<span class=\"caption-number\">\(word) \(number).</span>" + (text.isEmpty ? "" : " " + text)
    }

    /// `<table>` with its numbered `<caption>` (which carries the table's own
    /// id), a `<thead>` from the header row and a `<tbody>`. Every row has the
    /// header's column count: a short row is padded, a long one cut, as the
    /// PDF's are. An aligned column's cells say so in `style`.
    private static func emitTable(number: Int, address: String, header: [[ProjectAST.Inline]],
                                  alignments: [TableAlignment], rows: [[[ProjectAST.Inline]]],
                                  caption: [ProjectAST.Inline], anchor: Anchor?,
                                  scope: Scope, into out: inout [String]) {
        let columns = max(header.count, 1)
        func style(_ column: Int) -> String {
            guard column < alignments.count else { return "" }
            switch alignments[column] {
            case .none:     return ""
            case .leading:  return " style=\"text-align:left\""
            case .center:   return " style=\"text-align:center\""
            case .trailing: return " style=\"text-align:right\""
            }
        }
        func row(_ cells: [[ProjectAST.Inline]], _ cell: String) -> String {
            "<tr>" + (0..<columns).map { column in
                "<\(cell)\(style(column))>"
                    + (column < cells.count ? emitInline(cells[column], scope) : "") + "</\(cell)>"
            }.joined() + "</tr>"
        }
        out.append("<table\(idAttribute(anchor))>")
        out.append("<caption id=\"\(XHTMLEscape.attribute(address))\">"
                   + captionHTML("Table", number: number, caption, scope) + "</caption>")
        out.append("<thead>")
        out.append(row(header, "th"))
        out.append("</thead>")
        out.append("<tbody>")
        for r in rows { out.append(row(r, "td")) }
        out.append("</tbody>")
        out.append("</table>")
    }

    /// Render a run of inline nodes into a single XHTML string.
    private static func emitInline(_ inlines: [ProjectAST.Inline], _ scope: Scope) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s):      return XHTMLEscape.escape(s)
            case .emphasis(let xs): return "<em>\(emitInline(xs, scope))</em>"
            case .strong(let xs):   return "<strong>\(emitInline(xs, scope))</strong>"
            case .strikethrough(let xs): return "<s>\(emitInline(xs, scope))</s>"
            case .underline(let xs): return "<u>\(emitInline(xs, scope))</u>"
            case .code(let s):      return "<code>\(XHTMLEscape.escape(s))</code>"
            case .wikiLink(let target, let display):
                return "<span class=\"wiki-link\" data-target=\"\(XHTMLEscape.attribute(target))\">"
                    + XHTMLEscape.escape(display) + "</span>"
            case .lineBreak:        return "<br/>"
            case .footnoteRef(let label): return noteref(label, scope)
            case .citation(let items):
                return XHTMLEscape.escape(scope.resolution?.citationText[PublishResolution.citationKey(items)]
                                          ?? InterimReportLiteral.citation(items))
            case .crossRef(let label):
                guard let target = scope.resolution?.targets[label] else {
                    return XHTMLEscape.escape(InterimReportLiteral.crossRef(label))
                }
                guard let href = scope.labelHrefs[label] else { return XHTMLEscape.escape(target.text) }
                return "<a href=\"\(XHTMLEscape.attribute(href))\">\(XHTMLEscape.escape(target.text))</a>"
            }
        }.joined()
    }

    /// R-S2/R-S8: `<sup><a epub:type="noteref" href="#fn-n" id="fnref-n">n</a></sup>`
    /// — the `epub:type` is what makes a reading system pop the note up, the
    /// `<sup>` what makes it read as a note mark in one that doesn't. The
    /// number is the resolution's, continuous across the book. A later
    /// reference to the same note links to the same aside without a second
    /// `fnref` id. No number (no definition) → the literal `[^label]`.
    private static func noteref(_ label: String, _ scope: Scope) -> String {
        guard let n = scope.resolution?.footnoteNumbers[scope.pieceID]?[label],
              scope.section.footnotes[label] != nil else {
            return XHTMLEscape.escape(InterimReportLiteral.footnoteRef(label))
        }
        let first = !scope.notes.contains(label)
        if first { scope.notes.append(label) }
        let refID = first ? " id=\"\(scope.footnoteRefID(n))\"" : ""
        return "<sup><a epub:type=\"noteref\" href=\"#\(scope.footnoteID(n))\"\(refID)>\(n)</a></sup>"
    }

    /// Inline runs as plain, UNESCAPED text — an `alt`, a list entry. A
    /// numbered footnote drops out; a citation or cross-reference reads as it
    /// does in the text; anything unresolved as its literal source.
    static func plainText(_ inlines: [ProjectAST.Inline], resolution: PublishResolution?,
                          pieceID: String) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s), .code(let s): return s
            case .emphasis(let xs), .strong(let xs), .strikethrough(let xs), .underline(let xs):
                return plainText(xs, resolution: resolution, pieceID: pieceID)
            case .wikiLink(_, let display): return display
            case .lineBreak: return " "
            case .footnoteRef(let label):
                return resolution?.footnoteNumbers[pieceID]?[label] != nil
                    ? "" : InterimReportLiteral.footnoteRef(label)
            case .citation(let items):
                return resolution?.citationText[PublishResolution.citationKey(items)]
                    ?? InterimReportLiteral.citation(items)
            case .crossRef(let label):
                return resolution?.targets[label]?.text ?? InterimReportLiteral.crossRef(label)
            }
        }.joined()
    }

    private static func emit(fountain: ProjectAST.FountainNode, anchor: Anchor?,
                             scope: Scope, into out: inout [String]) {
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
            out.append("<p class=\"action\"\(idAttribute(anchor))>\(emitInline(xs, scope))</p>")
        case .character(let s):
            out.append("<p class=\"character\"\(idAttribute(anchor))>\(XHTMLEscape.escape(s))</p>")
        case .dialogue(let xs):
            out.append("<p class=\"dialogue\"\(idAttribute(anchor))>\(emitInline(xs, scope))</p>")
        case .parenthetical(let xs):
            out.append("<p class=\"parenthetical\"\(idAttribute(anchor))>\(emitInline(xs, scope))</p>")
        case .transition(let s):
            out.append("<p class=\"transition\"\(idAttribute(anchor))>\(XHTMLEscape.escape(s))</p>")
        case .lyric(let xs):
            out.append("<p class=\"lyric\"\(idAttribute(anchor))>\(emitInline(xs, scope))</p>")
        case .centered(let xs):
            out.append("<p class=\"centered\"\(idAttribute(anchor))>\(emitInline(xs, scope))</p>")
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
            for n in left { emit(fountain: n, anchor: nil, scope: scope, into: &out) }
            out.append("</div>")
            out.append("<div class=\"right\">")
            for n in right { emit(fountain: n, anchor: nil, scope: scope, into: &out) }
            out.append("</div>")
            out.append("</div>")
        }
    }
}
