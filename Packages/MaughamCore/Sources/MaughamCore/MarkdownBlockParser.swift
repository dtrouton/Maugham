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
/// publish/editor/phone surfaces. Block precedence, checked top of loop:
/// fence → blank → thematic break → heading → blockquote → table → list →
/// solo image → paragraph.
public enum MarkdownBlockParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            // Fence FIRST of all — its interior suppresses every other rule,
            // including blank-line paragraph breaks.
            if trimmed.hasPrefix("```") {
                let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
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
                blocks.append(.fence(lines: rawLines, info: info.isEmpty ? nil : info))
                continue
            }

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

            // Blockquote: consecutive `>`-prefixed lines, marker-stripped and
            // recursively parsed. No lazy continuation — a non-`>` line ends
            // the quote and is left for the outer loop to reprocess.
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoteLines.append(stripQuoteMarker(lines[i]))
                    i += 1
                }
                blocks.append(.blockquote(blocks: parse(quoteLines.joined(separator: "\n"))))
                continue
            }

            // Table: a `|`-containing line followed by a GFM delimiter row.
            // Checked BEFORE list so `| a | b |` never falls into list/paragraph.
            if trimmed.contains("|"), i + 1 < lines.count,
               isTableDelimiterRow(lines[i + 1]) {
                let header = splitTableRow(trimmed)
                var rawLines = [lines[i], lines[i + 1]]
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.contains("|"), !t.isEmpty else { break }
                    rows.append(splitTableRow(t))
                    rawLines.append(lines[i])
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows, rawLines: rawLines))
                continue
            }

            // List: consecutive marker lines collect items. An INDENTED
            // non-marker, non-blank line stays inside the current item's
            // text. A blank line ends the block; so does an UNINDENTED
            // non-marker line — that line is left for the outer loop to
            // reprocess as a normal block (verbatim port of
            // ProjectASTBuilder.parseProseBlocks's list loop).
            if let (ordered, firstContent) = parseListMarker(lines[i]) {
                var items: [[String]] = [[firstContent]]
                i += 1
                listLoop: while i < lines.count {
                    if let (_, content) = parseListMarker(lines[i]) {
                        items.append([content])
                        i += 1
                        continue
                    }
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break listLoop }
                    guard lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") else {
                        break listLoop   // unindented — end list, reprocess line
                    }
                    items[items.count - 1].append(lines[i])
                    i += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            // Solo image: whole trimmed line is a `![alt](./relative/path)`
            // reference — never a remote URL. Checked before paragraph
            // accumulation so it isn't swallowed as prose.
            if let (altText, path) = matchSoloImage(trimmed) {
                blocks.append(.soloImage(altText: altText, path: path, rawLine: lines[i]))
                i += 1; continue
            }

            // Paragraph: gather consecutive raw lines until a blank line
            // or the start of another block kind. Quote is the ONLY new
            // block kind that interrupts accumulation without a blank line
            // — a verbatim port of ProjectASTBuilder's paragraph loop. Table
            // and solo image do NOT interrupt accumulation: a table/image line
            // FOLLOWING prose (e.g. `text\n| a | b |`) stays in the one
            // paragraph, byte-for-byte with publish's old paragraph loop. A
            // LEADING table/image block followed by prose is different: it is
            // claimed as its own block at the top of the loop, so the trailing
            // prose becomes a SEPARATE paragraph. That split is an intentional,
            // ledger-sanctioned deviation from the old glue (Task 5 review,
            // option (a): uniform block grammar over re-gluing) — locked by the
            // split pins in ProjectASTBuilderTests.
            var paraLines: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || isThematicBreakLine(t) || parseHeading(t) != nil
                    || t.hasPrefix(">") {
                    break
                }
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

    /// Match `^\s*([-*+]|\d{1,9}[.)])\s+` and return whether the marker is
    /// ordered plus the content that follows the marker's whitespace run.
    /// Verbatim port of `ProjectASTBuilder.parseListMarker`. Called after
    /// the thematic-break check, so `* * *` never reaches here.
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

    /// Strip leading whitespace, one `>`, and one optional following space.
    /// Verbatim port of `ProjectASTBuilder.stripQuoteMarker`.
    private static func stripQuoteMarker(_ line: String) -> String {
        let trimmedLeading = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard trimmedLeading.hasPrefix(">") else { return line }
        var rest = String(trimmedLeading.dropFirst())
        if rest.hasPrefix(" ") { rest.removeFirst() }
        return rest
    }

    /// A GFM-style delimiter row: pipe-separated cells each matching `:?-+:?`.
    /// Verbatim port of `GuideMarkdownView.isTableDelimiterRow`.
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
    /// Verbatim port of `GuideMarkdownView.splitTableRow`.
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

    /// Matches a whole trimmed line as a `./`-relative solo image reference,
    /// returning its alt text and path. Public so consumers that need to
    /// detect an embedded (non-block-start) solo-image line — e.g.
    /// `ResearchNotePreviewPane` re-scanning a `.paragraph` block's raw lines
    /// for a same-run image reference — share this one regex instead of
    /// keeping a second copy.
    public static func matchSoloImage(_ trimmed: String) -> (altText: String, path: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^!\[(.*?)\]\((\.[/][^)]+)\)$"#) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let altRange = Range(match.range(at: 1), in: trimmed),
              let pathRange = Range(match.range(at: 2), in: trimmed) else { return nil }
        return (String(trimmed[altRange]), String(trimmed[pathRange]))
    }

    /// Every `![alt](path)` occurrence anywhere in `text`, in document order —
    /// an unanchored scan, unlike `matchSoloImage` above (whole-line, `./`-relative
    /// only). Shared home for consumers harvesting images embedded alongside other
    /// content in a run of text, e.g. `PaletteCard`'s `## Images` section (which may
    /// mix dash items, prose, and inline image references on the same or different
    /// lines) — one regex instead of a second hand-rolled copy per caller.
    public static func findInlineImages(in text: String) -> [(altText: String, path: String)] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[(.*?)\]\(([^)]+)\)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let altRange = Range(match.range(at: 1), in: text),
                  let pathRange = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[altRange]), String(text[pathRange]))
        }
    }
}
