import Foundation
import MaughamCore

/// View-layer block currency for the reader, adapted from the shared
/// `MarkdownBlockParser` (MaughamCore) so paragraph breaks, headings, lists,
/// fences, tables, blockquotes, and thematic breaks all survive.
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
        /// the view applies it inline). Lines are joined with "\n" — manuscript
        /// line breaks are preserved, not reflowed.
        case paragraph(String)
        case list(ordered: Bool, items: [String])
        /// Verbatim fence content — no inline emphasis interpretation.
        case code(String)
        case table(header: [String], rows: [[String]])
        case quote([Block])
        case divider
    }

    static func parse(_ markdown: String) -> [Block] {
        MarkdownBlockParser.parse(markdown).compactMap(adapt)
    }

    private static func adapt(_ b: MarkdownBlock) -> Block? {
        switch b {
        case .heading(let l, let t): return .heading(level: l, text: t)
        case .paragraph(let lines):
            let joined = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : .paragraph(joined)
        case .list(let o, let items):
            return .list(ordered: o, items: items.map { item in
                item.enumerated().map { i, l in i == 0 ? l : l.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
            })
        case .fence(let lines, _): return .code(lines.joined(separator: "\n"))
        case .table(let h, let r, _): return .table(header: h, rows: r)
        case .blockquote(let inner): return .quote(inner.compactMap(adapt))
        case .thematicBreak: return .divider
        case .soloImage(_, _, let raw): return .paragraph(raw)   // phone renders no images (existing behavior)
        }
    }
}
