import Foundation
import MaughamCore

/// The report elements' tokens for the prose tokenizer (report foundations
/// plan 3a): tables, figure lines and footnote-definition labels from
/// `ManuscriptBlocks.parse`, and footnote references, citations and
/// cross-references from `ManuscriptInlineScanner.scan`. Both readers are
/// MaughamCore's, the same ones publishing and the index use, so the editor
/// styles exactly what the book will treat as an element.
///
/// Both passes run per blank-line block (one op-log paragraph), behind a cheap
/// substring gate, because the tokenizer runs over the whole document on every
/// keystroke.
enum ReportBlocks {

    // MARK: - Block elements

    /// Claims the table, figure and footnote-definition tokens of one
    /// blank-line `block`. `tableHeader` and `tableBlock` go to `overlays`
    /// (appended after the gap fill); everything else is claimed in the main
    /// stream.
    static func tokenize(
        block: NSRange, in text: NSString,
        into tokens: inout [Token], overlays: inout [Token], claims: inout TokenClaims
    ) {
        guard has("|", in: block, text) || has("![", in: block, text)
                || has("[^", in: block, text) else { return }
        let parsed = ManuscriptBlocks.parse(text.substring(with: block))
        guard parsed.contains(where: { isReportBlock($0.block) }) else { return }
        let lines = lineRanges(of: block, in: text)

        for (element, span) in parsed {
            switch element {
            case .table(_, _, _, let caption, _):
                table(lines: lines, span: span, hasCaption: caption != nil, text: text,
                      into: &tokens, overlays: &overlays, claims: &claims)
            case .figure(let caption, let path, _):
                figure(line: lines[span.lowerBound], caption: caption, path: path, text: text,
                       into: &tokens, claims: &claims)
            case .footnoteDefinition:
                footnoteHead(line: lines[span.lowerBound], text: text,
                             into: &tokens, claims: &claims)
            case .heading, .other:
                break
            }
        }
    }

    private static func isReportBlock(_ block: ManuscriptBlock) -> Bool {
        switch block {
        case .table, .figure, .footnoteDefinition: return true
        case .heading, .other: return false
        }
    }

    /// Pipes and the delimiter row as syntax, header cells as overlays, the
    /// caption line and its `{#…}`, and the whole-table overlay.
    private static func table(
        lines: [NSRange], span: Range<Int>, hasCaption: Bool, text: NSString,
        into tokens: inout [Token], overlays: inout [Token], claims: inout TokenClaims
    ) {
        let header = span.lowerBound
        let delimiter = header + 1
        let rowsEnd = hasCaption ? span.upperBound - 1 : span.upperBound

        // Header row: pipes are syntax; each non-empty cell is bold.
        let headerLine = lines[header]
        let pipes = pipeLocations(in: headerLine, text: text)
        for p in pipes {
            claims.claimIfFree(Token(range: NSRange(location: p, length: 1), kind: .tableSyntax),
                               into: &tokens)
        }
        var cellStart = headerLine.location
        for boundary in pipes + [NSMaxRange(headerLine)] {
            let cell = trimmed(NSRange(location: cellStart, length: boundary - cellStart), in: text)
            if cell.length > 0 { overlays.append(Token(range: cell, kind: .tableHeader)) }
            cellStart = boundary + 1
        }

        // Delimiter row: all syntax.
        let delimiterRow = trimmed(lines[delimiter], in: text)
        claims.claimIfFree(Token(range: delimiterRow, kind: .tableSyntax), into: &tokens)

        // Body rows: only the pipes; cells stay prose.
        for row in (delimiter + 1)..<max(delimiter + 1, rowsEnd) {
            for p in pipeLocations(in: lines[row], text: text) {
                claims.claimIfFree(Token(range: NSRange(location: p, length: 1), kind: .tableSyntax),
                                   into: &tokens)
            }
        }

        // Caption line: `Table: …`, then its label.
        if hasCaption {
            claimLabelled(line: trimmed(lines[span.upperBound - 1], in: text),
                          kind: .tableCaption, text: text, into: &tokens, claims: &claims)
        }

        let first = lines[header].location
        overlays.append(Token(
            range: NSRange(location: first, length: NSMaxRange(lines[span.upperBound - 1]) - first),
            kind: .tableBlock))
    }

    /// `![` and `](path)` as figure syntax, and the trailing `{#…}`. The
    /// caption between stays prose.
    private static func figure(
        line: NSRange, caption: String, path: String, text: NSString,
        into tokens: inout [Token], claims: inout TokenClaims
    ) {
        let content = trimmed(line, in: text)
        let open = NSRange(location: content.location, length: 2)                  // ![
        let closeStart = open.location + 2 + (caption as NSString).length
        let close = NSRange(location: closeStart, length: 3 + (path as NSString).length)  // ](path)
        claims.claimIfFree(Token(range: open, kind: .figureSyntax), into: &tokens)
        claims.claimIfFree(Token(range: close, kind: .figureSyntax), into: &tokens)
        if let label = MarkdownTokenizer.trailingAttributeBlock(in: text, line: content) {
            claims.claimIfFree(Token(range: label, kind: .attributeBlock), into: &tokens)
        }
    }

    /// The `[^label]:` head of a footnote definition.
    private static func footnoteHead(
        line: NSRange, text: NSString, into tokens: inout [Token], claims: inout TokenClaims
    ) {
        let content = trimmed(line, in: text)
        let close = text.range(of: "]:", options: .literal, range: content)
        guard close.location != NSNotFound else { return }
        claims.claimIfFree(
            Token(range: NSRange(location: content.location,
                                 length: NSMaxRange(close) - content.location),
                  kind: .footnoteLabel),
            into: &tokens)
    }

    /// `line` as `kind`, except a valid trailing `{#…}`, which is an
    /// `attributeBlock` (the spaces before it belong to neither).
    private static func claimLabelled(
        line: NSRange, kind: Token.Kind, text: NSString,
        into tokens: inout [Token], claims: inout TokenClaims
    ) {
        guard let label = MarkdownTokenizer.trailingAttributeBlock(in: text, line: line) else {
            claims.claimIfFree(Token(range: line, kind: kind), into: &tokens)
            return
        }
        let head = trimmed(NSRange(location: line.location, length: label.location - line.location),
                           in: text)
        claims.claimIfFree(Token(range: head, kind: kind), into: &tokens)
        claims.claimIfFree(Token(range: label, kind: .attributeBlock), into: &tokens)
    }

    // MARK: - Inline markers

    /// Claims each footnote reference, citation and cross-reference in one
    /// blank-line `block`, with `ManuscriptInlineScanner.scan`'s ranges.
    static func tokenizeInlineMarkers(
        block: NSRange, in text: NSString,
        into tokens: inout [Token], claims: inout TokenClaims
    ) {
        guard has("@", in: block, text) || has("[^", in: block, text) else { return }
        for (marker, range) in ManuscriptInlineScanner.scan(text.substring(with: block)) {
            let kind: Token.Kind
            switch marker {
            case .footnoteRef: kind = .footnoteReference
            case .citation: kind = .citation
            case .crossRef: kind = .crossReference
            }
            claims.claimIfFree(
                Token(range: NSRange(location: block.location + range.location, length: range.length),
                      kind: kind),
                into: &tokens)
        }
    }

    // MARK: - Helpers

    private static func has(_ needle: String, in range: NSRange, _ text: NSString) -> Bool {
        text.range(of: needle, options: .literal, range: range).location != NSNotFound
    }

    /// The `"\n"`-separated lines of `block` (as `ManuscriptBlocks.parse`
    /// counts them), each without its newline, in document coordinates.
    private static func lineRanges(of block: NSRange, in text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = block.location
        let end = NSMaxRange(block)
        var i = start
        while i < end {
            if text.character(at: i) == newline {
                out.append(NSRange(location: start, length: i - start))
                start = i + 1
            }
            i += 1
        }
        out.append(NSRange(location: start, length: end - start))
        return out
    }

    /// The locations of the unescaped `|` in `line`, as
    /// `MarkdownBlockParser.splitTableRow` splits them (`\|` is a literal pipe).
    private static func pipeLocations(in line: NSRange, text: NSString) -> [Int] {
        var out: [Int] = []
        var i = line.location
        let end = NSMaxRange(line)
        while i < end {
            let c = text.character(at: i)
            if c == backslash, i + 1 < end, text.character(at: i + 1) == pipe {
                i += 2
                continue
            }
            if c == pipe { out.append(i) }
            i += 1
        }
        return out
    }

    /// `range` without leading or trailing spaces and tabs.
    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var lo = range.location
        var hi = NSMaxRange(range)
        while lo < hi, isSpace(text.character(at: lo)) { lo += 1 }
        while hi > lo, isSpace(text.character(at: hi - 1)) { hi -= 1 }
        return NSRange(location: lo, length: hi - lo)
    }

    private static func isSpace(_ c: unichar) -> Bool { c == space || c == tab }
}

private let newline = unichar(UInt8(ascii: "\n"))
private let pipe = unichar(UInt8(ascii: "|"))
private let backslash = unichar(UInt8(ascii: "\\"))
private let space = unichar(UInt8(ascii: " "))
private let tab = unichar(UInt8(ascii: "\t"))
