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
        switch piece.mode {
        case .prose:
            let parsed = parseProse(stripped)
            nodes = parsed.nodes
            starts = parsed.starts
        case .fountain:
            let parsed = parseFountain(stripped)
            nodes = parsed.nodes
            starts = parsed.starts
        }
        return .init(pieceID: piece.pieceID, title: piece.title,
                     mode: piece.mode, nodes: nodes,
                     anchors: anchors(for: piece, starts: starts, stripped: stripped))
    }

    // MARK: - anchors

    /// Node index → `¶id`, computed from the paragraph spans — never from a
    /// re-parse, and never at the cost of a different node.
    ///
    /// The reconciliation is deliberately strict. `displayText` is supposed to
    /// be the paragraphs joined with the blank-line block separator (that is
    /// what `Materializer` writes and what the translated path joins), so the
    /// builder re-derives that join and requires `stripAnchors(joined)` to equal
    /// the very string it parsed. If a source ever hands paragraphs that don't
    /// reconstitute its own display text, there is no honest alignment to be
    /// had — a guessed one would silently point a cross-link at the wrong
    /// paragraph — so the answer is no anchors at all.
    ///
    /// The one coordinate wrinkle: `stripAnchors` trims the WHOLE text's outer
    /// whitespace, so if paragraph 0 opens with a blank line the parsed text
    /// begins one or more lines later than the join does. That shift is measured
    /// off the join itself (the leading whitespace-only lines the trim ate) and
    /// reconciled against the parsed line count — if the two don't agree, the
    /// mapping is unknown and again the answer is no anchors.
    private static func anchors(
        for piece: PieceRef, starts: [Int], stripped: String
    ) -> [Int: String] {
        guard let paragraphs = piece.paragraphs, !paragraphs.isEmpty else { return [:] }

        let joined = paragraphs.map(\.text).joined(separator: "\n\n")
        guard MarkdownDisplayFilter.stripAnchors(joined) == stripped else { return [:] }

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
        guard end - leading == stripped.components(separatedBy: "\n").count else { return [:] }

        // Paragraph k occupies [cursor, cursor + its line count) in the join;
        // the +1 is the separator's blank line.
        var spans: [(range: Range<Int>, id: String)] = []
        var cursor = 0
        for paragraph in paragraphs {
            let lineCount = paragraph.text.components(separatedBy: "\n").count
            spans.append((cursor..<(cursor + lineCount), paragraph.id))
            cursor += lineCount + 1
        }

        var anchors: [Int: String] = [:]
        var claimed = Set<Int>()
        for (nodeIndex, start) in starts.enumerated() {
            let line = start + leading
            guard let k = spans.firstIndex(where: { $0.range.contains(line) }) else { continue }
            guard !claimed.contains(k) else { continue }   // one id per paragraph, on its FIRST node
            claimed.insert(k)
            anchors[nodeIndex] = spans[k].id
        }
        return anchors
    }

    // MARK: - prose

    /// `stripped` is the ALREADY anchor-stripped text (the caller does that
    /// once so the anchor pass can measure against the same string).
    private static func parseProse(
        _ stripped: String
    ) -> (nodes: [ProjectAST.Node], starts: [Int]) {
        // Run the shared block parser (headings, blockquotes, scene breaks,
        // lists, fences, multi-line paragraphs — plus the table/solo-image
        // grammar publish degrades), then map each block to a ProseNode. The
        // range-carrying entry point returns the same blocks `parse` does; the
        // ranges are only read by the anchor pass.
        let blocks = MarkdownBlockParser.parseWithLineRanges(stripped)
        return (mapProse(blocks.map(\.block)).map(ProjectAST.Node.prose),
                blocks.map { $0.lines.lowerBound })
    }

    /// Map shared `MarkdownBlock`s to publish `ProseNode`s. The block grammar
    /// was ported FROM the former local state machine, so this mapping is
    /// behavior-neutral by construction. Table and solo image are display-only
    /// grammar the publish path doesn't render, so they degrade to literal
    /// paragraph text through the same `parseParagraphInlines` helper the block
    /// loop used before the cutover — byte-identical to the former pass-through
    /// (locked by the degrade pins in ProjectASTBuilderTests). Recurses for
    /// blockquote bodies, which is why it returns `[ProseNode]`.
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
