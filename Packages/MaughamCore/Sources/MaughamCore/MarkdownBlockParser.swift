import Foundation

/// A single block-level Markdown element. `table`/`soloImage` carry their
/// raw source lines so a consumer that doesn't render them (e.g. publish)
/// can degrade them to literal paragraph text byte-identically.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(lines: [String])              // raw untrimmed lines
    case list(ordered: Bool, items: [[String]])  // raw lines per item (first line = marker-stripped content)
    case fence(lines: [String], info: String?)   // raw verbatim lines; fence lines dropped
    case table(header: [String], rows: [[String]], rawLines: [String]) // rawLines = original source incl. delimiter row
    indirect case blockquote(blocks: [MarkdownBlock])
    case thematicBreak
    case soloImage(altText: String, path: String, rawLine: String)     // ./-relative whole-line image
}

/// Shared block-level Markdown parser: one line-oriented state machine
/// replacing the hand-rolled splitters previously duplicated across
/// publish/editor/phone surfaces. This task implements headings,
/// paragraphs, and thematic breaks; list/fence/quote/table/image
/// recognition land in later tasks — until then those inputs fall through
/// to paragraph accumulation.
public enum MarkdownBlockParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // Thematic break BEFORE heading check — a bare `###` is an
            // ornament, not an H3.
            if isThematicBreakLine(trimmed) {
                blocks.append(.thematicBreak); i += 1; continue
            }

            // ATX heading: `#`..`######` then required whitespace then
            // non-empty content. 7+ `#` falls through to paragraph.
            if let (level, content) = parseHeading(trimmed) {
                blocks.append(.heading(level: level, text: content))
                i += 1; continue
            }

            // Paragraph: gather consecutive raw lines until a blank line
            // or the start of another block kind.
            var paraLines: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || isThematicBreakLine(t) || parseHeading(t) != nil { break }
                paraLines.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(lines: paraLines))
        }
        return blocks
    }

    /// A line of only `-` (count >= 3), or exactly `***`, or exactly `###`
    /// (spaces stripped first) — mirrors the editor's scene-break rule.
    private static func isThematicBreakLine(_ trimmed: String) -> Bool {
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        if stripped == "***" || stripped == "###" { return true }
        return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
    }

    /// Parse an ATX-heading line. Returns nil unless there is whitespace
    /// after a run of 1–6 `#` and non-empty content after it.
    private static func parseHeading(_ trimmed: String) -> (level: Int, content: String)? {
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let after = String(trimmed.dropFirst(level))
        guard after.hasPrefix(" ") || after.hasPrefix("\t") else { return nil }
        let content = after.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (level, content)
    }
}
