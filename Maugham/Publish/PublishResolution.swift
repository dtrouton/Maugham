import Foundation
import MaughamCore

/// The project-wide resolution pass (report foundations plan 2, Task 4): over
/// the AST of the edition's WHOLE book (R-S15: every piece the edition
/// includes), never a preview subset, it numbers figures,
/// tables, headings and footnotes, resolves cross-references and citations,
/// builds References and the lists of figures and tables, and collects every
/// publish problem against its piece and paragraph. The PDF and EPUB emitters
/// read the result; they never number or resolve on their own.
///
/// Rulings: R-P2-1 (severity, in `PublishProblem.isError`), R-P2-2
/// (numbering), R-P2-3 (footnotes), R-P2-4/5 (citations, References), R-P2-6
/// (the lists, gated by their switches here), R-P2-8 (a translation body is
/// resolved over its own AST, its problems tagged).
///
/// It runs in two walks: the first collects labels and numbers, so a
/// reference may point forward; the second resolves every inline. Only
/// top-level nodes carry labels (a heading inside a blockquote is not a
/// labelled heading), but every inline is walked — paragraphs, headings,
/// table cells and captions, figure captions, list items, blockquotes and
/// the footnote definitions a piece actually uses.
public struct PublishResolution: Sendable {

    /// Where a label points and how a reference to it reads.
    public struct Target: Sendable, Equatable {
        public let pieceID: String
        public let paragraphID: String?
        /// "Figure 3", "Table 2", "Section 1.2", or a heading's own text when
        /// it has no number (`numberSections` off, or deeper than the three
        /// shallowest heading levels the book uses).
        public let text: String

        public init(pieceID: String, paragraphID: String?, text: String) {
            self.pieceID = pieceID
            self.paragraphID = paragraphID
            self.text = text
        }
    }

    public typealias ListEntry = (number: Int, caption: [ProjectAST.Inline], target: Target)

    public let targets: [ManuscriptLabel: Target]
    /// pieceID → top-level node index → "1.2", over the three shallowest
    /// heading levels the book uses (a book starting at `##` numbers its `##`
    /// as "1"); empty when `numberSections` is off. A skipped level (`#` then
    /// `###`) reads "1.0.1", as Pandoc's does.
    public let headingNumbers: [String: [Int: String]]
    /// pieceID → top-level node index → n. Every figure is numbered, labelled or not.
    public let figureNumbers: [String: [Int: Int]]
    /// pieceID → top-level node index → n. Every table is numbered, captioned or not.
    public let tableNumbers: [String: [Int: Int]]
    /// pieceID → footnote label → n (R-P2-3): continuous across the book in
    /// first-reference order, counting only referenced labels that have a
    /// definition in their piece. A reference inside a used definition counts
    /// too, numbered after the piece's body references.
    public let footnoteNumbers: [String: [String: Int]]
    /// pieceID → top-level node index → the figure's resolved image file
    /// (`FigureImageResolver`), for the compilers to stage. A figure that is
    /// absent here is unresolved and renders as its literal source: its image
    /// was refused (a problem), or the source has no project to look in.
    /// A compiler that then fails to stage one calls `stagingFailed`.
    public private(set) var figureFiles: [String: [Int: URL]]
    /// `citationKey(items)` → "(Smith 2026a, p. 3)". Absent for a citation
    /// with any unknown key: it renders as its literal source.
    public let citationText: [String: String]
    /// R-P2-5: the cited sources only, in References order; empty when the
    /// body cites nothing.
    public let references: [[CitationStyle.Run]]
    /// The cited keys, index-aligned with `references`. References are the
    /// edition's book's, like everything here: a source cited only in a
    /// section the edition excludes is not listed (R-S15), while a preview of
    /// one chapter lists the edition's whole References.
    public let referenceKeys: [String]
    /// Every figure, in book order; empty when the switch is off (R-P2-6).
    public let listOfFigures: [ListEntry]
    /// Every table, in book order; empty when the switch is off (R-P2-6).
    public let listOfTables: [ListEntry]
    public private(set) var problems: [PublishProblem]
    /// pieceID → node index → the figure's path as written and its `¶id`, so a
    /// staging failure can name both.
    private let figureOrigins: [String: [Int: (path: String, paragraph: String?)]]

    /// A compiler could not stage this figure's resolved image (R-P2-7): the
    /// figure is unresolved from here on — it renders as its literal source —
    /// and its paragraph carries an `imageUnreadable` problem. The problem
    /// joins the end of `problems`; the order within it is not book order.
    public mutating func stagingFailed(pieceID: String, nodeIndex: Int, reason: String) {
        guard figureFiles[pieceID]?.removeValue(forKey: nodeIndex) != nil else { return }
        let origin = figureOrigins[pieceID]?[nodeIndex]
        problems.append(PublishProblem(
            kind: .imageUnreadable("\(origin?.path ?? "the image") couldn't be copied for the compile: \(reason)"),
            pieceID: pieceID, paragraphID: origin?.paragraph, bodyTag: bodyTag,
            bodyLanguage: bodyLanguage))
    }
    private let bodyTag: String?
    /// The body's own language — `BodyPlan.Body.tag`, nil for the source body
    /// — whatever the body count, so a problem reveals the paragraph in the
    /// text it was found in (R-S14).
    private let bodyLanguage: String?

    /// The ONE key `citationText` is looked up by; the emitters call it too,
    /// so a lookup can never disagree with what was stored. Order and
    /// locators matter. Unambiguous: a key can't hold a comma, and the items
    /// come from `ManuscriptInlineScanner`, whose locators never contain `\n`
    /// (it never spans a line), so items join on a newline.
    public static func citationKey(_ items: [CitationItem]) -> String {
        items.map { item in
            "@" + item.key + (item.locator.map { "," + $0 } ?? "")
        }.joined(separator: "\n")
    }

    /// The helper both compilers use: builds the AST of the source's book —
    /// the edition's, `resolutionScope` — and resolves it with that scope's
    /// context.
    /// The caller then emits the subset AST built from `source` itself.
    /// Throws when a piece's history is unreadable, as `ProjectASTBuilder.build`
    /// does (RULING-54).
    public static func forCompile(source: ProjectASTBuilder.Source, bodyTag: String?,
                                  imageAllowed: Set<String>,
                                  bodyLanguage: String? = nil) throws -> PublishResolution {
        let scope = source.resolutionScope
        return resolve(try ProjectASTBuilder.build(from: scope), context: scope.publishContext(),
                       bodyTag: bodyTag, imageAllowed: imageAllowed, bodyLanguage: bodyLanguage)
    }

    /// `forCompile`, given the AST the compiler already built from `source`
    /// for emitting: when `source.isWholeBook` that AST IS the whole book, and
    /// it is resolved as it stands — an ordinary compile derives its
    /// manuscript from the op log once, not twice. A subset source still
    /// builds its whole book.
    public static func forCompile(source: ProjectASTBuilder.Source, built ast: ProjectAST,
                                  bodyTag: String?, imageAllowed: Set<String>,
                                  bodyLanguage: String? = nil) throws -> PublishResolution {
        guard source.isWholeBook else {
            return try forCompile(source: source, bodyTag: bodyTag, imageAllowed: imageAllowed,
                                  bodyLanguage: bodyLanguage)
        }
        return resolve(ast, context: source.resolutionScope.publishContext(),
                       bodyTag: bodyTag, imageAllowed: imageAllowed, bodyLanguage: bodyLanguage)
    }

    /// - Parameter imageAllowed: the output's lowercase image extensions (R-P2-7).
    public static func resolve(_ ast: ProjectAST, context: PublishContext, bodyTag: String?,
                               imageAllowed: Set<String>,
                               bodyLanguage: String? = nil) -> PublishResolution {
        var pass = Pass(context: context, bodyTag: bodyTag, imageAllowed: imageAllowed,
                        bodyLanguage: bodyLanguage)
        pass.headingBase = ast.sections.flatMap(\.nodes).compactMap { node -> Int? in
            guard case .prose(.heading(let level, _, _)) = node else { return nil }
            return level
        }.min() ?? 1
        for section in ast.sections { pass.collect(section) }
        for section in ast.sections { pass.resolveInlines(section) }
        return pass.finish()
    }

    fileprivate init(pass: Pass, references: [[CitationStyle.Run]], referenceKeys: [String],
                     citationText: [String: String]) {
        let switches = pass.context.switches
        targets = pass.targets
        headingNumbers = pass.headingNumbers
        figureNumbers = pass.figureNumbers
        tableNumbers = pass.tableNumbers
        footnoteNumbers = pass.footnoteNumbers
        figureFiles = pass.figureFiles
        figureOrigins = pass.figureOrigins
        bodyTag = pass.bodyTag
        bodyLanguage = pass.bodyLanguage
        self.citationText = citationText
        self.references = references
        self.referenceKeys = referenceKeys
        listOfFigures = switches.listOfFigures ? pass.figures : []
        listOfTables = switches.listOfTables ? pass.tables : []
        problems = pass.problems
    }
}

// MARK: - the pass

private struct Pass {
    let context: PublishContext
    let bodyTag: String?
    let imageAllowed: Set<String>
    let bodyLanguage: String?

    var targets: [ManuscriptLabel: PublishResolution.Target] = [:]
    var headingNumbers: [String: [Int: String]] = [:]
    var figureNumbers: [String: [Int: Int]] = [:]
    var tableNumbers: [String: [Int: Int]] = [:]
    var footnoteNumbers: [String: [String: Int]] = [:]
    var figureFiles: [String: [Int: URL]] = [:]
    var figureOrigins: [String: [Int: (path: String, paragraph: String?)]] = [:]
    var figures: [PublishResolution.ListEntry] = []
    var tables: [PublishResolution.ListEntry] = []
    var problems: [PublishProblem] = []

    /// pieceID → its position in the book, so problems read in book order.
    private var pieceOrder: [String: Int] = [:]
    /// The shallowest top-level heading level in the book: numbering counts
    /// from it (R-S7), so a book that starts at `##` never prints "0.".
    var headingBase = 1
    private var headingCounters = [0, 0, 0]
    /// Per-occurrence problems already reported, so `[@x; @x]` is one.
    private var reportedOnce = Set<PublishProblem>()
    private var nextFootnote = 1
    /// Known cited keys in first-citation order, and every citation seen.
    private var cited: [String] = []
    private var citations: [[CitationItem]] = []

    init(context: PublishContext, bodyTag: String?, imageAllowed: Set<String>,
         bodyLanguage: String?) {
        self.context = context
        self.bodyTag = bodyTag
        self.imageAllowed = imageAllowed
        self.bodyLanguage = bodyLanguage
    }

    // MARK: walk 1 — labels and numbers

    mutating func collect(_ section: ProjectAST.Section) {
        let piece = section.pieceID
        if pieceOrder[piece] == nil { pieceOrder[piece] = pieceOrder.count }
        for (index, node) in section.nodes.enumerated() {
            guard case .prose(let prose) = node else { continue }
            let paragraph = section.nodeParagraphs[index]
            func target(_ text: String) -> PublishResolution.Target {
                .init(pieceID: piece, paragraphID: paragraph, text: text)
            }
            switch prose {
            case .heading(let level, let inlines, let label):
                var text = PlainText.of(inlines)
                if context.switches.numberSections, let number = headingNumber(level: level) {
                    headingNumbers[piece, default: [:]][index] = number
                    text = "Section \(number)"
                }
                register(label, expected: .sec, target: target(text), piece: piece, paragraph: paragraph)
                if label == nil { checkMalformed(inlines, piece: piece, paragraph: paragraph) }
            case .table(_, _, _, let caption, let label):
                let number = tables.count + 1
                tableNumbers[piece, default: [:]][index] = number
                let t = target("Table \(number)")
                tables.append((number, caption ?? [], t))
                register(label, expected: .tbl, target: t, piece: piece, paragraph: paragraph)
                if label == nil, let caption { checkMalformed(caption, piece: piece, paragraph: paragraph) }
            case .figure(let caption, let path, let label):
                let number = figures.count + 1
                figureNumbers[piece, default: [:]][index] = number
                let t = target("Figure \(number)")
                figures.append((number, caption, t))
                register(label, expected: .fig, target: t, piece: piece, paragraph: paragraph)
                resolveImage(path, piece: piece, index: index, paragraph: paragraph)
            case .paragraph, .blockquote, .sceneBreak, .list, .verbatim:
                continue
            }
        }
    }

    /// R-P2-2 with R-S7: the three shallowest heading levels the book uses
    /// (`headingBase` … `headingBase + 2`) are numbered hierarchically across
    /// the book; deeper ones are not. A skipped level (`#` then `###`) reads
    /// "1.0.1", as Pandoc's `--number-sections` does.
    private mutating func headingNumber(level: Int) -> String? {
        let relative = level - headingBase + 1
        guard (1...3).contains(relative) else { return nil }
        headingCounters[relative - 1] += 1
        for deeper in relative..<3 { headingCounters[deeper] = 0 }
        return headingCounters[0..<relative].map(String.init).joined(separator: ".")
    }

    private mutating func register(_ label: ManuscriptLabel?, expected: ManuscriptLabel.Kind,
                                   target: PublishResolution.Target, piece: String, paragraph: String?) {
        guard let label else { return }
        guard label.kind == expected else {
            report(.labelOnWrongElement(label), piece: piece, paragraph: paragraph)
            return
        }
        guard targets[label] == nil else {
            report(.duplicateLabel(label), piece: piece, paragraph: paragraph)
            return
        }
        targets[label] = target
    }

    /// A trailing `{#…}` that `ManuscriptAttributes.split` refused stays as
    /// the last text inline of a heading or a table caption. Reliable there,
    /// and only there: a figure with a bad block isn't a figure at all (it
    /// degrades to a paragraph), and prose may say `{#x}` on purpose.
    private mutating func checkMalformed(_ inlines: [ProjectAST.Inline], piece: String, paragraph: String?) {
        guard case .text(let last)? = inlines.last, last.hasSuffix("}"),
              let open = last.range(of: "{#", options: .backwards) else { return }
        let raw = String(last[open.upperBound..<last.index(before: last.endIndex)])
        report(.malformedLabel(raw), piece: piece, paragraph: paragraph)
    }

    private mutating func resolveImage(_ path: String, piece: String, index: Int, paragraph: String?) {
        guard let project = context.projectURL, let piecePath = context.piecePaths[piece] else { return }
        switch FigureImageResolver.resolve(path, piecePath: piecePath, projectURL: project,
                                           allowed: imageAllowed) {
        case .file(let url):
            figureFiles[piece, default: [:]][index] = url
            figureOrigins[piece, default: [:]][index] = (path, paragraph)
        case .notLocal:
            report(.figurePathNotLocal(path), piece: piece, paragraph: paragraph)
        case .unreadable(let reason):
            report(.imageUnreadable(reason), piece: piece, paragraph: paragraph)
        }
    }

    // MARK: walk 2 — inlines

    mutating func resolveInlines(_ section: ProjectAST.Section) {
        let piece = section.pieceID
        var used: [String] = []   // footnote labels with a definition, in first-reference order
        var referenced = Set<String>()

        func visit(_ inlines: [ProjectAST.Inline], paragraph: String?) {
            for inline in inlines {
                switch inline {
                case .text, .code, .wikiLink, .lineBreak:
                    continue
                case .emphasis(let inner), .strong(let inner), .strikethrough(let inner),
                     .underline(let inner):
                    visit(inner, paragraph: paragraph)
                case .footnoteRef(let label):
                    referenced.insert(label)
                    if section.footnotes[label] == nil {
                        reportOnce(.missingFootnoteDefinition(label), piece: piece, paragraph: paragraph)
                    } else if !used.contains(label) {
                        used.append(label)
                    }
                case .citation(let items):
                    citations.append(items)
                    for item in items {
                        if context.library.entry(for: item.key) == nil {
                            reportOnce(.unknownCitationKey(item.key), piece: piece, paragraph: paragraph)
                        } else if !cited.contains(item.key) {
                            cited.append(item.key)
                        }
                    }
                case .crossRef(let label):
                    if targets[label] == nil {
                        report(.unresolvedCrossRef(label), piece: piece, paragraph: paragraph)
                    }
                }
            }
        }

        func visit(_ node: ProjectAST.ProseNode, paragraph: String?) {
            switch node {
            case .paragraph(let inlines), .heading(_, let inlines, _):
                visit(inlines, paragraph: paragraph)
            case .blockquote(let inner):
                inner.forEach { visit($0, paragraph: paragraph) }
            case .list(_, let items):
                items.forEach { visit($0, paragraph: paragraph) }
            case .table(let header, _, let rows, let caption, _):
                header.forEach { visit($0, paragraph: paragraph) }
                rows.forEach { $0.forEach { visit($0, paragraph: paragraph) } }
                caption.map { visit($0, paragraph: paragraph) }
            case .figure(let caption, _, _):
                visit(caption, paragraph: paragraph)
            case .sceneBreak, .verbatim:
                return
            }
        }

        for (index, node) in section.nodes.enumerated() {
            // Fountain never produces report markers.
            guard case .prose(let prose) = node else { continue }
            visit(prose, paragraph: section.nodeParagraphs[index])
        }
        // The definitions this piece uses, in numbering order; a reference
        // inside one appends to `used`, so this walks to a fixed point.
        // Unused definitions are deliberately not walked: they never render,
        // and they get their own warning below.
        var next = 0
        while next < used.count {
            let label = used[next]
            next += 1
            footnoteNumbers[piece, default: [:]][label] = nextFootnote
            nextFootnote += 1
            visit(section.footnotes[label] ?? [], paragraph: section.footnoteParagraphs[label])
        }
        for label in section.footnotes.keys.sorted() where !referenced.contains(label) {
            report(.unusedFootnoteDefinition(label), piece: piece,
                   paragraph: section.footnoteParagraphs[label])
        }
        for label in section.duplicateFootnotes.keys.sorted() {
            for paragraph in section.duplicateFootnotes[label] ?? [] {
                report(.duplicateFootnoteDefinition(label), piece: piece, paragraph: paragraph)
            }
        }
    }

    // MARK: finish

    /// Once per (piece, paragraph, key or label): a paragraph that repeats a
    /// broken key is one problem, and each paragraph is still named.
    private mutating func reportOnce(_ kind: PublishProblem.Kind, piece: String, paragraph: String?) {
        let problem = PublishProblem(kind: kind, pieceID: piece, paragraphID: paragraph, bodyTag: bodyTag,
                                     bodyLanguage: bodyLanguage)
        guard reportedOnce.insert(problem).inserted else { return }
        problems.append(problem)
    }

    private mutating func report(_ kind: PublishProblem.Kind, piece: String, paragraph: String?) {
        problems.append(.init(kind: kind, pieceID: piece, paragraphID: paragraph, bodyTag: bodyTag,
                              bodyLanguage: bodyLanguage))
    }

    mutating func finish() -> PublishResolution {
        // Book order by piece; within a piece, the order found (labels and
        // images first, then references). Offsets keep the sort stable.
        problems = problems.enumerated().sorted { a, b in
            let (pa, pb) = (pieceOrder[a.element.pieceID] ?? 0, pieceOrder[b.element.pieceID] ?? 0)
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
        let ordered = CitationStyle.disambiguated(cited.compactMap(context.library.entry(for:)))
        var labels: [String: String] = [:]
        for (entry, label) in ordered { labels[entry.info.key] = label }
        var text: [String: String] = [:]
        for items in citations {
            text[PublishResolution.citationKey(items)] = CitationStyle.inText(items, labels: labels)
        }
        return PublishResolution(
            pass: self,
            references: ordered.map { CitationStyle.referenceEntry($0.entry, label: $0.label) },
            referenceKeys: ordered.map(\.entry.info.key),
            citationText: text)
    }
}

/// A heading's inlines as plain text, for a section reference that has no
/// number: markup dropped, a footnote marker dropped, any other report marker
/// as its literal source.
private enum PlainText {
    static func of(_ inlines: [ProjectAST.Inline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s), .code(let s): return s
            case .emphasis(let inner), .strong(let inner), .strikethrough(let inner),
                 .underline(let inner): return of(inner)
            case .wikiLink(_, let display): return display
            case .lineBreak: return " "
            case .footnoteRef: return ""
            case .citation(let items): return InterimReportLiteral.citation(items)
            case .crossRef(let label): return InterimReportLiteral.crossRef(label)
            }
        }.joined()
    }
}
