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
        func orderedPieces() -> [PieceRef]
    }

    public static func build(from source: Source) -> ProjectAST {
        let sections = source.orderedPieces().map(buildSection(from:))
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
        // truth, then run a line-oriented block parser (headings, blockquotes,
        // scene breaks, multi-line paragraphs).
        let stripped = MarkdownDisplayFilter.stripAnchors(text)
        let lines = stripped.components(separatedBy: "\n")
        return parseProseBlocks(lines).map(ProjectAST.Node.prose)
    }

    /// Block-level state machine over raw lines. Recurses for blockquote
    /// bodies, which is why it returns `[ProseNode]` rather than `[Node]`.
    private static func parseProseBlocks(_ lines: [String]) -> [ProjectAST.ProseNode] {
        var nodes: [ProjectAST.ProseNode] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // Scene break (a line of only * / - / # ornament) — checked
            // before headings so a bare `###` is an ornament, not a heading.
            if isSceneBreakLine(trimmed) {
                nodes.append(.sceneBreak); i += 1; continue
            }

            // ATX heading: `#`..`######` then a space then content.
            if let (level, rest) = parseHeading(trimmed) {
                nodes.append(.heading(level: level, InlineParser.parse(rest)))
                i += 1; continue
            }

            // Blockquote: consecutive `>`-prefixed lines, recursively parsed.
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoteLines.append(stripQuoteMarker(lines[i]))
                    i += 1
                }
                nodes.append(.blockquote(parseProseBlocks(quoteLines)))
                continue
            }

            // Paragraph: gather consecutive lines until a blank line or the
            // start of another block kind.
            var paraLines: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || isSceneBreakLine(t) || parseHeading(t) != nil
                    || t.hasPrefix(">") { break }
                paraLines.append(lines[i])
                i += 1
            }
            nodes.append(.paragraph(parseParagraphInlines(paraLines)))
        }
        return nodes
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

    /// Parse an ATX-heading line. Returns nil unless there is a space after
    /// the run of 1–6 `#` and non-empty content after it (so `###` alone is
    /// a scene break, not a heading).
    private static func parseHeading(_ line: String) -> (level: Int, rest: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let after = String(line.dropFirst(level))
        guard after.hasPrefix(" ") else { return nil }
        let content = after.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (level, content)
    }

    /// Strip a single leading `>` (and an optional following space) from a
    /// blockquote line, preserving inner indentation for nested quotes.
    private static func stripQuoteMarker(_ line: String) -> String {
        let trimmedLeading = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard trimmedLeading.hasPrefix(">") else { return line }
        var rest = String(trimmedLeading.dropFirst())
        if rest.hasPrefix(" ") { rest.removeFirst() }
        return rest
    }

    private static func isSceneBreakLine(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: " ", with: "")
        return stripped == "***" || stripped == "###" || stripped == "---"
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
