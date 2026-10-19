import Foundation

/// A manuscript block as the report layer reads it: the report elements
/// (labelled headings, captioned tables, figures, footnote definitions),
/// and every other `MarkdownBlock` passed through unchanged.
public enum ManuscriptBlock: Equatable, Sendable {
    case heading(level: Int, text: String, label: ManuscriptLabel?)
    case table(header: [String], rows: [[String]], caption: String?, label: ManuscriptLabel?)
    case figure(caption: String, path: String, label: ManuscriptLabel?)
    case footnoteDefinition(label: String, text: String)
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

            case .table(let header, let rows, _):
                if i < base.count, let caption = tableCaption(base[i], after: lines) {
                    out.append((.table(header: header, rows: rows,
                                       caption: caption.text, label: caption.label),
                                lines.lowerBound..<base[i].lines.upperBound))
                    i += 1
                } else {
                    out.append((.table(header: header, rows: rows, caption: nil, label: nil), lines))
                }

            case .soloImage(let altText, let path, _):
                out.append((.figure(caption: altText, path: path, label: nil), lines))

            case .paragraph(let paraLines):
                if paraLines.count == 1, let figure = figure(paraLines[0]) {
                    out.append((figure, lines))
                } else if let note = footnoteDefinition(paraLines) {
                    out.append((note, lines))
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
        let trimmed = lines[0].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Table: ") else { return nil }
        let split = ManuscriptAttributes.split(String(trimmed.dropFirst("Table: ".count)))
        return (split.text.trimmingCharacters(in: .whitespaces), split.label)
    }

    // The caption may contain `]` but not `](`, so two images on a line never
    // read as one. The path stops at whitespace.
    private static let imageRegex = try! NSRegularExpression(
        pattern: #"^!\[((?:[^\]]|\](?!\())*)\]\(([^)\s]+)\)$"#)

    private static let footnoteRegex = try! NSRegularExpression(
        pattern: #"^\[\^([A-Za-z0-9_-]+)\]:\s?(.*)$"#)

    /// `![caption](path)` alone on the line, optionally followed by any valid
    /// `{#kind:name}` block. An invalid block stays in the text, so no match.
    private static func figure(_ line: String) -> ManuscriptBlock? {
        let split = ManuscriptAttributes.split(line.trimmingCharacters(in: .whitespaces))
        guard let groups = match(imageRegex, split.text) else { return nil }
        return .figure(caption: groups[0], path: groups[1], label: split.label)
    }

    private static func footnoteDefinition(_ lines: [String]) -> ManuscriptBlock? {
        guard let first = lines.first,
              let groups = match(footnoteRegex, first.trimmingCharacters(in: .whitespaces))
        else { return nil }
        let rest = lines.dropFirst().map { String($0.drop(while: { $0 == " " || $0 == "\t" })) }
        return .footnoteDefinition(label: groups[0],
                                   text: ([groups[1]] + rest).joined(separator: "\n"))
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
