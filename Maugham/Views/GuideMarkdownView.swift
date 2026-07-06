import SwiftUI

/// Read-only markdown renderer for bundled help topics. Block parser mirrors
/// `ResearchNotePreviewPane` (headings + inline-markdown paragraphs) plus
/// bullets, ordered lists, pipe tables, and fenced code; no project-relative
/// image resolution.
///
/// The `orderedItem`/`table` parsing and rendering added here are deliberately
/// thin patches against the shipped `docs/guide/*.md` corpus (audit A3) — a
/// future shared block parser may replace this file; keep new parsing logic
/// testable as pure functions on `Block`.
struct GuideMarkdownView: View {
    let markdown: String

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case orderedItem(number: String, text: String)
        case table(header: [String], rows: [[String]])
        case code(String)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var inCode = false
        var codeLines: [String] = []
        // Consecutive plain lines reflow into one paragraph (Markdown semantics:
        // a hard-wrapped source paragraph is a single paragraph; line breaks
        // collapse to spaces). Flushed on a blank line, heading, bullet, code
        // fence, or end of input — otherwise every wrapped source line would
        // render as its own line.
        var para: [String] = []
        func flushParagraph() {
            if !para.isEmpty {
                blocks.append(.paragraph(para.joined(separator: " ")))
                para.removeAll()
            }
        }

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let raw = lines[i]

            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                } else {
                    flushParagraph()
                }
                inCode.toggle()
                i += 1
                continue
            }
            if inCode { codeLines.append(raw); i += 1; continue }

            var trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Blockquote: render the quote as ordinary paragraph text (no
            // dedicated quote styling on this read-only surface).
            if trimmed.hasPrefix(">") {
                trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { i += 1; continue }
            }

            if trimmed.hasPrefix("#") {
                flushParagraph()
                let hashes = trimmed.prefix { $0 == "#" }.count
                let body = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(hashes, 6), text: body))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else if let item = matchOrderedItem(trimmed) {
                flushParagraph()
                blocks.append(.orderedItem(number: item.number, text: item.text))
            } else if trimmed.contains("|"), i + 1 < lines.count,
                      isTableDelimiterRow(lines[i + 1]) {
                flushParagraph()
                let header = splitTableRow(trimmed)
                var rows: [[String]] = []
                i += 2 // header line + delimiter line
                while i < lines.count {
                    let rowTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if rowTrimmed.isEmpty || !rowTrimmed.contains("|") { break }
                    rows.append(splitTableRow(rowTrimmed))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue // `i` already advanced past the consumed rows
            } else {
                para.append(trimmed)
            }
            i += 1
        }
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    /// Matches a trimmed line starting with `1.` / `1)` (1-9 digits, then `.`
    /// or `)`, then whitespace), returning the marker digits and remaining text.
    private static func matchOrderedItem(_ trimmed: String) -> (number: String, text: String)? {
        guard let match = trimmed.range(of: #"^\d{1,9}[.)]\s+"#, options: .regularExpression) else { return nil }
        let marker = trimmed[match]
        let number = String(marker.prefix { $0.isNumber })
        let text = String(trimmed[match.upperBound...])
        return (number, text)
    }

    /// A GFM-style delimiter row: pipe-separated cells each matching `:?-+:?`.
    private static func isTableDelimiterRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            var s = Substring(cell)
            if s.first == ":" { s.removeFirst() }
            if s.last == ":" { s.removeLast() }
            return !s.isEmpty && s.allSatisfy { $0 == "-" }
        }
    }

    /// Splits a table row on unescaped `|`, trims each cell, and drops a
    /// leading/trailing empty cell produced by enclosing pipes (`| a | b |`).
    private static func splitTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        let chars = Array(line)
        var idx = 0
        while idx < chars.count {
            if chars[idx] == "\\", idx + 1 < chars.count, chars[idx + 1] == "|" {
                current.append("|")
                idx += 2
                continue
            }
            if chars[idx] == "|" {
                cells.append(current)
                current = ""
                idx += 1
                continue
            }
            current.append(chars[idx])
            idx += 1
        }
        cells.append(current)
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeFirst()
        }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
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
