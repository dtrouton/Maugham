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

            // Fenced verbatim: a mangle guard, not code support — raw lines,
            // NO trimming, NO inline parsing, until the closing fence or
            // end-of-input. The fence lines themselves are dropped.
            if trimmed.hasPrefix("```") {
                var rawLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    rawLines.append(lines[i])
                    i += 1
                }
                nodes.append(.verbatim(rawLines))
                continue
            }

            // List: consecutive marker lines collect items; an INDENTED
            // non-marker, non-blank line stays inside the CURRENT item's text
            // (flat/tight nesting — YAGNI per spec ledger). A blank line ends
            // the block; so does an UNINDENTED non-marker line — that line is
            // left for the outer loop to reprocess as a normal block, so a
            // trailing scene-break/heading/blockquote reclaims it rather than
            // being swallowed as list-item text.
            // Ordered-vs-unordered is decided by the first item's marker —
            // mixing (`- a` then `2. b`) is lossy-but-intentional: the list
            // stays unordered, the later numeral is just item text.
            if let (ordered, firstContent) = parseListMarker(lines[i]) {
                var itemTexts: [String] = [firstContent]
                i += 1
                listLoop: while i < lines.count {
                    if let (_, content) = parseListMarker(lines[i]) {
                        itemTexts.append(content)
                        i += 1
                        continue
                    }
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break listLoop }
                    guard lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") else {
                        break listLoop   // unindented — end list, reprocess line
                    }
                    itemTexts[itemTexts.count - 1] += " " + t
                    i += 1
                }
                nodes.append(.list(ordered: ordered, items: itemTexts.map(InlineParser.parse)))
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

    /// Match `^\s*([-*+]|\d{1,9}[.)])\s+` and return whether the marker is
    /// ordered plus the content that follows the marker's whitespace run.
    /// Called on the SCENE-BREAK/HEADING/BLOCKQUOTE-checked remainder, so
    /// `* * *` never reaches here (scene-break claims it first).
    private static func parseListMarker(_ line: String) -> (ordered: Bool, content: String)? {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex else { return nil }

        let ordered: Bool
        if line[idx] == "-" || line[idx] == "*" || line[idx] == "+" {
            ordered = false
            idx = line.index(after: idx)
        } else if line[idx].isNumber {
            var digits = 0
            while idx < line.endIndex, line[idx].isNumber, digits < 9 {
                idx = line.index(after: idx)
                digits += 1
            }
            guard idx < line.endIndex, line[idx] == "." || line[idx] == ")" else { return nil }
            ordered = true
            idx = line.index(after: idx)
        } else {
            return nil
        }

        guard idx < line.endIndex, line[idx] == " " || line[idx] == "\t" else { return nil }
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            idx = line.index(after: idx)
        }
        return (ordered, String(line[idx...]))
    }

    private static func isSceneBreakLine(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: " ", with: "")
        if stripped == "***" || stripped == "###" { return true }
        // Editor parity: the tokenizer's rule accepts any run of 3+ dashes,
        // not just exactly `---`.
        return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
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
