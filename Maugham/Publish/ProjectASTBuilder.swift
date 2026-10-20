import Foundation
import MaughamCore

public enum ProjectASTBuilder {

    public struct PieceRef: Sendable {
        public let pieceID: String
        public let title: String
        public let mode: ProjectAST.Mode
        public let displayText: String

        /// The piece's op-log paragraphs in `sequence` order, `(¶id, text)`.
        /// OPTIONAL and purely additive: `displayText` remains the only input to
        /// parsing, so a nil here is exactly the build this type has always
        /// produced, with `Section.anchors == [:]`. When present the builder
        /// re-derives the paragraph join, checks it against what it actually
        /// parsed, and uses the line spans to hang each `¶id` on the first node
        /// that paragraph produced.
        public let paragraphs: [(id: String, text: String)]?

        public init(pieceID: String, title: String,
                    mode: ProjectAST.Mode, displayText: String,
                    paragraphs: [(id: String, text: String)]? = nil) {
            self.pieceID = pieceID
            self.title = title
            self.mode = mode
            self.displayText = displayText
            self.paragraphs = paragraphs
        }
    }

    public protocol Source {
        /// THROWS when a piece's history is unreadable (RULING-54): a compile
        /// must fail loudly — through `CompileOrchestrator`'s DurableProgress
        /// catch — rather than emit a book silently missing the chapters an
        /// unreadable op-log file held. Non-throwing sources satisfy this
        /// requirement unchanged.
        func orderedPieces() throws -> [PieceRef]

        /// What publishing knows about the project beyond its text (report
        /// foundations plan 2). A REQUIREMENT with a default (below), not an
        /// extension-only method, so a wrapper's forwarding override is what a
        /// call through `any Source` reaches — an extension-only method
        /// dispatches statically and would answer `.empty` for every wrapper.
        func publishContext() -> PublishContext

        /// The WHOLE book this source is a view of. A filtering wrapper answers
        /// its base's, so a preview or subset edition numbers and resolves over
        /// every publishable piece and emits only its own. A requirement for
        /// the same dispatch reason as `publishContext()`.
        var resolutionScope: Source { get }

        /// True when this source IS its whole book — it filters no piece out —
        /// so the AST a compiler built from it is the AST `resolutionScope`
        /// would build, and the resolution can reuse it rather than derive
        /// every piece from the op log a second time
        /// (`PublishResolution.forCompile(source:built:…)`). A filtering
        /// wrapper answers false while its filter removes anything, else its
        /// base's answer. A requirement for the same dispatch reason.
        ///
        /// A wrapper that overrides `resolutionScope` must override
        /// `isWholeBook`: the default's `true` is the unsafe answer for a
        /// subset (`PublishContextTests.forwardingFailures` checks it).
        var isWholeBook: Bool { get }
    }

    public static func build(from source: Source) throws -> ProjectAST {
        let sections = try source.orderedPieces().map(buildSection(from:))
        return ProjectAST(sections: sections)
    }

    // MARK: - section assembly

    private static func buildSection(from piece: PieceRef) -> ProjectAST.Section {
        // `stripped` is what is parsed, exactly as before — the anchor pass
        // below only READS the same string to place ids, it never steers the
        // parse. `starts[n]` is the first source line of node n in `stripped`.
        let stripped = MarkdownDisplayFilter.stripAnchors(piece.displayText)
        let nodes: [ProjectAST.Node]
        let starts: [Int]
        var footnotes: [String: [ProjectAST.Inline]] = [:]
        var footnoteStarts: [String: Int] = [:]
        var duplicateStarts: [String: [Int]] = [:]
        switch piece.mode {
        case .prose:
            let parsed = parseProse(stripped)
            nodes = parsed.nodes
            starts = parsed.starts
            footnotes = parsed.footnotes
            footnoteStarts = parsed.footnoteStarts
            duplicateStarts = parsed.duplicateStarts
        case .fountain:
            let parsed = parseFountain(stripped)
            nodes = parsed.nodes
            starts = parsed.starts
        }
        let spans = paragraphSpans(for: piece, stripped: stripped)
        return .init(pieceID: piece.pieceID, title: piece.title,
                     mode: piece.mode, nodes: nodes,
                     anchors: anchors(starts: starts, spans: spans),
                     footnotes: footnotes,
                     nodeParagraphs: starts.enumerated().reduce(into: [:]) { out, entry in
                         out[entry.offset] = spans?.paragraphID(atStrippedLine: entry.element)
                     },
                     footnoteParagraphs: footnoteStarts.reduce(into: [:]) { out, entry in
                         out[entry.key] = spans?.paragraphID(atStrippedLine: entry.value)
                     },
                     duplicateFootnotes: duplicateStarts.mapValues { lines in
                         lines.map { spans?.paragraphID(atStrippedLine: $0) }
                     })
    }

    // MARK: - anchors

    /// The paragraphs' line spans in the join, plus the shift between the
    /// join's lines and `stripped`'s. The ONLY line → `¶id` map: `anchors`,
    /// `nodeParagraphs` and `footnoteParagraphs` all read it.
    private struct ParagraphSpans {
        let spans: [(range: Range<Int>, id: String)]
        let leading: Int

        /// The index of the span holding `line` of `stripped`, if any.
        func spanIndex(atStrippedLine line: Int) -> Int? {
            let joinedLine = line + leading
            return spans.firstIndex(where: { $0.range.contains(joinedLine) })
        }

        func paragraphID(atStrippedLine line: Int) -> String? {
            spanIndex(atStrippedLine: line).map { spans[$0].id }
        }
    }

    /// Node index → `¶id` for the FIRST node each paragraph produced —
    /// computed from the paragraph spans, never from a re-parse, and never at
    /// the cost of a different node. Sparse by design (see `Section.anchors`).
    private static func anchors(starts: [Int], spans: ParagraphSpans?) -> [Int: String] {
        guard let spans else { return [:] }
        var anchors: [Int: String] = [:]
        var claimed = Set<Int>()
        for (nodeIndex, start) in starts.enumerated() {
            guard let k = spans.spanIndex(atStrippedLine: start) else { continue }
            guard !claimed.contains(k) else { continue }   // one id per paragraph, on its FIRST node
            claimed.insert(k)
            anchors[nodeIndex] = spans.spans[k].id
        }
        return anchors
    }

    /// The reconciliation is deliberately strict. `displayText` is supposed to
    /// be the paragraphs joined with the blank-line block separator (that is
    /// what `Materializer` writes and what the translated path joins), so the
    /// builder re-derives that join and requires `stripAnchors(joined)` to equal
    /// the very string it parsed. If a source ever hands paragraphs that don't
    /// reconstitute its own display text, there is no honest alignment to be
    /// had — a guessed one would silently point a cross-link at the wrong
    /// paragraph — so the answer is nil: no anchors, no node paragraphs.
    ///
    /// The one coordinate wrinkle: `stripAnchors` trims the WHOLE text's outer
    /// whitespace, so if paragraph 0 opens with a blank line the parsed text
    /// begins one or more lines later than the join does. That shift is measured
    /// off the join itself (the leading whitespace-only lines the trim ate) and
    /// reconciled against the parsed line count — if the two don't agree, the
    /// mapping is unknown and again the answer is nil.
    private static func paragraphSpans(for piece: PieceRef, stripped: String) -> ParagraphSpans? {
        guard let paragraphs = piece.paragraphs, !paragraphs.isEmpty else { return nil }

        let joined = paragraphs.map(\.text).joined(separator: "\n\n")
        guard MarkdownDisplayFilter.stripAnchors(joined) == stripped else { return nil }

        let joinedLines = joined.components(separatedBy: "\n")
        var leading = 0
        while leading < joinedLines.count,
              joinedLines[leading].trimmingCharacters(in: .whitespaces).isEmpty {
            leading += 1
        }
        var end = joinedLines.count
        while end > leading,
              joinedLines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        guard end - leading == stripped.components(separatedBy: "\n").count else { return nil }

        // Paragraph k occupies [cursor, cursor + its line count) in the join;
        // the +1 is the separator's blank line.
        var spans: [(range: Range<Int>, id: String)] = []
        var cursor = 0
        for paragraph in paragraphs {
            let lineCount = paragraph.text.components(separatedBy: "\n").count
            spans.append((cursor..<(cursor + lineCount), paragraph.id))
            cursor += lineCount + 1
        }
        return ParagraphSpans(spans: spans, leading: leading)
    }

    // MARK: - prose

    /// `stripped` is the ALREADY anchor-stripped text (the caller does that
    /// once so the anchor pass can measure against the same string).
    ///
    /// Reads plan 1's manuscript grammar: `ManuscriptBlocks` lifts labelled
    /// headings, tables, figures and footnote definitions out of the shared
    /// block parser's output; every other block (`.other`) maps exactly as it
    /// always did. A footnote definition yields NO node — it goes to
    /// `footnotes` (first definition wins; each later one is recorded in
    /// `duplicateStarts`) with its own start line — so
    /// `nodes` and `starts` stay index-aligned, as with a fence's tail.
    private static func parseProse(_ stripped: String) -> (
        nodes: [ProjectAST.Node], starts: [Int],
        footnotes: [String: [ProjectAST.Inline]], footnoteStarts: [String: Int],
        duplicateStarts: [String: [Int]]
    ) {
        var nodes: [ProjectAST.Node] = []
        var starts: [Int] = []
        var footnotes: [String: [ProjectAST.Inline]] = [:]
        var footnoteStarts: [String: Int] = [:]
        var duplicateStarts: [String: [Int]] = [:]
        for (block, lines) in ManuscriptBlocks.parse(stripped) {
            let node: ProjectAST.ProseNode
            switch block {
            case .heading(let level, let text, let label):
                node = .heading(level: level, InlineParser.parse(text), label: label)
            case .table(let header, let alignments, let rows, let caption, let label):
                node = .table(header: header.map(InlineParser.parse),
                              alignments: alignments,
                              rows: rows.map { $0.map(InlineParser.parse) },
                              caption: caption.map(InlineParser.parse),
                              label: label)
            case .figure(let caption, let path, let label):
                node = .figure(caption: InlineParser.parse(caption), path: path, label: label)
            case .footnoteDefinition(let label, let text):
                if footnotes[label] == nil {
                    footnotes[label] = parseParagraphInlines(text.components(separatedBy: "\n"))
                    footnoteStarts[label] = lines.lowerBound
                } else {
                    duplicateStarts[label, default: []].append(lines.lowerBound)
                }
                continue
            case .other(let other):
                node = mapProse([other])[0]
            }
            nodes.append(.prose(node))
            starts.append(lines.lowerBound)
        }
        return (nodes, starts, footnotes, footnoteStarts, duplicateStarts)
    }

    /// Map shared `MarkdownBlock`s to publish `ProseNode`s — the `.other`
    /// path of `parseProse`, and every block inside a blockquote. The block
    /// grammar was ported FROM the former local state machine, so this mapping
    /// is behavior-neutral by construction. At the top level `ManuscriptBlocks`
    /// has already claimed headings, tables and figure lines; a table or a
    /// solo image that reaches here (inside a blockquote, or an image line the
    /// figure rule refuses) degrades to literal paragraph text through the
    /// same `parseParagraphInlines` helper the block loop always used.
    /// Recurses for blockquote bodies, which is why it returns `[ProseNode]`.
    private static func mapProse(_ blocks: [MarkdownBlock]) -> [ProjectAST.ProseNode] {
        blocks.map { block in
            switch block {
            case .heading(let level, let text):
                return .heading(level: level, InlineParser.parse(text))
            case .paragraph(let lines):
                return .paragraph(parseParagraphInlines(lines))
            case .list(let ordered, let items):
                // First item line is marker-stripped content; continuation
                // lines join with a space after trimming (today's rule).
                return .list(ordered: ordered, items: items.map { item in
                    InlineParser.parse(item.enumerated().map { i, l in
                        i == 0 ? l : l.trimmingCharacters(in: .whitespaces)
                    }.joined(separator: " "))
                })
            case .fence(let lines, _):
                return .verbatim(lines)
            case .blockquote(let inner):
                return .blockquote(mapProse(inner))
            case .thematicBreak:
                return .sceneBreak
            case .table(_, _, let rawLines):
                return .paragraph(parseParagraphInlines(rawLines))
            case .soloImage(_, _, let rawLine):
                return .paragraph(parseParagraphInlines([rawLine]))
            }
        }
    }

    /// Join a paragraph's physical lines into one inline string: a soft line
    /// break (no trailing markers) becomes a space; a line ending in two or
    /// more spaces becomes a markdown hard break that `InlineParser` renders
    /// as `.lineBreak`.
    private static func parseParagraphInlines(_ lines: [String]) -> [ProjectAST.Inline] {
        var combined = ""
        for (idx, line) in lines.enumerated() {
            let content = line.trimmingCharacters(in: .whitespaces)
            if idx == lines.count - 1 {
                combined += content
            } else if line.hasSuffix("  ") {
                combined += content + "  \n"   // InlineParser → .lineBreak
            } else {
                combined += content + " "       // soft break → space
            }
        }
        return InlineParser.parse(combined)
    }

    // MARK: - fountain

    private static func parseFountain(
        _ stripped: String
    ) -> (nodes: [ProjectAST.Node], starts: [Int]) {
        // Strip inline <!-- ¶XXXX --> anchors via the shared single source of
        // truth, exactly as parseProse does — otherwise op-log join keys leak
        // into rendered screenplay output (ADR 0019). Then classify through the
        // real shared FountainTokenizer (the same parser the editor and phone
        // use) and map its elements into publish `FountainNode`s, so published
        // PDF/EPUB output classifies exactly as the on-screen editor does. This
        // omits author-only content (boneyard, notes, synopses, sections),
        // strips forced markers, and unlocks dual dialogue — none of which the
        // former hand-rolled classifier could do (audit A1). Anchor stripping
        // already happened in `buildSection`, so the anchor pass and the parse
        // read the same string.
        let mapped = FountainNodeMapper.mapWithFirstLines(
            FountainTokenizer().parse(stripped))
        return (mapped.map { ProjectAST.Node.fountain($0.node) },
                mapped.map(\.firstLine))
    }
}

extension ProjectASTBuilder.Source {
    /// Defaulted to `.empty`, so the test conformers that implement only
    /// `orderedPieces()` need no change. `ProjectStoreASTSource` answers the
    /// real one; every filtering wrapper forwards its base's.
    public func publishContext() -> PublishContext { .empty }

    /// Defaulted to `self`: a source that filters nothing is its own whole
    /// book. A filtering wrapper answers its base's.
    public var resolutionScope: ProjectASTBuilder.Source { self }

    /// Defaulted to true, with `resolutionScope`'s `self`: a source that
    /// filters nothing is its own whole book.
    public var isWholeBook: Bool { true }
}
