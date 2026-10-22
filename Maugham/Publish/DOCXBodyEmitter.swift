import Foundation
import CoreGraphics
import ImageIO
import MaughamCore

// MARK: - what one body produces

/// One relationship a body's `word/document.xml` needs: today, an image.
struct DOCXRelationship: Equatable, Sendable {
    static let imageType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

    let id: String
    let type: String
    /// Relative to `word/`: `media/<hash>.<ext>`.
    let target: String
}

/// One image the packager puts under `word/media/` (R-S1): the emitter stays
/// pure, so it names the file and the packager copies `source` there. Under
/// R-S3 the compiler's prepare rasterises a PDF or SVG figure to PNG BEFORE
/// emission, so what it hands in is already embeddable and `needsRaster` is
/// false; it is true only for a PDF or SVG handed in as is, which the
/// packager would then have to rasterise to the PNG `name` already says.
struct DOCXMedia: Equatable, Sendable {
    let source: URL
    /// `<content hash>.<ext>`, the name `PDFCompiler`/`EPUBCompiler` stage
    /// under; `.png` for anything rasterised.
    let name: String
    let needsRaster: Bool
}

/// One list's `w:num` in `numbering.xml`: every list has its own, so an
/// ordered list restarts at 1 instead of continuing the one before it.
struct DOCXList: Equatable, Sendable {
    let numID: Int
    let ordered: Bool
}

/// The document's parts, every body in order. `bodyContent` and
/// `footnoteElements` are the fragments; `documentXML`, `footnotesXML` and
/// `numberingXML` are the complete parts.
struct DOCXBody {
    /// The children of `w:body`, without the closing `w:sectPr`.
    var bodyContent: String
    /// The `w:footnote` elements, in id order, without separators.
    var footnoteElements: String
    /// One per distinct image, however many bodies show it.
    var relationships: [DOCXRelationship]
    var media: [DOCXMedia]
    var lists: [DOCXList]
    /// The page the compiler chose (R-S4); the column stays 6 inches on it.
    var page: DOCXPage

    var documentXML: String { DOCXBodyEmitter.documentPart(bodyContent, page: page) }
    var footnotesXML: String { DOCXBodyEmitter.footnotesPart(footnoteElements) }
    var numberingXML: String { DOCXBodyEmitter.numberingPart(lists) }
}

// MARK: - the emitter

/// **The OOXML body emitter** (report plan 4, Task 3): one body's AST and
/// resolution → WordprocessingML, Word's own constructs throughout (spec
/// §6.2). Like `LaTeXBodyEmitter` and `XHTMLBodyEmitter` it walks the AST,
/// reads the resolution and never numbers; a report element it cannot
/// resolve prints its literal source (`InterimReportLiteral`).
///
/// | AST | Word |
/// |---|---|
/// | piece title | `Heading1`, unnumbered; a page break before every piece but the first |
/// | heading | `Heading1`–`3` by depth below the book's shallowest level, the resolution's number first |
/// | paragraph | runs: `w:i`, `w:b`, `w:strike`, `w:u`, `CodeChar` |
/// | blockquote | its paragraphs in `Quote` |
/// | scene break | a centred `* * *` |
/// | list | `w:numPr` to the list's own `w:num` (bullet or decimal abstract) |
/// | verbatim | one `Code` paragraph, lines joined by `w:br` |
/// | table | `Caption` above ("Table " + `SEQ Table`), a native `w:tbl`, its header row repeating |
/// | figure | an inline drawing fitted to the 6-inch column, `Caption` below ("Figure " + `SEQ Figure`) |
/// | footnote | `w:footnoteReference` → `footnotes.xml`, id from `footnoteNumbers`; a repeat prints Word's ordinal |
/// | citation | the resolution's text |
/// | cross-reference | `REF <label bookmark> \h`, result `Target.text` (a numbered section: the word, then the number as the result) |
/// | References | `Heading1` in the body's word, entries in `Bibliography` |
///
/// Every field carries its result, so nothing asks to be updated on open.
/// Every node with a `¶id` gets a bookmark (`DOCXNames.paragraphBookmark`)
/// on its first paragraph, and every labelled element a label bookmark.
/// Lists of figures and tables are not emitted: a Word user inserts Word's own.
enum DOCXBodyEmitter {

    /// The text column the figures and tables fit: 6 inches on every page
    /// (`DOCXPage` centres it).
    static let columnTwips = 8_640
    static let columnEMU = 5_486_400

    /// One body of the document: a language's AST, its own resolution, and
    /// the images prepared for it.
    struct Body {
        let ast: ProjectAST
        /// Over the edition's whole book. Its `words` spell every caption,
        /// target and the References heading.
        let resolution: PublishResolution
        /// nil for the first body; a later body's tag goes into its bookmark
        /// names, so two bodies never share one.
        let bodyTag: String?
        /// pieceID → node index → the image file to embed, as the compiler
        /// prepared it (R-S3: a PDF or SVG figure is already a PNG here, its
        /// refusal already a problem). The drawing's extent is read from THIS
        /// file. A numbered figure without one prints its literal source.
        let figureFiles: [String: [Int: URL]]
    }

    /// The document: every body in order, a page break between two, sharing
    /// one set of counters — bookmark and drawing ids, list ids, footnote ids
    /// and the numbers Word shows for them, the `SEQ` sequences — so the
    /// joined `document.xml` has no duplicate. `config` supplies
    /// `sections[piece].titleOverride`; `page` is the compiler's (R-S4).
    static func emit(bodies: [Body], config: PublishConfig, page: DOCXPage) -> DOCXBody {
        var state = State()
        var content: [String] = []
        var notes = ""
        var relationships: [DOCXRelationship] = []
        var media: [DOCXMedia] = []
        var lists: [DOCXList] = []
        for (i, body) in bodies.enumerated() {
            let scope = emit(body, config: config, state: state)
            if i > 0 { content.append("<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>") }
            content.append(scope.out.joined())
            notes += scope.footnotes.sorted { $0.key < $1.key }.map(\.value).joined()
            for r in scope.relationships where !relationships.contains(where: { $0.id == r.id }) {
                relationships.append(r)
            }
            for m in scope.media where !media.contains(where: { $0.name == m.name }) { media.append(m) }
            lists += scope.lists
            state = scope.state
            state.footnoteIDBase += body.resolution.footnoteNumbers.values.flatMap(\.values).max() ?? 0
        }
        return DOCXBody(bodyContent: content.joined(), footnoteElements: notes,
                        relationships: relationships, media: media, lists: lists, page: page)
    }

    /// The counters the bodies of one document share.
    fileprivate struct State {
        var nextBookmarkID = 0
        var nextDrawingID = 1
        var nextNumID = 1
        /// Added to a body's footnote numbers to make a `w:id`: 0 for the
        /// first body, so its ids ARE `footnoteNumbers`.
        var footnoteIDBase = 0
        /// How many footnote references the document has emitted: Word
        /// numbers notes by the order of their references, so this is the
        /// number Word shows, and a repeat reference prints it.
        var footnoteOrdinal = 0
        /// The last `SEQ` result per identifier, document-wide: a caption
        /// whose number isn't the next one says so with `\r`.
        var lastSequence: [String: Int] = [:]
        /// Every bookmark name used so far, lowercased (`uniqueName`).
        var bookmarkNames: Set<String> = []
    }

    private static func emit(_ body: Body, config: PublishConfig, state: State) -> Scope {
        let ast = body.ast
        let resolution = body.resolution
        let bodyTag = body.bodyTag
        let scope = Scope(resolution: resolution, figureFiles: body.figureFiles, state: state,
                          headingBase: headingBase(ast))
        // Label bookmarks are named before anything is written, so a
        // reference ahead of its target names the same bookmark.
        for section in ast.sections {
            for (index, node) in section.nodes.enumerated() {
                guard let label = ownedLabel(node, index: index, section: section,
                                             resolution: resolution) else { continue }
                scope.labelNames[label] = scope.uniqueName(DOCXNames.labelBookmark(label, bodyTag: bodyTag))
                // A numbered section's bookmark wraps its number alone, so a
                // REF to it is the word as text and the number as the field's
                // result: what Word reads back if the field is updated.
                if label.kind == .sec, let number = resolution.headingNumbers[section.pieceID]?[index] {
                    scope.labelShown[label] = (resolution.words.section + " ", number)
                }
            }
        }
        var out: [String] = []
        for (i, section) in ast.sections.enumerated() {
            scope.section = section
            let title = config.sections[section.pieceID]?.titleOverride ?? section.title
            out.append(scope.paragraph(Para(style: "Heading1", pageBreakBefore: i > 0),
                                       scope.textRun(title, Run())))
            for (index, node) in section.nodes.enumerated() {
                if let id = section.nodeParagraphs[index] {
                    scope.pending.append(scope.bookmark(DOCXNames.paragraphBookmark(id, bodyTag: bodyTag)))
                }
                emit(node: node, index: index, scope: scope, into: &out)
                if !scope.pending.isEmpty { out.append(scope.paragraph(Para(), "")) }
            }
        }
        if !resolution.references.isEmpty {
            out.append(scope.paragraph(Para(style: "Heading1"),
                                       scope.textRun(resolution.words.references, Run())))
            for entry in resolution.references {
                out.append(scope.paragraph(Para(style: "Bibliography"), entry.map {
                    scope.textRun($0.text, Run(italic: $0.italic))
                }.joined()))
            }
        }
        scope.out = out
        return scope
    }

    // MARK: - parts

    static let namespaces = [
        "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"",
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"",
        "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"",
        "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"",
        "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"",
    ].joined(separator: " ")

    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    /// `word/document.xml` around `content` on `page`: 1-inch top and bottom,
    /// and side margins that leave the 6-inch column the figures fit.
    static func documentPart(_ content: String, page: DOCXPage) -> String {
        let side = page.sideMarginTwips
        return declaration + "<w:document \(namespaces)><w:body>" + content
            + "<w:sectPr><w:pgSz w:w=\"\(page.widthTwips)\" w:h=\"\(page.heightTwips)\"/>"
            + "<w:pgMar w:top=\"1440\" w:right=\"\(side)\" w:bottom=\"1440\" w:left=\"\(side)\""
            + " w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
            + "</w:body></w:document>"
    }

    /// `word/footnotes.xml` around `notes`: the separator (-1) and the
    /// continuation separator (0) Word itself writes, which `settings.xml`'s
    /// `w:footnotePr` names.
    static func footnotesPart(_ notes: String) -> String {
        declaration + "<w:footnotes \(namespaces)>"
            + "<w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>"
            + "<w:footnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>"
            + notes + "</w:footnotes>"
    }

    /// `word/numbering.xml` for a document's lists: abstract 0 is the bullet,
    /// 1 the decimal; each list's `w:num` points at one, and an ordered one
    /// restarts at 1.
    static func numberingPart(_ lists: [DOCXList]) -> String {
        func abstract(_ id: Int, format: String, text: String) -> String {
            "<w:abstractNum w:abstractNumId=\"\(id)\"><w:multiLevelType w:val=\"singleLevel\"/>"
                + "<w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/>"
                + "<w:lvlText w:val=\"\(OOXMLEscape.attribute(text))\"/><w:lvlJc w:val=\"left\"/>"
                + "<w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum>"
        }
        let nums = lists.map { list in
            "<w:num w:numId=\"\(list.numID)\"><w:abstractNumId w:val=\"\(list.ordered ? 1 : 0)\"/>"
                + (list.ordered ? "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride>" : "")
                + "</w:num>"
        }.joined()
        return declaration + "<w:numbering \(namespaces)>"
            + abstract(0, format: "bullet", text: "\u{2022}") + abstract(1, format: "decimal", text: "%1.")
            + nums + "</w:numbering>"
    }

    // MARK: - labels and headings

    /// The book's shallowest heading level — the resolution numbers from it,
    /// so it is `Heading1` here.
    private static func headingBase(_ ast: ProjectAST) -> Int {
        ast.sections.flatMap(\.nodes).compactMap { node -> Int? in
            guard case .prose(.heading(let level, _, _)) = node else { return nil }
            return level
        }.min() ?? 1
    }

    /// The label a top-level node OWNS: the resolution gave this very element
    /// the label (right kind, same piece and paragraph, same text) — the
    /// LaTeX and XHTML emitters' rule. A duplicate or a wrong-kind label owns
    /// nothing, so it gets no bookmark and nothing refers to it.
    private static func ownedLabel(_ node: ProjectAST.Node, index: Int, section: ProjectAST.Section,
                                   resolution: PublishResolution) -> ManuscriptLabel? {
        func owns(_ label: ManuscriptLabel?, _ kind: ManuscriptLabel.Kind, text: String?) -> ManuscriptLabel? {
            guard let label, label.kind == kind, let target = resolution.targets[label],
                  target.pieceID == section.pieceID,
                  target.paragraphID == section.nodeParagraphs[index],
                  text == nil || target.text == text else { return nil }
            return label
        }
        let piece = section.pieceID
        switch node {
        case .fountain:
            return nil
        case .prose(let prose):
            switch prose {
            case .heading(_, _, let label):
                let number = resolution.headingNumbers[piece]?[index]
                return owns(label, .sec, text: number.map { "\(resolution.words.section) \($0)" })
            case .table(_, _, _, _, let label):
                guard let n = resolution.tableNumbers[piece]?[index] else { return nil }
                return owns(label, .tbl, text: "\(resolution.words.table) \(n)")
            case .figure(_, _, let label):
                guard let n = resolution.figureNumbers[piece]?[index] else { return nil }
                return owns(label, .fig, text: "\(resolution.words.figure) \(n)")
            case .paragraph, .blockquote, .sceneBreak, .list, .verbatim:
                return nil
            }
        }
    }

    // MARK: - nodes

    private static func emit(node: ProjectAST.Node, index: Int, scope: Scope, into out: inout [String]) {
        switch node {
        case .prose(let p):    emit(prose: p, index: index, quoted: false, scope: scope, into: &out)
        case .fountain(let f): emit(fountain: f, scope: scope, into: &out)
        }
    }

    /// - Parameter index: the node's top-level index, by which the resolution
    ///   numbers it; nil inside a blockquote, where nothing is numbered or
    ///   labelled and a table or figure prints literally.
    private static func emit(prose: ProjectAST.ProseNode, index: Int?, quoted: Bool,
                             scope: Scope, into out: inout [String]) {
        let resolution = scope.resolution
        let piece = scope.pieceID
        let body = quoted ? "Quote" : nil
        func literal(_ inlines: [ProjectAST.Inline], label: ManuscriptLabel? = nil) {
            out.append(scope.paragraph(Para(style: body), scope.labelled(label, scope.runs(inlines, Run()))))
        }
        switch prose {
        case .paragraph(let inlines):
            out.append(scope.paragraph(Para(style: body), scope.runs(inlines, Run())))
        case .heading(let level, let inlines, let label):
            let depth = min(max(level - scope.headingBase + 1, 1), 3)
            let number = index.flatMap { resolution.headingNumbers[piece]?[$0] }
            let owned = index.flatMap { scope.owned(label, kind: .sec, index: $0) }
            let text = scope.runs(inlines, Run())
            let runs = number.map { scope.labelled(owned, scope.textRun($0, Run())) + scope.textRun(" ", Run()) + text }
                ?? scope.labelled(owned, text)
            out.append(scope.paragraph(Para(style: "Heading\(depth)"), runs))
        case .blockquote(let nodes):
            for n in nodes { emit(prose: n, index: nil, quoted: true, scope: scope, into: &out) }
        case .sceneBreak:
            out.append(scope.paragraph(Para(style: body, jc: "center"), scope.textRun("* * *", Run())))
        case .list(let ordered, let items):
            guard !items.isEmpty else { return }
            let numID = scope.state.nextNumID
            scope.state.nextNumID += 1
            scope.lists.append(DOCXList(numID: numID, ordered: ordered))
            for item in items {
                out.append(scope.paragraph(Para(style: body, numID: numID), scope.runs(item, Run())))
            }
        case .verbatim(let lines):
            let runs = lines.map { scope.textRun($0, Run()) }.joined(separator: "<w:r><w:br/></w:r>")
            out.append(scope.paragraph(Para(style: "Code"), runs))
        case .table(let header, let alignments, let rows, let caption, let label):
            guard let index, let n = resolution.tableNumbers[piece]?[index] else {
                return literal(InterimReportLiteral.table(header: header, alignments: alignments, rows: rows,
                                                          caption: caption, label: label))
            }
            out.append(scope.paragraph(Para(style: "Caption", keepNext: true),
                                       scope.caption("Table", word: resolution.words.table, number: n,
                                                     label: scope.owned(label, kind: .tbl, index: index),
                                                     caption ?? [])))
            out.append(table(header: header, alignments: alignments, rows: rows, scope: scope))
        case .figure(let caption, let path, let label):
            let source = InterimReportLiteral.figure(caption: caption, path: path, label: label)
            guard let index, let n = resolution.figureNumbers[piece]?[index] else { return literal(source) }
            let owned = scope.owned(label, kind: .fig, index: index)
            guard let url = scope.figureFiles[piece]?[index], let image = scope.place(url) else {
                // Refused or never prepared: its literal source, still carrying
                // the label bookmark, so a cross-reference lands on it. The REF
                // keeps its precomputed "Figure n"; only a field update in Word
                // would read the literal the bookmark wraps — and a Report with
                // a refused image never gets past the gate to export.
                return literal(source, label: owned)
            }
            let alt = XHTMLBodyEmitter.plainText(caption, resolution: resolution, pieceID: piece)
            out.append(scope.paragraph(Para(style: body, keepNext: true, jc: "center"),
                                       scope.drawing(image, name: "\(resolution.words.figure) \(n)",
                                                     description: alt)))
            out.append(scope.paragraph(Para(style: "Caption"),
                                       scope.caption("Figure", word: resolution.words.figure, number: n,
                                                     label: owned, caption)))
        }
    }

    /// A native table: the grid has the header's column count, a short row is
    /// padded and a long one cut, as the PDF's are; the header row repeats on
    /// every page; an aligned column's cells say so in `w:jc`.
    private static func table(header: [[ProjectAST.Inline]], alignments: [TableAlignment],
                              rows: [[[ProjectAST.Inline]]], scope: Scope) -> String {
        let columns = max(header.count, 1)
        let width = columnTwips / columns
        func jc(_ column: Int) -> String? {
            guard column < alignments.count else { return nil }
            switch alignments[column] {
            case .none:     return nil
            case .leading:  return "left"
            case .center:   return "center"
            case .trailing: return "right"
            }
        }
        func row(_ cells: [[ProjectAST.Inline]], isHeader: Bool) -> String {
            "<w:tr>" + (isHeader ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
                + (0..<columns).map { column in
                    let inlines = column < cells.count ? cells[column] : []
                    return "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr>"
                        + scope.paragraph(Para(jc: jc(column)), scope.runs(inlines, Run(bold: isHeader)))
                        + "</w:tc>"
                }.joined() + "</w:tr>"
        }
        let border = ["top", "left", "bottom", "right", "insideH", "insideV"].map {
            "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
        }.joined()
        return "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/>"
            + "<w:tblBorders>\(border)</w:tblBorders><w:tblLook w:val=\"04A0\"/></w:tblPr>"
            + "<w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
            + row(header, isHeader: true) + rows.map { row($0, isHeader: false) }.joined()
            + "</w:tbl>"
    }

    /// A screenplay piece in a Word document: Normal paragraphs laid out by
    /// direct formatting (indents, alignment), since the built-in styles
    /// carry no screenplay set.
    private static func emit(fountain: ProjectAST.FountainNode, scope: Scope, into out: inout [String]) {
        func para(_ p: Para, _ runs: String) { out.append(scope.paragraph(p, runs)) }
        switch fountain {
        case .sceneHeading(let s, let number):
            para(Para(keepNext: true), scope.textRun(s + (number.map { "  #\($0)#" } ?? ""), Run(bold: true)))
        case .action(let xs):
            para(Para(), scope.runs(xs, Run()))
        case .character(let s):
            para(Para(keepNext: true, indLeft: 2880), scope.textRun(s, Run()))
        case .dialogue(let xs):
            para(Para(indLeft: 1440, indRight: 1440), scope.runs(xs, Run()))
        case .parenthetical(let xs):
            para(Para(keepNext: true, indLeft: 2160, indRight: 2160), scope.runs(xs, Run()))
        case .transition(let s):
            para(Para(jc: "right"), scope.textRun(s, Run()))
        case .lyric(let xs):
            para(Para(indLeft: 1440, indRight: 1440), scope.runs(xs, Run(italic: true)))
        case .centered(let xs):
            para(Para(jc: "center"), scope.runs(xs, Run()))
        case .pageBreak:
            para(Para(), "<w:r><w:br w:type=\"page\"/></w:r>")
        case .titlePage(let fields):
            for field in fields {
                para(Para(jc: "center"), scope.textRun(field.value, Run(bold: field.key == "Title")))
            }
        case .dualDialogue(let left, let right):
            for n in left + right { emit(fountain: n, scope: scope, into: &out) }
        }
    }

    // MARK: - properties, in the schema's order

    /// A paragraph's `w:pPr`, written in CT_PPr's sequence — `pStyle`,
    /// `keepNext`, `pageBreakBefore`, `numPr`, `ind`, `jc` — since Word
    /// refuses misordered children.
    fileprivate struct Para {
        var style: String? = nil
        var keepNext = false
        var pageBreakBefore = false
        var numID: Int? = nil
        var indLeft: Int? = nil
        var indRight: Int? = nil
        var jc: String? = nil

        var xml: String {
            var s = ""
            if let style { s += "<w:pStyle w:val=\"\(OOXMLEscape.attribute(style))\"/>" }
            if keepNext { s += "<w:keepNext/>" }
            if pageBreakBefore { s += "<w:pageBreakBefore/>" }
            if let numID { s += "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(numID)\"/></w:numPr>" }
            if indLeft != nil || indRight != nil {
                s += "<w:ind" + (indLeft.map { " w:left=\"\($0)\"" } ?? "")
                    + (indRight.map { " w:right=\"\($0)\"" } ?? "") + "/>"
            }
            if let jc { s += "<w:jc w:val=\"\(jc)\"/>" }
            return s.isEmpty ? "" : "<w:pPr>\(s)</w:pPr>"
        }
    }

    /// A run's `w:rPr`, in CT_RPr's sequence — `rStyle`, `b`, `i`, `strike`,
    /// `u`, `vertAlign`. Inline nesting adds to it: `**_x_**` is bold and
    /// underlined.
    fileprivate struct Run {
        var style: String? = nil
        var bold = false
        var italic = false
        var strike = false
        var underline = false
        var superscript = false

        var xml: String {
            var s = ""
            if let style { s += "<w:rStyle w:val=\"\(OOXMLEscape.attribute(style))\"/>" }
            if bold { s += "<w:b/>" }
            if italic { s += "<w:i/>" }
            if strike { s += "<w:strike/>" }
            if underline { s += "<w:u w:val=\"single\"/>" }
            if superscript { s += "<w:vertAlign w:val=\"superscript\"/>" }
            return s.isEmpty ? "" : "<w:rPr>\(s)</w:rPr>"
        }
    }

    // MARK: - the body's scope

    /// What one body's walk reads and appends to: the resolution, the counters
    /// it continues, the bookmarks owed to the next paragraph, the notes, the
    /// images and the lists. A class because the inline walk appends at every
    /// depth.
    private final class Scope {
        let resolution: PublishResolution
        let figureFiles: [String: [Int: URL]]
        let headingBase: Int
        var state: State
        var section: ProjectAST.Section?
        /// The body's paragraphs and tables, once the walk is done.
        var out: [String] = []
        /// Owned label → its bookmark name, named before the walk.
        var labelNames: [ManuscriptLabel: String] = [:]
        /// A label whose bookmark wraps less than its target's text: the
        /// text before the REF, and the REF's result (a numbered section).
        var labelShown: [ManuscriptLabel: (prefix: String, result: String)] = [:]
        /// The `¶id` bookmarks the node being emitted owes its FIRST paragraph.
        var pending: [(id: Int, name: String)] = []
        /// Footnote number → its `w:footnote` element.
        var footnotes: [Int: String] = [:]
        /// Note number → the number Word shows for it, the ordinal of its
        /// one `w:footnoteReference`.
        var shown: [Int: Int] = [:]
        /// The notes being written or printed in place, innermost last.
        var writing: Set<Int> = []
        var relationships: [DOCXRelationship] = []
        var media: [DOCXMedia] = []
        var lists: [DOCXList] = []
        /// File → what `place` answered, so an image used twice is read once.
        private var placed: [URL: Image] = [:]

        init(resolution: PublishResolution, figureFiles: [String: [Int: URL]],
             state: State, headingBase: Int) {
            self.resolution = resolution
            self.figureFiles = figureFiles
            self.state = state
            self.headingBase = headingBase
        }

        var pieceID: String { section?.pieceID ?? "" }

        // MARK: bookmarks

        /// `base`, or `base` with the first counter that makes it unused in
        /// the document; recorded as used. Compared case-insensitively, as
        /// Word compares bookmark names: `l_fig_Chart` and `l_fig_chart` are
        /// one bookmark to Word, so the second takes a counter (M4).
        func uniqueName(_ base: String) -> String {
            var name = base
            var counter = 2
            while state.bookmarkNames.contains(name.lowercased()) {
                name = DOCXNames.disambiguated(base, counter: counter)
                counter += 1
            }
            state.bookmarkNames.insert(name.lowercased())
            return name
        }

        func bookmark(_ base: String) -> (id: Int, name: String) {
            let id = state.nextBookmarkID
            state.nextBookmarkID += 1
            return (id, uniqueName(base))
        }

        func owned(_ label: ManuscriptLabel?, kind: ManuscriptLabel.Kind, index: Int) -> ManuscriptLabel? {
            guard let label, label.kind == kind, labelNames[label] != nil,
                  resolution.targets[label]?.pieceID == pieceID,
                  resolution.targets[label]?.paragraphID == section?.nodeParagraphs[index] else { return nil }
            return label
        }

        /// `runs` wrapped in the label's bookmark — what a REF's result
        /// would read if Word updated it.
        func labelled(_ label: ManuscriptLabel?, _ runs: String) -> String {
            guard let label, let name = labelNames[label] else { return runs }
            let id = state.nextBookmarkID
            state.nextBookmarkID += 1
            return "<w:bookmarkStart w:id=\"\(id)\" w:name=\"\(OOXMLEscape.attribute(name))\"/>"
                + runs + "<w:bookmarkEnd w:id=\"\(id)\"/>"
        }

        /// A body paragraph. The first one a node writes takes the node's
        /// `¶id` bookmarks, opened after its properties and closed at its end.
        func paragraph(_ props: Para, _ runs: String) -> String {
            let marks = pending
            pending = []
            return "<w:p>" + props.xml
                + marks.map { "<w:bookmarkStart w:id=\"\($0.id)\" w:name=\"\(OOXMLEscape.attribute($0.name))\"/>" }.joined()
                + runs
                + marks.map { "<w:bookmarkEnd w:id=\"\($0.id)\"/>" }.joined()
                + "</w:p>"
        }

        // MARK: runs

        /// Text as runs: a tab is `w:tab`, a newline `w:br`, a carriage
        /// return nothing; everything else is escaped into `w:t`.
        func textRun(_ text: String, _ run: Run) -> String {
            guard !text.isEmpty else { return "" }
            var content = ""
            var chunk = ""
            func flush() {
                if !chunk.isEmpty { content += "<w:t xml:space=\"preserve\">\(OOXMLEscape.text(chunk))</w:t>" }
                chunk = ""
            }
            for ch in text {
                switch ch {
                case "\t":         flush(); content += "<w:tab/>"
                case "\n", "\r\n": flush(); content += "<w:br/>"
                case "\r":         continue
                default:           chunk.append(ch)
                }
            }
            flush()
            return content.isEmpty ? "" : "<w:r>\(run.xml)\(content)</w:r>"
        }

        func runs(_ inlines: [ProjectAST.Inline], _ run: Run) -> String {
            inlines.map { inline -> String in
                switch inline {
                case .text(let s):
                    return textRun(s, run)
                case .emphasis(let xs):
                    var r = run; r.italic = true; return runs(xs, r)
                case .strong(let xs):
                    var r = run; r.bold = true; return runs(xs, r)
                case .strikethrough(let xs):
                    var r = run; r.strike = true; return runs(xs, r)
                case .underline(let xs):
                    var r = run; r.underline = true; return runs(xs, r)
                case .code(let s):
                    var r = run; r.style = "CodeChar"; return textRun(s, r)
                case .wikiLink(_, let display):
                    return textRun(display, run)
                case .lineBreak:
                    return "<w:r><w:br/></w:r>"
                case .footnoteRef(let label):
                    return noteReference(label, run)
                case .citation(let items):
                    return textRun(resolution.citationText[PublishResolution.citationKey(items)]
                                   ?? InterimReportLiteral.citation(items), run)
                case .crossRef(let label):
                    guard let target = resolution.targets[label] else {
                        return textRun(InterimReportLiteral.crossRef(label), run)
                    }
                    // A target this body bookmarks nowhere reads as its text.
                    guard let name = labelNames[label] else { return textRun(target.text, run) }
                    let shown = labelShown[label] ?? ("", target.text)
                    return textRun(shown.prefix, run)
                        + field("REF \(name) \\h", result: textRun(shown.result, run), run)
                }
            }.joined()
        }

        /// A complex field with its result already in place: Word shows the
        /// result as written and recomputes it only when asked.
        func field(_ instruction: String, result: String, _ run: Run) -> String {
            "<w:r>\(run.xml)<w:fldChar w:fldCharType=\"begin\"/></w:r>"
                + "<w:r>\(run.xml)<w:instrText xml:space=\"preserve\"> \(OOXMLEscape.text(instruction)) </w:instrText></w:r>"
                + "<w:r>\(run.xml)<w:fldChar w:fldCharType=\"separate\"/></w:r>"
                + result
                + "<w:r>\(run.xml)<w:fldChar w:fldCharType=\"end\"/></w:r>"
        }

        /// "Figure 1. Caption": the word and a `SEQ` field (the label bookmark
        /// around both, as Word's own captions are bookmarked), then the
        /// caption. The SEQ identifier is fixed — Word's caption feature keys
        /// on it — while the word is the body's own.
        func caption(_ sequence: String, word: String, number: Int, label: ManuscriptLabel?,
                     _ caption: [ProjectAST.Inline]) -> String {
            // Word numbers a SEQ field by counting; only a number that isn't
            // the next one (a gap the edition excludes, a later body) is reset.
            let reset = number == (state.lastSequence[sequence] ?? 0) + 1 ? "" : " \\r \(number)"
            state.lastSequence[sequence] = number
            let numbered = textRun(word + " ", Run())
                + field("SEQ \(sequence) \\* ARABIC" + reset, result: textRun("\(number)", Run()), Run())
            let text = runs(caption, Run())
            return labelled(label, numbered) + textRun(".", Run()) + (text.isEmpty ? "" : textRun(" ", Run()) + text)
        }

        // MARK: footnotes

        /// The first reference to a note is Word's footnote reference, its id
        /// the resolution's number (plus the body's base). Word shows a note
        /// the ordinal of its reference, so a later reference prints THAT
        /// number, never the resolution's — a caption's note, emitted above
        /// its table, can come before notes the resolution counted first.
        /// Word gives a note no note of its own: a note referenced only from
        /// inside another is printed in place, without a numeral, as
        /// " (— its text)"; a later reference from the text still makes it a
        /// footnote.
        func noteReference(_ label: String, _ run: Run) -> String {
            guard let section, let n = resolution.footnoteNumbers[section.pieceID]?[label],
                  let definition = section.footnotes[label] else {
                return textRun(InterimReportLiteral.footnoteRef(label), run)
            }
            var mark = run
            mark.style = "FootnoteReference"
            mark.superscript = true
            if let ordinal = shown[n] { return textRun("\(ordinal)", mark) }
            if !writing.isEmpty {
                // A note that cites itself, however deep, prints nothing more.
                guard !writing.contains(n) else { return "" }
                writing.insert(n)
                defer { writing.remove(n) }
                return textRun(" (\u{2014} ", run) + runs(definition, run) + textRun(")", run)
            }
            state.footnoteOrdinal += 1
            shown[n] = state.footnoteOrdinal
            let id = state.footnoteIDBase + n
            footnotes[n] = note(id: id, number: n, definition)
            return "<w:r>\(mark.xml)<w:footnoteReference w:id=\"\(id)\"/></w:r>"
        }

        private func note(id: Int, number: Int, _ definition: [ProjectAST.Inline]) -> String {
            writing.insert(number)
            defer { writing.remove(number) }
            return "<w:footnote w:id=\"\(id)\"><w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr>"
                + "<w:r>\(Run(style: "FootnoteReference", superscript: true).xml)<w:footnoteRef/></w:r>"
                + textRun(" ", Run()) + runs(definition, Run()) + "</w:p></w:footnote>"
        }

        // MARK: images

        struct Image {
            let relationship: String
            let file: String
            let cx: Int
            let cy: Int
        }

        /// The image's relationship, staged name and size, registering its
        /// media once; nil when it can't be read to be named.
        func place(_ url: URL) -> Image? {
            if let known = placed[url] { return known }
            guard let hash = try? FigureImageResolver.contentHash(of: url) else { return nil }
            let ext = url.pathExtension.lowercased()
            let needsRaster = DOCXImageGeometry.rasterised.contains(ext)
            // The relationship id is the hash alone, so one name per hash:
            // the same bytes as `.jpeg` and `.jpg` are one file, never two
            // media under one id.
            let name = hash + "." + (needsRaster ? "png" : ext == "jpeg" ? "jpg" : ext)
            let relationship = "rIdImg" + hash
            if !media.contains(where: { $0.name == name }) {
                media.append(DOCXMedia(source: url, name: name, needsRaster: needsRaster))
                relationships.append(DOCXRelationship(id: relationship, type: DOCXRelationship.imageType,
                                                      target: "media/" + name))
            }
            let (cx, cy) = DOCXImageGeometry.extent(of: url)
            let image = Image(relationship: relationship, file: name, cx: cx, cy: cy)
            placed[url] = image
            return image
        }

        /// An inline picture: `wp:inline`, its `docPr` id unique in the document.
        func drawing(_ image: Image, name: String, description: String) -> String {
            let id = state.nextDrawingID
            state.nextDrawingID += 1
            return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
                + "<wp:extent cx=\"\(image.cx)\" cy=\"\(image.cy)\"/>"
                + "<wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
                + "<wp:docPr id=\"\(id)\" name=\"\(OOXMLEscape.attribute(name))\" descr=\"\(OOXMLEscape.attribute(description))\"/>"
                + "<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
                + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
                + "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"0\" name=\"\(OOXMLEscape.attribute(image.file))\"/><pic:cNvPicPr/></pic:nvPicPr>"
                + "<pic:blipFill><a:blip r:embed=\"\(image.relationship)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
                + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(image.cx)\" cy=\"\(image.cy)\"/></a:xfrm>"
                + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>"
                + "</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
        }
    }
}

// MARK: - the page

/// The paper a Word document is set on (R-S4). The compiler chooses it
/// (`DOCXCompiler.page(forLanguage:)`); the text column stays 6 inches
/// (`DOCXBodyEmitter.columnTwips`) on either, centred by the side margins.
struct DOCXPage: Equatable, Sendable {
    let widthTwips: Int
    let heightTwips: Int

    static let letter = DOCXPage(widthTwips: 12_240, heightTwips: 15_840)
    static let a4 = DOCXPage(widthTwips: 11_906, heightTwips: 16_838)

    var sideMarginTwips: Int { (widthTwips - DOCXBodyEmitter.columnTwips) / 2 }
}

// MARK: - image geometry

/// How large a figure is drawn: its natural size — pixels over DPI, or a
/// PDF's first page in points — shrunk, never enlarged, to the 6-inch column
/// and an 8-inch height, aspect kept. Read from the file's header; nothing is
/// decoded.
enum DOCXImageGeometry {
    static let emuPerInch = 914_400.0
    /// Word assumes 96 DPI for an image that names none.
    static let defaultDPI = 96.0
    static let maxWidthInches = Double(DOCXBodyEmitter.columnEMU) / emuPerInch
    static let maxHeightInches = 8.0
    /// The size of an image whose size can't be read: the column's width at 4:3.
    static let fallbackInches = (width: 6.0, height: 4.5)
    /// What Word can't embed and the packager rasterises to PNG (R-4-2).
    static let rasterised: Set<String> = ["pdf", "svg"]
    /// The one PDF box a figure is measured and drawn by: the crop box, the
    /// page a viewer shows and the typesetter places (it is the media box
    /// when the PDF names none). `DOCXCompiler.rasterise` renders this box.
    static let pdfBox: CGPDFBox = .cropBox

    static func extent(of url: URL) -> (cx: Int, cy: Int) {
        let natural = naturalInches(of: url) ?? fallbackInches
        let scale = min(1, maxWidthInches / natural.width, maxHeightInches / natural.height)
        return (Int((natural.width * scale * emuPerInch).rounded()),
                Int((natural.height * scale * emuPerInch).rounded()))
    }

    static func naturalInches(of url: URL) -> (width: Double, height: Double)? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = CGPDFDocument(url as CFURL), // adr-0018-ok: research PDF's page size read for the Word drawing
                  let page = document.page(at: 1) else { return nil }
            let box = page.getBoxRect(pdfBox)
            let turned = abs(page.rotationAngle) % 180 == 90
            let (w, h) = turned ? (box.height, box.width) : (box.width, box.height)
            guard w > 0, h > 0 else { return nil }
            return (Double(w) / 72, Double(h) / 72)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), // adr-0018-ok: research image header read for the Word drawing
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let ph = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pw > 0, ph > 0 else { return nil }
        func dpi(_ key: CFString) -> Double {
            let value = (props[key] as? NSNumber)?.doubleValue ?? 0
            return value > 0 ? value : defaultDPI
        }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let w = pw / dpi(kCGImagePropertyDPIWidth)
        let h = ph / dpi(kCGImagePropertyDPIHeight)
        return (5...8).contains(orientation) ? (h, w) : (w, h)
    }
}
