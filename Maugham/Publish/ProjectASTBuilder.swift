import Foundation
import MaughamCore

public enum ProjectASTBuilder {

    public struct PieceRef: Sendable {
        public let pieceID: String
        public let title: String
        public let mode: ProjectAST.Mode
        public let displayText: String

        public init(pieceID: String, title: String,
                    mode: ProjectAST.Mode, displayText: String) {
            self.pieceID = pieceID
            self.title = title
            self.mode = mode
            self.displayText = displayText
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
        let nodes: [ProjectAST.Node]
        switch piece.mode {
        case .prose:
            nodes = parseProse(piece.displayText)
        case .fountain:
            nodes = parseFountain(piece.displayText)
        }
        return .init(pieceID: piece.pieceID, title: piece.title,
                     mode: piece.mode, nodes: nodes)
    }

    // MARK: - prose

    private static func parseProse(_ text: String) -> [ProjectAST.Node] {
        // Strip inline <!-- ¶XXXX --> anchors via the shared single source of
        // truth, run the shared block parser (headings, blockquotes, scene
        // breaks, lists, fences, multi-line paragraphs — plus the table/solo-
        // image grammar publish degrades), then map each block to a ProseNode.
        let stripped = MarkdownDisplayFilter.stripAnchors(text)
        return mapProse(MarkdownBlockParser.parse(stripped)).map(ProjectAST.Node.prose)
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

    private static func parseFountain(_ text: String) -> [ProjectAST.Node] {
        // Strip inline <!-- ¶XXXX --> anchors via the shared single source of
        // truth, exactly as parseProse does — otherwise op-log join keys leak
        // into rendered screenplay output (ADR 0019). Then classify through the
        // real shared FountainTokenizer (the same parser the editor and phone
        // use) and map its elements into publish `FountainNode`s, so published
        // PDF/EPUB output classifies exactly as the on-screen editor does. This
        // omits author-only content (boneyard, notes, synopses, sections),
        // strips forced markers, and unlocks dual dialogue — none of which the
        // former hand-rolled classifier could do (audit A1).
        let stripped = MarkdownDisplayFilter.stripAnchors(text)
        return FountainNodeMapper.map(FountainTokenizer().parse(stripped))
            .map(ProjectAST.Node.fountain)
    }
}
