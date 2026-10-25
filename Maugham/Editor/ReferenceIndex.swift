import Foundation
import MaughamCore

/// **The project's citation sources and cross-reference targets, numbered the
/// way the editor shows them** (report foundations plan 3b Task 1, R-3b-2).
/// The citation and cross-reference pickers, the faint labels and the editor's
/// problem marks all read this one value.
///
/// A pure value: `build` walks the pieces publishing prints, in publishing
/// order (`ProjectStoreASTSource.publishablePieces(in:)`, so reference pieces
/// are out). `ReferenceIndexHost` caches it and rebuilds it off the main
/// thread; the coordinator reads the cached value through a closure and never
/// builds one per keystroke.
///
/// **The numbers are the default book's.** Figures and tables count by plain
/// counting over every piece the book includes, as `PublishResolution` counts
/// them, so for a book with no imprint they match the PDF
/// (`ReferenceIndexTests.test_figureAndTableNumbersMatchPublishing`). An
/// imprint that drops sections can number differently, and that is accepted
/// (R-3b-2). A section shows its heading's own text, never a number.
///
/// **"Cited" is the pieces' text, not publishing's AST**, which diverges in one
/// way: a `[@key]` inside an unused footnote definition counts here, where
/// publishing walks only the definitions a piece references. A citation in a
/// fenced code block is skipped, as publishing skips it. The divergence can
/// only move an a/b letter.
struct ReferenceIndex: Equatable, Sendable {

    /// A live research item with a citation key.
    struct Source: Equatable, Sendable {
        let key: String
        /// **The in-text label without its parentheses**: "Smith 2026",
        /// "Lee and Wu n.d.", "Smith et al. 2020", exactly what
        /// `CitationStyle.disambiguated` gives. A source the project's
        /// manuscripts cite carries its a/b letter when another cited source
        /// shares its name and year ("Smith 2026a"); an uncited source never
        /// does. A picker row reads "\(label) — \(title)"; the faint label
        /// beside a marker wraps it as publishing does, "(Smith 2026a, p. 12)"
        /// (`citationText(_:)`).
        let label: String
        /// Every author as written in the inspector, joined by "; "; empty
        /// when the source names none.
        let authorsLine: String
        /// The source's title, else the research item's.
        let title: String
    }

    /// A labelled figure, table or section a cross-reference can point at.
    struct Target: Equatable, Sendable {
        let label: ManuscriptLabel
        /// "Figure 3" or "Table 2" in the book's words, or a section's heading
        /// text.
        let text: String
        /// A figure's or table's caption; empty for a section (its title is
        /// already `text`) and for a table with no caption.
        let detail: String
        /// The piece that defines it.
        let docId: String
        /// Its position among `targets`, from 0, in publishing order.
        let order: Int
    }

    /// Live research items with a key, each key once (the first wins, as
    /// `CitationLibrary` reads them), sorted by `authorsLine` — the title for
    /// a source with no authors — ignoring case and accents, then `label`,
    /// then `key`.
    let sources: [Source]
    /// Every labelled figure, table and section, in publishing order. A label
    /// on the wrong kind of element, or defined a second time, is not a
    /// target: publishing reports both and registers neither.
    let targets: [Target]
    /// Bumps when `sources` or `targets` change (`ReferenceIndexHost`); a
    /// freshly built index is version 0, and the host publishes its first
    /// build as 1 at least, so a host's version 0 means "not built yet".
    let version: Int

    /// Every label each piece DEFINES, whatever its kind and however often —
    /// what a command that mints a label must avoid (`labelsDefined(excluding:)`).
    private let definedLabels: [String: Set<ManuscriptLabel>]
    private let sourceIndex: [String: Int]
    private let targetIndex: [ManuscriptLabel: Int]

    static let empty = ReferenceIndex(sources: [], targets: [], definedLabels: [:], version: 0)

    func source(forKey key: String) -> Source? { sourceIndex[key].map { sources[$0] } }

    func target(for label: ManuscriptLabel) -> Target? { targetIndex[label].map { targets[$0] } }

    /// The in-text citation for `items` as publishing prints it, parentheses
    /// and locators included: "(Smith 2026a, p. 12; Lee 2020)". Nil when any
    /// key is not a source (the problem mark's case) or `items` is empty.
    func citationText(_ items: [CitationItem]) -> String? {
        var labels: [String: String] = [:]
        for item in items { labels[item.key] = source(forKey: item.key)?.label }
        return CitationStyle.inText(items, labels: labels)
    }

    /// The labels every indexed piece except `docId` defines — the project's
    /// OTHER manuscripts, for Insert Table's `tbl:` and a figure's `fig:` to
    /// stay unique against (`EditorCoordinator.projectLabelsElsewhere`). The
    /// edited document's own labels come from its live text at the command.
    func labelsDefined(excluding docId: String) -> Set<ManuscriptLabel> {
        var out = Set<ManuscriptLabel>()
        for (id, labels) in definedLabels where id != docId { out.formUnion(labels) }
        return out
    }

    /// Same sources and targets, whatever the version.
    func hasSameContents(as other: ReferenceIndex) -> Bool {
        sources == other.sources && targets == other.targets && definedLabels == other.definedLabels
    }

    /// This index's contents at `version`.
    func versioned(_ version: Int) -> ReferenceIndex {
        ReferenceIndex(sources: sources, targets: targets, definedLabels: definedLabels,
                       version: version)
    }

    private init(sources: [Source], targets: [Target],
                 definedLabels: [String: Set<ManuscriptLabel>], version: Int) {
        self.sources = sources
        self.targets = targets
        self.definedLabels = definedLabels
        self.version = version
        var bySource: [String: Int] = [:]
        for (i, s) in sources.enumerated() where bySource[s.key] == nil { bySource[s.key] = i }
        sourceIndex = bySource
        var byTarget: [ManuscriptLabel: Int] = [:]
        for (i, t) in targets.enumerated() where byTarget[t.label] == nil { byTarget[t.label] = i }
        targetIndex = byTarget
    }

    // MARK: - One piece

    /// What one piece contributes, read from its text once. Pure and
    /// `Sendable`, so the host keeps it per piece and re-reads only a piece
    /// whose text changed.
    struct PieceSummary: Equatable, Sendable {
        enum Element: Equatable, Sendable {
            case heading(text: String, label: ManuscriptLabel?)
            case table(caption: String?, label: ManuscriptLabel?)
            case figure(caption: String, label: ManuscriptLabel?)
        }
        /// The piece's top-level headings, tables and figures, in order.
        let elements: [Element]
        /// Every label the piece defines, any kind.
        let definedLabels: Set<ManuscriptLabel>
        /// Every key the piece cites, in first-citation order, each once.
        let citedKeys: [String]

        static let empty = PieceSummary(elements: [], definedLabels: [], citedKeys: [])

        /// Reads `text` with the parser publishing reads it with
        /// (`ManuscriptBlocks.parse`, as `ProjectASTBuilder.parseProse` does)
        /// and the inline scanner.
        init(text: String) {
            var elements: [Element] = []
            var labels = Set<ManuscriptLabel>()
            var fences: [Range<Int>] = []
            for (block, lines) in ManuscriptBlocks.parse(text) {
                switch block {
                case .other(.fence):
                    fences.append(lines)
                case .heading(_, let heading, let label):
                    // Markup and footnote markers dropped, as publishing's
                    // unnumbered section reference prints the heading.
                    elements.append(.heading(text: PlainText.of(InlineParser.parse(heading)),
                                             label: label))
                    if let label { labels.insert(label) }
                case .table(_, _, _, let caption, let label):
                    elements.append(.table(caption: caption, label: label))
                    if let label { labels.insert(label) }
                case .figure(let caption, let path, let label):
                    // R7a-1: a table figure's line is a table unless labelled `fig:`.
                    switch ManuscriptLabel.Kind.ofFigureLine(path: path, label: label) {
                    case .tbl: elements.append(.table(caption: caption, label: label))
                    case .fig, .sec: elements.append(.figure(caption: caption, label: label))
                    }
                    if let label { labels.insert(label) }
                case .footnoteDefinition, .other:
                    continue
                }
            }
            var cited: [String] = []
            var seen = Set<String>()
            let lineStarts = fences.isEmpty ? [] : Self.lineStarts(text)
            func inFence(_ location: Int) -> Bool {
                guard !fences.isEmpty else { return false }
                // The line holding `location`: the last line start at or before it.
                var lo = 0, hi = lineStarts.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if lineStarts[mid] <= location { lo = mid + 1 } else { hi = mid }
                }
                let line = lo - 1
                return fences.contains { $0.contains(line) }
            }
            for (marker, range) in ManuscriptInlineScanner.scan(text) {
                guard case .citation(let items) = marker, !inFence(range.location) else { continue }
                for item in items where seen.insert(item.key).inserted { cited.append(item.key) }
            }
            self.init(elements: elements, definedLabels: labels, citedKeys: cited)
        }

        /// The UTF-16 offset each line starts at (line 0 at 0), splitting on
        /// "\n" as `MarkdownBlockParser` numbers its lines.
        private static func lineStarts(_ text: String) -> [Int] {
            var starts = [0]
            var offset = 0
            for unit in text.utf16 {
                offset += 1
                if unit == 0x0A { starts.append(offset) }
            }
            return starts
        }

        init(elements: [Element], definedLabels: Set<ManuscriptLabel>, citedKeys: [String]) {
            self.elements = elements
            self.definedLabels = definedLabels
            self.citedKeys = citedKeys
        }
    }

    // MARK: - Building

    /// One piece in publishing order and what it holds. A screenplay's
    /// summary is `.empty`: it prints no figure, table or citation.
    typealias Piece = (docId: String, summary: PieceSummary)

    /// The index of `structure`'s publishable pieces (publishing's own rule,
    /// `ProjectStoreASTSource.publishablePieces(in:)`), each piece's text read
    /// through `text` (nil skips it: an unreadable piece contributes nothing).
    /// Screenplays are never read.
    static func build(structure: [StructureItem], research: [ResearchItem],
                      text: (StructureItem) -> String?, words: ElementWords) -> ReferenceIndex {
        let pieces = readablePieces(in: structure).map { piece -> Piece in
            guard piece.readablePath != nil, let body = text(piece.item) else {
                return (piece.item.id, .empty)
            }
            return (piece.item.id, PieceSummary(text: body))
        }
        return build(pieces: pieces, research: research, words: words)
    }

    /// **Which pieces the index reads, the one answer the builder and
    /// `ReferenceIndexHost` share**: every publishable piece in publishing
    /// order (`ProjectStoreASTSource.publishablePieces(in:)`), each with the
    /// path to read it at, or nil for a screenplay, which is in the book but
    /// holds no figure, table or citation and is never read.
    static func readablePieces(in structure: [StructureItem])
        -> [(item: StructureItem, readablePath: String?)] {
        ProjectStoreASTSource.publishablePieces(in: structure).map { item in
            guard let path = item.path, !DocumentFormat.ofManuscript(path: path).isScreenplay else {
                return (item, nil)
            }
            return (item, path)
        }
    }

    /// The index of `pieces`, already in publishing order.
    static func build(pieces: [Piece], research: [ResearchItem], words: ElementWords) -> ReferenceIndex {
        // Targets: figures and tables count every one, labelled or not, as
        // `PublishResolution`'s first walk does; a label registers only on its
        // own kind of element, and only the first time.
        var targets: [Target] = []
        var registered = Set<ManuscriptLabel>()
        var figures = 0, tables = 0
        var defined: [String: Set<ManuscriptLabel>] = [:]
        func register(_ label: ManuscriptLabel?, _ kind: ManuscriptLabel.Kind,
                      text: String, detail: String, docId: String) {
            guard let label, label.kind == kind, registered.insert(label).inserted else { return }
            targets.append(Target(label: label, text: text, detail: detail, docId: docId,
                                  order: targets.count))
        }
        for piece in pieces {
            defined[piece.docId, default: []].formUnion(piece.summary.definedLabels)
            for element in piece.summary.elements {
                switch element {
                case .heading(let text, let label):
                    register(label, .sec, text: text, detail: "", docId: piece.docId)
                case .table(let caption, let label):
                    tables += 1
                    register(label, .tbl, text: "\(words.table) \(tables)", detail: caption ?? "",
                             docId: piece.docId)
                case .figure(let caption, let label):
                    figures += 1
                    register(label, .fig, text: "\(words.figure) \(figures)", detail: caption,
                             docId: piece.docId)
                }
            }
        }

        // Sources: a/b letters over the known keys the pieces cite, as
        // publishing disambiguates them; an uncited source on its own.
        let library = CitationLibrary(items: research)
        var citedOrder: [String] = []
        var cited = Set<String>()
        for piece in pieces {
            for key in piece.summary.citedKeys where library.entry(for: key) != nil
                && cited.insert(key).inserted {
                citedOrder.append(key)
            }
        }
        var labels: [String: String] = [:]
        for (entry, label) in CitationStyle.disambiguated(citedOrder.compactMap(library.entry(for:))) {
            labels[entry.info.key] = label
        }
        var sources: [Source] = []
        for key in liveKeys(in: research) {
            guard let entry = library.entry(for: key) else { continue }
            let label = labels[key] ?? CitationStyle.disambiguated([entry]).first?.label ?? key
            let authors = entry.info.authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let title = entry.info.sourceTitle.flatMap { $0.isEmpty ? nil : $0 } ?? entry.itemTitle
            sources.append(Source(key: key, label: label,
                                  authorsLine: authors.joined(separator: "; "), title: title))
        }
        sources.sort { a, b in
            let fa = a.authorsLine.isEmpty ? a.title : a.authorsLine
            let fb = b.authorsLine.isEmpty ? b.title : b.authorsLine
            switch fa.compare(fb, options: [.caseInsensitive, .diacriticInsensitive]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame:
                if a.label != b.label { return a.label < b.label }
                return a.key < b.key
            }
        }
        return ReferenceIndex(sources: sources, targets: targets, definedLabels: defined, version: 0)
    }

    /// Every key in the research tree, children walked, each once, in tree
    /// order (`CitationLibrary`'s walk; the library answers which entry wins).
    private static func liveKeys(in research: [ResearchItem]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func walk(_ items: [ResearchItem]) {
            for item in items {
                if let key = item.citation?.key, seen.insert(key).inserted { out.append(key) }
                if let kids = item.children { walk(kids) }
            }
        }
        walk(research)
        return out
    }
}
