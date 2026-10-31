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
        /// A figure line (`![caption](path)`), recognised by Core's
        /// `ManuscriptBlocks` with its `{#fig:…}`/`{#tbl:…}` label split off.
        case figure(caption: String, path: String, label: ManuscriptLabel?)
        /// A pipe table's `Table:` caption, under its table: styled as a
        /// caption, like a figure's, with inline emphasis.
        case caption(String)
    }

    static func parse(_ markdown: String) -> [Block] {
        ManuscriptBlocks.parse(markdown).flatMap { adaptManuscript($0.block) }
    }

    /// The report layer's blocks (Core's `ManuscriptBlocks`, the recogniser
    /// Publish and the Mac use): labels never reach the screen, a figure line
    /// is a `.figure`, a table's `Table:` caption shows as a `.caption` under it.
    private static func adaptManuscript(_ b: ManuscriptBlock) -> [Block] {
        switch b {
        case .heading(let level, let text, _): return [.heading(level: level, text: text)]
        case .table(let header, _, let rows, let caption, _):
            let table = Block.table(header: header, rows: rows)
            if let caption, !caption.isEmpty { return [table, .caption(caption)] }
            return [table]
        case .figure(let caption, let path, let label):
            return [.figure(caption: caption, path: path, label: label)]
        case .footnoteDefinition(let label, let text):
            return [.paragraph("[^\(label)]: \(text)")]
        case .other(let block): return adapt(block).map { [$0] } ?? []
        }
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
