import SwiftUI
import MaughamCore

/// Read-only markdown renderer for bundled help topics. Block parsing comes
/// from the shared `MarkdownBlockParser` (MaughamCore); this file only adapts
/// `MarkdownBlock` into a view-layer `Block` and renders it. No project-
/// relative image resolution — a solo image degrades to its raw source line.
struct GuideMarkdownView: View {
    let markdown: String

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case orderedItem(number: String, text: String)
        case table(header: [String], rows: [[String]])
        case code(String)
        /// Grammar upgrade over the old local parser, which rendered a
        /// blockquote as unstyled paragraph text (audit section E row 6).
        /// Matches the phone reader's quote treatment.
        case quote(String)
        case divider
    }

    static func parse(_ text: String) -> [Block] {
        MarkdownBlockParser.parse(text).flatMap(expand)
    }

    /// Maps one `MarkdownBlock` to zero or more `Block`s. `.list` is the one
    /// case that expands to N blocks (one per item); every other case maps
    /// to at most one.
    private static func expand(_ block: MarkdownBlock) -> [Block] {
        switch block {
        case .heading(let level, let text):
            return [.heading(level: level, text: text)]
        case .paragraph(let lines):
            // Reflow: a hard-wrapped source paragraph collapses to one line
            // (today's rule, unchanged from the pre-shared-parser adapter).
            let joined = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return joined.isEmpty ? [] : [.paragraph(joined)]
        case .list(let ordered, let items):
            let texts = items.map(reflowListItem)
            if ordered {
                // The shared parser's `.list` doesn't retain source marker
                // digits, so numbers regenerate sequentially from position
                // rather than round-tripping the source (e.g. a list resuming
                // at "10)" renders as "1." — see task-7 report).
                return texts.enumerated().map { .orderedItem(number: "\($0.offset + 1)", text: $0.element) }
            } else {
                return texts.map { .bullet($0) }
            }
        case .fence(let lines, _):
            return [.code(lines.joined(separator: "\n"))]
        case .table(let header, let rows, _):
            return [.table(header: header, rows: rows)]
        case .thematicBreak:
            return [.divider]
        case .soloImage(_, _, let rawLine):
            return [.paragraph(rawLine)]
        case .blockquote(let inner):
            let text = flattenQuote(inner)
            return text.isEmpty ? [] : [.quote(text)]
        }
    }

    private static func reflowListItem(_ lines: [String]) -> String {
        lines.enumerated()
            .map { index, line in index == 0 ? line : line.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    /// Nested blocks beyond a plain paragraph are flattened to their text and
    /// space-joined — this is a glance surface (Help window), not a full
    /// nested-quote renderer (YAGNI).
    private static func flattenQuote(_ blocks: [MarkdownBlock]) -> String {
        blocks.flatMap { inner -> [String] in
            switch inner {
            case .paragraph(let lines):
                let joined = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                return joined.isEmpty ? [] : [joined]
            case .heading(_, let text): return [text]
            case .list(_, let items): return items.map(reflowListItem)
            case .fence(let lines, _): return [lines.joined(separator: " ")]
            case .blockquote(let nested): return [flattenQuote(nested)]
            case .table, .thematicBreak: return []
            case .soloImage(_, _, let rawLine): return [rawLine]
            }
        }.joined(separator: " ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                    render(block)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    @ViewBuilder private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level)).fontWeight(.semibold)
                .padding(.top, level <= 2 ? 10 : 4)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .textSelection(.enabled)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            }.textSelection(.enabled)
        case .orderedItem(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            }.textSelection(.enabled)
        case .table(let header, let rows):
            renderTable(header: header, rows: rows)
        case .code(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        case .quote(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        case .divider:
            Divider()
        }
    }

    @ViewBuilder private func renderTable(header: [String], rows: [[String]]) -> some View {
        let hasHeaderText = header.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
            if hasHeaderText {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        tableCellText(cell).fontWeight(.semibold)
                    }
                }
                Divider()
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        tableCellText(cell)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func tableCellText(_ cell: String) -> Text {
        Text((try? AttributedString(markdown: cell)) ?? AttributedString(cell))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level { case 1: return .title; case 2: return .title2; case 3: return .title3; default: return .headline }
    }
}
