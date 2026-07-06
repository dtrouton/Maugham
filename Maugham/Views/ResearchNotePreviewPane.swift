import SwiftUI
import AppKit
import MaughamCore

/// Renders a research note's Markdown text as a read-only preview pane,
/// displaying inline images referenced via Markdown ![alt](path) syntax.
/// Editor stays plain text; the writer sees the rendered version here.
///
/// Block parsing comes from the shared `MarkdownBlockParser` (MaughamCore);
/// this file adapts `MarkdownBlock` into a view-layer `Block` and renders it,
/// mirroring `GuideMarkdownView`'s adapter shape. The one wrinkle unique to
/// this pane: solo-image detection needs an actual `NSImage` load against the
/// note's on-disk directory, and (per the shared parser's grammar) a solo
/// image line that directly abuts prose with no blank line stays embedded
/// inside that `MarkdownBlock.paragraph`'s raw lines rather than splitting out
/// as its own `.soloImage` block — so `expandParagraph` re-scans a
/// paragraph's lines for embedded image references, exactly mirroring the
/// pre-cutover per-line algorithm (this is what keeps the flattened-alt
/// fallback pinned below byte-identical).
struct ResearchNotePreviewPane: View {
    let notePath: String       // e.g., "research/sarah.md"
    let projectURL: URL
    let noteText: String        // bound from the editor's text state (read-only here)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(parsedBlocks().indices, id: \.self) { i in
                    render(block: parsedBlocks()[i])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    enum Block {
        case heading(level: Int, text: String)
        case paragraph(AttributedString)
        case image(NSImage)
        case unknown(String)
        case listItem(ordered: Bool, index: Int?, text: AttributedString)
        case code(String)
        case table(header: [String], rows: [[String]])
        case quote(AttributedString)
        case divider
    }

    private func parsedBlocks() -> [Block] {
        Self.parse(text: noteText, notePath: notePath, projectURL: projectURL)
    }

    /// Exposed as `static` (rather than an instance method) so tests can drive
    /// the parse step directly, mirroring `GuideMarkdownView.parse`.
    static func parse(text: String, notePath: String, projectURL: URL) -> [Block] {
        let noteDir = projectURL
            .appendingPathComponent(notePath)
            .deletingLastPathComponent()
        return MarkdownBlockParser.parse(text).flatMap { expand($0, noteDir: noteDir) }
    }

    /// Maps one `MarkdownBlock` to zero or more `Block`s. `.paragraph` and
    /// `.list` are the cases that can expand to N blocks.
    private static func expand(_ block: MarkdownBlock, noteDir: URL) -> [Block] {
        switch block {
        case .heading(let level, let text):
            return [.heading(level: level, text: text)]
        case .paragraph(let lines):
            return expandParagraph(lines, noteDir: noteDir)
        case .soloImage(_, let path, let rawLine):
            if let img = loadImage(relativePath: path, noteDir: noteDir) {
                return [.image(img)]
            }
            return [attributedParagraph(rawLine)]
        case .list(let ordered, let items):
            return items.enumerated().map { offset, lines in
                .listItem(
                    ordered: ordered,
                    index: ordered ? offset + 1 : nil,
                    text: markdownAttr(reflowListItem(lines)))
            }
        case .fence(let lines, _):
            return [.code(lines.joined(separator: "\n"))]
        case .table(let header, let rows, _):
            return [.table(header: header, rows: rows)]
        case .thematicBreak:
            return [.divider]
        case .blockquote(let inner):
            let flattened = flattenQuote(inner)
            return flattened.isEmpty ? [] : [.quote(markdownAttr(flattened))]
        }
    }

    /// Re-scans a paragraph block's raw lines for embedded solo-image
    /// references, verbatim port of the pre-cutover per-line loop: a line
    /// whose image loads flushes the buffered text and becomes its own
    /// `.image` block; a line that matches the image syntax but fails to
    /// load (missing file) falls through and joins the paragraph buffer as
    /// plain text, same as any other line — `AttributedString(markdown:)`
    /// then renders only its alt text, not the raw source line.
    private static func expandParagraph(_ lines: [String], noteDir: URL) -> [Block] {
        var result: [Block] = []
        var buffer: [String] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            let joined = buffer.joined(separator: " ")
            buffer.removeAll()
            result.append(attributedParagraph(joined))
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let path = soloImagePath(inLine: trimmed),
               let img = loadImage(relativePath: path, noteDir: noteDir) {
                flush()
                result.append(.image(img))
                continue
            }
            buffer.append(trimmed)
        }
        flush()
        return result
    }

    private static let soloImageLineRegex = try? NSRegularExpression(
        pattern: #"^!\[.*?\]\((\.[/][^)]+)\)$"#)

    /// Matches a whole trimmed line as a `./`-relative solo image reference,
    /// returning its path. Verbatim port of the pre-cutover regex.
    private static func soloImagePath(inLine trimmed: String) -> String? {
        guard let regex = soloImageLineRegex else { return nil }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              match.numberOfRanges >= 2 else { return nil }
        return (trimmed as NSString).substring(with: match.range(at: 1))
    }

    private static func loadImage(relativePath: String, noteDir: URL) -> NSImage? {
        let trimmedRel = relativePath.hasPrefix("./")
            ? String(relativePath.dropFirst(2))
            : relativePath
        let imageURL = noteDir.appendingPathComponent(trimmedRel)
        return NSImage(contentsOf: imageURL)
    }

    private static func attributedParagraph(_ joined: String) -> Block {
        if let attr = try? AttributedString(markdown: joined) {
            return .paragraph(attr)
        } else {
            return .unknown(joined)
        }
    }

    private static func markdownAttr(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private static func reflowListItem(_ lines: [String]) -> String {
        lines.enumerated()
            .map { index, line in index == 0 ? line : line.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    /// Nested blocks beyond a plain paragraph are flattened to their text and
    /// space-joined — this is a glance surface (research note preview), not a
    /// full nested-quote renderer (YAGNI). Mirrors `GuideMarkdownView.flattenQuote`.
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

    @ViewBuilder
    private func render(block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(forLevel: level))
                .fontWeight(.bold)
                .padding(.top, level == 1 ? 8 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let attr):
            Text(attr)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image(let img):
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .unknown(let raw):
            Text(raw)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        case .listItem(let ordered, let index, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if ordered, let index {
                    Text("\(index).")
                } else {
                    Text("•")
                }
                Text(text)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        case .table(let header, let rows):
            renderTable(header: header, rows: rows)
        case .quote(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(text)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .divider:
            Divider()
        }
    }

    @ViewBuilder
    private func renderTable(header: [String], rows: [[String]]) -> some View {
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

    private func headingFont(forLevel level: Int) -> Font {
        switch level {
        case 1:  return .title
        case 2:  return .title2
        case 3:  return .title3
        case 4:  return .headline
        default: return .subheadline
        }
    }
}
