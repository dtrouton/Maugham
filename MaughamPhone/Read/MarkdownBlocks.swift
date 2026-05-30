import Foundation

/// Splits anchor-stripped manuscript markdown into block elements so the reader
/// can render real paragraph breaks + heading hierarchy.
///
/// `AttributedString(markdown:)` alone is unsuitable for a reader: with
/// `.full` it concatenates every block (heading + paragraphs) into one run with
/// no line breaks ("Chapter 1The sun…harbor.She watched…"); with
/// `.inlineOnlyPreservingWhitespace` it keeps whitespace but drops heading
/// styling. So we split into blocks here and let the view render each one,
/// applying inline emphasis per-paragraph via `AttributedString(markdown:)`.
enum MarkdownBlocks {
    enum Block: Equatable {
        /// An ATX heading: `level` 1–6, `text` is the content after the `#`s.
        case heading(level: Int, text: String)
        /// A paragraph of markdown (inline emphasis like `*x*`/`**x**` intact;
        /// the view applies it inline). May span multiple soft-wrapped lines.
        case paragraph(String)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            // An ATX heading is its own block (even without a surrounding blank
            // line) so it never glues onto adjacent prose.
            if let range = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushParagraph()
                let level = trimmed[range].filter { $0 == "#" }.count
                let text = String(trimmed[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: text))
            } else {
                paragraph.append(rawLine)
            }
        }
        flushParagraph()
        return blocks
    }
}
