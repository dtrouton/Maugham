import Foundation

/// A manuscript block as the report layer reads it: the report elements
/// (labelled headings, captioned tables, figures, footnote definitions),
/// and every other `MarkdownBlock` passed through unchanged.
/// A label may be of the wrong kind for its element; it is kept on purpose so
/// the index can diagnose it.
public enum ManuscriptBlock: Equatable, Sendable {
    /// An ATX heading; `label` comes from a trailing `{#kind:name}`.
    case heading(level: Int, text: String, label: ManuscriptLabel?)
    /// A pipe table; `caption` and `label` come from the `Table:` line under it.
    case table(header: [String], rows: [[String]], caption: String?, label: ManuscriptLabel?)
    /// `![caption](path)` alone on a line. The path is not validated; the
    /// index judges it.
    case figure(caption: String, path: String, label: ManuscriptLabel?)
    /// `[^label]: text`, with any continuation lines joined by `"\n"`.
    case footnoteDefinition(label: String, text: String)
    /// Any other parser block, unchanged.
    case other(MarkdownBlock)
}

/// The report block layer over `MarkdownBlockParser`. It only re-reads the
/// parser's blocks; it never changes how the parser splits the text.
public enum ManuscriptBlocks {
    /// Parses `text` into manuscript blocks with their source line ranges.
    /// A label of the wrong kind for its element is kept, not dropped.
    public static func parse(_ text: String) -> [(block: ManuscriptBlock, lines: Range<Int>)] {
        let base = MarkdownBlockParser.parseWithLineRanges(text)
        var out: [(block: ManuscriptBlock, lines: Range<Int>)] = []
        var i = 0
        while i < base.count {
            let (block, lines) = base[i]
            i += 1
            switch block {
            case .heading(let level, let headingText):
                let split = ManuscriptAttributes.split(headingText)
                out.append((.heading(level: level, text: split.text, label: split.label), lines))

            case .table(let header, var rows, let rawLines):
                // The parser keeps a `Table: a | b` caption as a row; take it back.
                if !rows.isEmpty, let last = rawLines.last,
                   let caption = captionLine(last) {
                    rows.removeLast()
                    out.append((.table(header: header, rows: rows,
                                       caption: caption.text, label: caption.label), lines))
                } else if i < base.count, let caption = tableCaption(base[i], after: lines) {
                    out.append((.table(header: header, rows: rows,
                                       caption: caption.text, label: caption.label),
                                lines.lowerBound..<base[i].lines.upperBound))
                    i += 1
                } else {
                    out.append((.table(header: header, rows: rows, caption: nil, label: nil), lines))
                }

            case .soloImage(_, _, let rawLine):
                // The parser's image rule is looser than ours (two images on
                // one line pass it); read the raw line by the figure rule.
                out.append((figure(rawLine) ?? .other(block), lines))

            case .paragraph(let paraLines):
                if paraLines.count == 1, let figure = figure(paraLines[0]) {
                    out.append((figure, lines))
                } else if let notes = footnoteDefinitions(paraLines, lines) {
                    out.append(contentsOf: notes)
                } else {
                    out.append((.other(block), lines))
                }

            default:
                out.append((.other(block), lines))
            }
        }
        return out
    }

    /// A one-line paragraph starting right below the table with `Table: `.
    /// A longer paragraph is left alone so no line is hidden.
    private static func tableCaption(
        _ next: (block: MarkdownBlock, lines: Range<Int>), after table: Range<Int>
    ) -> (text: String, label: ManuscriptLabel?)? {
        guard next.lines.lowerBound == table.upperBound,
              case .paragraph(let lines) = next.block, lines.count == 1 else { return nil }
        return captionLine(lines[0])
    }

    /// A raw line that, trimmed, starts with `Table: `, read as a caption.
    private static func captionLine(_ raw: String) -> (text: String, label: ManuscriptLabel?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Table: ") else { return nil }
        let split = ManuscriptAttributes.split(String(trimmed.dropFirst("Table: ".count)))
        return (split.text.trimmingCharacters(in: .whitespaces), split.label)
    }

    // The caption may contain `]` but not `](`, so two images on a line never
    // read as one. The path stops at whitespace.
    static let imageRegex = try! NSRegularExpression(
        pattern: #"^!\[((?:[^\]]|\](?!\())*)\]\(([^)\s]+)\)$"#)

    /// The footnote label rule (any label, per the spec). The inline
    /// `[^label]` scanner reuses this; never spell it again.
    public static let footnoteLabelPattern = "[A-Za-z0-9_-]+"

    /// True when `label` is a valid footnote label.
    public static func isValidFootnoteLabel(_ label: String) -> Bool {
        match(footnoteLabelRegex, label) != nil
    }

    private static let footnoteLabelRegex = try! NSRegularExpression(
        pattern: "^" + footnoteLabelPattern + "$")

    private static let footnoteRegex = try! NSRegularExpression(
        pattern: #"^\[\^("# + footnoteLabelPattern + #")\]:\s?(.*)$"#)

    /// `![caption](path)` alone on the line, optionally followed by any valid
    /// `{#kind:name}` block. An invalid block stays in the text, so no match.
    private static func figure(_ line: String) -> ManuscriptBlock? {
        let split = ManuscriptAttributes.split(line.trimmingCharacters(in: .whitespaces))
        guard let groups = match(imageRegex, split.text) else { return nil }
        return .figure(caption: groups[0], path: groups[1], label: split.label)
    }

    /// A paragraph whose first line is `[^label]:`. A later line that is also
    /// a definition starts a new one, each with its own sub-range.
    private static func footnoteDefinitions(
        _ lines: [String], _ range: Range<Int>
    ) -> [(block: ManuscriptBlock, lines: Range<Int>)]? {
        let heads = lines.map { match(footnoteRegex, $0.trimmingCharacters(in: .whitespaces)) }
        guard heads.first != nil, heads[0] != nil else { return nil }
        var out: [(block: ManuscriptBlock, lines: Range<Int>)] = []
        var start = 0
        while start < lines.count {
            let groups = heads[start]!
            var end = start + 1
            while end < lines.count, heads[end] == nil { end += 1 }
            let first = String(groups[1].drop(while: { $0 == " " || $0 == "\t" }))
            let rest = lines[(start + 1)..<end].map {
                String($0.drop(while: { $0 == " " || $0 == "\t" }))
            }
            let text = (first.isEmpty ? rest : [first] + rest).joined(separator: "\n")
            out.append((.footnoteDefinition(label: groups[0], text: text),
                        (range.lowerBound + start)..<(range.lowerBound + end)))
            start = end
        }
        return out
    }

    private static func match(_ regex: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else {
            return nil
        }
        return (1..<m.numberOfRanges).map { idx in
            Range(m.range(at: idx), in: s).map { String(s[$0]) } ?? ""
        }
    }
}
