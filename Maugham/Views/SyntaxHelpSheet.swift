import SwiftUI
import MaughamCore

public enum SyntaxHelpMode {
    case prose
    case screenplay
}

// MARK: - Block model

enum HelpBlock {
    case heading(level: Int, text: String)
    case paragraph(text: AttributedString)
    case codeBlock(text: String)
    case bullet(text: AttributedString)
    /// The curated content's one real GFM table (markdown-syntax.md's Smart
    /// typography section) — cells rendered inline-markdown at render time.
    case table(header: [String], rows: [[String]])
}

// MARK: - Main view

struct SyntaxHelpSheet: View {
    let mode: SyntaxHelpMode
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Tab

    enum Tab: String, Hashable {
        case markdown, fountain, keyboard
    }

    init(mode: SyntaxHelpMode) {
        self.mode = mode
        switch mode {
        case .prose:      self._selectedTab = State(initialValue: .markdown)
        case .screenplay: self._selectedTab = State(initialValue: .fountain)
        }
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                SyntaxHelpBlocksView(mode: .prose)
                    .tabItem { Text("Markdown") }
                    .tag(Tab.markdown)
                SyntaxHelpBlocksView(mode: .screenplay)
                    .tabItem { Text("Fountain") }
                    .tag(Tab.fountain)
                KeyboardCheatsheetView()
                    .tabItem { Text("Keyboard") }
                    .tag(Tab.keyboard)
            }
            .padding(.top, 8)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .navigationTitle("Reference")
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: - Content loading

    static func loadContent(mode: SyntaxHelpMode) -> [HelpBlock] {
        let resourceName: String
        switch mode {
        case .prose:        resourceName = "markdown-syntax"
        case .screenplay:   resourceName = "fountain-syntax"
        }
        guard let url = Bundle.main.url(
                forResource: resourceName, withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {  // adr-0018-ok: bundled syntax-help doc read, not manuscript
            return [.paragraph(text: AttributedString("Help content unavailable."))]
        }
        return parseMarkdownBlocks(raw)
    }

    // MARK: - Block parser

    /// Block parsing comes from the shared `MarkdownBlockParser`
    /// (MaughamCore); this only maps `MarkdownBlock` into the view-layer
    /// `HelpBlock`. The curated content (`markdown-syntax.md`,
    /// `fountain-syntax.md`) uses headings, paragraphs, fences, unordered
    /// bullet lists, and one GFM table — those map directly. Ordered lists,
    /// blockquotes, thematic breaks, and solo images don't appear in the
    /// curated content; they degrade to visible text (bullet/paragraph)
    /// rather than dropping silently, per `expand`'s fallback cases below.
    static func parseMarkdownBlocks(_ raw: String) -> [HelpBlock] {
        MarkdownBlockParser.parse(raw).flatMap(expand)
    }

    private static func expand(_ block: MarkdownBlock) -> [HelpBlock] {
        switch block {
        case .heading(let level, let text):
            return [.heading(level: level, text: text)]
        case .paragraph(let lines):
            let joined = lines.map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return joined.isEmpty ? [] : [.paragraph(text: parseInline(joined))]
        case .list(_, let items):
            // Both ordered and unordered render as bullets: the curated
            // content has no ordered list, so there's no source numbering
            // to preserve — a bullet keeps the item visible rather than
            // inventing an ordinal case nothing uses (see task-9 report).
            return items.map { .bullet(text: parseInline(reflowListItem($0))) }
        case .fence(let lines, _):
            return [.codeBlock(text: lines.joined(separator: "\n"))]
        case .table(let header, let rows, _):
            return [.table(header: header, rows: rows)]
        case .thematicBreak:
            // Not used by the curated content; degrades to visible text
            // rather than vanishing between two blocks.
            return [.paragraph(text: AttributedString("—"))]
        case .soloImage(_, _, let rawLine):
            return [.paragraph(text: parseInline(rawLine))]
        case .blockquote(let inner):
            let text = flattenQuote(inner)
            return text.isEmpty ? [] : [.paragraph(text: parseInline(text))]
        }
    }

    private static func reflowListItem(_ lines: [String]) -> String {
        lines.enumerated()
            .map { index, line in index == 0 ? line : line.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    /// Not exercised by the curated content (no nested blockquote), but
    /// keeps a blockquote from dropping silently if one is ever added.
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

    // MARK: - Inline markdown helper

    static func parseInline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

// MARK: - Per-mode blocks view

/// Renders a single help mode's blocks. Used inside each tab of SyntaxHelpSheet.
private struct SyntaxHelpBlocksView: View {
    let mode: SyntaxHelpMode
    @State private var blocks: [HelpBlock] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(for: block)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .task(id: mode) {
            blocks = SyntaxHelpSheet.loadContent(mode: mode)
        }
    }

    @ViewBuilder
    private func blockView(for block: HelpBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let attributed):
            Text(attributed)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .codeBlock(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(6)
        case .bullet(let attributed):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.body)
                Text(attributed)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        }
    }

    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(SyntaxHelpSheet.parseInline(cell)).fontWeight(.semibold)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(SyntaxHelpSheet.parseInline(cell))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        switch level {
        case 1:
            Text(text).font(.title2).bold().padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        case 2:
            Text(text).font(.title3).bold().padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        case 3:
            Text(text).font(.headline).padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Text(text).font(.subheadline).bold()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
